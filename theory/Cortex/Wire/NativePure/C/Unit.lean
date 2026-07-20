import Cortex.Wire.NativePure.C

/-! Executable construction checks for the concrete NativePure C lowering. -/

namespace Cortex.Wire.NativePure.C.Unit

open Cortex.Wire.NativePure
open Cortex.Wire.NativePure.C

private def one : I64 :=
  { value := 1, lower := by decide, upper := by decide }

private def incrementBody : Expr [.i64] .i64 :=
  .add (.var .zero) (.i64 one)

private def bounds : ResourceBounds :=
  { stackBytes := 24
  , staticBytes := 0
  , outputBytes := 8
  , checkpointBytes := 16
  , maxSteps := 3
  , checkpointWithinHostedCeiling := by decide
  }

private def kernel : CertifiedKernel :=
  { sourceNode := "increment"
  , inputs := [.i64]
  , output := .i64
  , body := incrementBody
  , bounds
  , regions :=
      [ { name := "input.score", access := .read, capacity := 8, alignment := 8 }
      , { name := "output.result", access := .write, capacity := 8, alignment := 8 }
      ]
  , regionsWellFormed := by simp [RegionsWellFormed]
  , inputsWellFormed := by simp [WellFormedTy]
  , outputWellFormed := by simp [WellFormedTy]
  , stepsSound := by native_decide
  , outputSound := by native_decide
  }

private def region : Region :=
  { name := "increment", inputLabels := ["score"], kernel }

private def renderedResult := render "native-pure-unit" region

example : renderedResult.toOption.isSome = true := by native_decide

def rendered : Cortex.Wire.C11.RenderedArtifacts :=
  renderedResult.toOption.get (by native_decide)

example : rendered.source.contains "__builtin_add_overflow" = true := by native_decide
example : rendered.source.contains "malloc" = false := by native_decide
example : rendered.source.contains "pthread" = false := by native_decide
example : rendered.header.contains "increment_run" = true := by native_decide
example : rendered.manifest.contains "checkpoint_bytes" = true := by native_decide
example : rendered.manifest.contains "increment_effect_frame" = true := by native_decide

private abbrev Decision : Ty :=
  Ty.sum [("accepted", .i64), ("rejected", .i64)]

private def acceptedMember :
    Member "accepted" .i64 [("accepted", .i64), ("rejected", .i64)] := .head

private def rejectedMember :
    Member "rejected" .i64 [("accepted", .i64), ("rejected", .i64)] := .tail .head

private def zero : I64 :=
  { value := 0, lower := by decide, upper := by decide }

private def classifyBody : Expr [.i64] Decision :=
  .ifE
    (.ltI64 (.var .zero) (.i64 zero))
    (.inject rejectedMember (.var .zero))
    (.inject acceptedMember (.var .zero))

private def classifyKernel : CertifiedKernel :=
  { sourceNode := "classify"
  , inputs := [.i64]
  , output := Decision
  , body := classifyBody
  , bounds :=
      { stackBytes := 40
      , staticBytes := 0
      , outputBytes := 16
      , checkpointBytes := 24
      , maxSteps := 6
      , checkpointWithinHostedCeiling := by decide
      }
  , regions :=
      [ { name := "input.score", access := .read, capacity := 8, alignment := 8 }
      , { name := "output.variant", access := .write, capacity := 16, alignment := 8 }
      ]
  , regionsWellFormed := by simp [RegionsWellFormed]
  , inputsWellFormed := by simp [WellFormedTy]
  , outputWellFormed := by
      simp [WellFormedTy, WellFormedFields, LabelsCanonical]
      native_decide
  , stepsSound := by native_decide
  , outputSound := by native_decide
  }

private def classifyRegion : Region :=
  { name := "classify", inputLabels := ["score"], kernel := classifyKernel }

private def classifyRenderedResult := render "native-pure-sum-unit" classifyRegion

example : classifyRenderedResult.toOption.isSome = true := by native_decide

def classifyRendered : Cortex.Wire.C11.RenderedArtifacts :=
  classifyRenderedResult.toOption.get (by native_decide)

example : classifyRendered.header.contains "typedef union" = true := by native_decide
example : classifyRendered.header.contains "uint32_t tag" = true := by native_decide
example : classifyRendered.header.contains "variant_1" = true := by native_decide
example : classifyRendered.source.contains "malloc" = false := by native_decide

private abbrev Product : Ty :=
  Ty.record [("flag", .bool), ("score", .i64)]

private def productBody : Expr [.i64] Product :=
  .record (.cons "flag" (.bool true) (.cons "score" (.var .zero) .nil))

private def productKernel : CertifiedKernel :=
  { sourceNode := "make_product"
  , inputs := [.i64]
  , output := Product
  , body := productBody
  , bounds :=
      { stackBytes := 40
      , staticBytes := 0
      , outputBytes := 16
      , checkpointBytes := 24
      , maxSteps := 3
      , checkpointWithinHostedCeiling := by decide
      }
  , regions :=
      [ { name := "input.score", access := .read, capacity := 8, alignment := 8 }
      , { name := "output.product", access := .write, capacity := 16, alignment := 8 }
      ]
  , regionsWellFormed := by simp [RegionsWellFormed]
  , inputsWellFormed := by simp [WellFormedTy]
  , outputWellFormed := by
      simp [WellFormedTy, WellFormedFields, LabelsCanonical]
      native_decide
  , stepsSound := by native_decide
  , outputSound := by native_decide
  }

private def productRegion : Region :=
  { name := "make_product", inputLabels := ["score"], kernel := productKernel }

private def productRenderedResult := render "native-pure-product-unit" productRegion

example : productRenderedResult.toOption.isSome = true := by native_decide

def productRendered : Cortex.Wire.C11.RenderedArtifacts :=
  productRenderedResult.toOption.get (by native_decide)

example : productRendered.header.contains "padding_0[7u]" = true := by native_decide
example : productRendered.source.contains "field_1 = input->field_0" = true := by native_decide

private def scoreMember : Member "score" .i64 [("flag", .bool), ("score", .i64)] :=
  .tail .head

private def projectionBody : Expr [Product] .i64 :=
  .project (.var .zero) scoreMember

private def projectionKernel : CertifiedKernel :=
  { sourceNode := "project_score"
  , inputs := [Product]
  , output := .i64
  , body := projectionBody
  , bounds :=
      { stackBytes := 32
      , staticBytes := 0
      , outputBytes := 8
      , checkpointBytes := 24
      , maxSteps := 2
      , checkpointWithinHostedCeiling := by decide
      }
  , regions :=
      [ { name := "input.product", access := .read, capacity := 16, alignment := 8 }
      , { name := "output.score", access := .write, capacity := 8, alignment := 8 }
      ]
  , regionsWellFormed := by simp [RegionsWellFormed]
  , inputsWellFormed := by
      simp [Product, WellFormedTy, WellFormedFields, LabelsCanonical]
      native_decide
  , outputWellFormed := by simp [WellFormedTy]
  , stepsSound := by native_decide
  , outputSound := by native_decide
  }

private def projectionRegion : Region :=
  { name := "project_score", inputLabels := ["product"], kernel := projectionKernel }

private def projectionRenderedResult :=
  render "native-pure-projection-unit" projectionRegion

example : projectionRenderedResult.toOption.isSome = true := by native_decide

def projectionRendered : Cortex.Wire.C11.RenderedArtifacts :=
  projectionRenderedResult.toOption.get (by native_decide)

example : projectionRendered.source.contains "input->field_0.field_1" = true := by native_decide

private def f64IdentityBody : Expr [.f64] .f64 := .var .zero

private def f64IdentityKernel : CertifiedKernel :=
  { sourceNode := "f64_identity"
  , inputs := [.f64]
  , output := .f64
  , body := f64IdentityBody
  , bounds :=
      { stackBytes := 16
      , staticBytes := 0
      , outputBytes := 8
      , checkpointBytes := 16
      , maxSteps := 1
      , checkpointWithinHostedCeiling := by decide
      }
  , regions :=
      [ { name := "input.value", access := .read, capacity := 8, alignment := 8 }
      , { name := "output.value", access := .write, capacity := 8, alignment := 8 }
      ]
  , regionsWellFormed := by simp [RegionsWellFormed]
  , inputsWellFormed := by simp [WellFormedTy]
  , outputWellFormed := by simp [WellFormedTy]
  , stepsSound := by native_decide
  , outputSound := by native_decide
  }

private def f64IdentityRegion : Region :=
  { name := "f64_identity", inputLabels := ["value"], kernel := f64IdentityKernel }

private def f64IdentityRenderedResult :=
  render "native-pure-f64-identity-unit" f64IdentityRegion

example : f64IdentityRenderedResult.toOption.isSome = true := by native_decide

def f64IdentityRendered : Cortex.Wire.C11.RenderedArtifacts :=
  f64IdentityRenderedResult.toOption.get (by native_decide)

example : f64IdentityRendered.source.contains "output->value = input->field_0" = true := by
  native_decide

private def checkedI64 (value : Int) (valid : (I64.checked value).isSome = true) : I64 :=
  (I64.checked value).get (by simpa [Option.isSome_iff_exists] using valid)

private def differentialI64Inputs : List I64 :=
  [ checkedI64 (-2) (by native_decide)
  , checkedI64 (-1) (by native_decide)
  , checkedI64 0 (by native_decide)
  , checkedI64 1 (by native_decide)
  , checkedI64 9223372036854775806 (by native_decide)
  , checkedI64 9223372036854775807 (by native_decide)
  ]

private def boolDigit : Bool → String
  | false => "0"
  | true => "1"

private def incrementTrace (input : I64) : String :=
  match eval incrementBody [.i64 input] with
  | some (.i64 result) => s!"increment:{input.value} status=0 value={result.value}"
  | none => s!"increment:{input.value} status=2"
  | some _ => s!"increment:{input.value} status=1"

private def classifyTrace (input : I64) : String :=
  match eval classifyBody [.i64 input] with
  | some (.sum label (.i64 result)) =>
      let tag := if label == "accepted" then "0" else "1"
      s!"classify:{input.value} status=0 tag={tag} value={result.value}"
  | none => s!"classify:{input.value} status=2"
  | some _ => s!"classify:{input.value} status=1"

private def productTrace (input : I64) : String :=
  match eval productBody [.i64 input] with
  | some (.record [("flag", .bool flag), ("score", .i64 score)]) =>
      s!"product:{input.value} status=0 flag={boolDigit flag} score={score.value}"
  | none => s!"product:{input.value} status=2"
  | some _ => s!"product:{input.value} status=1"

private def projectionTrace (flag : Bool) (score : I64) : String :=
  let input := Value.record [("flag", .bool flag), ("score", .i64 score)]
  match eval projectionBody [input] with
  | some (.i64 result) =>
      s!"projection:{boolDigit flag},{score.value} status=0 value={result.value}"
  | none => s!"projection:{boolDigit flag},{score.value} status=2"
  | some _ => s!"projection:{boolDigit flag},{score.value} status=1"

/-- Canonical Lean reference traces for the hermetic NativePure differential.
The checked-i64 and structural lines are computed by the executable typed
semantics. Binary64 lines deliberately exercise only bit-preserving identity;
f64 arithmetic remains outside the theorem boundary. -/
def differentialTraces : String :=
  let increments := differentialI64Inputs.map incrementTrace
  let classifications :=
    [ classifyTrace (checkedI64 (-2) (by native_decide))
    , classifyTrace (checkedI64 0 (by native_decide))
    , classifyTrace (checkedI64 9 (by native_decide))
    ]
  let products :=
    [ productTrace (checkedI64 (-7) (by native_decide))
    , productTrace (checkedI64 0 (by native_decide))
    ]
  let projections :=
    [ projectionTrace false (checkedI64 (-9) (by native_decide))
    , projectionTrace true (checkedI64 42 (by native_decide))
    ]
  let f64Identity :=
    [ "f64:0000000000000000 status=0 bits=0000000000000000"
    , "f64:8000000000000000 status=0 bits=8000000000000000"
    , "f64:0000000000000001 status=0 bits=0000000000000001"
    , "f64:3ff0000000000000 status=0 bits=3ff0000000000000"
    , "f64:7fefffffffffffff status=0 bits=7fefffffffffffff"
    ]
  let traces := increments ++ classifications ++ products ++ projections ++ f64Identity
  String.intercalate "\n" traces ++ "\n"

private def sourceBody : Expr [] .i64 := .i64 one

private def sourceKernel : CertifiedKernel :=
  { sourceNode := "source"
  , inputs := []
  , output := .i64
  , body := sourceBody
  , bounds :=
      { stackBytes := 16
      , staticBytes := 0
      , outputBytes := 8
      , checkpointBytes := 8
      , maxSteps := 1
      , checkpointWithinHostedCeiling := by decide
      }
  , regions :=
      [{ name := "output.value", access := .write, capacity := 8, alignment := 8 }]
  , regionsWellFormed := by simp [RegionsWellFormed]
  , inputsWellFormed := by simp
  , outputWellFormed := by simp [WellFormedTy]
  , stepsSound := by native_decide
  , outputSound := by native_decide
  }

private def sourceRegion : Region :=
  { name := "source", inputLabels := [], kernel := sourceKernel }

private def sourceRenderedResult := render "native-pure-source-unit" sourceRegion

example : sourceRenderedResult.toOption.isSome = true := by native_decide

private def sourceRendered : Cortex.Wire.C11.RenderedArtifacts :=
  sourceRenderedResult.toOption.get (by native_decide)

example : sourceRendered.header.contains "source_effect_frame" = true := by native_decide
example : sourceRendered.header.contains "source_input input" = false := by native_decide
example : sourceRendered.manifest.contains "\"size\":8" = true := by native_decide

private def undersizedCheckpointKernel : CertifiedKernel :=
  { kernel with
    bounds :=
      { kernel.bounds with
        checkpointBytes := 8
        checkpointWithinHostedCeiling := by decide
      }
  }

private def undersizedCheckpointRegion : Region :=
  { name := "undersized", inputLabels := ["score"], kernel := undersizedCheckpointKernel }

example :
    (translationUnit
      "native-pure-bounds-unit" undersizedCheckpointRegion).toOption.isNone = true := by
  native_decide


/-! ### Union payload size rounding (epic review batch 5)

A sum whose largest-size variant is not already a multiple of the payload
alignment (here: a 9-byte packed all-`bool` record vs. an 8-byte-aligned
`i64`) is the adversarial shape that a real C11 compiler rounds up when it
computes `sizeof` for the payload union — the union's declared size must
match, or the emitted `_Static_assert` fails to compile. -/

private abbrev WidePayload : Ty :=
  Ty.record
    [ ("f0", .bool), ("f1", .bool), ("f2", .bool), ("f3", .bool), ("f4", .bool)
    , ("f5", .bool), ("f6", .bool), ("f7", .bool), ("f8", .bool)
    ]

private abbrev MixedAlignmentSum : Ty :=
  Ty.sum [("big", WidePayload), ("small", .i64)]

private def mixedSmallMember :
    Member "small" .i64 [("big", WidePayload), ("small", .i64)] := .tail .head

private def mixedAlignmentBody : Expr [.i64] MixedAlignmentSum :=
  .inject mixedSmallMember (.var .zero)

private def mixedAlignmentKernel : CertifiedKernel :=
  { sourceNode := "mixed_alignment"
  , inputs := [.i64]
  , output := MixedAlignmentSum
  , body := mixedAlignmentBody
  , bounds :=
      { stackBytes := 56
      , staticBytes := 0
      , outputBytes := 24
      , checkpointBytes := 32
      , maxSteps := 10
      , checkpointWithinHostedCeiling := by decide
      }
  , regions :=
      [ { name := "input.score", access := .read, capacity := 8, alignment := 8 }
      , { name := "output.variant", access := .write, capacity := 24, alignment := 8 }
      ]
  , regionsWellFormed := by simp [RegionsWellFormed]
  , inputsWellFormed := by simp [WellFormedTy]
  , outputWellFormed := by
      simp [WellFormedTy, WellFormedFields, LabelsCanonical]
      native_decide
  , stepsSound := by native_decide
  , outputSound := by native_decide
  }

private def mixedAlignmentRegion : Region :=
  { name := "mixed_alignment", inputLabels := ["score"], kernel := mixedAlignmentKernel }

private def mixedAlignmentRenderedResult :=
  render "native-pure-mixed-alignment-unit" mixedAlignmentRegion

example : mixedAlignmentRenderedResult.toOption.isSome = true := by native_decide

def mixedAlignmentRendered : Cortex.Wire.C11.RenderedArtifacts :=
  mixedAlignmentRenderedResult.toOption.get (by native_decide)

-- The raw (unrounded) variant-size maximum is 9 bytes; a real compiler rounds
-- a union's own sizeof up to its alignment (8), giving 16, not 9. (A
-- `== 9u` assertion legitimately appears elsewhere, on the align-1 record
-- type's own struct size — only the union's declared size is at stake here.)
example :
    mixedAlignmentRendered.source.contains "_payload) == 16u" = true := by
  native_decide
example :
    mixedAlignmentRendered.source.contains "_payload) == 9u" = false := by
  native_decide
example :
    mixedAlignmentRendered.source.contains "cortex_np_type_1) == 24u" = true := by
  native_decide

end Cortex.Wire.NativePure.C.Unit
