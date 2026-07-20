import Lean
import Cortex.Wire.StaticCEmitter.Unit

/-!
## Overview

Host-side compiler for the restricted Wire @static-program/v1@ artifact.
It validates normalized dense node identifiers, endpoint closure, canonical
direct edges, and acyclicity before emitting one freestanding C program,
header, and manifest. Lean and its runtime are build-host dependencies only.
-/

open Lean

namespace Cortex.Wire.CBackend

private def schema : String :=
  "cortex.wire.static-program/v1"

private def uint32Max : Nat :=
  4294967295

private structure InputNode where
  id : Nat
  ref : String
  executor : String
  deriving Repr, BEq

private structure InputEdge where
  source : Nat
  target : Nat
  deriving Repr, BEq

private structure InputProgram where
  admissionSchemaVersion : Nat
  programId : String
  programIdentity : String
  nodes : List InputNode
  edges : List InputEdge
  deriving Repr

private structure ValidatedProgram where
  input : InputProgram
  topologicalOrder : List Nat

private def parseNode (value : Json) : Except String InputNode := do
  let idValue ← value.getObjVal? "id"
  let refValue ← value.getObjVal? "ref"
  let executorValue ← value.getObjVal? "executor"
  pure
    { id := ← idValue.getNat?
      ref := ← refValue.getStr?
      executor := ← executorValue.getStr? }

private def parseEdge (value : Json) : Except String InputEdge := do
  let sourceValue ← value.getObjVal? "from"
  let targetValue ← value.getObjVal? "to"
  pure
    { source := ← sourceValue.getNat?
      target := ← targetValue.getNat? }

private def parseProgram (value : Json) : Except String InputProgram := do
  let schemaValue ← (← value.getObjVal? "schema").getStr?
  if schemaValue != schema then
    throw s!"unsupported static program schema: {schemaValue}"
  let nodesValue ← (← value.getObjVal? "nodes").getArr?
  let edgesValue ← (← value.getObjVal? "edges").getArr?
  pure
    { admissionSchemaVersion := ← (← value.getObjVal? "admission_schema_version").getNat?
      programId := ← (← value.getObjVal? "program_id").getStr?
      programIdentity := ← (← value.getObjVal? "program_identity").getStr?
      nodes := ← nodesValue.toList.mapM parseNode
      edges := ← edgesValue.toList.mapM parseEdge }

private def idsCanonical : List InputNode → Nat → Bool
  | [], _expected => true
  | node :: rest, expected => node.id == expected && idsCanonical rest (expected + 1)

private def uniqueStrings : List String → Bool
  | [] => true
  | value :: rest => !rest.contains value && uniqueStrings rest

private def hasControlCharacter (value : String) : Bool :=
  value.toList.any fun char => char.toNat < 32

private def edgeLess (left right : InputEdge) : Bool :=
  left.source < right.source ||
    (left.source == right.source && left.target < right.target)

private def edgesCanonical : List InputEdge → Bool
  | [] => true
  | [_edge] => true
  | left :: right :: rest => edgeLess left right && edgesCanonical (right :: rest)

private def predecessorSatisfied
    (edges : List InputEdge)
    (emitted : List Nat)
    (node : Nat) : Bool :=
  edges.all fun edge => edge.target != node || emitted.contains edge.source

private def topologicalLoop
    (edges : List InputEdge)
    (remaining emitted : List Nat) : Nat → Option (List Nat)
  | 0 => if remaining.isEmpty then some emitted.reverse else none
  | fuel + 1 =>
      match remaining.find? (predecessorSatisfied edges emitted) with
      | none => none
      | some node =>
          topologicalLoop edges (remaining.erase node) (node :: emitted) fuel

private def topologicalOrder (program : InputProgram) : Option (List Nat) :=
  topologicalLoop program.edges (List.range program.nodes.length) [] program.nodes.length

private def validateProgram (program : InputProgram) : Except String ValidatedProgram := do
  if program.admissionSchemaVersion > uint32Max then
    throw "admission schema version exceeds uint32_t"
  if program.nodes.length > uint32Max then
    throw "node count exceeds uint32_t"
  if program.edges.length > uint32Max then
    throw "edge count exceeds uint32_t"
  if program.programId.isEmpty then
    throw "program_id must not be empty"
  if program.programIdentity.isEmpty then
    throw "program_identity must not be empty"
  if hasControlCharacter program.programId || hasControlCharacter program.programIdentity then
    throw "program identity fields must not contain JSON control characters"
  if !idsCanonical program.nodes 0 then
    throw "node ids must be canonical dense integers starting at zero"
  if !uniqueStrings (program.nodes.map (·.ref)) then
    throw "node refs must be unique"
  if program.nodes.any fun node => node.ref.isEmpty then
    throw "node refs must not be empty"
  if program.nodes.any fun node => hasControlCharacter node.ref then
    throw "node refs must not contain JSON control characters"
  if program.nodes.any fun node => node.executor.isEmpty then
    throw "executor ids must not be empty"
  if program.nodes.any fun node => hasControlCharacter node.executor then
    throw "executor ids must not contain JSON control characters"
  if program.nodes.any fun node => node.executor == "pure" then
    throw "static-program/v1 rejects delayed CorePure nodes"
  if !edgesCanonical program.edges then
    throw "direct edges must be unique and in canonical lexicographic order"
  if program.edges.any fun edge =>
      edge.source >= program.nodes.length || edge.target >= program.nodes.length then
    throw "direct edge endpoint is outside the dense node domain"
  match topologicalOrder program with
  | none => throw "static-program/v1 requires an acyclic topology"
  | some order => pure { input := program, topologicalOrder := order }

private def predecessors (program : InputProgram) (node : Nat) : List Nat :=
  (program.edges.filter fun edge => edge.target == node).map (·.source)

private def predecessorRows (program : InputProgram) : List (List Nat) :=
  (List.range program.nodes.length).map (predecessors program)

private def offsetsFromRows : List (List Nat) → Nat → List Nat
  | [], offset => [offset]
  | row :: rest, offset => offset :: offsetsFromRows rest (offset + row.length)

private def commaNats (values : List Nat) : String :=
  String.intercalate ", " (values.map toString)

private def escapeJsonChar : Char → String
  | '"' => "\\\""
  | '\\' => "\\\\"
  | '\n' => "\\n"
  | '\r' => "\\r"
  | '\t' => "\\t"
  | char => String.singleton char

private def escapeJson (value : String) : String :=
  String.join (value.toList.map escapeJsonChar)

private def renderManifest (validated : ValidatedProgram) : String :=
  let program := validated.input
  let nodes :=
    program.nodes.map fun node =>
      "    {\"id\": " ++ toString node.id ++
        s!", \"ref\": \"{escapeJson node.ref}\", " ++
          s!"\"executor\": \"{escapeJson node.executor}\"" ++ "}"
  let edges :=
    program.edges.map fun edge =>
      "    {\"from\": " ++ toString edge.source ++
        s!", \"to\": {edge.target}" ++ "}"
  "{\n" ++
  "  \"schema\": \"cortex.wire.program-manifest/v1\",\n" ++
  s!"  \"source_schema\": \"{schema}\",\n" ++
  s!"  \"admission_schema_version\": {program.admissionSchemaVersion},\n" ++
  s!"  \"program_id\": \"{escapeJson program.programId}\",\n" ++
  s!"  \"program_identity\": \"{escapeJson program.programIdentity}\",\n" ++
  s!"  \"node_count\": {program.nodes.length},\n" ++
  s!"  \"edge_count\": {program.edges.length},\n" ++
  s!"  \"topological_order\": [{commaNats validated.topologicalOrder}],\n" ++
  "  \"nodes\": [\n" ++ String.intercalate ",\n" nodes ++ "\n  ],\n" ++
  "  \"edges\": [\n" ++ String.intercalate ",\n" edges ++ "\n  ]\n" ++
  "}\n"

private def compileProgram (inputPath outputDirectory : String) : IO Unit := do
  let source ← IO.FS.readFile inputPath
  let parsed ←
    match Json.parse source with
    | .ok value => pure value
    | .error message => throw (IO.userError s!"invalid JSON: {message}")
  let input ←
    match parseProgram parsed with
    | .ok program => pure program
    | .error message => throw (IO.userError message)
  let validated ←
    match validateProgram input with
    | .ok program => pure program
    | .error message => throw (IO.userError message)
  let rows := predecessorRows validated.input
  let offsets := offsetsFromRows rows 0
  let predecessorEntries := rows.flatten
  let nodeCount := validated.input.nodes.length
  let storageCount := Nat.max 1 nodeCount
  let unit :=
    Cortex.Wire.StaticCEmitter.translationUnit
      nodeCount storageCount offsets predecessorEntries validated.topologicalOrder
      validated.input.programIdentity
  let rendered ←
    match Cortex.Wire.C11.validate unit with
    | .ok checked => pure (Cortex.Wire.C11.renderArtifacts checked)
    | .error message => throw (IO.userError s!"invalid structured C translation unit: {message}")
  IO.FS.createDirAll outputDirectory
  IO.FS.writeFile (outputDirectory ++ "/program.h") rendered.header
  IO.FS.writeFile (outputDirectory ++ "/program.c") rendered.source
  IO.FS.writeFile
    (outputDirectory ++ "/program.manifest.json")
    (renderManifest validated)
  IO.FS.writeFile (outputDirectory ++ "/program.exports.txt") rendered.exports

/-- Command-line entry point for the host-side Wire C compiler. -/
def main (args : List String) : IO UInt32 := do
  let usage : IO UInt32 := do
    IO.eprintln "usage: cortex-wire-c STATIC_PROGRAM_JSON OUTPUT_DIRECTORY"
    pure 2
  match args with
  | [inputPath, outputDirectory] =>
      try
        compileProgram inputPath outputDirectory
        IO.println s!"emitted freestanding Wire C program to {outputDirectory}"
        pure 0
      catch error =>
        IO.eprintln s!"cortex-wire-c: {error}"
        pure 1
  | [] => usage
  | [_] => usage
  | _ :: _ :: _ => usage

end Cortex.Wire.CBackend

def main (args : List String) : IO UInt32 :=
  Cortex.Wire.CBackend.main args
