import Cortex.Wire.ContractValidation.Json

/-!
## Overview

Prop-level acceptance semantics for the Wire contract-schema validator
dialect (ADR 0085): the parsed dialect model (`SchemaNode`), the acceptance
predicate (`SchemaAccepts`), and the missing-schema gate (`SchemaOptAccepts`).

The dialect is the deliberately narrow Logos-incubated subset upstreamed as
`Cortex.Wire.ContractValidation` on the Haskell side: `type`, `enum`,
`required`, `properties`, `additionalProperties` (boolean form), `items`,
string `minLength`/`maxLength`, and numeric `minimum`/`maximum`. Lean models
the **parsed** dialect: every `InvalidSchema` branch of the Haskell keyword
readers is a parse rejection that never reaches acceptance semantics, so it
stays Haskell-tested; a `SchemaNode` is by construction a well-formed dialect
schema.

## Context

The predicate is acceptance-only. The Haskell validator is fail-fast with a
fixed check order, but the order only selects *which error* is reported;
acceptance is the conjunction of all checks, which is what this file states.
Error and path selection stay pinned by the Haskell spec
(`test/Cortex/Wire/ContractValidationSpec.hs`).

`dialectVersion` mirrors `wireContractDialectVersion` in
`src/Cortex/Wire/ContractValidation.hs`; the emitted fixture umbrella guards
the two against silent divergence.
-/

namespace Cortex.Wire
namespace ContractValidation

/-- Version of the supported schema dialect, mirroring the Haskell constant
`wireContractDialectVersion`. -/
def dialectVersion : Nat := 1

/-- Parsed dialect schema node. Field conventions mirror the Haskell keyword
readers: an absent `type` is the empty list (admits everything), an absent
`enum` is `none` (`some []` rejects everything), absent `required`/
`properties` are empty lists, and `additionalProperties? = some false` is the
only rejecting setting. Length bounds are `Int` (the image of
`Scientific.toBoundedInteger`); numeric bounds are `Rat` (the image of
`Scientific`). -/
inductive SchemaNode : Type where
  | mk
      (types : List String)
      (enum? : Option (List Json))
      (required : List String)
      (properties : List (String × SchemaNode))
      (additionalProperties? : Option Bool)
      (items? : Option SchemaNode)
      (minLength? : Option Int)
      (maxLength? : Option Int)
      (minimum? : Option Rat)
      (maximum? : Option Rat)

/-- The `enum` clause: when declared, the payload must be a structural member
of the allowed list (no coercion — `"1"` never matches `1`). -/
def EnumAccepts (enum? : Option (List Json)) (payload : Json) : Prop :=
  ∀ allowed, enum? = some allowed → payload ∈ allowed

/-- The `type` clause: an empty (or absent) type list admits everything;
otherwise some declared name must admit the payload. -/
def TypeAccepts (types : List String) (payload : Json) : Prop :=
  types = [] ∨ ∃ typeName ∈ types, Json.typeNameAdmits typeName payload = true

/-- String length bounds, inclusive, counted in Unicode scalar values. Only
string payloads are constrained. -/
def StringBoundsAccept (minLength? maxLength? : Option Int) (payload : Json) : Prop :=
  ∀ s, payload = .str s →
    (∀ bound, minLength? = some bound → bound ≤ (s.length : Int))
      ∧ (∀ bound, maxLength? = some bound → (s.length : Int) ≤ bound)

/-- Numeric bounds, inclusive. Only number payloads are constrained. -/
def NumberBoundsAccept (minimum? maximum? : Option Rat) (payload : Json) : Prop :=
  ∀ q, payload = .num q →
    (∀ bound, minimum? = some bound → bound ≤ q)
      ∧ (∀ bound, maximum? = some bound → q ≤ bound)

/-- The `required` clause: every required key is present. Required keys are
independent of `properties` (a required key need not be declared there). -/
def RequiredPresent (required : List String) (fields : List (String × Json)) : Prop :=
  ∀ key ∈ required, (lookupKey fields key).isSome

/-- The `additionalProperties` clause: only `some false` rejects, and it
rejects payload keys that are not declared in `properties`. -/
def AdditionalAllowed
    (properties : List (String × SchemaNode))
    (additionalProperties? : Option Bool)
    (fields : List (String × Json)) : Prop :=
  additionalProperties? = some false →
    ∀ field ∈ fields, (lookupKey properties field.1).isSome

/-- Acceptance of a payload by a parsed dialect schema: the conjunction of
every clause, recursing through declared `properties` sub-schemas on present
payload fields and through the `items` sub-schema on array elements.
Recursion is on the schema, never the payload. -/
def SchemaAccepts : SchemaNode → Json → Prop
  | .mk types enum? required properties additionalProperties? items?
      minLength? maxLength? minimum? maximum?, payload =>
    EnumAccepts enum? payload
      ∧ TypeAccepts types payload
      ∧ StringBoundsAccept minLength? maxLength? payload
      ∧ NumberBoundsAccept minimum? maximum? payload
      ∧ (match payload with
          | .obj fields =>
              RequiredPresent required fields
                ∧ (∀ key subSchema, (key, subSchema) ∈ properties →
                    ∀ value, lookupKey fields key = some value →
                      SchemaAccepts subSchema value)
                ∧ AdditionalAllowed properties additionalProperties? fields
          | .null => True
          | .bool _ => True
          | .num _ => True
          | .str _ => True
          | .arr _ => True)
      ∧ (match items?, payload with
          | some itemSchema, .arr elems =>
              ∀ element ∈ elems, SchemaAccepts itemSchema element
          | _, _ => True)
termination_by schema _ => sizeOf schema
decreasing_by
  · have hPairSize := List.sizeOf_lt_of_mem ‹(key, subSchema) ∈ properties›
    simp only [Prod.mk.sizeOf_spec] at hPairSize
    simp only [SchemaNode.mk.sizeOf_spec]
    omega
  · simp only [SchemaNode.mk.sizeOf_spec, Option.some.sizeOf_spec]
    omega

/-- A contract without a declared schema accepts any payload (the ADR 0085
gate: enforcement fires only when `wireContractSpecSchema` is present). -/
def SchemaOptAccepts (schema? : Option SchemaNode) (payload : Json) : Prop :=
  ∀ schema, schema? = some schema → SchemaAccepts schema payload

end ContractValidation
end Cortex.Wire
