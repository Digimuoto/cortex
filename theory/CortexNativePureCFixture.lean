import Cortex.Wire.NativePure.C.Unit

/-! Test-only artifact writer used by target and compiler gates. -/

open Cortex.Wire.NativePure.C.Unit

private def writeArtifacts
    (directory stem : String) (artifacts : Cortex.Wire.C11.RenderedArtifacts) : IO Unit := do
  IO.FS.writeFile (directory ++ "/" ++ stem ++ ".c") artifacts.source
  IO.FS.writeFile (directory ++ "/" ++ stem ++ ".h") artifacts.header
  IO.FS.writeFile (directory ++ "/" ++ stem ++ ".exports.txt") artifacts.exports
  IO.FS.writeFile (directory ++ "/" ++ stem ++ ".manifest.json") artifacts.manifest

def main (args : List String) : IO UInt32 := do
  match args with
  | [directory] =>
      IO.FS.createDirAll directory
      writeArtifacts directory "increment" rendered
      writeArtifacts directory "classify" classifyRendered
      pure 0
  | [] | _ :: _ :: _ =>
      IO.eprintln "usage: cortex-native-pure-c-fixture OUTPUT_DIRECTORY"
      pure 2
