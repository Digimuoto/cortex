import Cortex.Wire.NativePure.C.Engine

/-! Executable construction checks for the generated NativePure v2 engine. -/

namespace Cortex.Wire.NativePure.C.Engine.Unit

open Cortex.Wire.NativePure.C.Engine

private def program : Program :=
  { identity := "native-pure-engine-unit"
  , planDigest := "0123456789abcdef0123456789abcdef"
  , regions :=
      [ { unitId := 0, dispatchName := "native_pure_region_0000_dispatch" }
      , { unitId := 1, dispatchName := "native_pure_region_0001_dispatch" }
      ]
  }

private def renderedResult := render program

example : renderedResult.toOption.isSome = true := by native_decide

def rendered : Cortex.Wire.C11.RenderedArtifacts :=
  renderedResult.toOption.get (by native_decide)

example : rendered.source.contains "awaiting_checkpoint" = true := by native_decide
example : rendered.source.contains "checkpoint_committed" = true := by native_decide
example : rendered.source.contains "effect_completed" = true := by native_decide
example : rendered.source.contains "native_pure_region_0000_dispatch" = true := by native_decide
example : rendered.source.contains "malloc" = false := by native_decide
example : rendered.source.contains "pthread" = false := by native_decide
example : rendered.exports.contains "dispatch" = true := by native_decide
example : rendered.manifest.contains "cortex.wire.native-pure-engine/v2" = true := by
  native_decide

private def sparseProgram : Program :=
  { program with
    regions := [{ unitId := 1, dispatchName := "native_pure_region_0000_dispatch" }] }

example : (render sparseProgram).toOption.isNone = true := by native_decide

private def duplicateProgram : Program :=
  { program with
    regions :=
      [ { unitId := 0, dispatchName := "native_pure_region_0000_dispatch" }
      , { unitId := 1, dispatchName := "native_pure_region_0000_dispatch" }
      ] }

example : (render duplicateProgram).toOption.isNone = true := by native_decide

end Cortex.Wire.NativePure.C.Engine.Unit
