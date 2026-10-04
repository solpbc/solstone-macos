// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

globalThis.SolstoneNativeBrowserSchemas = {
  "envelope": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "solstone-native-browser:envelope",
    "title": "Solstone Native Browser Wire Envelope",
    "oneOf": [
      {
        "$ref": "#/$defs/hello"
      },
      {
        "$ref": "#/$defs/hello_ack"
      },
      {
        "$ref": "#/$defs/unsupported"
      },
      {
        "$ref": "#/$defs/state"
      },
      {
        "$ref": "#/$defs/batch"
      },
      {
        "$ref": "#/$defs/boundary"
      },
      {
        "$ref": "#/$defs/accepted"
      },
      {
        "$ref": "#/$defs/bye"
      }
    ],
    "$defs": {
      "hello": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "type",
          "protocol",
          "version",
          "brand",
          "inst"
        ],
        "properties": {
          "type": {
            "const": "hello"
          },
          "protocol": {
            "type": "integer",
            "minimum": 0,
            "maximum": 9007199254740991
          },
          "version": {
            "type": "string",
            "maxLength": 64
          },
          "brand": {
            "enum": [
              "chrome",
              "edge",
              "firefox"
            ]
          },
          "inst": {
            "$ref": "solstone-journal-format:browser-jsonl#/$defs/instString",
            "minLength": 1
          }
        }
      },
      "hello_ack": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "type",
          "capture",
          "delivery",
          "freshness_ms"
        ],
        "properties": {
          "type": {
            "const": "hello_ack"
          },
          "capture": {
            "enum": [
              "unavailable",
              "not_paired",
              "permitted",
              "paused",
              "intake_off"
            ]
          },
          "delivery": {
            "enum": [
              "unknown",
              "kept_locally",
              "delivered",
              "idle",
              "failed"
            ]
          },
          "freshness_ms": {
            "type": "integer",
            "minimum": 0,
            "maximum": 15000
          },
          "destination_generation": {
            "anyOf": [
              {
                "type": "string",
                "minLength": 1,
                "maxLength": 128
              },
              {
                "type": "null"
              }
            ]
          },
          "period_id": {
            "anyOf": [
              {
                "type": "string",
                "minLength": 1,
                "maxLength": 128
              },
              {
                "type": "null"
              }
            ]
          },
          "failure": {
            "enum": [
              "relay_unavailable",
              "journal_rejected",
              "local_io",
              "resource_exhausted",
              "queue_full",
              "age_policy",
              "unaccepted_lost"
            ]
          },
          "version": {
            "type": "string",
            "maxLength": 64
          },
          "custody": {
            "type": "object",
            "additionalProperties": true,
            "required": [
              "full",
              "stale"
            ],
            "properties": {
              "full": {
                "type": "boolean"
              },
              "stale": {
                "type": "boolean"
              }
            }
          }
        },
        "allOf": [
          {
            "if": {
              "properties": {
                "capture": {
                  "enum": [
                    "unavailable",
                    "not_paired"
                  ]
                }
              }
            },
            "then": {
              "properties": {
                "destination_generation": {
                  "type": "null"
                },
                "period_id": {
                  "type": "null"
                }
              }
            }
          },
          {
            "if": {
              "properties": {
                "capture": {
                  "const": "permitted"
                }
              }
            },
            "then": {
              "required": [
                "destination_generation",
                "period_id"
              ],
              "properties": {
                "destination_generation": {
                  "type": "string",
                  "minLength": 1,
                  "maxLength": 128
                },
                "period_id": {
                  "type": "string",
                  "minLength": 1,
                  "maxLength": 128
                }
              }
            }
          },
          {
            "if": {
              "properties": {
                "capture": {
                  "enum": [
                    "paused",
                    "intake_off"
                  ]
                }
              }
            },
            "then": {
              "required": [
                "destination_generation"
              ],
              "properties": {
                "destination_generation": {
                  "type": "string",
                  "minLength": 1,
                  "maxLength": 128
                }
              }
            }
          },
          {
            "if": {
              "properties": {
                "delivery": {
                  "const": "failed"
                }
              }
            },
            "then": {
              "required": [
                "failure"
              ]
            }
          }
        ]
      },
      "unsupported": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "type",
          "protocol",
          "behind"
        ],
        "properties": {
          "type": {
            "const": "unsupported"
          },
          "protocol": {
            "type": "integer",
            "minimum": 0,
            "maximum": 9007199254740991
          },
          "version": {
            "type": "string",
            "maxLength": 64
          },
          "behind": {
            "enum": [
              "app",
              "extension"
            ]
          }
        }
      },
      "state": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "type",
          "capture",
          "delivery",
          "freshness_ms"
        ],
        "properties": {
          "type": {
            "const": "state"
          },
          "capture": {
            "enum": [
              "unavailable",
              "not_paired",
              "permitted",
              "paused",
              "intake_off"
            ]
          },
          "delivery": {
            "enum": [
              "unknown",
              "kept_locally",
              "delivered",
              "idle",
              "failed"
            ]
          },
          "freshness_ms": {
            "type": "integer",
            "minimum": 0,
            "maximum": 15000
          },
          "destination_generation": {
            "anyOf": [
              {
                "type": "string",
                "minLength": 1,
                "maxLength": 128
              },
              {
                "type": "null"
              }
            ]
          },
          "period_id": {
            "anyOf": [
              {
                "type": "string",
                "minLength": 1,
                "maxLength": 128
              },
              {
                "type": "null"
              }
            ]
          },
          "failure": {
            "enum": [
              "relay_unavailable",
              "journal_rejected",
              "local_io",
              "resource_exhausted",
              "queue_full",
              "age_policy",
              "unaccepted_lost"
            ]
          },
          "version": {
            "type": "string",
            "maxLength": 64
          },
          "custody": {
            "type": "object",
            "additionalProperties": true,
            "required": [
              "full",
              "stale"
            ],
            "properties": {
              "full": {
                "type": "boolean"
              },
              "stale": {
                "type": "boolean"
              }
            }
          }
        },
        "allOf": [
          {
            "if": {
              "properties": {
                "capture": {
                  "enum": [
                    "unavailable",
                    "not_paired"
                  ]
                }
              }
            },
            "then": {
              "properties": {
                "destination_generation": {
                  "type": "null"
                },
                "period_id": {
                  "type": "null"
                }
              }
            }
          },
          {
            "if": {
              "properties": {
                "capture": {
                  "const": "permitted"
                }
              }
            },
            "then": {
              "required": [
                "destination_generation",
                "period_id"
              ],
              "properties": {
                "destination_generation": {
                  "type": "string",
                  "minLength": 1,
                  "maxLength": 128
                },
                "period_id": {
                  "type": "string",
                  "minLength": 1,
                  "maxLength": 128
                }
              }
            }
          },
          {
            "if": {
              "properties": {
                "capture": {
                  "enum": [
                    "paused",
                    "intake_off"
                  ]
                }
              }
            },
            "then": {
              "required": [
                "destination_generation"
              ],
              "properties": {
                "destination_generation": {
                  "type": "string",
                  "minLength": 1,
                  "maxLength": 128
                }
              }
            }
          },
          {
            "if": {
              "properties": {
                "delivery": {
                  "const": "failed"
                }
              }
            },
            "then": {
              "required": [
                "failure"
              ]
            }
          }
        ]
      },
      "batch": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "type",
          "destination_generation",
          "inst",
          "batch_id",
          "queued_at_ms",
          "records"
        ],
        "properties": {
          "type": {
            "const": "batch"
          },
          "destination_generation": {
            "type": "string",
            "minLength": 1,
            "maxLength": 128
          },
          "inst": {
            "$ref": "solstone-journal-format:browser-jsonl#/$defs/instString",
            "minLength": 1
          },
          "batch_id": {
            "type": "string",
            "pattern": "^[0-9a-f]{32}$"
          },
          "queued_at_ms": {
            "$ref": "solstone-journal-format:browser-jsonl#/$defs/timestamp"
          },
          "records": {
            "type": "array",
            "minItems": 1,
            "maxItems": 3000,
            "items": {
              "$ref": "solstone-journal-format:browser-jsonl"
            }
          }
        }
      },
      "boundary": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "type",
          "destination_generation",
          "period_id"
        ],
        "properties": {
          "type": {
            "const": "boundary"
          },
          "destination_generation": {
            "type": "string",
            "minLength": 1,
            "maxLength": 128
          },
          "period_id": {
            "type": "string",
            "minLength": 1,
            "maxLength": 128
          }
        }
      },
      "accepted": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "type",
          "result",
          "destination_generation",
          "inst",
          "batch_id"
        ],
        "properties": {
          "type": {
            "const": "accepted"
          },
          "result": {
            "enum": [
              "accepted",
              "duplicate",
              "rejected"
            ]
          },
          "destination_generation": {
            "type": "string",
            "minLength": 1,
            "maxLength": 128
          },
          "inst": {
            "$ref": "solstone-journal-format:browser-jsonl#/$defs/instString",
            "minLength": 1
          },
          "batch_id": {
            "type": "string",
            "pattern": "^[0-9a-f]{32}$"
          },
          "period_id": {
            "type": "string",
            "minLength": 1,
            "maxLength": 128
          },
          "reason": {
            "enum": [
              "snapshot_required",
              "resource_exhausted",
              "queue_full",
              "age_policy",
              "malformed",
              "oversize",
              "unaccepted_lost",
              "stale_generation",
              "expired_unaccepted"
            ]
          },
          "class": {
            "enum": [
              "retryable",
              "permanent"
            ]
          }
        },
        "oneOf": [
          {
            "properties": {
              "result": {
                "enum": [
                  "accepted",
                  "duplicate"
                ]
              }
            },
            "required": [
              "period_id"
            ],
            "not": {
              "anyOf": [
                {
                  "required": [
                    "reason"
                  ]
                },
                {
                  "required": [
                    "class"
                  ]
                }
              ]
            }
          },
          {
            "properties": {
              "result": {
                "const": "rejected"
              },
              "reason": {
                "enum": [
                  "snapshot_required",
                  "resource_exhausted",
                  "queue_full",
                  "age_policy"
                ]
              },
              "class": {
                "const": "retryable"
              }
            },
            "required": [
              "reason",
              "class"
            ],
            "not": {
              "anyOf": [
                {
                  "required": [
                    "period_id"
                  ]
                }
              ]
            }
          },
          {
            "properties": {
              "result": {
                "const": "rejected"
              },
              "reason": {
                "enum": [
                  "malformed",
                  "oversize",
                  "unaccepted_lost",
                  "stale_generation",
                  "expired_unaccepted"
                ]
              },
              "class": {
                "const": "permanent"
              }
            },
            "required": [
              "reason",
              "class"
            ],
            "not": {
              "anyOf": [
                {
                  "required": [
                    "period_id"
                  ]
                }
              ]
            }
          }
        ]
      },
      "bye": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "type",
          "reason"
        ],
        "properties": {
          "type": {
            "const": "bye"
          },
          "reason": {
            "enum": [
              "shutdown",
              "replaced",
              "update"
            ]
          }
        }
      }
    }
  },
  "journal": {
    "$schema": "https://json-schema.org/draft/2020-12/schema",
    "$id": "solstone-journal-format:browser-jsonl",
    "title": "Browser stream JSONL",
    "oneOf": [
      {
        "$ref": "#/$defs/snapshot"
      },
      {
        "$ref": "#/$defs/delta"
      }
    ],
    "$defs": {
      "timestamp": {
        "type": "integer",
        "minimum": 0,
        "maximum": 9007199254740991
      },
      "textBlock": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "text"
        ],
        "properties": {
          "text": {
            "type": "string",
            "maxLength": 2001
          },
          "id": {
            "$ref": "#/$defs/idString"
          },
          "type": {
            "$ref": "#/$defs/typeString"
          },
          "attrs": {
            "$ref": "#/$defs/blockAttributes"
          },
          "depth": {
            "$ref": "#/$defs/blockDepth"
          }
        }
      },
      "removeBlock": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "id"
        ],
        "properties": {
          "id": {
            "$ref": "#/$defs/idString"
          },
          "text": {
            "type": "string",
            "maxLength": 2001
          },
          "type": {
            "$ref": "#/$defs/typeString"
          },
          "depth": {
            "$ref": "#/$defs/blockDepth"
          },
          "attrs": {
            "$ref": "#/$defs/blockAttributes"
          }
        }
      },
      "snapshot": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "t",
          "ts",
          "blocks"
        ],
        "properties": {
          "t": {
            "const": "segment_start"
          },
          "ts": {
            "$ref": "#/$defs/timestamp"
          },
          "inst": {
            "$ref": "#/$defs/instString"
          },
          "ctx": {
            "$ref": "#/$defs/ctxString"
          },
          "title": {
            "$ref": "#/$defs/titleString"
          },
          "url": {
            "$ref": "#/$defs/urlString"
          },
          "site": {
            "$ref": "#/$defs/siteString"
          },
          "adapter": {
            "$ref": "#/$defs/adapterString"
          },
          "rel": {
            "type": "number"
          },
          "n": {
            "type": "integer",
            "minimum": 0,
            "maximum": 1500
          },
          "blocks": {
            "type": "array",
            "maxItems": 1500,
            "items": {
              "$ref": "#/$defs/textBlock"
            }
          }
        }
      },
      "addUpdateDelta": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "t",
          "ts",
          "op",
          "block"
        ],
        "properties": {
          "t": {
            "const": "delta"
          },
          "ts": {
            "$ref": "#/$defs/timestamp"
          },
          "op": {
            "enum": [
              "add",
              "update"
            ]
          },
          "block": {
            "$ref": "#/$defs/textBlock"
          },
          "inst": {
            "$ref": "#/$defs/instString"
          },
          "ctx": {
            "$ref": "#/$defs/ctxString"
          },
          "title": {
            "$ref": "#/$defs/titleString"
          },
          "url": {
            "$ref": "#/$defs/urlString"
          },
          "site": {
            "$ref": "#/$defs/siteString"
          },
          "adapter": {
            "$ref": "#/$defs/adapterString"
          },
          "rel": {
            "type": "number"
          }
        }
      },
      "removeDelta": {
        "type": "object",
        "additionalProperties": true,
        "required": [
          "t",
          "ts",
          "op",
          "block"
        ],
        "properties": {
          "t": {
            "const": "delta"
          },
          "ts": {
            "$ref": "#/$defs/timestamp"
          },
          "op": {
            "const": "remove"
          },
          "block": {
            "$ref": "#/$defs/removeBlock"
          },
          "inst": {
            "$ref": "#/$defs/instString"
          },
          "ctx": {
            "$ref": "#/$defs/ctxString"
          },
          "title": {
            "$ref": "#/$defs/titleString"
          },
          "url": {
            "$ref": "#/$defs/urlString"
          },
          "site": {
            "$ref": "#/$defs/siteString"
          },
          "adapter": {
            "$ref": "#/$defs/adapterString"
          },
          "rel": {
            "type": "number"
          }
        }
      },
      "delta": {
        "oneOf": [
          {
            "$ref": "#/$defs/addUpdateDelta"
          },
          {
            "$ref": "#/$defs/removeDelta"
          }
        ]
      },
      "titleString": {
        "type": "string",
        "maxLength": 8192
      },
      "urlString": {
        "type": "string",
        "maxLength": 32768
      },
      "siteString": {
        "type": "string",
        "maxLength": 512
      },
      "adapterString": {
        "type": "string",
        "maxLength": 64
      },
      "ctxString": {
        "type": "string",
        "maxLength": 256
      },
      "instString": {
        "type": "string",
        "maxLength": 128
      },
      "idString": {
        "type": "string",
        "maxLength": 256
      },
      "typeString": {
        "type": "string",
        "maxLength": 64
      },
      "linkHostString": {
        "type": "string",
        "maxLength": 512
      },
      "levelString": {
        "type": "string",
        "maxLength": 16
      },
      "blockAttributes": {
        "type": "object",
        "additionalProperties": true,
        "properties": {
          "label": {
            "type": "string",
            "maxLength": 300
          },
          "level": {
            "$ref": "#/$defs/levelString"
          },
          "linkHost": {
            "$ref": "#/$defs/linkHostString"
          }
        }
      },
      "blockDepth": {
        "type": "integer",
        "minimum": 0,
        "maximum": 4096
      }
    },
    "x-journal-contract": {
      "format_id": "browser-jsonl",
      "schema_owner": "solstone-core-ingest-contract",
      "reference_writer": "native desktop apps via authenticated ingest",
      "allowed_producers": [
        "authenticated linked-device clients"
      ],
      "write_discipline": "immutable finalized JSONL, one file for the segment period. Allocation may disambiguate the stream name from {label}_browser. The extension is not a linked-device identity.",
      "file_kind": "browser_jsonl",
      "key_fields": [
        "t",
        "ts",
        "site",
        "op",
        "block",
        "blocks"
      ],
      "producer_write_paths": [
        "chronicle/YYYYMMDD/{label}_browser/HHMMSS_LEN/browser_pages.jsonl"
      ]
    }
  }
};
