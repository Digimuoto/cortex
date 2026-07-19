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
  , refinementBasis := by simp [incrementBody, RefinementExpr, RefinementTy]
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
  , refinementBasis := by
      simp [classifyBody, Decision, RefinementExpr, RefinementTy, RefinementFields]
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
  , refinementBasis := by
      simp [productBody, Product, RefinementExpr, RefinementRecord, RefinementTy]
  , stepsSound := by native_decide
  , outputSound := by native_decide
  }

private def productRegion : Region :=
  { name := "make_product", inputLabels := ["score"], kernel := productKernel }

private def productRenderedResult := render "native-pure-product-unit" productRegion

example : productRenderedResult.toOption.isSome = true := by native_decide

private def productRendered : Cortex.Wire.C11.RenderedArtifacts :=
  productRenderedResult.toOption.get (by native_decide)

example : productRendered.header.contains "padding_0[7u]" = true := by native_decide
example : productRendered.source.contains "field_1 = input->field_0" = true := by native_decide

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
  , refinementBasis := by simp [sourceBody, RefinementExpr]
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

end Cortex.Wire.NativePure.C.Unit
