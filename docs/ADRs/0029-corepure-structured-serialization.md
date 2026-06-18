---
title: "ADR 0029 - CorePure Structured Serialization"
description:
  "Adds explicit canonical JSON serialization for CorePure structured values while keeping string
  interpolation scalar-only."
sidebar:
  label: "0029. CorePure serialization"
  order: 29
status: proposed
date: 2026-04-29
superseded_by: null
related:
  - docs/Architecture/05-wire-language.md
  - docs/Reference/Wire/pure-execution.md
  - docs/ADRs/0021-wire-source-elaborates-to-circuits.md
  - docs/ADRs/0023-corepure-expression-surface.md
  - docs/ADRs/0026-wire-failure-taxonomy.md
  - docs/ADRs/0050-wire-corepure-output-residue.md
---

# ADR 0029 - CorePure Structured Serialization

## Status

Proposed - fills the structured-stringification gap left open by ADR 0023.

## Context

ADR 0023 intentionally keeps string interpolation scalar-only. This is the right default:

```wire
"Score: ${score}"
```

is readable, while:

```wire
"Items: ${items}"
```

should not accidentally commit Cortex to unspecified record/list formatting.

Real prompt and report templates will still need to include structured values. The first such use
should not re-open generic `Show` semantics or host callbacks. CorePure needs an explicit,
deterministic serialization primitive.

## Decision

CorePure should add two structured serialization primitives:

```text
toJson : JsonSerializable -> String
fromJson : String -> JsonValue
```

`JsonSerializable` is the recursive subset of CorePure values that can be represented as JSON:

- null;
- booleans;
- numbers;
- strings;
- lists of JSON-serializable values;
- records whose field values are JSON-serializable.

Lambdas and configured executor values are not serializable. Future opaque values are not
serializable unless a later ADR admits them.

String interpolation remains scalar-only. Authors serialize structured values explicitly:

```text
-> prompt: Prompt = ''
  Analyze these items:
  ${toJson evidence.items}
'';
```

### Canonical JSON

`toJson` emits canonical JSON:

- record keys are emitted in lexicographic order by UTF-8 byte sequence;
- no insignificant whitespace is emitted;
- strings use JSON escaping;
- booleans, null, arrays, and objects use standard JSON tokens;
- numbers are finite decimal values rendered without leading plus signs, insignificant leading
  zeroes, or insignificant fractional trailing zeroes;
- exponent notation is not emitted in the first slice;
- negative zero is rendered as `0`;
- NaN and infinity are impossible CorePure numbers and are not representable.

This is a serialization function, not a schema validator. It does not check that a value satisfies a
Wire contract. Contract validation remains a Wire/runtime boundary concern.

`fromJson` accepts standard JSON text and returns the corresponding CorePure JSON value. It is a
parser, not a contract validator: malformed JSON is a typed pure failure, and valid JSON still needs
any contract checks required by a later boundary.

### Budget And Failures

Serialization and parsing are budgeted. Cost must account for traversal and emitted or consumed text
size. Budget exhaustion is a typed CorePure failure under ADR 0026.

Serializing a non-serializable value is a typed CorePure failure. Because `toJson` is ordinary
CorePure, the failure occurs during elaboration when the argument is statically known and during
runtime pure execution when it depends on input ports.

### No Generic Show

CorePure should not add a generic `show`, implicit record interpolation, pretty-printer, or
host-defined stringification in this slice. Pretty JSON, markdown tables, CSV, and contract-aware
renderers can be proposed later as explicit closed stdlib additions.

## Alternatives considered

- **Auto-stringify records and lists in interpolation.** Rejected because it makes structural
  formatting implicit and hard to change.
- **Add a generic `show` function.** Rejected because it creates an underspecified textual format
  for every value kind.
- **Use host callbacks for rendering.** Rejected because CorePure is closed and authority-free.
- **Add both compact and pretty JSON now.** Rejected because compact canonical JSON is enough for
  deterministic prompt/report embedding; pretty rendering can be admitted later if examples need it.

## Consequences

### Positive

- Prompt templates can include structured values without unsafe implicit interpolation.
- Serialization is deterministic, budgeted, and testable.
- The first stdlib addition is narrow and contract-independent.
- CorePure remains host-independent and authority-free.

### Negative

- Human-facing prompts may need explicit formatting helpers later.
- Large structured values can exhaust budget when serialized.
- Authors must write `${toJson value}` explicitly for records and lists.

### Obligations

- Add `toJson` and `fromJson` to the closed CorePure stdlib.
- Add canonical JSON golden tests for key ordering, escaping, nesting, and numbers.
- Add typed failure tests for lambdas and non-serializable future values.
- Add budget tests based on traversal and output size.
- Keep interpolation scalar-only in parser and evaluator tests.

## Related

- [ADR 0021 - Wire Source Elaborates to Circuits](./0021-wire-source-elaborates-to-circuits.md)
- [ADR 0023 - CorePure Expression Surface](./0023-corepure-expression-surface.md)
- [ADR 0026 - Wire Failure Taxonomy](./0026-wire-failure-taxonomy.md)
- [Wire Pure Execution Reference](../Reference/Wire/pure-execution.md)
