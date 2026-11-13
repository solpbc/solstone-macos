// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc
// Generated; regenerate from the catalog. Fluent runtime: see LICENSE.fluent.
(() => {
"use strict";
const types = (() => {
/**
 * The `FluentType` class is the base of Fluent's type system.
 *
 * Fluent types wrap JavaScript values and store additional configuration for
 * them, which can then be used in the `toString` method together with a proper
 * `Intl` formatter.
 */
class FluentType {
    /**
     * Create a `FluentType` instance.
     *
     * @param value The JavaScript value to wrap.
     */
    constructor(value) {
        this.value = value;
    }
    /**
     * Unwrap the raw value stored by this `FluentType`.
     */
    valueOf() {
        return this.value;
    }
}
/**
 * A `FluentType` representing no correct value.
 */
class FluentNone extends FluentType {
    /**
     * Create an instance of `FluentNone` with an optional fallback value.
     * @param value The fallback value of this `FluentNone`.
     */
    constructor(value = "???") {
        super(value);
    }
    /**
     * Format this `FluentNone` to the fallback string.
     */
    toString(scope) {
        return `{${this.value}}`;
    }
}
/**
 * A `FluentType` representing a number.
 *
 * A `FluentNumber` instance stores the number value of the number it
 * represents. It may also store an option bag of options which will be passed
 * to `Intl.NumerFormat` when the `FluentNumber` is formatted to a string.
 */
class FluentNumber extends FluentType {
    /**
     * Create an instance of `FluentNumber` with options to the
     * `Intl.NumberFormat` constructor.
     *
     * @param value The number value of this `FluentNumber`.
     * @param opts Options which will be passed to `Intl.NumberFormat`.
     */
    constructor(value, opts = {}) {
        super(value);
        this.opts = opts;
    }
    /**
     * Format this `FluentNumber` to a string.
     */
    toString(scope) {
        try {
            const nf = scope.memoizeIntlObject(Intl.NumberFormat, this.opts);
            return nf.format(this.value);
        }
        catch (err) {
            scope.reportError(err);
            return this.value.toString(10);
        }
    }
}
/**
 * A `FluentType` representing a date and time.
 *
 * A `FluentDateTime` instance stores the number value of the date it
 * represents, as a numerical timestamp in milliseconds. It may also store an
 * option bag of options which will be passed to `Intl.DateTimeFormat` when the
 * `FluentDateTime` is formatted to a string.
 */
class FluentDateTime extends FluentType {
    /**
     * Create an instance of `FluentDateTime` with options to the
     * `Intl.DateTimeFormat` constructor.
     *
     * @param value The number value of this `FluentDateTime`, in milliseconds.
     * @param opts Options which will be passed to `Intl.DateTimeFormat`.
     */
    constructor(value, opts = {}) {
        super(value);
        this.opts = opts;
    }
    /**
     * Format this `FluentDateTime` to a string.
     */
    toString(scope) {
        try {
            const dtf = scope.memoizeIntlObject(Intl.DateTimeFormat, this.opts);
            return dtf.format(this.value);
        }
        catch (err) {
            scope.reportError(err);
            return new Date(this.value).toISOString();
        }
    }
}
return { FluentType, FluentNone, FluentNumber, FluentDateTime };
})();
const scope = (() => {
class Scope {
    constructor(bundle, errors, args) {
        /**
         * The Set of patterns already encountered during this resolution.
         * Used to detect and prevent cyclic resolutions.
         * @ignore
         */
        this.dirty = new WeakSet();
        /** A dict of parameters passed to a TermReference. */
        this.params = null;
        /**
         * The running count of placeables resolved so far.
         * Used to detect the Billion Laughs and Quadratic Blowup attacks.
         * @ignore
         */
        this.placeables = 0;
        this.bundle = bundle;
        this.errors = errors;
        this.args = args;
    }
    reportError(error) {
        if (!this.errors || !(error instanceof Error)) {
            throw error;
        }
        this.errors.push(error);
    }
    memoizeIntlObject(ctor, opts) {
        let cache = this.bundle._intls.get(ctor);
        if (!cache) {
            cache = {};
            this.bundle._intls.set(ctor, cache);
        }
        let id = JSON.stringify(opts);
        if (!cache[id]) {
            cache[id] = new ctor(this.bundle.locales, opts);
        }
        return cache[id];
    }
}
return { Scope };
})();
const memoizer = (() => {
const cache = new Map();
function getMemoizerForLocale(locales) {
    const stringLocale = Array.isArray(locales) ? locales.join(" ") : locales;
    let memoizer = cache.get(stringLocale);
    if (memoizer === undefined) {
        memoizer = new Map();
        cache.set(stringLocale, memoizer);
    }
    return memoizer;
}
return { getMemoizerForLocale };
})();
const resolver = (() => {
/* global Intl */
/**
 * @overview
 *
 * The role of the Fluent resolver is to format a `Pattern` to an instance of
 * `FluentValue`. For performance reasons, primitive strings are considered
 * such instances, too.
 *
 * Translations can contain references to other messages or variables,
 * conditional logic in form of select expressions, traits which describe their
 * grammatical features, and can use Fluent builtins which make use of the
 * `Intl` formatters to format numbers and dates into the bundle's languages.
 * See the documentation of the Fluent syntax for more information.
 *
 * In case of errors the resolver will try to salvage as much of the
 * translation as possible. In rare situations where the resolver didn't know
 * how to recover from an error it will return an instance of `FluentNone`.
 *
 * All expressions resolve to an instance of `FluentValue`. The caller should
 * use the `toString` method to convert the instance to a native value.
 *
 * Functions in this file pass around an instance of the `Scope` class, which
 * stores the data required for successful resolution and error recovery.
 */
const { FluentType, FluentNone, FluentNumber, FluentDateTime, } = types;
/**
 * The maximum number of placeables which can be expanded in a single call to
 * `formatPattern`. The limit protects against the Billion Laughs and Quadratic
 * Blowup attacks.
 */
const MAX_PLACEABLES = 100;
/** Unicode bidi isolation characters. */
const FSI = "\u2068";
const PDI = "\u2069";
/** Helper: match a variant key to the given selector. */
function match(scope, selector, key) {
    if (key === selector) {
        // Both are strings.
        return true;
    }
    // XXX Consider comparing options too, e.g. minimumFractionDigits.
    if (key instanceof FluentNumber &&
        selector instanceof FluentNumber &&
        key.value === selector.value) {
        return true;
    }
    if (selector instanceof FluentNumber && typeof key === "string") {
        let category = scope
            .memoizeIntlObject(Intl.PluralRules, selector.opts)
            .select(selector.value);
        if (key === category) {
            return true;
        }
    }
    return false;
}
/** Helper: resolve the default variant from a list of variants. */
function getDefault(scope, variants, star) {
    if (variants[star]) {
        return resolvePattern(scope, variants[star].value);
    }
    scope.reportError(new RangeError("No default"));
    return new FluentNone();
}
/** Helper: resolve arguments to a call expression. */
function getArguments(scope, args) {
    const positional = [];
    const named = Object.create(null);
    for (const arg of args) {
        if (arg.type === "narg") {
            named[arg.name] = resolveExpression(scope, arg.value);
        }
        else {
            positional.push(resolveExpression(scope, arg));
        }
    }
    return { positional, named };
}
/** Resolve an expression to a Fluent type. */
function resolveExpression(scope, expr) {
    switch (expr.type) {
        case "str":
            return expr.value;
        case "num":
            return new FluentNumber(expr.value, {
                minimumFractionDigits: expr.precision,
            });
        case "var":
            return resolveVariableReference(scope, expr);
        case "mesg":
            return resolveMessageReference(scope, expr);
        case "term":
            return resolveTermReference(scope, expr);
        case "func":
            return resolveFunctionReference(scope, expr);
        case "select":
            return resolveSelectExpression(scope, expr);
        default:
            return new FluentNone();
    }
}
/** Resolve a reference to a variable. */
function resolveVariableReference(scope, { name }) {
    let arg;
    if (scope.params) {
        // We're inside a TermReference. It's OK to reference undefined parameters.
        if (Object.prototype.hasOwnProperty.call(scope.params, name)) {
            arg = scope.params[name];
        }
        else {
            return new FluentNone(`$${name}`);
        }
    }
    else if (scope.args &&
        Object.prototype.hasOwnProperty.call(scope.args, name)) {
        // We're in the top-level Pattern or inside a MessageReference. Missing
        // variables references produce ReferenceErrors.
        arg = scope.args[name];
    }
    else {
        scope.reportError(new ReferenceError(`Unknown variable: $${name}`));
        return new FluentNone(`$${name}`);
    }
    // Return early if the argument already is an instance of FluentType.
    if (arg instanceof FluentType) {
        return arg;
    }
    // Convert the argument to a Fluent type.
    switch (typeof arg) {
        case "string":
            return arg;
        case "number":
            return new FluentNumber(arg);
        case "object":
            if (arg instanceof Date) {
                return new FluentDateTime(arg.getTime());
            }
        // eslint-disable-next-line no-fallthrough
        default:
            scope.reportError(new TypeError(`Variable type not supported: $${name}, ${typeof arg}`));
            return new FluentNone(`$${name}`);
    }
}
/** Resolve a reference to another message. */
function resolveMessageReference(scope, { name, attr }) {
    const message = scope.bundle._messages.get(name);
    if (!message) {
        scope.reportError(new ReferenceError(`Unknown message: ${name}`));
        return new FluentNone(name);
    }
    if (attr) {
        const attribute = message.attributes[attr];
        if (attribute) {
            return resolvePattern(scope, attribute);
        }
        scope.reportError(new ReferenceError(`Unknown attribute: ${attr}`));
        return new FluentNone(`${name}.${attr}`);
    }
    if (message.value) {
        return resolvePattern(scope, message.value);
    }
    scope.reportError(new ReferenceError(`No value: ${name}`));
    return new FluentNone(name);
}
/** Resolve a call to a Term with key-value arguments. */
function resolveTermReference(scope, { name, attr, args }) {
    const id = `-${name}`;
    const term = scope.bundle._terms.get(id);
    if (!term) {
        scope.reportError(new ReferenceError(`Unknown term: ${id}`));
        return new FluentNone(id);
    }
    if (attr) {
        const attribute = term.attributes[attr];
        if (attribute) {
            // Every TermReference has its own variables.
            scope.params = getArguments(scope, args).named;
            const resolved = resolvePattern(scope, attribute);
            scope.params = null;
            return resolved;
        }
        scope.reportError(new ReferenceError(`Unknown attribute: ${attr}`));
        return new FluentNone(`${id}.${attr}`);
    }
    scope.params = getArguments(scope, args).named;
    const resolved = resolvePattern(scope, term.value);
    scope.params = null;
    return resolved;
}
/** Resolve a call to a Function with positional and key-value arguments. */
function resolveFunctionReference(scope, { name, args }) {
    // Some functions are built-in. Others may be provided by the runtime via
    // the `FluentBundle` constructor.
    let func = scope.bundle._functions[name];
    if (!func) {
        scope.reportError(new ReferenceError(`Unknown function: ${name}()`));
        return new FluentNone(`${name}()`);
    }
    if (typeof func !== "function") {
        scope.reportError(new TypeError(`Function ${name}() is not callable`));
        return new FluentNone(`${name}()`);
    }
    try {
        let resolved = getArguments(scope, args);
        return func(resolved.positional, resolved.named);
    }
    catch (err) {
        scope.reportError(err);
        return new FluentNone(`${name}()`);
    }
}
/** Resolve a select expression to the member object. */
function resolveSelectExpression(scope, { selector, variants, star }) {
    let sel = resolveExpression(scope, selector);
    if (sel instanceof FluentNone) {
        return getDefault(scope, variants, star);
    }
    // Match the selector against keys of each variant, in order.
    for (const variant of variants) {
        const key = resolveExpression(scope, variant.key);
        if (match(scope, sel, key)) {
            return resolvePattern(scope, variant.value);
        }
    }
    return getDefault(scope, variants, star);
}
/** Resolve a pattern (a complex string with placeables). */
function resolveComplexPattern(scope, ptn) {
    if (scope.dirty.has(ptn)) {
        scope.reportError(new RangeError("Cyclic reference"));
        return new FluentNone();
    }
    // Tag the pattern as dirty for the purpose of the current resolution.
    scope.dirty.add(ptn);
    const result = [];
    // Wrap interpolations with Directional Isolate Formatting characters
    // only when the pattern has more than one element.
    const useIsolating = scope.bundle._useIsolating && ptn.length > 1;
    for (const elem of ptn) {
        if (typeof elem === "string") {
            result.push(scope.bundle._transform(elem));
            continue;
        }
        scope.placeables++;
        if (scope.placeables > MAX_PLACEABLES) {
            scope.dirty.delete(ptn);
            // This is a fatal error which causes the resolver to instantly bail out
            // on this pattern. The length check protects against excessive memory
            // usage, and throwing protects against eating up the CPU when long
            // placeables are deeply nested.
            throw new RangeError(`Too many placeables expanded: ${scope.placeables}, ` +
                `max allowed is ${MAX_PLACEABLES}`);
        }
        if (useIsolating) {
            result.push(FSI);
        }
        result.push(resolveExpression(scope, elem).toString(scope));
        if (useIsolating) {
            result.push(PDI);
        }
    }
    scope.dirty.delete(ptn);
    return result.join("");
}
/**
 * Resolve a simple or a complex Pattern to a FluentString
 * (which is really the string primitive).
 */
function resolvePattern(scope, value) {
    // Resolve a simple pattern.
    if (typeof value === "string") {
        return scope.bundle._transform(value);
    }
    return resolveComplexPattern(scope, value);
}
return { resolveComplexPattern };
})();
const builtins = (() => {
/**
 * @overview
 *
 * The FTL resolver ships with a number of functions built-in.
 *
 * Each function take two arguments:
 *   - args - an array of positional args
 *   - opts - an object of key-value args
 *
 * Arguments to functions are guaranteed to already be instances of
 * `FluentValue`.  Functions must return `FluentValues` as well.
 */
const { FluentNone, FluentNumber, FluentDateTime, } = types;
function values(opts, allowed) {
    const unwrapped = Object.create(null);
    for (const [name, opt] of Object.entries(opts)) {
        if (allowed.includes(name)) {
            unwrapped[name] = opt.valueOf();
        }
    }
    return unwrapped;
}
const NUMBER_ALLOWED = [
    "unitDisplay",
    "currencyDisplay",
    "useGrouping",
    "minimumIntegerDigits",
    "minimumFractionDigits",
    "maximumFractionDigits",
    "minimumSignificantDigits",
    "maximumSignificantDigits",
];
/**
 * The implementation of the `NUMBER()` builtin available to translations.
 *
 * Translations may call the `NUMBER()` builtin in order to specify formatting
 * options of a number. For example:
 *
 *     pi = The value of \u03c0 is {NUMBER($pi, maximumFractionDigits: 2)}.
 *
 * The implementation expects an array of `FluentValues` representing the
 * positional arguments, and an object of named `FluentValues` representing the
 * named parameters.
 *
 * The following options are recognized:
 *
 *     unitDisplay
 *     currencyDisplay
 *     useGrouping
 *     minimumIntegerDigits
 *     minimumFractionDigits
 *     maximumFractionDigits
 *     minimumSignificantDigits
 *     maximumSignificantDigits
 *
 * Other options are ignored.
 *
 * @param args The positional arguments passed to this `NUMBER()`.
 * @param opts The named argments passed to this `NUMBER()`.
 */
function NUMBER(args, opts) {
    let arg = args[0];
    if (arg instanceof FluentNone) {
        return new FluentNone(`NUMBER(${arg.valueOf()})`);
    }
    if (arg instanceof FluentNumber) {
        return new FluentNumber(arg.valueOf(), {
            ...arg.opts,
            ...values(opts, NUMBER_ALLOWED),
        });
    }
    if (arg instanceof FluentDateTime) {
        return new FluentNumber(arg.valueOf(), {
            ...values(opts, NUMBER_ALLOWED),
        });
    }
    throw new TypeError("Invalid argument to NUMBER");
}
const DATETIME_ALLOWED = [
    "dateStyle",
    "timeStyle",
    "fractionalSecondDigits",
    "dayPeriod",
    "hour12",
    "weekday",
    "era",
    "year",
    "month",
    "day",
    "hour",
    "minute",
    "second",
    "timeZoneName",
];
/**
 * The implementation of the `DATETIME()` builtin available to translations.
 *
 * Translations may call the `DATETIME()` builtin in order to specify
 * formatting options of a number. For example:
 *
 *     now = It's {DATETIME($today, month: "long")}.
 *
 * The implementation expects an array of `FluentValues` representing the
 * positional arguments, and an object of named `FluentValues` representing the
 * named parameters.
 *
 * The following options are recognized:
 *
 *     dateStyle
 *     timeStyle
 *     fractionalSecondDigits
 *     dayPeriod
 *     hour12
 *     weekday
 *     era
 *     year
 *     month
 *     day
 *     hour
 *     minute
 *     second
 *     timeZoneName
 *
 * Other options are ignored.
 *
 * @param args The positional arguments passed to this `DATETIME()`.
 * @param opts The named argments passed to this `DATETIME()`.
 */
function DATETIME(args, opts) {
    let arg = args[0];
    if (arg instanceof FluentNone) {
        return new FluentNone(`DATETIME(${arg.valueOf()})`);
    }
    if (arg instanceof FluentDateTime) {
        return new FluentDateTime(arg.valueOf(), {
            ...arg.opts,
            ...values(opts, DATETIME_ALLOWED),
        });
    }
    if (arg instanceof FluentNumber) {
        return new FluentDateTime(arg.valueOf(), {
            ...values(opts, DATETIME_ALLOWED),
        });
    }
    throw new TypeError("Invalid argument to DATETIME");
}
return { NUMBER, DATETIME };
})();
const bundle = (() => {
const { resolveComplexPattern } = resolver;
const { Scope } = scope;
const { FluentNone } = types;
const { NUMBER, DATETIME } = builtins;
const { getMemoizerForLocale } = memoizer;
/**
 * Message bundles are single-language stores of translation resources. They are
 * responsible for formatting message values and attributes to strings.
 */
class FluentBundle {
    /**
     * Create an instance of `FluentBundle`.
     *
     * @example
     * ```js
     * let bundle = new FluentBundle(["en-US", "en"]);
     *
     * let bundle = new FluentBundle(locales, {useIsolating: false});
     *
     * let bundle = new FluentBundle(locales, {
     *   useIsolating: true,
     *   functions: {
     *     NODE_ENV: () => process.env.NODE_ENV
     *   }
     * });
     * ```
     *
     * @param locales - Used to instantiate `Intl` formatters used by translations.
     * @param options - Optional configuration for the bundle.
     */
    constructor(locales, { functions, useIsolating = true, transform = (v) => v, } = {}) {
        /** @ignore */
        this._terms = new Map();
        /** @ignore */
        this._messages = new Map();
        this.locales = Array.isArray(locales) ? locales : [locales];
        this._functions = {
            NUMBER,
            DATETIME,
            ...functions,
        };
        this._useIsolating = useIsolating;
        this._transform = transform;
        this._intls = getMemoizerForLocale(locales);
    }
    /**
     * Check if a message is present in the bundle.
     *
     * @param id - The identifier of the message to check.
     */
    hasMessage(id) {
        return this._messages.has(id);
    }
    /**
     * Return a raw unformatted message object from the bundle.
     *
     * Raw messages are `{value, attributes}` shapes containing translation units
     * called `Patterns`. `Patterns` are implementation-specific; they should be
     * treated as black boxes and formatted with `FluentBundle.formatPattern`.
     *
     * @param id - The identifier of the message to check.
     */
    getMessage(id) {
        return this._messages.get(id);
    }
    /**
     * Add a translation resource to the bundle.
     *
     * @example
     * ```js
     * let res = new FluentResource("foo = Foo");
     * bundle.addResource(res);
     * bundle.getMessage("foo");
     * // \u2192 {value: .., attributes: {..}}
     * ```
     *
     * @param res
     * @param options
     */
    addResource(res, { allowOverrides = false, } = {}) {
        const errors = [];
        for (let i = 0; i < res.body.length; i++) {
            let entry = res.body[i];
            if (entry.id.startsWith("-")) {
                // Identifiers starting with a dash (-) define terms. Terms are private
                // and cannot be retrieved from FluentBundle.
                if (allowOverrides === false && this._terms.has(entry.id)) {
                    errors.push(new Error(`Attempt to override an existing term: "${entry.id}"`));
                    continue;
                }
                this._terms.set(entry.id, entry);
            }
            else {
                if (allowOverrides === false && this._messages.has(entry.id)) {
                    errors.push(new Error(`Attempt to override an existing message: "${entry.id}"`));
                    continue;
                }
                this._messages.set(entry.id, entry);
            }
        }
        return errors;
    }
    /**
     * Format a `Pattern` to a string.
     *
     * Format a raw `Pattern` into a string. `args` will be used to resolve
     * references to variables passed as arguments to the translation.
     *
     * In case of errors `formatPattern` will try to salvage as much of the
     * translation as possible and will still return a string. For performance
     * reasons, the encountered errors are not returned but instead are appended
     * to the `errors` array passed as the third argument.
     *
     * If `errors` is omitted, the first encountered error will be thrown.
     *
     * @example
     * ```js
     * let errors = [];
     * bundle.addResource(
     *     new FluentResource("hello = Hello, {$name}!"));
     *
     * let hello = bundle.getMessage("hello");
     * if (hello.value) {
     *     bundle.formatPattern(hello.value, {name: "Jane"}, errors);
     *     // Returns "Hello, Jane!" and `errors` is empty.
     *
     *     bundle.formatPattern(hello.value, undefined, errors);
     *     // Returns "Hello, {$name}!" and `errors` is now:
     *     // [<ReferenceError: Unknown variable: name>]
     * }
     * ```
     */
    formatPattern(pattern, args = null, errors = null) {
        // Resolve a simple pattern without creating a scope. No error handling is
        // required; by definition simple patterns don't have placeables.
        if (typeof pattern === "string") {
            return this._transform(pattern);
        }
        // Resolve a complex pattern.
        let scope = new Scope(this, errors, args);
        try {
            let value = resolveComplexPattern(scope, pattern);
            return value.toString(scope);
        }
        catch (err) {
            if (scope.errors && err instanceof Error) {
                scope.errors.push(err);
                return new FluentNone().toString(scope);
            }
            throw err;
        }
    }
}
return { FluentBundle };
})();
const resource = (() => {
// This regex is used to iterate through the beginnings of messages and terms.
// With the /m flag, the ^ matches at the beginning of every line.
const RE_MESSAGE_START = /^(-?[a-zA-Z][\w-]*) *= */gm;
// Both Attributes and Variants are parsed in while loops. These regexes are
// used to break out of them.
const RE_ATTRIBUTE_START = /\.([a-zA-Z][\w-]*) *= */y;
const RE_VARIANT_START = /\*?\[/y;
const RE_NUMBER_LITERAL = /(-?[0-9]+(?:\.([0-9]+))?)/y;
const RE_IDENTIFIER = /([a-zA-Z][\w-]*)/y;
const RE_REFERENCE = /([$-])?([a-zA-Z][\w-]*)(?:\.([a-zA-Z][\w-]*))?/y;
const RE_FUNCTION_NAME = /^[A-Z][A-Z0-9_-]*$/;
// A "run" is a sequence of text or string literal characters which don't
// require any special handling. For TextElements such special characters are: {
// (starts a placeable), and line breaks which require additional logic to check
// if the next line is indented. For StringLiterals they are: \ (starts an
// escape sequence), " (ends the literal), and line breaks which are not allowed
// in StringLiterals. Note that string runs may be empty; text runs may not.
const RE_TEXT_RUN = /([^{}\n\r]+)/y;
const RE_STRING_RUN = /([^\\"\n\r]*)/y;
// Escape sequences.
const RE_STRING_ESCAPE = /\\([\\"])/y;
const RE_UNICODE_ESCAPE = /\\u([a-fA-F0-9]{4})|\\U([a-fA-F0-9]{6})/y;
// Used for trimming TextElements and indents.
const RE_LEADING_NEWLINES = /^\n+/;
const RE_TRAILING_SPACES = / +$/;
// Used in makeIndent to strip spaces from blank lines and normalize CRLF to LF.
const RE_BLANK_LINES = / *\r?\n/g;
// Used in makeIndent to measure the indentation.
const RE_INDENT = /( *)$/;
// Common tokens.
const TOKEN_BRACE_OPEN = /{\s*/y;
const TOKEN_BRACE_CLOSE = /\s*}/y;
const TOKEN_BRACKET_OPEN = /\[\s*/y;
const TOKEN_BRACKET_CLOSE = /\s*] */y;
const TOKEN_PAREN_OPEN = /\s*\(\s*/y;
const TOKEN_ARROW = /\s*->\s*/y;
const TOKEN_COLON = /\s*:\s*/y;
// Note the optional comma. As a deviation from the Fluent EBNF, the parser
// doesn't enforce commas between call arguments.
const TOKEN_COMMA = /\s*,?\s*/y;
const TOKEN_BLANK = /\s+/y;
/**
 * Fluent Resource is a structure storing parsed localization entries.
 */
class FluentResource {
    constructor(source) {
        this.body = [];
        RE_MESSAGE_START.lastIndex = 0;
        let cursor = 0;
        // Iterate over the beginnings of messages and terms to efficiently skip
        // comments and recover from errors.
        while (true) {
            let next = RE_MESSAGE_START.exec(source);
            if (next === null) {
                break;
            }
            cursor = RE_MESSAGE_START.lastIndex;
            try {
                this.body.push(parseMessage(next[1]));
            }
            catch (err) {
                if (err instanceof SyntaxError) {
                    // Don't report any Fluent syntax errors. Skip directly to the
                    // beginning of the next message or term.
                    continue;
                }
                throw err;
            }
        }
        // The parser implementation is inlined below for performance reasons,
        // as well as for convenience of accessing `source` and `cursor`.
        // The parser focuses on minimizing the number of false negatives at the
        // expense of increasing the risk of false positives. In other words, it
        // aims at parsing valid Fluent messages with a success rate of 100%, but it
        // may also parse a few invalid messages which the reference parser would
        // reject. The parser doesn't perform any validation and may produce entries
        // which wouldn't make sense in the real world. For best results users are
        // advised to validate translations with the fluent-syntax parser
        // pre-runtime.
        // The parser makes an extensive use of sticky regexes which can be anchored
        // to any offset of the source string without slicing it. Errors are thrown
        // to bail out of parsing of ill-formed messages.
        function test(re) {
            re.lastIndex = cursor;
            return re.test(source);
        }
        // Advance the cursor by the char if it matches. May be used as a predicate
        // (was the match found?) or, if errorClass is passed, as an assertion.
        function consumeChar(char, errorClass) {
            if (source[cursor] === char) {
                cursor++;
                return true;
            }
            if (errorClass) {
                throw new errorClass(`Expected ${char}`);
            }
            return false;
        }
        // Advance the cursor by the token if it matches. May be used as a predicate
        // (was the match found?) or, if errorClass is passed, as an assertion.
        function consumeToken(re, errorClass) {
            if (test(re)) {
                cursor = re.lastIndex;
                return true;
            }
            if (errorClass) {
                throw new errorClass(`Expected ${re.toString()}`);
            }
            return false;
        }
        // Execute a regex, advance the cursor, and return all capture groups.
        function match(re) {
            re.lastIndex = cursor;
            let result = re.exec(source);
            if (result === null) {
                throw new SyntaxError(`Expected ${re.toString()}`);
            }
            cursor = re.lastIndex;
            return result;
        }
        // Execute a regex, advance the cursor, and return the capture group.
        function match1(re) {
            return match(re)[1];
        }
        function parseMessage(id) {
            let value = parsePattern();
            let attributes = parseAttributes();
            if (value === null && Object.keys(attributes).length === 0) {
                throw new SyntaxError("Expected message value or attributes");
            }
            return { id, value, attributes };
        }
        function parseAttributes() {
            let attrs = Object.create(null);
            while (test(RE_ATTRIBUTE_START)) {
                let name = match1(RE_ATTRIBUTE_START);
                let value = parsePattern();
                if (value === null) {
                    throw new SyntaxError("Expected attribute value");
                }
                attrs[name] = value;
            }
            return attrs;
        }
        function parsePattern() {
            let first;
            // First try to parse any simple text on the same line as the id.
            if (test(RE_TEXT_RUN)) {
                first = match1(RE_TEXT_RUN);
            }
            // If there's a placeable on the first line, parse a complex pattern.
            if (source[cursor] === "{" || source[cursor] === "}") {
                // Re-use the text parsed above, if possible.
                return parsePatternElements(first ? [first] : [], Infinity);
            }
            // RE_TEXT_VALUE stops at newlines. Only continue parsing the pattern if
            // what comes after the newline is indented.
            let indent = parseIndent();
            if (indent) {
                if (first) {
                    // If there's text on the first line, the blank block is part of the
                    // translation content in its entirety.
                    return parsePatternElements([first, indent], indent.length);
                }
                // Otherwise, we're dealing with a block pattern, i.e. a pattern which
                // starts on a new line. Discrad the leading newlines but keep the
                // inline indent; it will be used by the dedentation logic.
                indent.value = trim(indent.value, RE_LEADING_NEWLINES);
                return parsePatternElements([indent], indent.length);
            }
            if (first) {
                // It was just a simple inline text after all.
                return trim(first, RE_TRAILING_SPACES);
            }
            return null;
        }
        // Parse a complex pattern as an array of elements.
        function parsePatternElements(elements = [], commonIndent) {
            while (true) {
                if (test(RE_TEXT_RUN)) {
                    elements.push(match1(RE_TEXT_RUN));
                    continue;
                }
                if (source[cursor] === "{") {
                    elements.push(parsePlaceable());
                    continue;
                }
                if (source[cursor] === "}") {
                    throw new SyntaxError("Unbalanced closing brace");
                }
                let indent = parseIndent();
                if (indent) {
                    elements.push(indent);
                    commonIndent = Math.min(commonIndent, indent.length);
                    continue;
                }
                break;
            }
            let lastIndex = elements.length - 1;
            let lastElement = elements[lastIndex];
            // Trim the trailing spaces in the last element if it's a TextElement.
            if (typeof lastElement === "string") {
                elements[lastIndex] = trim(lastElement, RE_TRAILING_SPACES);
            }
            let baked = [];
            for (let element of elements) {
                if (element instanceof Indent) {
                    // Dedent indented lines by the maximum common indent.
                    element = element.value.slice(0, element.value.length - commonIndent);
                }
                if (element) {
                    baked.push(element);
                }
            }
            return baked;
        }
        function parsePlaceable() {
            consumeToken(TOKEN_BRACE_OPEN, SyntaxError);
            let selector = parseInlineExpression();
            if (consumeToken(TOKEN_BRACE_CLOSE)) {
                return selector;
            }
            if (consumeToken(TOKEN_ARROW)) {
                let variants = parseVariants();
                consumeToken(TOKEN_BRACE_CLOSE, SyntaxError);
                return {
                    type: "select",
                    selector,
                    ...variants,
                };
            }
            throw new SyntaxError("Unclosed placeable");
        }
        function parseInlineExpression() {
            if (source[cursor] === "{") {
                // It's a nested placeable.
                return parsePlaceable();
            }
            if (test(RE_REFERENCE)) {
                let [, sigil, name, attr = null] = match(RE_REFERENCE);
                if (sigil === "$") {
                    return { type: "var", name };
                }
                if (consumeToken(TOKEN_PAREN_OPEN)) {
                    let args = parseArguments();
                    if (sigil === "-") {
                        // A parameterized term: -term(...).
                        return { type: "term", name, attr, args };
                    }
                    if (RE_FUNCTION_NAME.test(name)) {
                        return { type: "func", name, args };
                    }
                    throw new SyntaxError("Function names must be all upper-case");
                }
                if (sigil === "-") {
                    // A non-parameterized term: -term.
                    return {
                        type: "term",
                        name,
                        attr,
                        args: [],
                    };
                }
                return { type: "mesg", name, attr };
            }
            return parseLiteral();
        }
        function parseArguments() {
            let args = [];
            while (true) {
                switch (source[cursor]) {
                    case ")": // End of the argument list.
                        cursor++;
                        return args;
                    case undefined: // EOF
                        throw new SyntaxError("Unclosed argument list");
                }
                args.push(parseArgument());
                // Commas between arguments are treated as whitespace.
                consumeToken(TOKEN_COMMA);
            }
        }
        function parseArgument() {
            let expr = parseInlineExpression();
            if (expr.type !== "mesg") {
                return expr;
            }
            if (consumeToken(TOKEN_COLON)) {
                // The reference is the beginning of a named argument.
                return {
                    type: "narg",
                    name: expr.name,
                    value: parseLiteral(),
                };
            }
            // It's a regular message reference.
            return expr;
        }
        function parseVariants() {
            let variants = [];
            let count = 0;
            let star;
            while (test(RE_VARIANT_START)) {
                if (consumeChar("*")) {
                    star = count;
                }
                let key = parseVariantKey();
                let value = parsePattern();
                if (value === null) {
                    throw new SyntaxError("Expected variant value");
                }
                variants[count++] = { key, value };
            }
            if (count === 0) {
                return null;
            }
            if (star === undefined) {
                throw new SyntaxError("Expected default variant");
            }
            return { variants, star };
        }
        function parseVariantKey() {
            consumeToken(TOKEN_BRACKET_OPEN, SyntaxError);
            let key;
            if (test(RE_NUMBER_LITERAL)) {
                key = parseNumberLiteral();
            }
            else {
                key = {
                    type: "str",
                    value: match1(RE_IDENTIFIER),
                };
            }
            consumeToken(TOKEN_BRACKET_CLOSE, SyntaxError);
            return key;
        }
        function parseLiteral() {
            if (test(RE_NUMBER_LITERAL)) {
                return parseNumberLiteral();
            }
            if (source[cursor] === '"') {
                return parseStringLiteral();
            }
            throw new SyntaxError("Invalid expression");
        }
        function parseNumberLiteral() {
            let [, value, fraction = ""] = match(RE_NUMBER_LITERAL);
            let precision = fraction.length;
            return {
                type: "num",
                value: parseFloat(value),
                precision,
            };
        }
        function parseStringLiteral() {
            consumeChar('"', SyntaxError);
            let value = "";
            while (true) {
                value += match1(RE_STRING_RUN);
                if (source[cursor] === "\\") {
                    value += parseEscapeSequence();
                    continue;
                }
                if (consumeChar('"')) {
                    return { type: "str", value };
                }
                // We've reached an EOL of EOF.
                throw new SyntaxError("Unclosed string literal");
            }
        }
        // Unescape known escape sequences.
        function parseEscapeSequence() {
            if (test(RE_STRING_ESCAPE)) {
                return match1(RE_STRING_ESCAPE);
            }
            if (test(RE_UNICODE_ESCAPE)) {
                let [, codepoint4, codepoint6] = match(RE_UNICODE_ESCAPE);
                let codepoint = parseInt(codepoint4 || codepoint6, 16);
                return codepoint <= 0xd7ff || 0xe000 <= codepoint
                    ? // It's a Unicode scalar value.
                        String.fromCodePoint(codepoint)
                    : // Lonely surrogates can cause trouble when the parsing result is
                        // saved using UTF-8. Use U+FFFD REPLACEMENT CHARACTER instead.
                        "\ufffd";
            }
            throw new SyntaxError("Unknown escape sequence");
        }
        // Parse blank space. Return it if it looks like indent before a pattern
        // line. Skip it othwerwise.
        function parseIndent() {
            let start = cursor;
            consumeToken(TOKEN_BLANK);
            // Check the first non-blank character after the indent.
            switch (source[cursor]) {
                case ".":
                case "[":
                case "*":
                case "}":
                case undefined: // EOF
                    // A special character. End the Pattern.
                    return false;
                case "{":
                    // Placeables don't require indentation (in EBNF: block-placeable).
                    // Continue the Pattern.
                    return makeIndent(source.slice(start, cursor));
            }
            // If the first character on the line is not one of the special characters
            // listed above, it's a regular text character. Check if there's at least
            // one space of indent before it.
            if (source[cursor - 1] === " ") {
                // It's an indented text character (in EBNF: indented-char). Continue
                // the Pattern.
                return makeIndent(source.slice(start, cursor));
            }
            // A not-indented text character is likely the identifier of the next
            // message. End the Pattern.
            return false;
        }
        // Trim blanks in text according to the given regex.
        function trim(text, re) {
            return text.replace(re, "");
        }
        // Normalize a blank block and extract the indent details.
        function makeIndent(blank) {
            let value = blank.replace(RE_BLANK_LINES, "\n");
            // eslint-disable-next-line @typescript-eslint/no-non-null-assertion
            let length = RE_INDENT.exec(blank)[1].length;
            return new Indent(value, length);
        }
    }
}
class Indent {
    constructor(value, length) {
        this.value = value;
        this.length = length;
    }
}
return { FluentResource };
})();
const { FluentBundle } = bundle;
const { FluentResource } = resource;
const CATALOGS = {
"en-US": "m62726f777365722e61626f75742e626c6f636b = solstone extension { $version } \u00b7 { $os } { $os_version } \u00b7 { $arch }{ \"\\u000a\" }{ $journal }\n\nm62726f777365722e61626f75742e6461797361676f = { $i18nCategory ->\n    [one] { NUMBER($count, useGrouping: 0) } day ago\n   *[other] { NUMBER($count, useGrouping: 0) } days ago\n}\n\nm62726f777365722e61626f75742e657874656e73696f6e76657273696f6e = solstone extension { $value1 }\n\nm62726f777365722e61626f75742e686f75727361676f = { $i18nCategory ->\n    [one] { NUMBER($count, useGrouping: 0) } hour ago\n   *[other] { NUMBER($count, useGrouping: 0) } hours ago\n}\n\nm62726f777365722e61626f75742e6a6f75726e616c756e6b6e6f776e = journal unknown\n\nm62726f777365722e61626f75742e6a7573746e6f77 = just now\n\nm62726f777365722e61626f75742e6c6173747365656e = { \" \" }\u00b7 last seen { $value1 }\n\nm62726f777365722e61626f75742e6c696e6573 = { $own }{ \"\\u000a\" }{ $journal }\n\nm62726f777365722e61626f75742e6d696e7574657361676f = { $i18nCategory ->\n    [one] { NUMBER($count, useGrouping: 0) } minute ago\n   *[other] { NUMBER($count, useGrouping: 0) } minutes ago\n}\n\nm62726f777365722e6272616e642e6e616d65 = solstone\n\nm62726f777365722e6368726f6d652e6164647468697373697465 = add this site\n\nm62726f777365722e6368726f6d652e6469736d697373 = dismiss\n\nm62726f777365722e6368726f6d652e696e796f757262726f77736572 = in your browser\n\nm62726f777365722e6368726f6d652e6974676f6573746f = it goes to\n\nm62726f777365722e636f70792e61636365737364656e69656468656c70_v7361666172692d6465736b746f70 = to include one, set it to Allow in Safari's website settings for solstone.\n\nm62726f777365722e636f70792e61636365737364656e69656468656c70_v7361666172692d6d6f62696c65 = to include one, set it to Allow in Settings, under Apps, Safari, Extensions, solstone.\n\nm62726f777365722e636f70792e6163636573736772616e7465646a6f696e = { $granted }\n\nm62726f777365722e636f70792e6163636573736772616e7465646e6f7465_v7361666172692d6465736b746f70 = a site set to Deny in Safari's website settings stays off.\n\nm62726f777365722e636f70792e6163636573736772616e7465646e6f7465_v7361666172692d6d6f62696c65 = in Settings, under Apps, Safari, Extensions, solstone, a site set to Deny stays off.\n\nm62726f777365722e636f70792e616464626c6f636b656462656c6f77 = Safari won't ask about { $arg1 } while it allows { $under }. to add { $arg3 }, set it to Allow in Safari's website settings.\n\nm62726f777365722e636f70792e61646464656e696564 = permission declined. nothing added.\n\nm62726f777365722e636f70792e6164646564_v6578616374 = { $host } added.\n\nm62726f777365722e636f70792e6164646564_v77686f6c65 = all { $host } sites and pages added.\n\nm62726f777365722e636f70792e61646465646a6f696e6564_v6578616374 = { $host } added.\n\nm62726f777365722e636f70792e61646465646a6f696e6564_v77686f6c65 = all { $host } sites and pages added.\n\nm62726f777365722e636f70792e61646468656c70 = adding bank.com shares every bank.com site and page, like www.bank.com and login.bank.com. to share only part, add that address, like mail.google.com.\n\nm62726f777365722e636f70792e61646468656c706a6f696e6564_v66697265666f78 = a site you allow in Firefox's own settings is on too.\n\nm62726f777365722e636f70792e61646468656c706a6f696e6564_v65646765 = a site you allow in Edge's own settings is on too.\n\nm62726f777365722e636f70792e61646468656c706a6f696e6564_v6368726f6d65 = a site you allow in Chrome's own settings is on too.\n\nm62726f777365722e636f70792e61646468656c706a6f696e6564_v736166617269 = a site you allow in Safari's own settings is on too.\n\nm62726f777365722e636f70792e61646468656c706a6f696e6564_v6f74686572 = a site you allow in your browser's own settings is on too.\n\nm62726f777365722e636f70792e61646468656c70737566666978_v66697265666f78 = a site you allow in Firefox's own settings is added here too.\n\nm62726f777365722e636f70792e61646468656c70737566666978_v65646765 = a site you allow in Edge's own settings is added here too.\n\nm62726f777365722e636f70792e61646468656c70737566666978_v6368726f6d65 = a site you allow in Chrome's own settings is added here too.\n\nm62726f777365722e636f70792e61646468656c70737566666978_v736166617269 = a site you allow in Safari's own settings is added here too.\n\nm62726f777365722e636f70792e61646468656c70737566666978_v6f74686572 = a site you allow in your browser's own settings is added here too.\n\nm62726f777365722e636f70792e6164646e6f746e6f77 = can't add a site right now. the status above says why.\n\nm62726f777365722e636f70792e616c6c6f77696e_v66697265666f78 = allow in Firefox\n\nm62726f777365722e636f70792e616c6c6f77696e_v65646765 = allow in Edge\n\nm62726f777365722e636f70792e616c6c6f77696e_v6368726f6d65 = allow in Chrome\n\nm62726f777365722e636f70792e616c6c6f77696e_v736166617269 = allow in Safari\n\nm62726f777365722e636f70792e616c6c6f77696e_v6f74686572 = allow in your browser\n\nm62726f777365722e636f70792e616c6c6f7773616c6c6f66627574746865 = { $value1 } allows all of { $value2 }, but the solstone extension takes in only the part of it you added. sharing all of it can include messages on mail and chat sites, and words you've typed but haven't sent, and all of it goes into your journal.\n\nm62726f777365722e636f70792e616c6c6f7773657665727977656273697465736f6576657279 = { $value1 } allows every website, so every site is on, except what you leave out.\n\nm62726f777365722e636f70792e616c6c6f77736d6f72656f66736f6d657369746573 = { $value1 } allows more of some sites you added, like { $value2 }, but the solstone extension takes in only the parts of them you added. sharing all of them can include messages on mail and chat sites, and words you've typed but haven't sent, and all of it goes into your journal.\n\nm62726f777365722e636f70792e616c6c6f77736d6f72657468616e796f75727369746573 = { $value1 } allows more than your sites. { $value2 }\n\nm62726f777365722e636f70792e616c6c6f7773746865736f6c73746f6e65657874656e73696f6e6f6e = { $value1 } allows the solstone extension on every website, but only the sites you added are taken in. sharing every site includes messages on mail and chat sites, and words you've typed but haven't sent, and all of it goes into your journal.\n\nm62726f777365722e636f70792e616c6c6f7773746865736f6c73746f6e65657874656e73696f6e6f6e32 = { $value1 } allows the solstone extension on sites you didn't add, like { $value2 }, but only the sites you added are taken in. sharing them can include messages on mail and chat sites, and words you've typed but haven't sent, and all of it goes into your journal.\n\nm62726f777365722e636f70792e616c6c7369746573616e647061676573617265 = all { $value1 } sites and pages are no longer left out.\n\nm62726f777365722e636f70792e616c7265616479616c6c6f7773657665727977656273697465736f = { $value1 } already allows every website, so agreeing shares every site. to choose sites one at a time instead, change that in { $value2 } first.\n\nm62726f777365722e636f70792e6170706c6566746f757461776179 = the solstone app leaves it out too.\n\nm62726f777365722e636f70792e6170706c6566746f757473697465736f6e = kept out of your journal, including this browser window on your screen and activity.\n\nm62726f777365722e636f70792e6170706c6566746f7574756e7265616461626c65 = the solstone extension leaves it out. the solstone app can't read { $value1 }'s page addresses right now, so { $value1 } stays out of what the app takes in from your screen until it can read them.\n\nm62726f777365722e636f70792e6170706f6e6c796c6566746f7574 = left out in the solstone app\n\nm62726f777365722e636f70792e62726f777365726d656e75 = your browser's toolbar or extensions menu\n\nm62726f777365722e636f70792e62726f777365726e616d65_v66697265666f78 = Firefox\n\nm62726f777365722e636f70792e62726f777365726e616d65_v65646765 = Edge\n\nm62726f777365722e636f70792e62726f777365726e616d65_v6368726f6d65 = Chrome\n\nm62726f777365722e636f70792e62726f777365726e616d65_v736166617269 = Safari\n\nm62726f777365722e636f70792e62726f777365726e616d65_v6f74686572 = your browser\n\nm62726f777365722e636f70792e636865636b616761696e = check again\n\nm62726f777365722e636f70792e636865636b696e67_v66697265666f78 = checking Firefox\u2026\n\nm62726f777365722e636f70792e636865636b696e67_v65646765 = checking Edge\u2026\n\nm62726f777365722e636f70792e636865636b696e67_v6368726f6d65 = checking Chrome\u2026\n\nm62726f777365722e636f70792e636865636b696e67_v736166617269 = checking Safari\u2026\n\nm62726f777365722e636f70792e636865636b696e67_v6f74686572 = checking your browser\u2026\n\nm62726f777365722e636f70792e636f756c646e74636865636b_v66697265666f78 = couldn't check what Firefox allows. try again.\n\nm62726f777365722e636f70792e636f756c646e74636865636b_v65646765 = couldn't check what Edge allows. try again.\n\nm62726f777365722e636f70792e636f756c646e74636865636b_v6368726f6d65 = couldn't check what Chrome allows. try again.\n\nm62726f777365722e636f70792e636f756c646e74636865636b_v736166617269 = couldn't check what Safari allows. try again.\n\nm62726f777365722e636f70792e636f756c646e74636865636b_v6f74686572 = couldn't check what your browser allows. try again.\n\nm62726f777365722e636f70792e636f756c646e747374617274 = couldn't start on your sites\n\nm62726f777365722e636f70792e64656e6965646e6f7465_v7361666172692d6465736b746f70 = to include it, set it to Allow in Safari's website settings.\n\nm62726f777365722e636f70792e64656e6965646e6f7465_v7361666172692d6d6f62696c65 = to include it, set it to Allow in Settings, under Apps, Safari, Extensions, solstone.\n\nm62726f777365722e636f70792e64656e6965647469746c65_v66697265666f78 = Firefox doesn't let this extension take in these sites:\n\nm62726f777365722e636f70792e64656e6965647469746c65_v65646765 = Edge doesn't let this extension take in these sites:\n\nm62726f777365722e636f70792e64656e6965647469746c65_v6368726f6d65 = Chrome doesn't let this extension take in these sites:\n\nm62726f777365722e636f70792e64656e6965647469746c65_v736166617269 = Safari is denying these sites, so they aren't taken in:\n\nm62726f777365722e636f70792e64656e6965647469746c65_v6f74686572 = your browser doesn't let this extension take in these sites:\n\nm62726f777365722e636f70792e64656e79696e6773697465_v66697265666f78 = Firefox is denying this site\n\nm62726f777365722e636f70792e64656e79696e6773697465_v65646765 = Edge is denying this site\n\nm62726f777365722e636f70792e64656e79696e6773697465_v6368726f6d65 = Chrome is denying this site\n\nm62726f777365722e636f70792e64656e79696e6773697465_v736166617269 = Safari is denying this site\n\nm62726f777365722e636f70792e64656e79696e6773697465_v6f74686572 = your browser is denying this site\n\nm62726f777365722e636f70792e6465736b746f7061637469766974796f6e = the solstone extension isn't taking in this site. this browser's activity still goes into your journal.\n\nm62726f777365722e636f70792e6465736b746f7073637265656e6f6e = the solstone extension isn't taking in this site. your screen still goes into your journal.\n\nm62726f777365722e636f70792e646973636c6f73757265_v636f6d7075746572 = where it goes: nothing leaves this browser except to the solstone app on this computer. from there it goes into your journal over the link the solstone app already uses.\n\nm62726f777365722e636f70792e646973636c6f73757265_v6970686f6e65 = where it goes: nothing leaves this browser except to the solstone app on this iphone. from there it goes into your journal over the link the solstone app already uses. the solstone extension keeps taking in the sites you allow while the solstone app is closed. what it takes in waits on this iphone and goes into your journal the next time you open the solstone app.\n\nm62726f777365722e636f70792e646973636c6f73757265_v69706164 = where it goes: nothing leaves this browser except to the solstone app on this ipad. from there it goes into your journal over the link the solstone app already uses. the solstone extension keeps taking in the sites you allow while the solstone app is closed. what it takes in waits on this ipad and goes into your journal the next time you open the solstone app.\n\nm62726f777365722e636f70792e646973636c6f737572657061757365_v6465736b746f70 = pause any time in the solstone extension. pausing the solstone app stops this extension too, unless you turn that off in settings. pausing doesn't hold back what's already taken in. if you remove a site, nothing new comes from it; what's already in your journal stays there.\n\nm62726f777365722e636f70792e646973636c6f737572657061757365_v6d6f62696c65 = pause any time in the solstone extension. pausing doesn't hold back what's already taken in. if you remove a site, nothing new comes from it; what's already in your journal stays there.\n\nm62726f777365722e636f70792e646973636c6f7375726570726976617465_v6465736b746f70 = the solstone extension takes in nothing from private windows, even where your browser lets it run there. that covers this extension only.\n\nm62726f777365722e636f70792e646973636c6f7375726570726976617465_v6d6f62696c65 = the solstone extension takes in nothing from private browsing, even where Safari lets it run there. that covers this extension only.\n\nm62726f777365722e636f70792e646973636c6f7375726572657374 = the sites you allow in your browser are the sites the solstone extension takes in, and that can be every site. on those sites, it takes in the page's text and rough layout whenever a tab is open, and all of it goes into your journal:{ \"\\u000a\" }- the text you can see, the text you'd see by scrolling, text in background tabs, some labels pages provide for screen readers and tooltips, and text the page has but doesn't show you{ \"\\u000a\" }- each page's address, without anything after a ? or #, its title, when you were on it, and the sites its links point to{ \"\\u000a\" }- whether the tab was in front, whether its window had focus, whether audio or video was playing, the page's language, which browser it is, and how long the tab has been open{ \"\\u000a\" }- on a mail or chat site, your messages{ \"\\u000a\" }- some words you've typed but haven't sent, and anything a site shows, even something you'd consider secret, like a code in an email{ \"\\u000a\\u000a\" }never pixels. never raw HTML. sites you leave out aren't taken in, but other sites shown inside those pages still are.{ \"\\u000a\\u000a\" }no analytics. no telemetry. no phone home. nobody counted.\n\nm62726f777365722e636f70792e6576657279736974656c6566746f7574 = every site \u00b7 { $value1 } left out\n\nm62726f777365722e636f70792e657874656e73696f6e6c6566746f7574 = the solstone extension leaves it out.\n\nm62726f777365722e636f70792e6661696c616464 = couldn't add the site. try again.\n\nm62726f777365722e636f70792e6661696c6564626f6479_v66697265666f78 = something went wrong turning on every site in Firefox.\n\nm62726f777365722e636f70792e6661696c6564626f6479_v65646765 = something went wrong turning on every site in Edge.\n\nm62726f777365722e636f70792e6661696c6564626f6479_v6368726f6d65 = something went wrong turning on every site in Chrome.\n\nm62726f777365722e636f70792e6661696c6564626f6479_v736166617269 = something went wrong turning on every site in Safari.\n\nm62726f777365722e636f70792e6661696c6564626f6479_v6f74686572 = something went wrong turning on every site in your browser.\n\nm62726f777365722e636f70792e6661696c67656e65726963 = something went wrong. try again.\n\nm62726f777365722e636f70792e6661696c6c6566746f7574 = this site is left out. stop leaving it out first.\n\nm62726f777365722e636f70792e6661696c70616765 = a page from this site couldn't be kept\n\nm62726f777365722e636f70792e6661696c706167657265747279 = a page from this site couldn't be kept. the extension tries again when the page changes.\n\nm62726f777365722e636f70792e6661696c7265737461727473697465 = couldn't start on this site. remove it and add it again.\n\nm62726f777365722e636f70792e6661696c73617665 = couldn't save that. try again.\n\nm62726f777365722e636f70792e6661696c73657475706669727374 = finish setting up first.\n\nm62726f777365722e636f70792e6661696c73697465 = something went wrong on this site\n\nm62726f777365722e636f70792e6661696c7369746566756c6c = no room for more from this site right now\n\nm62726f777365722e636f70792e6669656c646572726f72 = enter a website address, like mail.google.com.\n\nm62726f777365722e636f70792e686f7374616c7265616479 = { $host } is already on your list.\n\nm62726f777365722e636f70792e686f737472656d6f766564 = { $host } removed. nothing new comes from it; what's already in your journal stays there.\n\nm62726f777365722e636f70792e69736c6566746f757473746f706c656176696e67 = { $value1 } is left out. stop leaving it out first.\n\nm62726f777365722e636f70792e69736e6f6c6f6e6765726c6566746f7574 = { $value1 } is no longer left out.\n\nm62726f777365722e636f70792e69736e74616c6c6f77696e67657665727977656273697465 = { $value1 } isn't allowing every website\n\nm62726f777365722e636f70792e6c656176656f757468656c70 = leaving out bank.com leaves out all bank.com sites and pages, like www.bank.com and login.bank.com, even inside another page. other sites shown inside its pages are still shared, unless you leave them out too.\n\nm62726f777365722e636f70792e6c656176656f75746e65656473616363657373 = to leave sites out, allow Accessibility in the solstone app's settings.\n\nm62726f777365722e636f70792e6c656176656f75746e6f7465_v6578616374 = leaving it out covers { $host }. other sites shown inside its pages are still shared.\n\nm62726f777365722e636f70792e6c656176656f75746e6f7465_v77686f6c65 = leaving it out covers all { $host } sites and pages. other sites shown inside them are still shared.\n\nm62726f777365722e636f70792e6c6566746f7574616e6e6f756e63656d656e74_v6578616374 = { $host } left out. other sites shown inside its pages are still shared.\n\nm62726f777365722e636f70792e6c6566746f7574616e6e6f756e63656d656e74_v77686f6c65 = all { $host } sites and pages left out. other sites shown inside them are still shared.\n\nm62726f777365722e636f70792e6c6566746f757473756d6d617279 = { $i18nCategory ->\n    [one] { NUMBER($count, useGrouping: 0) } site left out\n   *[other] { NUMBER($count, useGrouping: 0) } sites left out\n}\n\nm62726f777365722e636f70792e6c696e757863616e747265616368_v636f6d7075746572 = start the solstone app on this computer. if it's already running, { \"solstone-linux doctor\" } says what's wrong.\n\nm62726f777365722e636f70792e6c696e757863616e747265616368_v6970686f6e65 = start the solstone app on this iphone. if it's already running, { \"solstone-linux doctor\" } says what's wrong.\n\nm62726f777365722e636f70792e6c696e757863616e747265616368_v69706164 = start the solstone app on this ipad. if it's already running, { \"solstone-linux doctor\" } says what's wrong.\n\nm62726f777365722e636f70792e6c696e7578696e74616b656f6666 = turn them back on with { $cmd }.\n\nm62726f777365722e636f70792e6c696e75787374657031696e74616b65 = turn them on with { $cmd }.\n\nm62726f777365722e636f70792e6c696e7578757064617465_v636f6d7075746572 = this extension needs a newer version of the solstone app on this computer. run { $cmd } to get it.\n\nm62726f777365722e636f70792e6c696e7578757064617465_v6970686f6e65 = this extension needs a newer version of the solstone app on this iphone. run { $cmd } to get it.\n\nm62726f777365722e636f70792e6c696e7578757064617465_v69706164 = this extension needs a newer version of the solstone app on this ipad. run { $cmd } to get it.\n\nm62726f777365722e636f70792e6e6f77616c6c6f77736576657279776562736974656576657279 = { $value1 } now allows every website. every site is on, except what you leave out.\n\nm62726f777365722e636f70792e6f6e6c797468657369746573616c7265616479616c6c6f7773 = only the sites { $value1 } already allows are on.\n\nm62726f777365722e636f70792e7065726d697373696f6e6465636c696e65646f6e6c797468657369746573 = permission declined. only the sites { $value1 } already allows are on. to add a site, open it, open solstone from { $value2 }, and choose add this site.\n\nm62726f777365722e636f70792e7065726d697373696f6e736368616e676564_v66697265666f78 = Firefox's permissions changed while saving. try again.\n\nm62726f777365722e636f70792e7065726d697373696f6e736368616e676564_v65646765 = Edge's permissions changed while saving. try again.\n\nm62726f777365722e636f70792e7065726d697373696f6e736368616e676564_v6368726f6d65 = Chrome's permissions changed while saving. try again.\n\nm62726f777365722e636f70792e7065726d697373696f6e736368616e676564_v736166617269 = Safari's permissions changed while saving. try again.\n\nm62726f777365722e636f70792e7065726d697373696f6e736368616e676564_v6f74686572 = your browser's permissions changed while saving. try again.\n\nm62726f777365722e636f70792e707269766174656e6f7465_v6465736b746f70 = this extension takes in nothing from private browsing.\n\nm62726f777365722e636f70792e707269766174656e6f7465_v6d6f62696c65 = this extension takes in nothing from private browsing.\n\nm62726f777365722e636f70792e707269766174657374617465_v6465736b746f70 = private window\n\nm62726f777365722e636f70792e707269766174657374617465_v6d6f62696c65 = private browsing\n\nm62726f777365722e636f70792e72657374726963746564_v66697265666f78 = Firefox doesn't let extensions work on this page\n\nm62726f777365722e636f70792e72657374726963746564_v65646765 = Edge doesn't let extensions work on this page\n\nm62726f777365722e636f70792e72657374726963746564_v6368726f6d65 = Chrome doesn't let extensions work on this page\n\nm62726f777365722e636f70792e72657374726963746564_v736166617269 = Safari doesn't let extensions work on this page\n\nm62726f777365722e636f70792e72657374726963746564_v6f74686572 = your browser doesn't let extensions work on this page\n\nm62726f777365722e636f70792e72657475726e6e6f7465 = this page checks again when you come back to it.\n\nm62726f777365722e636f70792e7368617265676f6573696e = { $arg1 } what you share there now goes into your journal.\n\nm62726f777365722e636f70792e7368617265676f6573696e6e6f77 = { $arg1 } what you share there now goes into your journal.\n\nm62726f777365722e636f70792e73686172696e67616c6c636f756e74 = { $i18nCategory ->\n    [one] { NUMBER($count, useGrouping: 0) } site left out\n   *[other] { NUMBER($count, useGrouping: 0) } sites left out\n}\n\nm62726f777365722e636f70792e73686172696e676576657279 = every site\n\nm62726f777365722e636f70792e73686172696e676578636c75646564 = every site \u00b7 { $count } left out\n\nm62726f777365722e636f70792e73686565747469746c65_v6578616374 = add { $host }?\n\nm62726f777365722e636f70792e73686565747469746c65_v77686f6c65 = add all { $host } sites and pages?\n\nm62726f777365722e636f70792e736f776e73657474696e6773646f6e74 = { $value1 }'s own settings don't show the sites you leave out. they're on solstone's own list.\n\nm62726f777365722e636f70792e737465703163616e747265616368_v636f6d7075746572 = the solstone extension works with the solstone app on this computer, and nothing is taken in without it. if the solstone app isn't on this computer yet, get it at { \"solstone.app\" }. this page moves on by itself once the solstone app answers.\n\nm62726f777365722e636f70792e737465703163616e747265616368_v6970686f6e65 = the solstone extension works with the solstone app on this iphone, and nothing is taken in without it. if the solstone app isn't on this iphone yet, get it at { \"solstone.app\" }. this page moves on by itself once the solstone app answers.\n\nm62726f777365722e636f70792e737465703163616e747265616368_v69706164 = the solstone extension works with the solstone app on this ipad, and nothing is taken in without it. if the solstone app isn't on this ipad yet, get it at { \"solstone.app\" }. this page moves on by itself once the solstone app answers.\n\nm62726f777365722e636f70792e7374657031696e74616b656f6666 = turn them on under sources in the solstone app's settings. this page moves on by itself.\n\nm62726f777365722e636f70792e73746570316e6f74706169726564_v636f6d7075746572 = pair the solstone app on this computer with your journal. this page moves on by itself once it is.\n\nm62726f777365722e636f70792e73746570316e6f74706169726564_v6970686f6e65 = pair the solstone app on this iphone with your journal and confirm your journal's mark. this page moves on by itself once you have.\n\nm62726f777365722e636f70792e73746570316e6f74706169726564_v69706164 = pair the solstone app on this ipad with your journal and confirm your journal's mark. this page moves on by itself once you have.\n\nm62726f777365722e636f70792e73746570316f70656e617070_v636f6d7075746572 = the solstone extension works with the solstone app on this computer, and nothing is taken in without it. open the solstone app to go on. this page moves on by itself once it answers.\n\nm62726f777365722e636f70792e73746570316f70656e617070_v6970686f6e65 = the solstone extension works with the solstone app on this iphone, and nothing is taken in without it. the solstone app isn't answering right now. this extension tries again on its own, and this page moves on by itself once it answers.\n\nm62726f777365722e636f70792e73746570316f70656e617070_v69706164 = the solstone extension works with the solstone app on this ipad, and nothing is taken in without it. the solstone app isn't answering right now. this extension tries again on its own, and this page moves on by itself once it answers.\n\nm62726f777365722e636f70792e737465703270656e64696e67 = you'll agree to this once the step above is done.\n\nm62726f777365722e636f70792e7374657033626f6479_v66697265666f78 = Firefox will ask you to allow it.\n\nm62726f777365722e636f70792e7374657033626f6479_v65646765 = Edge will ask you to allow it.\n\nm62726f777365722e636f70792e7374657033626f6479_v6368726f6d65 = Chrome will ask you to allow it.\n\nm62726f777365722e636f70792e7374657033626f6479_v736166617269 = Safari will ask you to allow it.\n\nm62726f777365722e636f70792e7374657033626f6479_v6f74686572 = your browser will ask you to allow it.\n\nm62726f777365722e636f70792e73746570657874656e73696f6e736c656674 = under Extensions on the left, choose solstone.\n\nm62726f777365722e636f70792e73746570666f726f74686572 = set For other websites to Allow.\n\nm62726f777365722e636f70792e737465706f746865727765627369746573 = set For other websites to Allow.\n\nm62726f777365722e636f70792e737465707361666172697765627369746573 = in Safari, choose Safari \u203a Settings, then Websites.\n\nm62726f777365722e636f70792e7374657073657474696e677361707073 = in Settings, open Apps, then Safari, then Extensions, then solstone.\n\nm62726f777365722e636f70792e7374696c6c616c6c6f7773657665727977656273697465 = { $value1 } still allows every website.\n\nm62726f777365722e636f70792e7374696c6c69736e74616c6c6f77696e676576657279 = { $value1 } still isn't allowing every website.\n\nm62726f777365722e636f70792e746865736f6c73746f6e65657874656e73696f6e6c65617665736974 = the solstone extension leaves it out. the solstone app doesn't check { $value1 } windows on your screen.\n\nm62726f777365722e636f70792e7472756e636174696f6e = part of what you shared on this site was too long to keep\n\nm62726f777365722e636f70792e747279616761696e = try again\n\nm62726f777365722e636f70792e756e6b6e6f776e6e6f7465_v7361666172692d6465736b746f70 = if it's set to Deny in Safari's website settings, it isn't taken in.\n\nm62726f777365722e636f70792e756e6b6e6f776e6e6f7465_v7361666172692d6d6f62696c65 = if it's set to Deny in Settings, under Apps, Safari, Extensions, solstone, it isn't taken in.\n\nm62726f777365722e636f70792e756e6b6e6f776e7374617465 = this extension can't reach this page\n\nm62726f777365722e636f70792e7761726d31 = welcome to solstone.\n\nm62726f777365722e636f70792e7761726d32 = the solstone app takes in what you share with it, and all of it goes into your journal.\n\nm62726f777365722e636f70792e7761726d33 = your journal is always private, only yours.\n\nm62726f777365722e657874656e73696f6e2e616464696e6773697465636f766572736576657279 = adding a site covers every site and page under it.\n\nm62726f777365722e657874656e73696f6e2e636c6561726564657874656e73696f6e7373746f72616765 = you cleared this extension's storage, so it's paused, and sites you left out aren't left out any more. when you resume, every site Safari allows goes into your journal.\n\nm62726f777365722e657874656e73696f6e2e636c6561726564657874656e73696f6e7373746f7261676532 = you cleared this extension's storage, so it's paused. when you resume, every site Safari allows goes into your journal, except what you've left out in the solstone app.\n\nm62726f777365722e657874656e73696f6e2e656e74657277656273697465616464726573736c696b65 = enter a website address, like bank.com.\n\nm62726f777365722e657874656e73696f6e2e6576657279736974656f6666657863657074 = every site is off, except sites you added one at a time.\n\nm62726f777365722e657874656e73696f6e2e6576657279736974656f6666696e636c7564696e67 = every site is off, including sites you added one at a time. add a site to share it again.\n\nm62726f777365722e657874656e73696f6e2e657665727977656273697465696e636c7564696e676f6e6573 = every website, including ones you visit later, once your browser allows it. you can leave sites out.\n\nm62726f777365722e657874656e73696f6e2e657874656e73696f6e73627574746f6e73616661726973 = the extensions button in Safari's address bar\n\nm62726f777365722e657874656e73696f6e2e657874656e73696f6e74616b65736e6f7468696e6766726f6d = this extension takes in nothing from private windows.\n\nm62726f777365722e657874656e73696f6e2e657874656e73696f6e74616b65736f6e6c797369746573 = this extension takes in only the sites you added, and all of it goes into your journal.\n\nm62726f777365722e657874656e73696f6e2e6f6e6c797369746573616c6c6f776f70656e = only the sites you allow. open a site, open solstone from your browser's toolbar or extensions menu, and choose add this site.\n\nm62726f777365722e657874656e73696f6e2e6f6e6c797369746573736166617269616c7265616479 = only the sites Safari already allows are on. to share every site:\n\nm62726f777365722e657874656e73696f6e2e73616661726973706167656d656e75 = Safari's page menu\n\nm62726f777365722e657874656e73696f6e2e7361666172697374696c6c69736e74 = Safari still isn't allowing every website. set All Websites (or Other Websites) to Allow.\n\nm62726f777365722e657874656e73696f6e2e7361666172697374696c6c69736e7432 = Safari still isn't allowing every website. set For other websites to Allow.\n\nm62726f777365722e657874656e73696f6e2e736574616c6c77656273697465736f74686572 = set All Websites (or Other Websites) to Allow.\n\nm62726f777365722e657874656e73696f6e2e7368617265616c6c = share all of it\n\nm62726f777365722e657874656e73696f6e2e73686172657468656d746f6f = share them too\n\nm62726f777365722e657874656e73696f6e2e73686172696e67657665727973697465696e636c75646573 = sharing every site includes messages on mail and chat sites, and words you've typed but haven't sent, and all of it goes into your journal.\n\nm62726f777365722e657874656e73696f6e2e7369746573657464656e797468657265 = a site set to Deny there stays off.\n\nm62726f777365722e657874656e73696f6e2e736f6c73746f6e65657874656e73696f6e6c65617665736f7574 = the solstone extension leaves it out. the solstone app can't leave websites out until it has Accessibility.\n\nm62726f777365722e657874656e73696f6e2e73746f7073686172696e67657665727973697465 = stop sharing every site\n\nm62726f777365722e657874656e73696f6e2e73746f7073686172696e6765766572797369746532 = to stop sharing every site, set All Websites (or Other Websites) to Ask in Settings, under Apps, Safari, Extensions, solstone.\n\nm62726f777365722e657874656e73696f6e2e73746f7073686172696e6765766572797369746533 = to stop sharing every site, set For other websites to Ask in Safari's website settings.\n\nm62726f777365722e6661696c7572652e726177 = something went wrong: { $raw }\n\nm62726f777365722e6c6162656c732e6f6e6e6f77 = on now\n\nm62726f777365722e6c6162656c732e6f70656e73657474696e6773 = open settings\n\nm62726f777365722e6c6162656c732e7570646174656e6f77 = update now\n\nm62726f777365722e6d616e69666573742e6465736372697074696f6e = on sites you allow, the solstone extension takes in page text, addresses and rough layout, and all of it goes into your journal.\n\nm62726f777365722e6d616e69666573742e7361666172696465736372697074696f6e = on sites you allow, it takes in page text, addresses and rough layout, and all of it goes into your journal.\n\nm62726f777365722e6f7074696f6e732e6164646173697465 = add a site\n\nm62726f777365722e6f7074696f6e732e61646473697465736f6e656174 = add sites one at a time\n\nm62726f777365722e6f7074696f6e732e616772656561646473697465736f6e65 = agree and add sites one at a time\n\nm62726f777365722e6f7074696f6e732e6167726565676f6f6e = agree and go on\n\nm62726f777365722e6f7074696f6e732e61677265657368617265657665727973697465 = agree and share every site\n\nm62726f777365722e6f7074696f6e732e63686f6f73656669727374 = choose your first site\n\nm62726f777365722e6f7074696f6e732e646f63756d656e747469746c65 = solstone settings\n\nm62726f777365722e6f7074696f6e732e6b6565706d797369746573 = keep my sites\n\nm62726f777365722e6f7074696f6e732e6c656176656f7574 = leave out\n\nm62726f777365722e6f7074696f6e732e6c656176656f75746173697465 = leave out a site\n\nm62726f777365722e6f7074696f6e732e6c656176656f7574706c616365686f6c646572 = bank.com\n\nm62726f777365722e6f7074696f6e732e6c6f6f6b696e67666f72617070_v636f6d7075746572 = looking for the solstone app on this computer\u2026\n\nm62726f777365722e6f7074696f6e732e6c6f6f6b696e67666f72617070_v6970686f6e65 = looking for the solstone app on this iphone\u2026\n\nm62726f777365722e6f7074696f6e732e6c6f6f6b696e67666f72617070_v69706164 = looking for the solstone app on this ipad\u2026\n\nm62726f777365722e6f7074696f6e732e6d6f62696c65706c616365686f6c646572 = eff.org\n\nm62726f777365722e6f7074696f6e732e7061757365 = pause\n\nm62726f777365722e6f7074696f6e732e706175736568656164696e67 = pause with the solstone app\n\nm62726f777365722e6f7074696f6e732e706175736568656c70 = on: when the solstone app on this computer pauses, so does this extension. off: when you pause the solstone app, this extension keeps taking in your shared sites, and all of it goes into your journal.\n\nm62726f777365722e6f7074696f6e732e70617573656c6162656c = pause this extension when the solstone app pauses\n\nm62726f777365722e6f7074696f6e732e706c616365686f6c646572 = mail.google.com\n\nm62726f777365722e6f7074696f6e732e72656164616761696e = read it again\n\nm62726f777365722e6f7074696f6e732e72656d6f7665 = remove\n\nm62726f777365722e6f7074696f6e732e7368617265657665727973697465 = share every site\n\nm62726f777365722e6f7074696f6e732e73697465726f7761726961_v72656d6f7665 = remove { $host }\n\nm62726f777365722e6f7074696f6e732e73697465726f7761726961_v696e636c756465 = include { $host } again\n\nm62726f777365722e6f7074696f6e732e73746f706c656176696e676f7574 = stop leaving out\n\nm62726f777365722e6f7074696f6e732e74616b6573696e = what the solstone extension takes in\n\nm62726f777365722e6f7074696f6e732e76657273696f6e = v{ $version }\n\nm62726f777365722e6f7074696f6e732e77686174796f757368617265 = what you share\n\nm62726f777365722e6f7074696f6e732e77686963687369746573646f77616e74 = which sites do you want in your journal?\n\nm62726f777365722e6f7074696f6e732e796f75727369746573 = your sites\n\nm62726f777365722e706167652e6d61726b65727374617465_v6f6e = on\n\nm62726f777365722e706167652e6d61726b65727374617465_v706175736564 = paused\n\nm62726f777365722e706f7075702e61626f7574 = about\n\nm62726f777365722e706f7075702e6164646564 = added\n\nm62726f777365722e706f7075702e616464656469646c65 = added. open or reload a tab\n\nm62726f777365722e706f7075702e617474656e74696f6e68656164696e67 = sites that need attention\n\nm62726f777365722e706f7075702e63616e74616464 = this page can't be added\n\nm62726f777365722e706f7075702e636f7079627574746f6e_v636f7079 = copy\n\nm62726f777365722e706f7075702e636f7079627574746f6e_v636f70696564 = copied\n\nm62726f777365722e706f7075702e636f70796661696c6564 = couldn't copy. select the text and copy it.\n\nm62726f777365722e706f7075702e696e636c75646564 = included\n\nm62726f777365722e706f7075702e6c656176656f757474686973 = leave this site out\n\nm62726f777365722e706f7075702e6c6566746f7574 = left out\n\nm62726f777365722e706f7075702e6d616e616765 = manage \u203a\n\nm62726f777365722e706f7075702e6e6f746164646564 = not added\n\nm62726f777365722e706f7075702e6e6f7474616b656e696e = not taken in right now\n\nm62726f777365722e706f7075702e7061757365616c6c_v72756e6e696e67 = pause all\n\nm62726f777365722e706f7075702e7061757365616c6c_v706175736564 = resume\n\nm62726f777365722e706f7075702e72656c6f6164746162 = reload this tab to begin\n\nm62726f777365722e706f7075702e72656d6f7665686f7374 = remove { $arg1 }\n\nm62726f777365722e706f7075702e72656d6f766574686973 = remove this site\n\nm62726f777365722e706f7075702e73657474696e6773 = settings \u203a\n\nm62726f777365722e706f7075702e73686172696e67 = sharing\n\nm62726f777365722e706f7075702e73697465636f756e74616c6c6f6e = { $i18nCategory ->\n    [one] { NUMBER($count, useGrouping: 0) } site, all on\n   *[other] { NUMBER($count, useGrouping: 0) } sites, all on\n}\n\nm62726f777365722e706f7075702e73697465636f756e74616c6c706175736564 = { $i18nCategory ->\n    [one] { NUMBER($count, useGrouping: 0) } site, all paused\n   *[other] { NUMBER($count, useGrouping: 0) } sites, all paused\n}\n\nm62726f777365722e706f7075702e73697465636f756e746d69786564 = { $i18nCategory ->\n    [one] { NUMBER($count, useGrouping: 0) } site, { NUMBER($on, useGrouping: 0) } on\n   *[other] { NUMBER($count, useGrouping: 0) } sites, { NUMBER($on, useGrouping: 0) } on\n}\n\nm62726f777365722e706f7075702e73697465636f756e746f6e6c79 = { $i18nCategory ->\n    [one] { NUMBER($count, useGrouping: 0) } site\n   *[other] { NUMBER($count, useGrouping: 0) } sites\n}\n\nm62726f777365722e706f7075702e73746f706c656176696e67686f73746f7574 = stop leaving { $value1 } out\n\nm62726f777365722e706f7075702e73746f706c656176696e67736974656f7574 = stop leaving this site out\n\nm62726f777365722e706f7075702e7468697370616765 = this page\n\nm62726f777365722e706f7075702e7768617474616b6573 = what it takes in\n\nm62726f777365722e7374617475732e617070706175736564686561646c696e65_v6465736b746f70 = the solstone app is paused\n\nm62726f777365722e7374617475732e617070706175736564686561646c696e65_v6d6f62696c65 = Safari is paused in the solstone app\n\nm62726f777365722e7374617475732e6170707061757365646e6f7465_v636f6d7075746572 = the solstone app is paused on this computer\n\nm62726f777365722e7374617475732e6170707061757365646e6f7465_v6970686f6e65 = the solstone app is paused on this iphone\n\nm62726f777365722e7374617475732e6170707061757365646e6f7465_v69706164 = the solstone app is paused on this ipad\n\nm62726f777365722e7374617475732e617070706175736564726561736f6e_v6465736b746f70 = pausing doesn't hold back what's already taken in. resume from the solstone app.\n\nm62726f777365722e7374617475732e617070706175736564726561736f6e_v6d6f62696c65 = pausing doesn't hold back what's already taken in. resume Safari in the solstone app.\n\nm62726f777365722e7374617475732e63616e747265616368 = can't reach the solstone app\n\nm62726f777365722e7374617475732e63616e747265616368616e73776572696e67_v636f6d7075746572 = the solstone app on this computer isn't answering. open it to go on.\n\nm62726f777365722e7374617475732e63616e747265616368616e73776572696e67_v6970686f6e65 = the solstone app on this iphone isn't answering right now. this extension tries again on its own.\n\nm62726f777365722e7374617475732e63616e747265616368616e73776572696e67_v69706164 = the solstone app on this ipad isn't answering right now. this extension tries again on its own.\n\nm62726f777365722e7374617475732e63616e747265616368676574617070_v636f6d7075746572 = the solstone extension works with the solstone app on this computer. if the solstone app isn't on this computer yet, get it at { \"solstone.app\" }.\n\nm62726f777365722e7374617475732e63616e747265616368676574617070_v6970686f6e65 = the solstone extension works with the solstone app on this iphone. if the solstone app isn't on this iphone yet, get it at { \"solstone.app\" }.\n\nm62726f777365722e7374617475732e63616e747265616368676574617070_v69706164 = the solstone extension works with the solstone app on this ipad. if the solstone app isn't on this ipad yet, get it at { \"solstone.app\" }.\n\nm62726f777365722e7374617475732e63616e74726561636872656f70656e_v636f6d7075746572 = open the solstone app on this computer. if it's already open, look under sources in its settings.\n\nm62726f777365722e7374617475732e63616e74726561636872656f70656e_v6970686f6e65 = the solstone app on this iphone isn't answering right now. this extension tries again on its own.\n\nm62726f777365722e7374617475732e63616e74726561636872656f70656e_v69706164 = the solstone app on this ipad isn't answering right now. this extension tries again on its own.\n\nm62726f777365722e7374617475732e6368616e67696e677369746573 = changing your sites\n\nm62726f777365722e7374617475732e636f6e6e656374696e67 = connecting to the solstone app\n\nm62726f777365722e7374617475732e66696e6973687365747570 = finish setting up\n\nm62726f777365722e7374617475732e666f756e64736f6c73746f6e65617070 = found the solstone app\n\nm62726f777365722e7374617475732e666f756e64736f6c73746f6e6561707073 = found the solstone app. it's paused right now.\n\nm62726f777365722e7374617475732e676574617070 = get the solstone app\n\nm62726f777365722e7374617475732e69636f6e7469746c65 = { $headline }\n\nm62726f777365722e7374617475732e69646c65726561736f6e_v73656c6563746564 = none of your sites are open right now.\n\nm62726f777365722e7374617475732e69646c65726561736f6e_v616c6c = none of the websites you share are open right now.\n\nm62726f777365722e7374617475732e696e74616b6568656c64_v636f6d7075746572 = the solstone app on this computer isn't taking in new pages right now.\n\nm62726f777365722e7374617475732e696e74616b6568656c64_v6970686f6e65 = the solstone app on this iphone isn't taking in new pages right now.\n\nm62726f777365722e7374617475732e696e74616b6568656c64_v69706164 = the solstone app on this ipad isn't taking in new pages right now.\n\nm62726f777365722e7374617475732e6b657074666f726e6f77_v636f6d7075746572 = kept on this computer for now\n\nm62726f777365722e7374617475732e6b657074666f726e6f77_v6970686f6e65 = kept on this iphone for now\n\nm62726f777365722e7374617475732e6b657074666f726e6f77_v69706164 = kept on this ipad for now\n\nm62726f777365722e7374617475732e6b657074666f726e6f77726561736f6e_v636f6d7075746572 = what you share from this browser is kept on this computer for now. the solstone app has the details.\n\nm62726f777365722e7374617475732e6b657074666f726e6f77726561736f6e_v6970686f6e65 = what you share from this browser is kept on this iphone for now. the solstone app has the details.\n\nm62726f777365722e7374617475732e6b657074666f726e6f77726561736f6e_v69706164 = what you share from this browser is kept on this ipad for now. the solstone app has the details.\n\nm62726f777365722e7374617475732e6b65707477616974696e67_v636f6d7075746572 = kept on this computer, waiting to go into your journal\n\nm62726f777365722e7374617475732e6b65707477616974696e67_v6970686f6e65 = kept on this iphone, waiting to go into your journal\n\nm62726f777365722e7374617475732e6b65707477616974696e67_v69706164 = kept on this ipad, waiting to go into your journal\n\nm62726f777365722e7374617475732e6c6173747061676573 = the last pages reached your journal\n\nm62726f777365722e7374617475732e6c6f737462726f7773657273 = part of what you shared from your browsers couldn't be kept, so it won't go into your journal. the solstone app has the details.\n\nm62726f777365722e7374617475732e6c6f737474686973 = part of what you shared from this browser couldn't be kept, so it won't go into your journal.\n\nm62726f777365722e7374617475732e6e6f726f6f6d = no room for more right now\n\nm62726f777365722e7374617475732e6e6f7369746573 = no sites yet\n\nm62726f777365722e7374617475732e6e6f7468696e6766726f6d62726f77736572 = nothing new is taken in from this browser\n\nm62726f777365722e7374617475732e6e6f7468696e676e6577 = nothing new is taken in\n\nm62726f777365722e7374617475732e6e6f7468696e6772696768746e6f77 = nothing new is taken in right now\n\nm62726f777365722e7374617475732e6e6f7468696e6777616974696e67 = nothing waiting to go into your journal\n\nm62726f777365722e7374617475732e6e6f74706169726564_v636f6d7075746572 = pair the solstone app on this computer with your journal, then come back.\n\nm62726f777365722e7374617475732e6e6f74706169726564_v6970686f6e65 = pair the solstone app on this iphone with your journal and confirm your journal's mark, then come back.\n\nm62726f777365722e7374617475732e6e6f74706169726564_v69706164 = pair the solstone app on this ipad with your journal and confirm your journal's mark, then come back.\n\nm62726f777365722e7374617475732e6e6f74706169726564686561646c696e65 = the solstone app isn't paired yet\n\nm62726f777365722e7374617475732e6e6f747265616368696e67 = not reaching your journal\n\nm62726f777365722e7374617475732e6e6f776f7264796574 = no word yet on whether it's reaching your journal\n\nm62726f777365722e7374617475732e6f70656e616e64616464 = open a site you want to share and choose add this site.\n\nm62726f777365722e7374617475732e70616765736f6666 = browser pages are off in the solstone app\n\nm62726f777365722e7374617475732e70617573656468657265 = paused in this browser\n\nm62726f777365722e7374617475732e7061757365646f65736e74686f6c64 = pausing doesn't hold back what's already taken in.\n\nm62726f777365722e7374617475732e7072657373757265 = what you shared from this browser is waiting for the solstone app to accept it. new pages are taken in again once there's room.\n\nm62726f777365722e7374617475732e7265616368696e67 = reaching your journal\n\nm62726f777365722e7374617475732e726561647468656e63686f6f7365 = read what the solstone extension takes in, then choose your first site.\n\nm62726f777365722e7374617475732e73697465736e656564617474656e74696f6e = { $i18nCategory ->\n    [one] { NUMBER($count, useGrouping: 0) } site needs attention\n   *[other] { NUMBER($count, useGrouping: 0) } sites need attention\n}\n\nm62726f777365722e7374617475732e736f6d65636f756c646e74 = some pages couldn't be kept\n\nm62726f777365722e7374617475732e73746f706c656176696e67686f73746f7574 = stop leaving { $value1 } out\n\nm62726f777365722e7374617475732e73746f726566756c6c_v636f6d7075746572 = the room on this computer for what you share from your browsers is full. new pages are taken in again once there's room. the solstone app has the details.\n\nm62726f777365722e7374617475732e73746f726566756c6c_v6970686f6e65 = the room on this iphone for Safari pages is full. open the solstone app to make room.\n\nm62726f777365722e7374617475732e73746f726566756c6c_v69706164 = the room on this ipad for Safari pages is full. open the solstone app to make room.\n\nm62726f777365722e7374617475732e7475726e70616765736f6e = turn browser pages back on under sources in the solstone app's settings.\n\nm62726f777365722e7374617475732e756e617661696c61626c65 = status unavailable\n\nm62726f777365722e7374617475732e756e617661696c61626c65726561736f6e = the solstone extension can't show its status right now.\n\nm62726f777365722e7374617475732e756e74696c616e7377657273 = nothing is taken in until it answers\n\nm62726f777365722e7374617475732e756e74696c706169726564 = nothing is taken in until it is\n\nm62726f777365722e7374617475732e756e74696c726f6f6d = nothing new is taken in until there's room\n\nm62726f777365722e7374617475732e756e74696c7361766564 = nothing new is taken in until this is saved\n\nm62726f777365722e7374617475732e756e74696c75706461746564 = nothing new is taken in until it's updated\n\nm62726f777365722e7374617475732e756e74696c796f75616464 = nothing is taken in until you add a site\n\nm62726f777365722e7374617475732e756e74696c796f75646f = nothing is taken in until you do\n\nm62726f777365722e7374617475732e757064617465617070_v636f6d7075746572 = this extension needs a newer version of the solstone app on this computer. look under updates in the solstone app's settings.\n\nm62726f777365722e7374617475732e757064617465617070_v6970686f6e65 = update the solstone app on this iphone.\n\nm62726f777365722e7374617475732e757064617465617070_v69706164 = update the solstone app on this ipad.\n\nm62726f777365722e7374617475732e757064617465617070686561646c696e65 = update the solstone app\n\nm62726f777365722e7374617475732e757064617465636865636b696e67_v636f6d7075746572 = the solstone app on this computer needs a newer version of this extension. { $browser } is checking for it now.\n\nm62726f777365722e7374617475732e757064617465636865636b696e67_v6970686f6e65 = the solstone app on this iphone needs a newer version of this extension. { $browser } is checking for it now.\n\nm62726f777365722e7374617475732e757064617465636865636b696e67_v69706164 = the solstone app on this ipad needs a newer version of this extension. { $browser } is checking for it now.\n\nm62726f777365722e7374617475732e757064617465657874656e73696f6e = update the solstone extension\n\nm62726f777365722e7374617475732e75706461746566697265666f786d616e75616c_v636f6d7075746572 = the solstone app on this computer needs a newer version of this extension. in Firefox, open Add-ons and themes, then choose Check for Updates from the gear menu.\n\nm62726f777365722e7374617475732e75706461746566697265666f786d616e75616c_v6970686f6e65 = the solstone app on this iphone needs a newer version of this extension. in Firefox, open Add-ons and themes, then choose Check for Updates from the gear menu.\n\nm62726f777365722e7374617475732e75706461746566697265666f786d616e75616c_v69706164 = the solstone app on this ipad needs a newer version of this extension. in Firefox, open Add-ons and themes, then choose Check for Updates from the gear menu.\n\nm62726f777365722e7374617475732e75706461746570656e64696e67_v636f6d7075746572 = the solstone app on this computer needs a newer version of this extension. { $browser } hasn't found it yet; it checks again on its own.\n\nm62726f777365722e7374617475732e75706461746570656e64696e67_v6970686f6e65 = the solstone app on this iphone needs a newer version of this extension. { $browser } hasn't found it yet; it checks again on its own.\n\nm62726f777365722e7374617475732e75706461746570656e64696e67_v69706164 = the solstone app on this ipad needs a newer version of this extension. { $browser } hasn't found it yet; it checks again on its own.\n\nm62726f777365722e7374617475732e7570646174657265616479 = the update is ready.\n\nm62726f777365722e7374617475732e7570646174657361666172696d616e75616c_v636f6d7075746572 = the solstone app on this computer needs a newer version of this extension. in Safari it comes with the solstone app, so update the solstone app.\n\nm62726f777365722e7374617475732e7570646174657361666172696d616e75616c_v6970686f6e65 = the solstone app on this iphone needs a newer version of this extension. in Safari it comes with the solstone app, so update the solstone app.\n\nm62726f777365722e7374617475732e7570646174657361666172696d616e75616c_v69706164 = the solstone app on this ipad needs a newer version of this extension. in Safari it comes with the solstone app, so update the solstone app.\n\nm62726f777365722e7374617475732e7761697465647765656b_v636f6d7075746572 = some pages from your browsers have waited more than a week to go into your journal. they're still kept on this computer. the solstone app has the details.\n\nm62726f777365722e7374617475732e7761697465647765656b_v6970686f6e65 = some pages from Safari have waited more than a week to go into your journal. they're still kept on this iphone. open the solstone app and they go into your journal.\n\nm62726f777365722e7374617475732e7761697465647765656b_v69706164 = some pages from Safari have waited more than a week to go into your journal. they're still kept on this ipad. open the solstone app and they go into your journal.\n\nm62726f777365722e7374617475732e7761697465647765656b686561646c696e65 = some pages have waited more than a week\n\n",
};
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc


function cardinal(val) { return { type: "cardinal", value: val }; }
function integer(val) { return { type: "integer", value: val }; }

const LOCALES = {
  "en-US": { bundleLocale: "en-US", cardinal: "en" },
};

const CATEGORIES = {
  "en": (n) => (n == 1) ? "one" : "other",
};

const MESSAGES = {
  "browser.about.block": {
    resourceKey: "m62726f777365722e61626f75742e626c6f636b",
    formatIntent: "text",
    arguments: [
      { name: "version", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "os", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "os_version", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "arch", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "journal", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.about.daysago": {
    resourceKey: "m62726f777365722e61626f75742e6461797361676f",
    formatIntent: "cardinal",
    selectorVar: "count",
    arguments: [
      { name: "count", type: "cardinal", min: 0, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.about.extensionversion": {
    resourceKey: "m62726f777365722e61626f75742e657874656e73696f6e76657273696f6e",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.about.hoursago": {
    resourceKey: "m62726f777365722e61626f75742e686f75727361676f",
    formatIntent: "cardinal",
    selectorVar: "count",
    arguments: [
      { name: "count", type: "cardinal", min: 0, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.about.journalunknown": {
    resourceKey: "m62726f777365722e61626f75742e6a6f75726e616c756e6b6e6f776e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.about.justnow": {
    resourceKey: "m62726f777365722e61626f75742e6a7573746e6f77",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.about.lastseen": {
    resourceKey: "m62726f777365722e61626f75742e6c6173747365656e",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.about.lines": {
    resourceKey: "m62726f777365722e61626f75742e6c696e6573",
    formatIntent: "text",
    arguments: [
      { name: "own", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "journal", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.about.minutesago": {
    resourceKey: "m62726f777365722e61626f75742e6d696e7574657361676f",
    formatIntent: "cardinal",
    selectorVar: "count",
    arguments: [
      { name: "count", type: "cardinal", min: 0, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.brand.name": {
    resourceKey: "m62726f777365722e6272616e642e6e616d65",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.chrome.addthissite": {
    resourceKey: "m62726f777365722e6368726f6d652e6164647468697373697465",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.chrome.dismiss": {
    resourceKey: "m62726f777365722e6368726f6d652e6469736d697373",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.chrome.inyourbrowser": {
    resourceKey: "m62726f777365722e6368726f6d652e696e796f757262726f77736572",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.chrome.itgoesto": {
    resourceKey: "m62726f777365722e6368726f6d652e6974676f6573746f",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.accessdeniedhelp": {
    resourceKey: "m62726f777365722e636f70792e61636365737364656e69656468656c70",
    formatIntent: "enum",
    selectorVar: "surface",
    enumValues: ["safari-desktop", "safari-mobile"],
    enumDefault: "safari-desktop",
    variantKeys: {
      "safari-desktop": "m62726f777365722e636f70792e61636365737364656e69656468656c70_v7361666172692d6465736b746f70",
      "safari-mobile": "m62726f777365722e636f70792e61636365737364656e69656468656c70_v7361666172692d6d6f62696c65",
    },
    defaultKey: "m62726f777365722e636f70792e61636365737364656e69656468656c70_v7361666172692d6465736b746f70",
    arguments: [
      { name: "surface", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.accessgrantedjoin": {
    resourceKey: "m62726f777365722e636f70792e6163636573736772616e7465646a6f696e",
    formatIntent: "text",
    arguments: [
      { name: "granted", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.accessgrantednote": {
    resourceKey: "m62726f777365722e636f70792e6163636573736772616e7465646e6f7465",
    formatIntent: "enum",
    selectorVar: "surface",
    enumValues: ["safari-desktop", "safari-mobile"],
    enumDefault: "safari-desktop",
    variantKeys: {
      "safari-desktop": "m62726f777365722e636f70792e6163636573736772616e7465646e6f7465_v7361666172692d6465736b746f70",
      "safari-mobile": "m62726f777365722e636f70792e6163636573736772616e7465646e6f7465_v7361666172692d6d6f62696c65",
    },
    defaultKey: "m62726f777365722e636f70792e6163636573736772616e7465646e6f7465_v7361666172692d6465736b746f70",
    arguments: [
      { name: "surface", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.addblockedbelow": {
    resourceKey: "m62726f777365722e636f70792e616464626c6f636b656462656c6f77",
    formatIntent: "text",
    arguments: [
      { name: "arg1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "under", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "arg3", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.adddenied": {
    resourceKey: "m62726f777365722e636f70792e61646464656e696564",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.added": {
    resourceKey: "m62726f777365722e636f70792e6164646564",
    formatIntent: "enum",
    selectorVar: "scope",
    enumValues: ["exact", "whole"],
    enumDefault: "exact",
    variantKeys: {
      "exact": "m62726f777365722e636f70792e6164646564_v6578616374",
      "whole": "m62726f777365722e636f70792e6164646564_v77686f6c65",
    },
    defaultKey: "m62726f777365722e636f70792e6164646564_v6578616374",
    arguments: [
      { name: "scope", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "host", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.addedjoined": {
    resourceKey: "m62726f777365722e636f70792e61646465646a6f696e6564",
    formatIntent: "enum",
    selectorVar: "scope",
    enumValues: ["exact", "whole"],
    enumDefault: "exact",
    variantKeys: {
      "exact": "m62726f777365722e636f70792e61646465646a6f696e6564_v6578616374",
      "whole": "m62726f777365722e636f70792e61646465646a6f696e6564_v77686f6c65",
    },
    defaultKey: "m62726f777365722e636f70792e61646465646a6f696e6564_v6578616374",
    arguments: [
      { name: "scope", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "host", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.addhelp": {
    resourceKey: "m62726f777365722e636f70792e61646468656c70",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.addhelpjoined": {
    resourceKey: "m62726f777365722e636f70792e61646468656c706a6f696e6564",
    formatIntent: "enum",
    selectorVar: "browser",
    enumValues: ["firefox", "edge", "chrome", "safari", "other"],
    enumDefault: "other",
    variantKeys: {
      "firefox": "m62726f777365722e636f70792e61646468656c706a6f696e6564_v66697265666f78",
      "edge": "m62726f777365722e636f70792e61646468656c706a6f696e6564_v65646765",
      "chrome": "m62726f777365722e636f70792e61646468656c706a6f696e6564_v6368726f6d65",
      "safari": "m62726f777365722e636f70792e61646468656c706a6f696e6564_v736166617269",
      "other": "m62726f777365722e636f70792e61646468656c706a6f696e6564_v6f74686572",
    },
    defaultKey: "m62726f777365722e636f70792e61646468656c706a6f696e6564_v6f74686572",
    arguments: [
      { name: "browser", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.addhelpsuffix": {
    resourceKey: "m62726f777365722e636f70792e61646468656c70737566666978",
    formatIntent: "enum",
    selectorVar: "browser",
    enumValues: ["firefox", "edge", "chrome", "safari", "other"],
    enumDefault: "other",
    variantKeys: {
      "firefox": "m62726f777365722e636f70792e61646468656c70737566666978_v66697265666f78",
      "edge": "m62726f777365722e636f70792e61646468656c70737566666978_v65646765",
      "chrome": "m62726f777365722e636f70792e61646468656c70737566666978_v6368726f6d65",
      "safari": "m62726f777365722e636f70792e61646468656c70737566666978_v736166617269",
      "other": "m62726f777365722e636f70792e61646468656c70737566666978_v6f74686572",
    },
    defaultKey: "m62726f777365722e636f70792e61646468656c70737566666978_v6f74686572",
    arguments: [
      { name: "browser", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.addnotnow": {
    resourceKey: "m62726f777365722e636f70792e6164646e6f746e6f77",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.allowin": {
    resourceKey: "m62726f777365722e636f70792e616c6c6f77696e",
    formatIntent: "enum",
    selectorVar: "browser",
    enumValues: ["firefox", "edge", "chrome", "safari", "other"],
    enumDefault: "other",
    variantKeys: {
      "firefox": "m62726f777365722e636f70792e616c6c6f77696e_v66697265666f78",
      "edge": "m62726f777365722e636f70792e616c6c6f77696e_v65646765",
      "chrome": "m62726f777365722e636f70792e616c6c6f77696e_v6368726f6d65",
      "safari": "m62726f777365722e636f70792e616c6c6f77696e_v736166617269",
      "other": "m62726f777365722e636f70792e616c6c6f77696e_v6f74686572",
    },
    defaultKey: "m62726f777365722e636f70792e616c6c6f77696e_v6f74686572",
    arguments: [
      { name: "browser", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.allowsallofbutthe": {
    resourceKey: "m62726f777365722e636f70792e616c6c6f7773616c6c6f66627574746865",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "value2", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.allowseverywebsitesoevery": {
    resourceKey: "m62726f777365722e636f70792e616c6c6f7773657665727977656273697465736f6576657279",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.allowsmoreofsomesites": {
    resourceKey: "m62726f777365722e636f70792e616c6c6f77736d6f72656f66736f6d657369746573",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "value2", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.allowsmorethanyoursites": {
    resourceKey: "m62726f777365722e636f70792e616c6c6f77736d6f72657468616e796f75727369746573",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "value2", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.allowsthesolstoneextensionon": {
    resourceKey: "m62726f777365722e636f70792e616c6c6f7773746865736f6c73746f6e65657874656e73696f6e6f6e",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.allowsthesolstoneextensionon2": {
    resourceKey: "m62726f777365722e636f70792e616c6c6f7773746865736f6c73746f6e65657874656e73696f6e6f6e32",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "value2", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.allsitesandpagesare": {
    resourceKey: "m62726f777365722e636f70792e616c6c7369746573616e647061676573617265",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.alreadyallowseverywebsiteso": {
    resourceKey: "m62726f777365722e636f70792e616c7265616479616c6c6f7773657665727977656273697465736f",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "value2", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.appleftoutaway": {
    resourceKey: "m62726f777365722e636f70792e6170706c6566746f757461776179",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.appleftoutsiteson": {
    resourceKey: "m62726f777365722e636f70792e6170706c6566746f757473697465736f6e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.appleftoutunreadable": {
    resourceKey: "m62726f777365722e636f70792e6170706c6566746f7574756e7265616461626c65",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.apponlyleftout": {
    resourceKey: "m62726f777365722e636f70792e6170706f6e6c796c6566746f7574",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.browsermenu": {
    resourceKey: "m62726f777365722e636f70792e62726f777365726d656e75",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.browsername": {
    resourceKey: "m62726f777365722e636f70792e62726f777365726e616d65",
    formatIntent: "enum",
    selectorVar: "brand",
    enumValues: ["firefox", "edge", "chrome", "safari", "other"],
    enumDefault: "other",
    variantKeys: {
      "firefox": "m62726f777365722e636f70792e62726f777365726e616d65_v66697265666f78",
      "edge": "m62726f777365722e636f70792e62726f777365726e616d65_v65646765",
      "chrome": "m62726f777365722e636f70792e62726f777365726e616d65_v6368726f6d65",
      "safari": "m62726f777365722e636f70792e62726f777365726e616d65_v736166617269",
      "other": "m62726f777365722e636f70792e62726f777365726e616d65_v6f74686572",
    },
    defaultKey: "m62726f777365722e636f70792e62726f777365726e616d65_v6f74686572",
    arguments: [
      { name: "brand", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.checkagain": {
    resourceKey: "m62726f777365722e636f70792e636865636b616761696e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.checking": {
    resourceKey: "m62726f777365722e636f70792e636865636b696e67",
    formatIntent: "enum",
    selectorVar: "browser",
    enumValues: ["firefox", "edge", "chrome", "safari", "other"],
    enumDefault: "other",
    variantKeys: {
      "firefox": "m62726f777365722e636f70792e636865636b696e67_v66697265666f78",
      "edge": "m62726f777365722e636f70792e636865636b696e67_v65646765",
      "chrome": "m62726f777365722e636f70792e636865636b696e67_v6368726f6d65",
      "safari": "m62726f777365722e636f70792e636865636b696e67_v736166617269",
      "other": "m62726f777365722e636f70792e636865636b696e67_v6f74686572",
    },
    defaultKey: "m62726f777365722e636f70792e636865636b696e67_v6f74686572",
    arguments: [
      { name: "browser", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.couldntcheck": {
    resourceKey: "m62726f777365722e636f70792e636f756c646e74636865636b",
    formatIntent: "enum",
    selectorVar: "browser",
    enumValues: ["firefox", "edge", "chrome", "safari", "other"],
    enumDefault: "other",
    variantKeys: {
      "firefox": "m62726f777365722e636f70792e636f756c646e74636865636b_v66697265666f78",
      "edge": "m62726f777365722e636f70792e636f756c646e74636865636b_v65646765",
      "chrome": "m62726f777365722e636f70792e636f756c646e74636865636b_v6368726f6d65",
      "safari": "m62726f777365722e636f70792e636f756c646e74636865636b_v736166617269",
      "other": "m62726f777365722e636f70792e636f756c646e74636865636b_v6f74686572",
    },
    defaultKey: "m62726f777365722e636f70792e636f756c646e74636865636b_v6f74686572",
    arguments: [
      { name: "browser", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.couldntstart": {
    resourceKey: "m62726f777365722e636f70792e636f756c646e747374617274",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.deniednote": {
    resourceKey: "m62726f777365722e636f70792e64656e6965646e6f7465",
    formatIntent: "enum",
    selectorVar: "surface",
    enumValues: ["safari-desktop", "safari-mobile"],
    enumDefault: "safari-desktop",
    variantKeys: {
      "safari-desktop": "m62726f777365722e636f70792e64656e6965646e6f7465_v7361666172692d6465736b746f70",
      "safari-mobile": "m62726f777365722e636f70792e64656e6965646e6f7465_v7361666172692d6d6f62696c65",
    },
    defaultKey: "m62726f777365722e636f70792e64656e6965646e6f7465_v7361666172692d6465736b746f70",
    arguments: [
      { name: "surface", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.deniedtitle": {
    resourceKey: "m62726f777365722e636f70792e64656e6965647469746c65",
    formatIntent: "enum",
    selectorVar: "browser",
    enumValues: ["firefox", "edge", "chrome", "safari", "other"],
    enumDefault: "other",
    variantKeys: {
      "firefox": "m62726f777365722e636f70792e64656e6965647469746c65_v66697265666f78",
      "edge": "m62726f777365722e636f70792e64656e6965647469746c65_v65646765",
      "chrome": "m62726f777365722e636f70792e64656e6965647469746c65_v6368726f6d65",
      "safari": "m62726f777365722e636f70792e64656e6965647469746c65_v736166617269",
      "other": "m62726f777365722e636f70792e64656e6965647469746c65_v6f74686572",
    },
    defaultKey: "m62726f777365722e636f70792e64656e6965647469746c65_v6f74686572",
    arguments: [
      { name: "browser", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.denyingsite": {
    resourceKey: "m62726f777365722e636f70792e64656e79696e6773697465",
    formatIntent: "enum",
    selectorVar: "browser",
    enumValues: ["firefox", "edge", "chrome", "safari", "other"],
    enumDefault: "other",
    variantKeys: {
      "firefox": "m62726f777365722e636f70792e64656e79696e6773697465_v66697265666f78",
      "edge": "m62726f777365722e636f70792e64656e79696e6773697465_v65646765",
      "chrome": "m62726f777365722e636f70792e64656e79696e6773697465_v6368726f6d65",
      "safari": "m62726f777365722e636f70792e64656e79696e6773697465_v736166617269",
      "other": "m62726f777365722e636f70792e64656e79696e6773697465_v6f74686572",
    },
    defaultKey: "m62726f777365722e636f70792e64656e79696e6773697465_v6f74686572",
    arguments: [
      { name: "browser", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.desktopactivityon": {
    resourceKey: "m62726f777365722e636f70792e6465736b746f7061637469766974796f6e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.desktopscreenon": {
    resourceKey: "m62726f777365722e636f70792e6465736b746f7073637265656e6f6e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.disclosure": {
    resourceKey: "m62726f777365722e636f70792e646973636c6f73757265",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e636f70792e646973636c6f73757265_v636f6d7075746572",
      "iphone": "m62726f777365722e636f70792e646973636c6f73757265_v6970686f6e65",
      "ipad": "m62726f777365722e636f70792e646973636c6f73757265_v69706164",
    },
    defaultKey: "m62726f777365722e636f70792e646973636c6f73757265_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.disclosurepause": {
    resourceKey: "m62726f777365722e636f70792e646973636c6f737572657061757365",
    formatIntent: "enum",
    selectorVar: "surface",
    enumValues: ["desktop", "mobile"],
    enumDefault: "desktop",
    variantKeys: {
      "desktop": "m62726f777365722e636f70792e646973636c6f737572657061757365_v6465736b746f70",
      "mobile": "m62726f777365722e636f70792e646973636c6f737572657061757365_v6d6f62696c65",
    },
    defaultKey: "m62726f777365722e636f70792e646973636c6f737572657061757365_v6465736b746f70",
    arguments: [
      { name: "surface", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.disclosureprivate": {
    resourceKey: "m62726f777365722e636f70792e646973636c6f7375726570726976617465",
    formatIntent: "enum",
    selectorVar: "surface",
    enumValues: ["desktop", "mobile"],
    enumDefault: "desktop",
    variantKeys: {
      "desktop": "m62726f777365722e636f70792e646973636c6f7375726570726976617465_v6465736b746f70",
      "mobile": "m62726f777365722e636f70792e646973636c6f7375726570726976617465_v6d6f62696c65",
    },
    defaultKey: "m62726f777365722e636f70792e646973636c6f7375726570726976617465_v6465736b746f70",
    arguments: [
      { name: "surface", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.disclosurerest": {
    resourceKey: "m62726f777365722e636f70792e646973636c6f7375726572657374",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.everysiteleftout": {
    resourceKey: "m62726f777365722e636f70792e6576657279736974656c6566746f7574",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.extensionleftout": {
    resourceKey: "m62726f777365722e636f70792e657874656e73696f6e6c6566746f7574",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.failadd": {
    resourceKey: "m62726f777365722e636f70792e6661696c616464",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.failedbody": {
    resourceKey: "m62726f777365722e636f70792e6661696c6564626f6479",
    formatIntent: "enum",
    selectorVar: "browser",
    enumValues: ["firefox", "edge", "chrome", "safari", "other"],
    enumDefault: "other",
    variantKeys: {
      "firefox": "m62726f777365722e636f70792e6661696c6564626f6479_v66697265666f78",
      "edge": "m62726f777365722e636f70792e6661696c6564626f6479_v65646765",
      "chrome": "m62726f777365722e636f70792e6661696c6564626f6479_v6368726f6d65",
      "safari": "m62726f777365722e636f70792e6661696c6564626f6479_v736166617269",
      "other": "m62726f777365722e636f70792e6661696c6564626f6479_v6f74686572",
    },
    defaultKey: "m62726f777365722e636f70792e6661696c6564626f6479_v6f74686572",
    arguments: [
      { name: "browser", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.failgeneric": {
    resourceKey: "m62726f777365722e636f70792e6661696c67656e65726963",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.failleftout": {
    resourceKey: "m62726f777365722e636f70792e6661696c6c6566746f7574",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.failpage": {
    resourceKey: "m62726f777365722e636f70792e6661696c70616765",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.failpageretry": {
    resourceKey: "m62726f777365722e636f70792e6661696c706167657265747279",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.failrestartsite": {
    resourceKey: "m62726f777365722e636f70792e6661696c7265737461727473697465",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.failsave": {
    resourceKey: "m62726f777365722e636f70792e6661696c73617665",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.failsetupfirst": {
    resourceKey: "m62726f777365722e636f70792e6661696c73657475706669727374",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.failsite": {
    resourceKey: "m62726f777365722e636f70792e6661696c73697465",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.failsitefull": {
    resourceKey: "m62726f777365722e636f70792e6661696c7369746566756c6c",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.fielderror": {
    resourceKey: "m62726f777365722e636f70792e6669656c646572726f72",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.hostalready": {
    resourceKey: "m62726f777365722e636f70792e686f7374616c7265616479",
    formatIntent: "text",
    arguments: [
      { name: "host", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.hostremoved": {
    resourceKey: "m62726f777365722e636f70792e686f737472656d6f766564",
    formatIntent: "text",
    arguments: [
      { name: "host", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.isleftoutstopleaving": {
    resourceKey: "m62726f777365722e636f70792e69736c6566746f757473746f706c656176696e67",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.isnolongerleftout": {
    resourceKey: "m62726f777365722e636f70792e69736e6f6c6f6e6765726c6566746f7574",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.isntallowingeverywebsite": {
    resourceKey: "m62726f777365722e636f70792e69736e74616c6c6f77696e67657665727977656273697465",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.leaveouthelp": {
    resourceKey: "m62726f777365722e636f70792e6c656176656f757468656c70",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.leaveoutneedsaccess": {
    resourceKey: "m62726f777365722e636f70792e6c656176656f75746e65656473616363657373",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.leaveoutnote": {
    resourceKey: "m62726f777365722e636f70792e6c656176656f75746e6f7465",
    formatIntent: "enum",
    selectorVar: "scope",
    enumValues: ["exact", "whole"],
    enumDefault: "exact",
    variantKeys: {
      "exact": "m62726f777365722e636f70792e6c656176656f75746e6f7465_v6578616374",
      "whole": "m62726f777365722e636f70792e6c656176656f75746e6f7465_v77686f6c65",
    },
    defaultKey: "m62726f777365722e636f70792e6c656176656f75746e6f7465_v6578616374",
    arguments: [
      { name: "scope", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "host", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.leftoutannouncement": {
    resourceKey: "m62726f777365722e636f70792e6c6566746f7574616e6e6f756e63656d656e74",
    formatIntent: "enum",
    selectorVar: "scope",
    enumValues: ["exact", "whole"],
    enumDefault: "exact",
    variantKeys: {
      "exact": "m62726f777365722e636f70792e6c6566746f7574616e6e6f756e63656d656e74_v6578616374",
      "whole": "m62726f777365722e636f70792e6c6566746f7574616e6e6f756e63656d656e74_v77686f6c65",
    },
    defaultKey: "m62726f777365722e636f70792e6c6566746f7574616e6e6f756e63656d656e74_v6578616374",
    arguments: [
      { name: "scope", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "host", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.leftoutsummary": {
    resourceKey: "m62726f777365722e636f70792e6c6566746f757473756d6d617279",
    formatIntent: "cardinal",
    selectorVar: "count",
    arguments: [
      { name: "count", type: "cardinal", min: 0, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.linuxcantreach": {
    resourceKey: "m62726f777365722e636f70792e6c696e757863616e747265616368",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e636f70792e6c696e757863616e747265616368_v636f6d7075746572",
      "iphone": "m62726f777365722e636f70792e6c696e757863616e747265616368_v6970686f6e65",
      "ipad": "m62726f777365722e636f70792e6c696e757863616e747265616368_v69706164",
    },
    defaultKey: "m62726f777365722e636f70792e6c696e757863616e747265616368_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.linuxintakeoff": {
    resourceKey: "m62726f777365722e636f70792e6c696e7578696e74616b656f6666",
    formatIntent: "text",
    arguments: [
      { name: "cmd", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.linuxstep1intake": {
    resourceKey: "m62726f777365722e636f70792e6c696e75787374657031696e74616b65",
    formatIntent: "text",
    arguments: [
      { name: "cmd", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.linuxupdate": {
    resourceKey: "m62726f777365722e636f70792e6c696e7578757064617465",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e636f70792e6c696e7578757064617465_v636f6d7075746572",
      "iphone": "m62726f777365722e636f70792e6c696e7578757064617465_v6970686f6e65",
      "ipad": "m62726f777365722e636f70792e6c696e7578757064617465_v69706164",
    },
    defaultKey: "m62726f777365722e636f70792e6c696e7578757064617465_v636f6d7075746572",
    arguments: [
      { name: "cmd", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.nowallowseverywebsiteevery": {
    resourceKey: "m62726f777365722e636f70792e6e6f77616c6c6f77736576657279776562736974656576657279",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.onlythesitesalreadyallows": {
    resourceKey: "m62726f777365722e636f70792e6f6e6c797468657369746573616c7265616479616c6c6f7773",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.permissiondeclinedonlythesites": {
    resourceKey: "m62726f777365722e636f70792e7065726d697373696f6e6465636c696e65646f6e6c797468657369746573",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "value2", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.permissionschanged": {
    resourceKey: "m62726f777365722e636f70792e7065726d697373696f6e736368616e676564",
    formatIntent: "enum",
    selectorVar: "browser",
    enumValues: ["firefox", "edge", "chrome", "safari", "other"],
    enumDefault: "other",
    variantKeys: {
      "firefox": "m62726f777365722e636f70792e7065726d697373696f6e736368616e676564_v66697265666f78",
      "edge": "m62726f777365722e636f70792e7065726d697373696f6e736368616e676564_v65646765",
      "chrome": "m62726f777365722e636f70792e7065726d697373696f6e736368616e676564_v6368726f6d65",
      "safari": "m62726f777365722e636f70792e7065726d697373696f6e736368616e676564_v736166617269",
      "other": "m62726f777365722e636f70792e7065726d697373696f6e736368616e676564_v6f74686572",
    },
    defaultKey: "m62726f777365722e636f70792e7065726d697373696f6e736368616e676564_v6f74686572",
    arguments: [
      { name: "browser", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.privatenote": {
    resourceKey: "m62726f777365722e636f70792e707269766174656e6f7465",
    formatIntent: "enum",
    selectorVar: "surface",
    enumValues: ["desktop", "mobile"],
    enumDefault: "desktop",
    variantKeys: {
      "desktop": "m62726f777365722e636f70792e707269766174656e6f7465_v6465736b746f70",
      "mobile": "m62726f777365722e636f70792e707269766174656e6f7465_v6d6f62696c65",
    },
    defaultKey: "m62726f777365722e636f70792e707269766174656e6f7465_v6465736b746f70",
    arguments: [
      { name: "surface", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.privatestate": {
    resourceKey: "m62726f777365722e636f70792e707269766174657374617465",
    formatIntent: "enum",
    selectorVar: "surface",
    enumValues: ["desktop", "mobile"],
    enumDefault: "desktop",
    variantKeys: {
      "desktop": "m62726f777365722e636f70792e707269766174657374617465_v6465736b746f70",
      "mobile": "m62726f777365722e636f70792e707269766174657374617465_v6d6f62696c65",
    },
    defaultKey: "m62726f777365722e636f70792e707269766174657374617465_v6465736b746f70",
    arguments: [
      { name: "surface", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.restricted": {
    resourceKey: "m62726f777365722e636f70792e72657374726963746564",
    formatIntent: "enum",
    selectorVar: "browser",
    enumValues: ["firefox", "edge", "chrome", "safari", "other"],
    enumDefault: "other",
    variantKeys: {
      "firefox": "m62726f777365722e636f70792e72657374726963746564_v66697265666f78",
      "edge": "m62726f777365722e636f70792e72657374726963746564_v65646765",
      "chrome": "m62726f777365722e636f70792e72657374726963746564_v6368726f6d65",
      "safari": "m62726f777365722e636f70792e72657374726963746564_v736166617269",
      "other": "m62726f777365722e636f70792e72657374726963746564_v6f74686572",
    },
    defaultKey: "m62726f777365722e636f70792e72657374726963746564_v6f74686572",
    arguments: [
      { name: "browser", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.returnnote": {
    resourceKey: "m62726f777365722e636f70792e72657475726e6e6f7465",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.sharegoesin": {
    resourceKey: "m62726f777365722e636f70792e7368617265676f6573696e",
    formatIntent: "text",
    arguments: [
      { name: "arg1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.sharegoesinnow": {
    resourceKey: "m62726f777365722e636f70792e7368617265676f6573696e6e6f77",
    formatIntent: "text",
    arguments: [
      { name: "arg1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.sharingallcount": {
    resourceKey: "m62726f777365722e636f70792e73686172696e67616c6c636f756e74",
    formatIntent: "cardinal",
    selectorVar: "count",
    arguments: [
      { name: "count", type: "cardinal", min: 0, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.sharingevery": {
    resourceKey: "m62726f777365722e636f70792e73686172696e676576657279",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.sharingexcluded": {
    resourceKey: "m62726f777365722e636f70792e73686172696e676578636c75646564",
    formatIntent: "text",
    arguments: [
      { name: "count", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.sheettitle": {
    resourceKey: "m62726f777365722e636f70792e73686565747469746c65",
    formatIntent: "enum",
    selectorVar: "scope",
    enumValues: ["exact", "whole"],
    enumDefault: "exact",
    variantKeys: {
      "exact": "m62726f777365722e636f70792e73686565747469746c65_v6578616374",
      "whole": "m62726f777365722e636f70792e73686565747469746c65_v77686f6c65",
    },
    defaultKey: "m62726f777365722e636f70792e73686565747469746c65_v6578616374",
    arguments: [
      { name: "scope", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "host", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.sownsettingsdont": {
    resourceKey: "m62726f777365722e636f70792e736f776e73657474696e6773646f6e74",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.step1cantreach": {
    resourceKey: "m62726f777365722e636f70792e737465703163616e747265616368",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e636f70792e737465703163616e747265616368_v636f6d7075746572",
      "iphone": "m62726f777365722e636f70792e737465703163616e747265616368_v6970686f6e65",
      "ipad": "m62726f777365722e636f70792e737465703163616e747265616368_v69706164",
    },
    defaultKey: "m62726f777365722e636f70792e737465703163616e747265616368_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.step1intakeoff": {
    resourceKey: "m62726f777365722e636f70792e7374657031696e74616b656f6666",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.step1notpaired": {
    resourceKey: "m62726f777365722e636f70792e73746570316e6f74706169726564",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e636f70792e73746570316e6f74706169726564_v636f6d7075746572",
      "iphone": "m62726f777365722e636f70792e73746570316e6f74706169726564_v6970686f6e65",
      "ipad": "m62726f777365722e636f70792e73746570316e6f74706169726564_v69706164",
    },
    defaultKey: "m62726f777365722e636f70792e73746570316e6f74706169726564_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.step1openapp": {
    resourceKey: "m62726f777365722e636f70792e73746570316f70656e617070",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e636f70792e73746570316f70656e617070_v636f6d7075746572",
      "iphone": "m62726f777365722e636f70792e73746570316f70656e617070_v6970686f6e65",
      "ipad": "m62726f777365722e636f70792e73746570316f70656e617070_v69706164",
    },
    defaultKey: "m62726f777365722e636f70792e73746570316f70656e617070_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.step2pending": {
    resourceKey: "m62726f777365722e636f70792e737465703270656e64696e67",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.step3body": {
    resourceKey: "m62726f777365722e636f70792e7374657033626f6479",
    formatIntent: "enum",
    selectorVar: "browser",
    enumValues: ["firefox", "edge", "chrome", "safari", "other"],
    enumDefault: "other",
    variantKeys: {
      "firefox": "m62726f777365722e636f70792e7374657033626f6479_v66697265666f78",
      "edge": "m62726f777365722e636f70792e7374657033626f6479_v65646765",
      "chrome": "m62726f777365722e636f70792e7374657033626f6479_v6368726f6d65",
      "safari": "m62726f777365722e636f70792e7374657033626f6479_v736166617269",
      "other": "m62726f777365722e636f70792e7374657033626f6479_v6f74686572",
    },
    defaultKey: "m62726f777365722e636f70792e7374657033626f6479_v6f74686572",
    arguments: [
      { name: "browser", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.stepextensionsleft": {
    resourceKey: "m62726f777365722e636f70792e73746570657874656e73696f6e736c656674",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.stepforother": {
    resourceKey: "m62726f777365722e636f70792e73746570666f726f74686572",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.stepotherwebsites": {
    resourceKey: "m62726f777365722e636f70792e737465706f746865727765627369746573",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.stepsafariwebsites": {
    resourceKey: "m62726f777365722e636f70792e737465707361666172697765627369746573",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.stepsettingsapps": {
    resourceKey: "m62726f777365722e636f70792e7374657073657474696e677361707073",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.stillallowseverywebsite": {
    resourceKey: "m62726f777365722e636f70792e7374696c6c616c6c6f7773657665727977656273697465",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.stillisntallowingevery": {
    resourceKey: "m62726f777365722e636f70792e7374696c6c69736e74616c6c6f77696e676576657279",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.thesolstoneextensionleavesit": {
    resourceKey: "m62726f777365722e636f70792e746865736f6c73746f6e65657874656e73696f6e6c65617665736974",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.truncation": {
    resourceKey: "m62726f777365722e636f70792e7472756e636174696f6e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.tryagain": {
    resourceKey: "m62726f777365722e636f70792e747279616761696e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.unknownnote": {
    resourceKey: "m62726f777365722e636f70792e756e6b6e6f776e6e6f7465",
    formatIntent: "enum",
    selectorVar: "surface",
    enumValues: ["safari-desktop", "safari-mobile"],
    enumDefault: "safari-desktop",
    variantKeys: {
      "safari-desktop": "m62726f777365722e636f70792e756e6b6e6f776e6e6f7465_v7361666172692d6465736b746f70",
      "safari-mobile": "m62726f777365722e636f70792e756e6b6e6f776e6e6f7465_v7361666172692d6d6f62696c65",
    },
    defaultKey: "m62726f777365722e636f70792e756e6b6e6f776e6e6f7465_v7361666172692d6465736b746f70",
    arguments: [
      { name: "surface", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.copy.unknownstate": {
    resourceKey: "m62726f777365722e636f70792e756e6b6e6f776e7374617465",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.warm1": {
    resourceKey: "m62726f777365722e636f70792e7761726d31",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.warm2": {
    resourceKey: "m62726f777365722e636f70792e7761726d32",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.copy.warm3": {
    resourceKey: "m62726f777365722e636f70792e7761726d33",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.addingsitecoversevery": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e616464696e6773697465636f766572736576657279",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.clearedextensionsstorage": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e636c6561726564657874656e73696f6e7373746f72616765",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.clearedextensionsstorage2": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e636c6561726564657874656e73696f6e7373746f7261676532",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.enterwebsiteaddresslike": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e656e74657277656273697465616464726573736c696b65",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.everysiteoffexcept": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e6576657279736974656f6666657863657074",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.everysiteoffincluding": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e6576657279736974656f6666696e636c7564696e67",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.everywebsiteincludingones": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e657665727977656273697465696e636c7564696e676f6e6573",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.extensionsbuttonsafaris": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e657874656e73696f6e73627574746f6e73616661726973",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.extensiontakesnothingfrom": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e657874656e73696f6e74616b65736e6f7468696e6766726f6d",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.extensiontakesonlysites": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e657874656e73696f6e74616b65736f6e6c797369746573",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.onlysitesallowopen": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e6f6e6c797369746573616c6c6f776f70656e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.onlysitessafarialready": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e6f6e6c797369746573736166617269616c7265616479",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.safarispagemenu": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e73616661726973706167656d656e75",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.safaristillisnt": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e7361666172697374696c6c69736e74",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.safaristillisnt2": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e7361666172697374696c6c69736e7432",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.setallwebsitesother": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e736574616c6c77656273697465736f74686572",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.shareall": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e7368617265616c6c",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.sharethemtoo": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e73686172657468656d746f6f",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.sharingeverysiteincludes": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e73686172696e67657665727973697465696e636c75646573",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.sitesetdenythere": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e7369746573657464656e797468657265",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.solstoneextensionleavesout": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e736f6c73746f6e65657874656e73696f6e6c65617665736f7574",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.stopsharingeverysite": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e73746f7073686172696e67657665727973697465",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.stopsharingeverysite2": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e73746f7073686172696e6765766572797369746532",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.extension.stopsharingeverysite3": {
    resourceKey: "m62726f777365722e657874656e73696f6e2e73746f7073686172696e6765766572797369746533",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.failure.raw": {
    resourceKey: "m62726f777365722e6661696c7572652e726177",
    formatIntent: "text",
    arguments: [
      { name: "raw", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.labels.onnow": {
    resourceKey: "m62726f777365722e6c6162656c732e6f6e6e6f77",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.labels.opensettings": {
    resourceKey: "m62726f777365722e6c6162656c732e6f70656e73657474696e6773",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.labels.updatenow": {
    resourceKey: "m62726f777365722e6c6162656c732e7570646174656e6f77",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.manifest.description": {
    resourceKey: "m62726f777365722e6d616e69666573742e6465736372697074696f6e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.manifest.safaridescription": {
    resourceKey: "m62726f777365722e6d616e69666573742e7361666172696465736372697074696f6e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.addasite": {
    resourceKey: "m62726f777365722e6f7074696f6e732e6164646173697465",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.addsitesoneat": {
    resourceKey: "m62726f777365722e6f7074696f6e732e61646473697465736f6e656174",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.agreeaddsitesone": {
    resourceKey: "m62726f777365722e6f7074696f6e732e616772656561646473697465736f6e65",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.agreegoon": {
    resourceKey: "m62726f777365722e6f7074696f6e732e6167726565676f6f6e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.agreeshareeverysite": {
    resourceKey: "m62726f777365722e6f7074696f6e732e61677265657368617265657665727973697465",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.choosefirst": {
    resourceKey: "m62726f777365722e6f7074696f6e732e63686f6f73656669727374",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.documenttitle": {
    resourceKey: "m62726f777365722e6f7074696f6e732e646f63756d656e747469746c65",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.keepmysites": {
    resourceKey: "m62726f777365722e6f7074696f6e732e6b6565706d797369746573",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.leaveout": {
    resourceKey: "m62726f777365722e6f7074696f6e732e6c656176656f7574",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.leaveoutasite": {
    resourceKey: "m62726f777365722e6f7074696f6e732e6c656176656f75746173697465",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.leaveoutplaceholder": {
    resourceKey: "m62726f777365722e6f7074696f6e732e6c656176656f7574706c616365686f6c646572",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.lookingforapp": {
    resourceKey: "m62726f777365722e6f7074696f6e732e6c6f6f6b696e67666f72617070",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e6f7074696f6e732e6c6f6f6b696e67666f72617070_v636f6d7075746572",
      "iphone": "m62726f777365722e6f7074696f6e732e6c6f6f6b696e67666f72617070_v6970686f6e65",
      "ipad": "m62726f777365722e6f7074696f6e732e6c6f6f6b696e67666f72617070_v69706164",
    },
    defaultKey: "m62726f777365722e6f7074696f6e732e6c6f6f6b696e67666f72617070_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.options.mobileplaceholder": {
    resourceKey: "m62726f777365722e6f7074696f6e732e6d6f62696c65706c616365686f6c646572",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.pause": {
    resourceKey: "m62726f777365722e6f7074696f6e732e7061757365",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.pauseheading": {
    resourceKey: "m62726f777365722e6f7074696f6e732e706175736568656164696e67",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.pausehelp": {
    resourceKey: "m62726f777365722e6f7074696f6e732e706175736568656c70",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.pauselabel": {
    resourceKey: "m62726f777365722e6f7074696f6e732e70617573656c6162656c",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.placeholder": {
    resourceKey: "m62726f777365722e6f7074696f6e732e706c616365686f6c646572",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.readagain": {
    resourceKey: "m62726f777365722e6f7074696f6e732e72656164616761696e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.remove": {
    resourceKey: "m62726f777365722e6f7074696f6e732e72656d6f7665",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.shareeverysite": {
    resourceKey: "m62726f777365722e6f7074696f6e732e7368617265657665727973697465",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.siterowaria": {
    resourceKey: "m62726f777365722e6f7074696f6e732e73697465726f7761726961",
    formatIntent: "enum",
    selectorVar: "action",
    enumValues: ["remove", "include"],
    enumDefault: "remove",
    variantKeys: {
      "remove": "m62726f777365722e6f7074696f6e732e73697465726f7761726961_v72656d6f7665",
      "include": "m62726f777365722e6f7074696f6e732e73697465726f7761726961_v696e636c756465",
    },
    defaultKey: "m62726f777365722e6f7074696f6e732e73697465726f7761726961_v72656d6f7665",
    arguments: [
      { name: "host", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "action", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.options.stopleavingout": {
    resourceKey: "m62726f777365722e6f7074696f6e732e73746f706c656176696e676f7574",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.takesin": {
    resourceKey: "m62726f777365722e6f7074696f6e732e74616b6573696e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.version": {
    resourceKey: "m62726f777365722e6f7074696f6e732e76657273696f6e",
    formatIntent: "text",
    arguments: [
      { name: "version", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.options.whatyoushare": {
    resourceKey: "m62726f777365722e6f7074696f6e732e77686174796f757368617265",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.whichsitesdowant": {
    resourceKey: "m62726f777365722e6f7074696f6e732e77686963687369746573646f77616e74",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.options.yoursites": {
    resourceKey: "m62726f777365722e6f7074696f6e732e796f75727369746573",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.page.markerstate": {
    resourceKey: "m62726f777365722e706167652e6d61726b65727374617465",
    formatIntent: "enum",
    selectorVar: "phase",
    enumValues: ["on", "paused"],
    enumDefault: "on",
    variantKeys: {
      "on": "m62726f777365722e706167652e6d61726b65727374617465_v6f6e",
      "paused": "m62726f777365722e706167652e6d61726b65727374617465_v706175736564",
    },
    defaultKey: "m62726f777365722e706167652e6d61726b65727374617465_v6f6e",
    arguments: [
      { name: "phase", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.popup.about": {
    resourceKey: "m62726f777365722e706f7075702e61626f7574",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.added": {
    resourceKey: "m62726f777365722e706f7075702e6164646564",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.addedidle": {
    resourceKey: "m62726f777365722e706f7075702e616464656469646c65",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.attentionheading": {
    resourceKey: "m62726f777365722e706f7075702e617474656e74696f6e68656164696e67",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.cantadd": {
    resourceKey: "m62726f777365722e706f7075702e63616e74616464",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.copybutton": {
    resourceKey: "m62726f777365722e706f7075702e636f7079627574746f6e",
    formatIntent: "enum",
    selectorVar: "phase",
    enumValues: ["copy", "copied"],
    enumDefault: "copy",
    variantKeys: {
      "copy": "m62726f777365722e706f7075702e636f7079627574746f6e_v636f7079",
      "copied": "m62726f777365722e706f7075702e636f7079627574746f6e_v636f70696564",
    },
    defaultKey: "m62726f777365722e706f7075702e636f7079627574746f6e_v636f7079",
    arguments: [
      { name: "phase", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.popup.copyfailed": {
    resourceKey: "m62726f777365722e706f7075702e636f70796661696c6564",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.included": {
    resourceKey: "m62726f777365722e706f7075702e696e636c75646564",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.leaveoutthis": {
    resourceKey: "m62726f777365722e706f7075702e6c656176656f757474686973",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.leftout": {
    resourceKey: "m62726f777365722e706f7075702e6c6566746f7574",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.manage": {
    resourceKey: "m62726f777365722e706f7075702e6d616e616765",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.notadded": {
    resourceKey: "m62726f777365722e706f7075702e6e6f746164646564",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.nottakenin": {
    resourceKey: "m62726f777365722e706f7075702e6e6f7474616b656e696e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.pauseall": {
    resourceKey: "m62726f777365722e706f7075702e7061757365616c6c",
    formatIntent: "enum",
    selectorVar: "phase",
    enumValues: ["running", "paused"],
    enumDefault: "running",
    variantKeys: {
      "running": "m62726f777365722e706f7075702e7061757365616c6c_v72756e6e696e67",
      "paused": "m62726f777365722e706f7075702e7061757365616c6c_v706175736564",
    },
    defaultKey: "m62726f777365722e706f7075702e7061757365616c6c_v72756e6e696e67",
    arguments: [
      { name: "phase", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.popup.reloadtab": {
    resourceKey: "m62726f777365722e706f7075702e72656c6f6164746162",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.removehost": {
    resourceKey: "m62726f777365722e706f7075702e72656d6f7665686f7374",
    formatIntent: "text",
    arguments: [
      { name: "arg1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.popup.removethis": {
    resourceKey: "m62726f777365722e706f7075702e72656d6f766574686973",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.settings": {
    resourceKey: "m62726f777365722e706f7075702e73657474696e6773",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.sharing": {
    resourceKey: "m62726f777365722e706f7075702e73686172696e67",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.sitecountallon": {
    resourceKey: "m62726f777365722e706f7075702e73697465636f756e74616c6c6f6e",
    formatIntent: "cardinal",
    selectorVar: "count",
    arguments: [
      { name: "count", type: "cardinal", min: 0, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.popup.sitecountallpaused": {
    resourceKey: "m62726f777365722e706f7075702e73697465636f756e74616c6c706175736564",
    formatIntent: "cardinal",
    selectorVar: "count",
    arguments: [
      { name: "count", type: "cardinal", min: 0, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.popup.sitecountmixed": {
    resourceKey: "m62726f777365722e706f7075702e73697465636f756e746d69786564",
    formatIntent: "cardinal",
    selectorVar: "count",
    arguments: [
      { name: "on", type: "integer", min: 0, max: null, numericStyle: "ungrouped" },
      { name: "count", type: "cardinal", min: 0, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.popup.sitecountonly": {
    resourceKey: "m62726f777365722e706f7075702e73697465636f756e746f6e6c79",
    formatIntent: "cardinal",
    selectorVar: "count",
    arguments: [
      { name: "count", type: "cardinal", min: 0, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.popup.stopleavinghostout": {
    resourceKey: "m62726f777365722e706f7075702e73746f706c656176696e67686f73746f7574",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.popup.stopleavingsiteout": {
    resourceKey: "m62726f777365722e706f7075702e73746f706c656176696e67736974656f7574",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.thispage": {
    resourceKey: "m62726f777365722e706f7075702e7468697370616765",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.popup.whattakes": {
    resourceKey: "m62726f777365722e706f7075702e7768617474616b6573",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.apppausedheadline": {
    resourceKey: "m62726f777365722e7374617475732e617070706175736564686561646c696e65",
    formatIntent: "enum",
    selectorVar: "surface",
    enumValues: ["desktop", "mobile"],
    enumDefault: "desktop",
    variantKeys: {
      "desktop": "m62726f777365722e7374617475732e617070706175736564686561646c696e65_v6465736b746f70",
      "mobile": "m62726f777365722e7374617475732e617070706175736564686561646c696e65_v6d6f62696c65",
    },
    defaultKey: "m62726f777365722e7374617475732e617070706175736564686561646c696e65_v6465736b746f70",
    arguments: [
      { name: "surface", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.apppausednote": {
    resourceKey: "m62726f777365722e7374617475732e6170707061757365646e6f7465",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e6170707061757365646e6f7465_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e6170707061757365646e6f7465_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e6170707061757365646e6f7465_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e6170707061757365646e6f7465_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.apppausedreason": {
    resourceKey: "m62726f777365722e7374617475732e617070706175736564726561736f6e",
    formatIntent: "enum",
    selectorVar: "surface",
    enumValues: ["desktop", "mobile"],
    enumDefault: "desktop",
    variantKeys: {
      "desktop": "m62726f777365722e7374617475732e617070706175736564726561736f6e_v6465736b746f70",
      "mobile": "m62726f777365722e7374617475732e617070706175736564726561736f6e_v6d6f62696c65",
    },
    defaultKey: "m62726f777365722e7374617475732e617070706175736564726561736f6e_v6465736b746f70",
    arguments: [
      { name: "surface", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.cantreach": {
    resourceKey: "m62726f777365722e7374617475732e63616e747265616368",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.cantreachanswering": {
    resourceKey: "m62726f777365722e7374617475732e63616e747265616368616e73776572696e67",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e63616e747265616368616e73776572696e67_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e63616e747265616368616e73776572696e67_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e63616e747265616368616e73776572696e67_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e63616e747265616368616e73776572696e67_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.cantreachgetapp": {
    resourceKey: "m62726f777365722e7374617475732e63616e747265616368676574617070",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e63616e747265616368676574617070_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e63616e747265616368676574617070_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e63616e747265616368676574617070_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e63616e747265616368676574617070_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.cantreachreopen": {
    resourceKey: "m62726f777365722e7374617475732e63616e74726561636872656f70656e",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e63616e74726561636872656f70656e_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e63616e74726561636872656f70656e_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e63616e74726561636872656f70656e_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e63616e74726561636872656f70656e_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.changingsites": {
    resourceKey: "m62726f777365722e7374617475732e6368616e67696e677369746573",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.connecting": {
    resourceKey: "m62726f777365722e7374617475732e636f6e6e656374696e67",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.finishsetup": {
    resourceKey: "m62726f777365722e7374617475732e66696e6973687365747570",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.foundsolstoneapp": {
    resourceKey: "m62726f777365722e7374617475732e666f756e64736f6c73746f6e65617070",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.foundsolstoneapps": {
    resourceKey: "m62726f777365722e7374617475732e666f756e64736f6c73746f6e6561707073",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.getapp": {
    resourceKey: "m62726f777365722e7374617475732e676574617070",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.icontitle": {
    resourceKey: "m62726f777365722e7374617475732e69636f6e7469746c65",
    formatIntent: "text",
    arguments: [
      { name: "headline", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.idlereason": {
    resourceKey: "m62726f777365722e7374617475732e69646c65726561736f6e",
    formatIntent: "enum",
    selectorVar: "mode",
    enumValues: ["selected", "all"],
    enumDefault: "selected",
    variantKeys: {
      "selected": "m62726f777365722e7374617475732e69646c65726561736f6e_v73656c6563746564",
      "all": "m62726f777365722e7374617475732e69646c65726561736f6e_v616c6c",
    },
    defaultKey: "m62726f777365722e7374617475732e69646c65726561736f6e_v73656c6563746564",
    arguments: [
      { name: "mode", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.intakeheld": {
    resourceKey: "m62726f777365722e7374617475732e696e74616b6568656c64",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e696e74616b6568656c64_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e696e74616b6568656c64_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e696e74616b6568656c64_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e696e74616b6568656c64_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.keptfornow": {
    resourceKey: "m62726f777365722e7374617475732e6b657074666f726e6f77",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e6b657074666f726e6f77_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e6b657074666f726e6f77_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e6b657074666f726e6f77_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e6b657074666f726e6f77_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.keptfornowreason": {
    resourceKey: "m62726f777365722e7374617475732e6b657074666f726e6f77726561736f6e",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e6b657074666f726e6f77726561736f6e_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e6b657074666f726e6f77726561736f6e_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e6b657074666f726e6f77726561736f6e_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e6b657074666f726e6f77726561736f6e_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.keptwaiting": {
    resourceKey: "m62726f777365722e7374617475732e6b65707477616974696e67",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e6b65707477616974696e67_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e6b65707477616974696e67_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e6b65707477616974696e67_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e6b65707477616974696e67_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.lastpages": {
    resourceKey: "m62726f777365722e7374617475732e6c6173747061676573",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.lostbrowsers": {
    resourceKey: "m62726f777365722e7374617475732e6c6f737462726f7773657273",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.lostthis": {
    resourceKey: "m62726f777365722e7374617475732e6c6f737474686973",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.noroom": {
    resourceKey: "m62726f777365722e7374617475732e6e6f726f6f6d",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.nosites": {
    resourceKey: "m62726f777365722e7374617475732e6e6f7369746573",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.nothingfrombrowser": {
    resourceKey: "m62726f777365722e7374617475732e6e6f7468696e6766726f6d62726f77736572",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.nothingnew": {
    resourceKey: "m62726f777365722e7374617475732e6e6f7468696e676e6577",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.nothingrightnow": {
    resourceKey: "m62726f777365722e7374617475732e6e6f7468696e6772696768746e6f77",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.nothingwaiting": {
    resourceKey: "m62726f777365722e7374617475732e6e6f7468696e6777616974696e67",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.notpaired": {
    resourceKey: "m62726f777365722e7374617475732e6e6f74706169726564",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e6e6f74706169726564_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e6e6f74706169726564_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e6e6f74706169726564_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e6e6f74706169726564_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.notpairedheadline": {
    resourceKey: "m62726f777365722e7374617475732e6e6f74706169726564686561646c696e65",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.notreaching": {
    resourceKey: "m62726f777365722e7374617475732e6e6f747265616368696e67",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.nowordyet": {
    resourceKey: "m62726f777365722e7374617475732e6e6f776f7264796574",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.openandadd": {
    resourceKey: "m62726f777365722e7374617475732e6f70656e616e64616464",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.pagesoff": {
    resourceKey: "m62726f777365722e7374617475732e70616765736f6666",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.pausedhere": {
    resourceKey: "m62726f777365722e7374617475732e70617573656468657265",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.pausedoesnthold": {
    resourceKey: "m62726f777365722e7374617475732e7061757365646f65736e74686f6c64",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.pressure": {
    resourceKey: "m62726f777365722e7374617475732e7072657373757265",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.reaching": {
    resourceKey: "m62726f777365722e7374617475732e7265616368696e67",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.readthenchoose": {
    resourceKey: "m62726f777365722e7374617475732e726561647468656e63686f6f7365",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.sitesneedattention": {
    resourceKey: "m62726f777365722e7374617475732e73697465736e656564617474656e74696f6e",
    formatIntent: "cardinal",
    selectorVar: "count",
    arguments: [
      { name: "count", type: "cardinal", min: 0, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.somecouldnt": {
    resourceKey: "m62726f777365722e7374617475732e736f6d65636f756c646e74",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.stopleavinghostout": {
    resourceKey: "m62726f777365722e7374617475732e73746f706c656176696e67686f73746f7574",
    formatIntent: "text",
    arguments: [
      { name: "value1", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.storefull": {
    resourceKey: "m62726f777365722e7374617475732e73746f726566756c6c",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e73746f726566756c6c_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e73746f726566756c6c_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e73746f726566756c6c_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e73746f726566756c6c_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.turnpageson": {
    resourceKey: "m62726f777365722e7374617475732e7475726e70616765736f6e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.unavailable": {
    resourceKey: "m62726f777365722e7374617475732e756e617661696c61626c65",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.unavailablereason": {
    resourceKey: "m62726f777365722e7374617475732e756e617661696c61626c65726561736f6e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.untilanswers": {
    resourceKey: "m62726f777365722e7374617475732e756e74696c616e7377657273",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.untilpaired": {
    resourceKey: "m62726f777365722e7374617475732e756e74696c706169726564",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.untilroom": {
    resourceKey: "m62726f777365722e7374617475732e756e74696c726f6f6d",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.untilsaved": {
    resourceKey: "m62726f777365722e7374617475732e756e74696c7361766564",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.untilupdated": {
    resourceKey: "m62726f777365722e7374617475732e756e74696c75706461746564",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.untilyouadd": {
    resourceKey: "m62726f777365722e7374617475732e756e74696c796f75616464",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.untilyoudo": {
    resourceKey: "m62726f777365722e7374617475732e756e74696c796f75646f",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.updateapp": {
    resourceKey: "m62726f777365722e7374617475732e757064617465617070",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e757064617465617070_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e757064617465617070_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e757064617465617070_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e757064617465617070_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.updateappheadline": {
    resourceKey: "m62726f777365722e7374617475732e757064617465617070686561646c696e65",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.updatechecking": {
    resourceKey: "m62726f777365722e7374617475732e757064617465636865636b696e67",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e757064617465636865636b696e67_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e757064617465636865636b696e67_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e757064617465636865636b696e67_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e757064617465636865636b696e67_v636f6d7075746572",
    arguments: [
      { name: "browser", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.updateextension": {
    resourceKey: "m62726f777365722e7374617475732e757064617465657874656e73696f6e",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.updatefirefoxmanual": {
    resourceKey: "m62726f777365722e7374617475732e75706461746566697265666f786d616e75616c",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e75706461746566697265666f786d616e75616c_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e75706461746566697265666f786d616e75616c_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e75706461746566697265666f786d616e75616c_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e75706461746566697265666f786d616e75616c_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.updatepending": {
    resourceKey: "m62726f777365722e7374617475732e75706461746570656e64696e67",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e75706461746570656e64696e67_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e75706461746570656e64696e67_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e75706461746570656e64696e67_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e75706461746570656e64696e67_v636f6d7075746572",
    arguments: [
      { name: "browser", type: "string", min: null, max: null, numericStyle: "ungrouped" },
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.updateready": {
    resourceKey: "m62726f777365722e7374617475732e7570646174657265616479",
    formatIntent: "text",
    arguments: [
    ],
  },
  "browser.status.updatesafarimanual": {
    resourceKey: "m62726f777365722e7374617475732e7570646174657361666172696d616e75616c",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e7570646174657361666172696d616e75616c_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e7570646174657361666172696d616e75616c_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e7570646174657361666172696d616e75616c_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e7570646174657361666172696d616e75616c_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.waitedweek": {
    resourceKey: "m62726f777365722e7374617475732e7761697465647765656b",
    formatIntent: "enum",
    selectorVar: "place",
    enumValues: ["computer", "iphone", "ipad"],
    enumDefault: "computer",
    variantKeys: {
      "computer": "m62726f777365722e7374617475732e7761697465647765656b_v636f6d7075746572",
      "iphone": "m62726f777365722e7374617475732e7761697465647765656b_v6970686f6e65",
      "ipad": "m62726f777365722e7374617475732e7761697465647765656b_v69706164",
    },
    defaultKey: "m62726f777365722e7374617475732e7761697465647765656b_v636f6d7075746572",
    arguments: [
      { name: "place", type: "string", min: null, max: null, numericStyle: "ungrouped" },
    ],
  },
  "browser.status.waitedweekheadline": {
    resourceKey: "m62726f777365722e7374617475732e7761697465647765656b686561646c696e65",
    formatIntent: "text",
    arguments: [
    ],
  },
};

const BUNDLES = new Map();

function getBundle(locale, useIsolating) {
  const cacheKey = `${locale}:${useIsolating}`;
  let bundle = BUNDLES.get(cacheKey);
  if (!bundle) {
    const locInfo = LOCALES[locale];
    if (!locInfo) throw new Error(`Unknown locale: ${locale}`);
    const ftlSource = CATALOGS[locale];
    if (ftlSource === undefined) throw new Error(`Unknown catalog: ${locale}`);
    const resource = new FluentResource(ftlSource);
    bundle = new FluentBundle(locInfo.bundleLocale, { useIsolating });
    const errors = bundle.addResource(resource);
    if (errors.length > 0) throw new Error(`FTL errors: ${errors.join(", ")}`);
    BUNDLES.set(cacheKey, bundle);
  }
  return bundle;
}

function render(locale, messageId, args = [], { useIsolating = true } = {}) {
  if (typeof useIsolating !== "boolean") throw new Error("Expected boolean useIsolating");
  const locInfo = LOCALES[locale];
  if (!locInfo) throw new Error(`Unknown locale: ${locale}`);

  const msgInfo = MESSAGES[messageId];
  if (!msgInfo) throw new Error(`Unknown message: ${messageId}`);

  const seen = new Set();
  for (const [k] of args) {
    if (seen.has(k)) throw new Error(`Duplicate argument: ${k}`);
    seen.add(k);
  }

  const declaredMap = new Map(msgInfo.arguments.map(a => [a.name, a]));
  for (const [k] of args) {
    if (!declaredMap.has(k)) throw new Error(`Unknown argument: ${k}`);
  }
  for (const k of declaredMap.keys()) {
    if (!seen.has(k)) throw new Error(`Missing argument: ${k}`);
  }

  const fArgs = {};
  let selectedVariant = msgInfo.enumDefault || null;

  for (const [k, v] of args) {
    const spec = declaredMap.get(k);
    if (spec.type === "string") {
      if (typeof v !== "string") throw new Error(`Expected string for ${k}`);
      if (msgInfo.formatIntent === "enum" && msgInfo.selectorVar === k) {
        if (msgInfo.enumValues.includes(v)) {
          selectedVariant = v;
        } else {
          selectedVariant = msgInfo.enumDefault;
        }
      }
      fArgs[k] = v;
    } else if (spec.type === "boolean") {
      if (typeof v !== "boolean") throw new Error(`Expected boolean for ${k}`);
      fArgs[k] = v ? "true" : "false";
    } else if (spec.type === "integer") {
      if (v && typeof v === "object" && v.type === "cardinal") throw new Error(`Expected integer, got cardinal for ${k}`);
      const num = (v && typeof v === "object" && v.type === "integer") ? v.value : v;
      if (typeof num !== "number" && typeof num !== "bigint") throw new Error(`Expected number for ${k}`);
      if (typeof num === "number" && (!Number.isFinite(num) || !Number.isInteger(num))) throw new Error(`Expected integer number for ${k}`);
      const nVal = BigInt(num);
      const minVal = spec.min !== null ? BigInt(spec.min) : -9007199254740991n;
      const maxVal = spec.max !== null ? BigInt(spec.max) : 9007199254740991n;
      const effMin = minVal < -9007199254740991n ? -9007199254740991n : minVal;
      const effMax = maxVal > 9007199254740991n ? 9007199254740991n : maxVal;
      if (nVal < effMin || nVal > effMax) throw new Error(`Out of range for ${k}`);
      fArgs[k] = Number(nVal);
    } else if (spec.type === "cardinal") {
      if (v && typeof v === "object" && v.type === "integer") throw new Error(`Expected cardinal, got integer for ${k}`);
      const num = (v && typeof v === "object" && v.type === "cardinal") ? v.value : v;
      if (typeof num !== "number" && typeof num !== "bigint") throw new Error(`Expected number for ${k}`);
      if (typeof num === "number" && (!Number.isFinite(num) || !Number.isInteger(num))) throw new Error(`Expected integer number for ${k}`);
      const nVal = BigInt(num);
      const minVal = spec.min !== null ? BigInt(spec.min) : -2147483648n;
      const maxVal = spec.max !== null ? BigInt(spec.max) : 2147483647n;
      const effMin = minVal < -2147483648n ? -2147483648n : minVal;
      const effMax = maxVal > 2147483647n ? 2147483647n : maxVal;
      if (nVal < effMin || nVal > effMax) throw new Error(`Out of range for ${k}`);
      fArgs[k] = Number(nVal);
    }
  }

  if (msgInfo.formatIntent === "cardinal") {
    const select = CATEGORIES[locInfo.cardinal];
    fArgs.i18nCategory = select ? select(Math.abs(fArgs[msgInfo.selectorVar])) : "other";
  }

  const bundle = getBundle(locale, useIsolating);

  const targetKey = msgInfo.formatIntent === "enum" ? (msgInfo.variantKeys[selectedVariant] || msgInfo.defaultKey) : msgInfo.resourceKey;
  const message = bundle.getMessage(targetKey);
  if (!message || !message.value) throw new Error(`Message not found: ${targetKey}`);

  const formatErrors = [];
  const output = bundle.formatPattern(message.value, fArgs, formatErrors);
  if (formatErrors.length > 0) throw new Error(`Format error: ${formatErrors.join(", ")}`);
  return output;
}
globalThis.SolstoneI18nBundles ??= Object.create(null);
globalThis.SolstoneI18nBundles["browser"] = Object.freeze({render, integer, cardinal, messageIds: Object.freeze(Object.keys(MESSAGES))});
})();
