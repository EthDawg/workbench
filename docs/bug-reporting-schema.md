# Bug report protocol schema

Shared build target for the native producer and the receipt verifier described in [Report a problem](bug-reporting.md). This is a contract fixture, not a live customer report or an implemented validator. Extract the first JSON block as `manifest.schema.json`; the second is a synthetic valid text-only input. Use JSON Schema draft 2020-12 with **format assertions enabled**, not only annotations.

## Manifest

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:workbench:bug-report:manifest:1",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "schema_version",
    "report_id",
    "created_at",
    "explanation",
    "build",
    "context",
    "attachments"
  ],
  "properties": {
    "schema_version": {
      "const": 1
    },
    "report_id": {
      "type": "string",
      "pattern": "^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$"
    },
    "created_at": {
      "type": [
        "string",
        "null"
      ],
      "format": "date-time"
    },
    "explanation": {
      "type": "string",
      "maxLength": 2048
    },
    "reply_email": {
      "type": "string",
      "minLength": 3,
      "maxLength": 254,
      "format": "email"
    },
    "build": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "edition",
        "version",
        "build",
        "revision",
        "dirty",
        "kind",
        "os_version",
        "os_build"
      ],
      "properties": {
        "edition": {
          "enum": [
            "stable",
            "preview"
          ]
        },
        "version": {
          "type": "string",
          "maxLength": 64,
          "minLength": 1
        },
        "build": {
          "type": "string",
          "maxLength": 64,
          "minLength": 1
        },
        "revision": {
          "type": "string",
          "pattern": "^(unknown|[a-f0-9]{40})$"
        },
        "dirty": {
          "type": [
            "boolean",
            "null"
          ]
        },
        "kind": {
          "enum": [
            "release",
            "local",
            "unknown"
          ]
        },
        "os_version": {
          "type": "string",
          "maxLength": 64,
          "minLength": 1
        },
        "os_build": {
          "type": "string",
          "maxLength": 32,
          "minLength": 1
        }
      }
    },
    "context": {
      "type": "object",
      "additionalProperties": false,
      "required": [],
      "properties": {
        "surface": {
          "enum": [
            "help",
            "home",
            "dictate",
            "meetings",
            "snap",
            "readback",
            "present",
            "personas",
            "history",
            "library",
            "settings",
            "unknown"
          ]
        },
        "active_tools": {
          "type": "array",
          "maxItems": 9,
          "uniqueItems": true,
          "items": {
            "enum": [
              "dictate",
              "meetings",
              "snap",
              "readback",
              "draw",
              "present",
              "persona",
              "timer",
              "legacy_read"
            ]
          }
        },
        "permissions": {
          "type": "object",
          "additionalProperties": false,
          "required": [],
          "properties": {
            "microphone": {
              "enum": [
                "not_requested",
                "authorized",
                "denied",
                "restricted",
                "unknown"
              ]
            },
            "screen_capture": {
              "enum": [
                "not_requested",
                "authorized",
                "denied",
                "restricted",
                "unknown"
              ]
            },
            "accessibility": {
              "enum": [
                "not_requested",
                "authorized",
                "denied",
                "restricted",
                "unknown"
              ]
            }
          }
        },
        "recognition": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "provider",
            "ready"
          ],
          "properties": {
            "provider": {
              "enum": [
                "parakeet",
                "local_server",
                "unknown"
              ]
            },
            "ready": {
              "type": [
                "boolean",
                "null"
              ]
            }
          }
        },
        "error_code": {
          "type": "string",
          "pattern": "^[a-z][a-z0-9_.]{0,63}$"
        },
        "screenshot": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "width",
            "height",
            "scale"
          ],
          "properties": {
            "width": {
              "type": "integer",
              "minimum": 1,
              "maximum": 16384
            },
            "height": {
              "type": "integer",
              "minimum": 1,
              "maximum": 16384
            },
            "scale": {
              "type": "number",
              "exclusiveMinimum": 0,
              "maximum": 8
            }
          }
        }
      }
    },
    "attachments": {
      "type": "array",
      "minItems": 0,
      "maxItems": 2,
      "items": {
        "oneOf": [
          {
            "type": "object",
            "additionalProperties": false,
            "required": [
              "name",
              "content_type",
              "bytes",
              "sha256"
            ],
            "properties": {
              "name": {
                "const": "screenshot.png"
              },
              "content_type": {
                "const": "image/png"
              },
              "bytes": {
                "type": "integer",
                "minimum": 1,
                "maximum": 8388608
              },
              "sha256": {
                "type": "string",
                "pattern": "^[a-f0-9]{64}$"
              }
            }
          },
          {
            "type": "object",
            "additionalProperties": false,
            "required": [
              "name",
              "content_type",
              "bytes",
              "sha256"
            ],
            "properties": {
              "name": {
                "const": "voice.wav"
              },
              "content_type": {
                "const": "audio/wav"
              },
              "bytes": {
                "type": "integer",
                "minimum": 1,
                "maximum": 4194304
              },
              "sha256": {
                "type": "string",
                "pattern": "^[a-f0-9]{64}$"
              }
            }
          }
        ]
      },
      "allOf": [
        {
          "contains": {
            "properties": {
              "name": {
                "const": "screenshot.png"
              }
            },
            "required": [
              "name"
            ]
          },
          "minContains": 0,
          "maxContains": 1
        },
        {
          "contains": {
            "properties": {
              "name": {
                "const": "voice.wav"
              }
            },
            "required": [
              "name"
            ]
          },
          "minContains": 0,
          "maxContains": 1
        }
      ]
    }
  },
  "anyOf": [
    {
      "properties": {
        "explanation": {
          "type": "string",
          "pattern": "\\S"
        }
      }
    },
    {
      "properties": {
        "attachments": {
          "minItems": 1
        }
      }
    }
  ]
}
```

## Synthetic input

```json
{
  "schema_version": 1,
  "report_id": "a02149ed-36f5-4f10-9a21-10acfe2289b2",
  "created_at": "2026-10-06T05:00:00Z",
  "explanation": "The Snap window disappeared before I could show the problem.",
  "build": {
    "edition": "preview",
    "version": "fixture",
    "build": "fixture-1",
    "revision": "unknown",
    "dirty": null,
    "kind": "local",
    "os_version": "fixture",
    "os_build": "fixture"
  },
  "context": {
    "surface": "snap",
    "permissions": {
      "screen_capture": "unknown"
    }
  },
  "attachments": []
}
```

## Verification request and result

Revised 7 October 2026: the app sends the manifest to Sentry as `context.json` and asks the stateless [Report check](../services/report-check/README.md) verifier for receipt. The 6 October gateway receipt (revisions, removal states, failure codes) is superseded.

Request, `POST /api/v1/verify`, at most 4 KiB, strict JSON (unknown and duplicate keys rejected). `event_id` is the Sentry envelope's UUIDv4 as 32 lowercase hex; `report_id` matches the manifest; `report_id` matches the manifest (sent lowercase, compared case-insensitively); `elapsed_seconds` is a required whole number from 0 to 31,536,000, the seconds since the app received Sentry's 200 for its latest send of this `event_id`, measured on the app's own clock; `attachments` lists one to three of the fixed names with their exact byte counts and SHA-256, and always includes `context.json` (whose own digest is computed over the exact manifest bytes sent). The hashes below are illustrative placeholders, not digests of this fixture.

```json
{
  "event_id": "9ec79c33ec9942ab8353589fcb2e04dc",
  "report_id": "a02149ed-36f5-4f10-9a21-10acfe2289b2",
  "elapsed_seconds": 29,
  "attachments": [
    {
      "name": "context.json",
      "size": 512,
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000"
    }
  ]
}
```

Result, `200` with `Cache-Control: no-store`: exactly `state` (`received`, `pending`, `not_found` or `mismatch`) and `checked_at`. Errors are `405`, `413`, `422`, `429` and `503` (the last two with `Retry-After`) and never carry a state; a client treats any non-`200` or non-JSON answer like `503`. Neither shape carries credentials, private Sentry URLs or reporter content.

```json
{
  "state": "received",
  "checked_at": "2026-10-06T05:00:31Z"
}
```

## Required validation beyond JSON Schema

Revised 7 October 2026: there is no intake service, and Sentry does not validate the manifest or media. These rules belong to the **producer** (the native app, before Send) and to the operator **fetch tool** (`services/report-check/ops/report_ops.py fetch`, which re-checks a received packet). The verifier checks only identity, sizes and SHA-256 in Sentry.

- Parse UTF-8 strictly, rejecting invalid Unicode/unpaired surrogates and duplicate JSON keys before schema validation (the producer before Send; the fetch tool when it reads `context.json`). Exact manifest bytes must fit 32 KiB. `explanation` must also fit 4096 UTF-8 bytes and email 254 bytes; schema character limits alone cannot enforce these byte limits.
- Whitespace-only explanation needs at least one attachment. Schema enums describe facts; map unavailable platform state to unknown, never infer denied from an undifferentiated false result. Omit unavailable optional context. Empty required build/OS strings become `unknown` in the producer, which never emits an empty value.
- Treat `created_at` as evidence, not authorization or retention. A clock discrepancy does not block a legitimate report; Sentry's receive time governs retention. Map unavailable client time to null.
- No raw newlines/control characters in build/OS/email/error fields, and no text in optional fields outside their approved meaning. No system paths, titles, endpoint URLs or arbitrary error messages. Bound safe strings before populating the manifest rather than truncate user explanation.
- At most one descriptor per fixed attachment name. The producer confirms actual byte count, type, SHA-256 and media decode before Send: an image is at most 40 megapixels; the WAV must be PCM mono 16 kHz/16-bit and at most 60 seconds; total payload at most 16 MiB; no archives, executables, symlinks or caller-selected paths. The fetch tool re-checks byte counts and SHA-256 against `context.json` and writes only the fixed names.
- `context.screenshot` is present only with `screenshot.png`, matches decoded dimensions, and has a finite scale. Media validation does not follow links or launch players. Bound CPU, memory and decoding time.
- Context files, original note and selected attachments are reviewable content. The optional email appears in the reviewed manifest (`context.json`), never in tags, URLs or operational logs; Sentry turns `contexts.feedback.contact_email` into a `user.email` tag, so the producer leaves it out unless one-click reply is decided. Do not mark Received until the verifier has confirmed every expected attachment's size and SHA-256 in Sentry.

## Shared negative vectors

The implementation test suites must reject: blank text and no attachment; unknown top-level/nested properties; malformed/non-v4 UUID; unknown edition/permission/provider; over-limit explanation characters or UTF-8 bytes; invalid email; duplicate image descriptors with different digests; mismatched filename/MIME; zero/oversized media; missing build field; negative/noninteger dimensions; unknown SHA format; invalid date; duplicate JSON key; same report ID with changed manifest bytes. Test valid voice-only and image-only reports too. Schema checks alone do not prove file, race, service or native behavior.
