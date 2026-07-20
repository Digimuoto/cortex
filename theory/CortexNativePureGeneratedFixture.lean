import Cortex.Wire.NativePure.Generated.Program

/-! Artifact writer for the production Haskell-plan to checked-Lean path. -/

def main (args : List String) : IO UInt32 := do
  match args with
  | [directory] =>
      Cortex.Wire.NativePure.Generated.Cortex_Wire_NativePure_Generated_Program.writeAllArtifacts
        directory
      pure 0
  | [] | [_, _] | _ :: _ :: _ :: _ =>
      IO.eprintln "usage: cortex-native-pure-generated-fixture OUTPUT_DIRECTORY"
      pure 2
