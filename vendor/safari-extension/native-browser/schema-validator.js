// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

// Offline evaluator for the generated schema bundle. No record definitions live here.
(function () {
  "use strict";
  const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
  const keywords = new Set([
    "$schema", "$id", "$ref", "$defs", "title", "description", "x-journal-contract",
    "type", "const", "enum", "oneOf", "anyOf", "allOf", "not", "if", "then", "else",
    "required", "properties", "additionalProperties", "items", "minItems", "maxItems",
    "minLength", "maxLength", "pattern", "minimum", "maximum",
  ]);
  const object = value => value !== null && typeof value === "object" && !Array.isArray(value);
  const equal = (a, b) => {
    if (a === b) return true;
    if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((v, i) => equal(v, b[i]));
    if (object(a) && object(b)) return Object.keys(a).length === Object.keys(b).length && Object.keys(a).every(k => own(b, k) && equal(a[k], b[k]));
    return false;
  };

  function compile(documents) {
    const roots = new Map(documents.map(document => [document.$id, document]));
    const checked = new Set();
    function inspect(schema) {
      if (typeof schema === "boolean" || checked.has(schema)) return;
      if (!object(schema)) throw new Error("invalid contract schema");
      checked.add(schema);
      for (const key of Object.keys(schema)) if (!keywords.has(key)) throw new Error("unsupported contract schema keyword: " + key);
      for (const key of ["$defs", "properties"]) for (const child of Object.values(schema[key] || {})) inspect(child);
      for (const key of ["oneOf", "anyOf", "allOf"]) for (const child of schema[key] || []) inspect(child);
      for (const key of ["not", "if", "then", "else", "items", "additionalProperties"]) if (own(schema, key)) inspect(schema[key]);
    }
    documents.forEach(inspect);
    function resolve(ref, root) {
      const [id, fragment = ""] = ref.split("#");
      const targetRoot = id ? roots.get(id) : root;
      if (!targetRoot || (fragment && !fragment.startsWith("/"))) throw new Error("unresolved offline contract reference");
      let target = targetRoot;
      for (const part of fragment ? fragment.slice(1).split("/") : []) {
        const key = part.replace(/~1/g, "/").replace(/~0/g, "~");
        if (!own(target, key)) throw new Error("unresolved offline contract reference");
        target = target[key];
      }
      return [target, targetRoot];
    }
    // Resolve every reference before validating input; an unused bad branch is still drift.
    function references(schema, root) {
      if (typeof schema === "boolean") return;
      if (schema.$ref) resolve(schema.$ref, root);
      for (const key of ["$defs", "properties"]) for (const child of Object.values(schema[key] || {})) references(child, root);
      for (const key of ["oneOf", "anyOf", "allOf"]) for (const child of schema[key] || []) references(child, root);
      for (const key of ["not", "if", "then", "else", "items", "additionalProperties"]) if (own(schema, key)) references(schema[key], root);
    }
    documents.forEach(root => references(root, root));
    function visit(schema, value, root, path) {
      const fail = keyword => ({keyword, path});
      if (schema === true) return null;
      if (schema === false) return fail("false");
      if (schema.$ref) {
        const [target, targetRoot] = resolve(schema.$ref, root);
        const error = visit(target, value, targetRoot, path);
        if (error) return error;
      }
      if (schema.type) {
        const types = Array.isArray(schema.type) ? schema.type : [schema.type];
        const matches = types.some(type => {
          if (type === "object") return object(value);
          if (type === "array") return Array.isArray(value);
          if (type === "null") return value === null;
          if (type === "integer") return Number.isInteger(value);
          if (type === "number") return typeof value === "number" && Number.isFinite(value);
          if (["boolean", "string"].includes(type)) return typeof value === type;
          throw new Error("unsupported contract schema type");
        });
        if (!matches) return fail("type");
      }
      if (own(schema, "const") && !equal(value, schema.const)) return fail("const");
      if (schema.enum && !schema.enum.some(candidate => equal(candidate, value))) return fail("enum");
      if (typeof value === "number") {
        if (own(schema, "minimum") && value < schema.minimum) return fail("minimum");
        if (own(schema, "maximum") && value > schema.maximum) return fail("maximum");
      }
      if (typeof value === "string") {
        let length = 0;
        for (const _character of value) {
          length++;
          if (own(schema, "maxLength") && length > schema.maxLength) return fail("maxLength");
        }
        if (own(schema, "minLength") && length < schema.minLength) return fail("minLength");
        if (schema.pattern && !new RegExp(schema.pattern, "u").test(value)) return fail("pattern");
      }
      if (Array.isArray(value)) {
        if (own(schema, "minItems") && value.length < schema.minItems) return fail("minItems");
        if (own(schema, "maxItems") && value.length > schema.maxItems) return fail("maxItems");
        if (own(schema, "items")) for (let i = 0; i < value.length; i++) {
          const error = visit(schema.items, value[i], root, path.concat(i));
          if (error) return error;
        }
      }
      if (object(value)) {
        for (const key of schema.required || []) if (!own(value, key)) return {keyword: "required", path: path.concat(key)};
        for (const [key, child] of Object.entries(schema.properties || {})) if (own(value, key)) {
          const error = visit(child, value[key], root, path.concat(key));
          if (error) return error;
        }
        if (own(schema, "additionalProperties")) for (const key of Object.keys(value)) {
          if (own(schema.properties || {}, key)) continue;
          // Never include an untrusted additional-property name in diagnostics.
          const error = visit(schema.additionalProperties, value[key], root, path);
          if (error) return error;
        }
      }
      for (const child of schema.allOf || []) {
        const error = visit(child, value, root, path);
        if (error) return error;
      }
      for (const keyword of ["oneOf", "anyOf"]) if (schema[keyword]) {
        const results = schema[keyword].map(child => visit(child, value, root, path));
        const passes = results.filter(result => result === null).length;
        if ((keyword === "oneOf" && passes !== 1) || (keyword === "anyOf" && passes === 0)) {
          return results.filter(Boolean).sort((a, b) => b.path.length - a.path.length)[0] || fail(keyword);
        }
      }
      if (own(schema, "not") && !visit(schema.not, value, root, path)) return fail("not");
      if (own(schema, "if")) {
        const branch = visit(schema.if, value, root, path) ? schema.else : schema.then;
        if (branch !== undefined) return visit(branch, value, root, path);
      }
      return null;
    }
    return (root, ref, value) => {
      const [schema, resolvedRoot] = resolve(ref, root);
      return visit(schema, value, resolvedRoot, []);
    };
  }
  globalThis.SolstoneNativeBrowserSchemaValidator = {compile};
})();
