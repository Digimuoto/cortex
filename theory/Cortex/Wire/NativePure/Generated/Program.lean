import Cortex.Wire.NativePure.C.Engine

/-!
Generated from `cortex.wire.native-pure-plan/v1` by
`Cortex.Wire.NativePure.Lean`. The Haskell compiler owns the normalized
plan; Lean checks these intrinsically typed terms before C rendering.
Plan digest: `b498f115caa074426f6be4c8674dbd2bdf7ccef4bb9bf797451432a0c2f2868f`.
GENERATED FILE - do not edit by hand.
-/

namespace Cortex.Wire.NativePure.Generated
namespace Cortex_Wire_NativePure_Generated_Program

open Cortex.Wire.NativePure
open Cortex.Wire.NativePure.C

private def checkedI64 (value : Int) (valid : (I64.checked value).isSome = true) : I64 :=
  (I64.checked value).get (by simpa [Option.isSome_iff_exists] using valid)

private def native_pure_region_0000Body : Expr [.i64, .i64] .i64 :=
  .letE
    (.i64 (checkedI64 1 (by native_decide)))
    (.letE
      (.add
        (.var (.succ (.zero)))
        (.var (.zero)))
      (.letE
        (.var (.zero))
        (.letE
          (.ltI64
            (.var (.zero))
            (.var (.succ (.succ (.succ (.succ (.zero)))))))
          (.letE
            (.ifE
              (.var (.zero))
              (.var (.succ (.zero)))
              (.var (.succ (.succ (.succ (.succ (.succ (.zero))))))))
            (.letE
              (.var (.zero))
              (.var (.zero)))))))

private def native_pure_region_0000Kernel : CertifiedKernel :=
  { sourceNode := "first+second"
  , inputs := [.i64, .i64]
  , output := .i64
  , body := native_pure_region_0000Body
  , bounds :=
      { stackBytes := 56
      , staticBytes := 0
      , outputBytes := 16
      , checkpointBytes := 40
      , maxSteps := 19
      , checkpointWithinHostedCeiling := by native_decide
      }
  , regions :=
      [ { name := "input.0", access := .read, capacity := 8, alignment := 8 }
      , { name := "input.1", access := .read, capacity := 8, alignment := 8 }
      , { name := "output.value", access := .write, capacity := 8, alignment := 8 }
      ]
  , regionsWellFormed := by simp [RegionsWellFormed] <;> native_decide
  , inputsWellFormed := by
      simp [WellFormedTy] <;> native_decide
  , outputWellFormed := by
      simp [WellFormedTy] <;> native_decide
  , stepsSound := by native_decide
  , outputSound := by native_decide
  }

private def native_pure_region_0000Region : C.Region :=
  { name := "native_pure_region_0000"
  , inputLabels := ["input_0000", "input_0001"]
  , kernel := native_pure_region_0000Kernel
  }

private def native_pure_region_0000RenderedResult :=
  C.renderDispatchable "native-pure/0000" native_pure_region_0000Region
#guard native_pure_region_0000RenderedResult.toOption.isSome

def native_pure_region_0000Rendered : Cortex.Wire.C11.RenderedArtifacts :=
  native_pure_region_0000RenderedResult.toOption.get (by native_decide)

def engineProgram : Engine.Program :=
  { identity := "c71892065c0a9cccecaec3d31f166c8c853cef9317feccbc1bfe8797666caf2c"
  , planDigest := "b498f115caa074426f6be4c8674dbd2bdf7ccef4bb9bf797451432a0c2f2868f"
  , regions :=
      [
        { unitId := 0, dispatchName := "native_pure_region_0000_dispatch" }
      ]
  }

private def engineRenderedResult := Engine.render engineProgram
#guard engineRenderedResult.toOption.isSome

def engineRendered : Cortex.Wire.C11.RenderedArtifacts :=
  engineRenderedResult.toOption.get (by native_decide)

def regionArtifacts : List Cortex.Wire.C11.RenderedArtifacts :=
  [native_pure_region_0000Rendered]

private def writeArtifacts
    (directory stem : String) (artifacts : Cortex.Wire.C11.RenderedArtifacts) : IO Unit := do
  IO.FS.writeFile (directory ++ "/" ++ stem ++ ".c") artifacts.source
  IO.FS.writeFile (directory ++ "/" ++ stem ++ ".h") artifacts.header
  IO.FS.writeFile (directory ++ "/" ++ stem ++ ".exports.txt") artifacts.exports
  IO.FS.writeFile (directory ++ "/" ++ stem ++ ".manifest.json") artifacts.manifest

def writeAllArtifacts (directory : String) : IO Unit := do
  IO.FS.createDirAll directory
  writeArtifacts directory "native_pure_region_0000" native_pure_region_0000Rendered
  writeArtifacts directory "cortex_np_engine_b498f115caa07442" engineRendered

end Cortex_Wire_NativePure_Generated_Program
end Cortex.Wire.NativePure.Generated
