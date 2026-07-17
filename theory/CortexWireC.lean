import Lean

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

private def cArray (values : List Nat) : String :=
  match values with
  | [] => "0u"
  | value :: rest =>
      String.intercalate ", " ((value :: rest).map fun element => s!"{element}u")

private def escapeJsonChar : Char → String
  | '"' => "\\\""
  | '\\' => "\\\\"
  | '\n' => "\\n"
  | '\r' => "\\r"
  | '\t' => "\\t"
  | char => String.singleton char

private def escapeJson (value : String) : String :=
  String.join (value.toList.map escapeJsonChar)

private def renderHeader : String :=
  "#ifndef CORTEX_WIRE_PROGRAM_V1_H\n" ++
  "#define CORTEX_WIRE_PROGRAM_V1_H\n\n" ++
  "#include <stdint.h>\n\n" ++
  "#ifdef __cplusplus\nextern \"C\" {\n#endif\n\n" ++
  "typedef enum {\n" ++
  "  CORTEX_WIRE_STATUS_PENDING = 0,\n" ++
  "  CORTEX_WIRE_STATUS_RUNNING = 1,\n" ++
  "  CORTEX_WIRE_STATUS_COMPLETED = 2,\n" ++
  "  CORTEX_WIRE_STATUS_FAILED = 3,\n" ++
  "  CORTEX_WIRE_STATUS_SKIPPED = 4,\n" ++
  "  CORTEX_WIRE_STATUS_INVALID = 255\n" ++
  "} cortex_wire_program_v1_status;\n\n" ++
  "typedef enum {\n" ++
  "  CORTEX_WIRE_EFFECT_ACCEPTED_ASYNC = 0,\n" ++
  "  CORTEX_WIRE_EFFECT_SUCCESS = 1,\n" ++
  "  CORTEX_WIRE_EFFECT_SKIPPED = 2,\n" ++
  "  CORTEX_WIRE_EFFECT_FAILURE = 3\n" ++
  "} cortex_wire_program_v1_effect_kind;\n\n" ++
  "typedef struct {\n" ++
  "  cortex_wire_program_v1_effect_kind kind;\n" ++
  "  uint64_t payload_handle;\n" ++
  "} cortex_wire_program_v1_effect_result;\n\n" ++
  "typedef cortex_wire_program_v1_effect_result (*cortex_wire_program_v1_effect_begin_fn)(\n" ++
  "    uint32_t node_id, void *context);\n" ++
  "typedef void (*cortex_wire_program_v1_effect_cancel_fn)(uint32_t node_id, void *context);\n\n" ++
  "typedef struct {\n" ++
  "  cortex_wire_program_v1_effect_begin_fn effect_begin;\n" ++
  "  cortex_wire_program_v1_effect_cancel_fn effect_cancel;\n" ++
  "  void *context;\n" ++
  "} cortex_wire_program_v1_effect_api;\n\n" ++
  "typedef enum {\n" ++
  "  CORTEX_WIRE_DRIVE_AWAITING_COMPLETIONS = 0,\n" ++
  "  CORTEX_WIRE_DRIVE_COMPLETED = 1,\n" ++
  "  CORTEX_WIRE_DRIVE_FAILED = 2,\n" ++
  "  CORTEX_WIRE_DRIVE_STUCK = 3,\n" ++
  "  CORTEX_WIRE_DRIVE_ABI_ERROR = 4\n" ++
  "} cortex_wire_program_v1_drive_result;\n\n" ++
  "typedef enum {\n" ++
  "  CORTEX_WIRE_COMPLETION_APPLIED = 0,\n" ++
  "  CORTEX_WIRE_COMPLETION_STALE = 1,\n" ++
  "  CORTEX_WIRE_COMPLETION_INVALID = 2\n" ++
  "} cortex_wire_program_v1_completion_result;\n\n" ++
  "typedef enum {\n" ++
  "  CORTEX_WIRE_TERMINAL_ACTIVE = 0,\n" ++
  "  CORTEX_WIRE_TERMINAL_COMPLETED = 1,\n" ++
  "  CORTEX_WIRE_TERMINAL_FAILED = 2\n" ++
  "} cortex_wire_program_v1_terminal_state;\n\n" ++
  "int cortex_wire_program_v1_init(const cortex_wire_program_v1_effect_api *api);\n" ++
  "cortex_wire_program_v1_drive_result cortex_wire_program_v1_drive(void);\n" ++
  "cortex_wire_program_v1_completion_result cortex_wire_program_v1_complete(\n" ++
  "    uint32_t node_id, cortex_wire_program_v1_effect_kind outcome, uint64_t payload_handle);\n" ++
  "cortex_wire_program_v1_terminal_state cortex_wire_program_v1_terminal(void);\n" ++
  "uint32_t cortex_wire_program_v1_node_count(void);\n" ++
  "cortex_wire_program_v1_status cortex_wire_program_v1_node_status(uint32_t node_id);\n" ++
  "uint64_t cortex_wire_program_v1_output_handle(uint32_t node_id);\n\n" ++
  "#ifdef __cplusplus\n}\n#endif\n\n" ++
  "#endif\n"

private def renderSource (validated : ValidatedProgram) : String :=
  let program := validated.input
  let rows := predecessorRows program
  let offsets : List Nat := offsetsFromRows rows 0
  let predecessorEntries : List Nat := rows.flatten
  let nodeCount := program.nodes.length
  let storageCount := Nat.max 1 nodeCount
  "#include \"program.h\"\n\n" ++
  s!"#define CORTEX_WIRE_NODE_COUNT {nodeCount}u\n" ++
  s!"#define CORTEX_WIRE_STORAGE_COUNT {storageCount}u\n\n" ++
  s!"static const uint32_t predecessor_offsets[{offsets.length}u] = " ++
  "{" ++ cArray offsets ++ "};\n" ++
  s!"static const uint32_t predecessor_nodes[{Nat.max 1 predecessorEntries.length}u] = " ++
  "{" ++ cArray predecessorEntries ++ "};\n" ++
  s!"static const uint32_t topological_order[{storageCount}u] = " ++
  "{" ++ cArray validated.topologicalOrder ++ "};\n" ++
  "static uint8_t node_status[CORTEX_WIRE_STORAGE_COUNT];\n" ++
  "static uint64_t output_handle[CORTEX_WIRE_STORAGE_COUNT];\n" ++
  "static uint8_t frontier_snapshot[CORTEX_WIRE_STORAGE_COUNT];\n" ++
  "static cortex_wire_program_v1_effect_api effect_api;\n" ++
  "static uint8_t initialized;\n" ++
  "static uint8_t driving;\n\n" ++
  "static uint8_t status_unblocks(uint8_t status) {\n" ++
  "  return (uint8_t)(status == CORTEX_WIRE_STATUS_COMPLETED ||\n" ++
  "                   status == CORTEX_WIRE_STATUS_SKIPPED);\n" ++
  "}\n\n" ++
  "static uint8_t node_ready(uint32_t node_id) {\n" ++
  "  uint32_t cursor;\n" ++
  "  if (node_status[node_id] != CORTEX_WIRE_STATUS_PENDING) { return 0u; }\n" ++
  "  for (cursor = predecessor_offsets[node_id];\n" ++
  "       cursor < predecessor_offsets[node_id + 1u]; ++cursor) {\n" ++
  "    if (!status_unblocks(node_status[predecessor_nodes[cursor]])) { return 0u; }\n" ++
  "  }\n" ++
  "  return 1u;\n" ++
  "}\n\n" ++
  "static uint8_t has_failed_predecessor(uint32_t node_id) {\n" ++
  "  uint32_t cursor;\n" ++
  "  for (cursor = predecessor_offsets[node_id];\n" ++
  "       cursor < predecessor_offsets[node_id + 1u]; ++cursor) {\n" ++
  "    if (node_status[predecessor_nodes[cursor]] == CORTEX_WIRE_STATUS_FAILED) { return 1u; }\n" ++
  "  }\n" ++
  "  return 0u;\n" ++
  "}\n\n" ++
  "static void propagate_failures(void) {\n" ++
  "  uint32_t order_index;\n" ++
  "  for (order_index = 0u; order_index < CORTEX_WIRE_NODE_COUNT; ++order_index) {\n" ++
  "    uint32_t node_id = topological_order[order_index];\n" ++
  "    if (node_status[node_id] == CORTEX_WIRE_STATUS_PENDING &&\n" ++
  "        has_failed_predecessor(node_id)) {\n" ++
  "      node_status[node_id] = CORTEX_WIRE_STATUS_FAILED;\n" ++
  "    }\n" ++
  "  }\n" ++
  "}\n\n" ++
  "static uint8_t any_status(uint8_t expected) {\n" ++
  "  uint32_t node_id;\n" ++
  "  for (node_id = 0u; node_id < CORTEX_WIRE_NODE_COUNT; ++node_id) {\n" ++
  "    if (node_status[node_id] == expected) { return 1u; }\n" ++
  "  }\n" ++
  "  return 0u;\n" ++
  "}\n\n" ++
  "static uint8_t all_settled(void) {\n" ++
  "  uint32_t node_id;\n" ++
  "  for (node_id = 0u; node_id < CORTEX_WIRE_NODE_COUNT; ++node_id) {\n" ++
  "    uint8_t status = node_status[node_id];\n" ++
  "    if (status != CORTEX_WIRE_STATUS_COMPLETED &&\n" ++
  "        status != CORTEX_WIRE_STATUS_FAILED &&\n" ++
  "        status != CORTEX_WIRE_STATUS_SKIPPED) { return 0u; }\n" ++
  "  }\n" ++
  "  return 1u;\n" ++
  "}\n\n" ++
  "static void cancel_running(void) {\n" ++
  "  uint32_t node_id;\n" ++
  "  if (effect_api.effect_cancel == 0) { return; }\n" ++
  "  for (node_id = 0u; node_id < CORTEX_WIRE_NODE_COUNT; ++node_id) {\n" ++
  "    if (node_status[node_id] == CORTEX_WIRE_STATUS_RUNNING) {\n" ++
  "      effect_api.effect_cancel(node_id, effect_api.context);\n" ++
  "    }\n" ++
  "  }\n" ++
  "}\n\n" ++
  "int cortex_wire_program_v1_init(const cortex_wire_program_v1_effect_api *api) {\n" ++
  "  uint32_t node_id;\n" ++
  "  if (api == 0 || api->effect_begin == 0 || initialized != 0u || driving != 0u) {\n" ++
  "    return -1;\n" ++
  "  }\n" ++
  "  effect_api = *api;\n" ++
  "  for (node_id = 0u; node_id < CORTEX_WIRE_NODE_COUNT; ++node_id) {\n" ++
  "    node_status[node_id] = CORTEX_WIRE_STATUS_PENDING;\n" ++
  "    output_handle[node_id] = 0u;\n" ++
  "    frontier_snapshot[node_id] = 0u;\n" ++
  "  }\n" ++
  "  initialized = 1u;\n" ++
  "  return 0;\n" ++
  "}\n\n" ++
  "cortex_wire_program_v1_drive_result cortex_wire_program_v1_drive(void) {\n" ++
  "  uint32_t node_id;\n" ++
  "  if (initialized == 0u || driving != 0u) { return CORTEX_WIRE_DRIVE_ABI_ERROR; }\n" ++
  "  driving = 1u;\n" ++
  "  for (;;) {\n" ++
  "    uint32_t frontier_count = 0u;\n" ++
  "    propagate_failures();\n" ++
  "    if (any_status(CORTEX_WIRE_STATUS_FAILED)) {\n" ++
  "      cancel_running(); driving = 0u; return CORTEX_WIRE_DRIVE_FAILED;\n" ++
  "    }\n" ++
  "    for (node_id = 0u; node_id < CORTEX_WIRE_NODE_COUNT; ++node_id) {\n" ++
  "      frontier_snapshot[node_id] = node_ready(node_id);\n" ++
  "      if (frontier_snapshot[node_id] != 0u) { ++frontier_count; }\n" ++
  "    }\n" ++
  "    if (frontier_count == 0u) {\n" ++
  "      driving = 0u;\n" ++
  "      if (any_status(CORTEX_WIRE_STATUS_RUNNING)) {\n" ++
  "        return CORTEX_WIRE_DRIVE_AWAITING_COMPLETIONS;\n" ++
  "      }\n" ++
  "      if (all_settled()) { return CORTEX_WIRE_DRIVE_COMPLETED; }\n" ++
  "      return CORTEX_WIRE_DRIVE_STUCK;\n" ++
  "    }\n" ++
  "    for (node_id = 0u; node_id < CORTEX_WIRE_NODE_COUNT; ++node_id) {\n" ++
  "      if (frontier_snapshot[node_id] != 0u) {\n" ++
  "        node_status[node_id] = CORTEX_WIRE_STATUS_RUNNING;\n" ++
  "      }\n" ++
  "    }\n" ++
  "    for (node_id = 0u; node_id < CORTEX_WIRE_NODE_COUNT; ++node_id) {\n" ++
  "      if (frontier_snapshot[node_id] != 0u &&\n" ++
  "          !any_status(CORTEX_WIRE_STATUS_FAILED)) {\n" ++
  "        cortex_wire_program_v1_effect_result effect =\n" ++
  "            effect_api.effect_begin(node_id, effect_api.context);\n" ++
  "        switch (effect.kind) {\n" ++
  "          case CORTEX_WIRE_EFFECT_ACCEPTED_ASYNC: break;\n" ++
  "          case CORTEX_WIRE_EFFECT_SUCCESS:\n" ++
  "            node_status[node_id] = CORTEX_WIRE_STATUS_COMPLETED;\n" ++
  "            output_handle[node_id] = effect.payload_handle; break;\n" ++
  "          case CORTEX_WIRE_EFFECT_SKIPPED:\n" ++
  "            node_status[node_id] = CORTEX_WIRE_STATUS_SKIPPED; break;\n" ++
  "          case CORTEX_WIRE_EFFECT_FAILURE:\n" ++
  "            node_status[node_id] = CORTEX_WIRE_STATUS_FAILED; break;\n" ++
  "          default:\n" ++
  "            node_status[node_id] = CORTEX_WIRE_STATUS_FAILED; break;\n" ++
  "        }\n" ++
  "      }\n" ++
  "    }\n" ++
  "  }\n" ++
  "}\n\n" ++
  "cortex_wire_program_v1_completion_result cortex_wire_program_v1_complete(\n" ++
  "    uint32_t node_id, cortex_wire_program_v1_effect_kind outcome, uint64_t payload) {\n" ++
  "  if (initialized == 0u || driving != 0u || node_id >= CORTEX_WIRE_NODE_COUNT) {\n" ++
  "    return CORTEX_WIRE_COMPLETION_INVALID;\n" ++
  "  }\n" ++
  "  if (node_status[node_id] != CORTEX_WIRE_STATUS_RUNNING) {\n" ++
  "    return CORTEX_WIRE_COMPLETION_STALE;\n" ++
  "  }\n" ++
  "  switch (outcome) {\n" ++
  "    case CORTEX_WIRE_EFFECT_SUCCESS:\n" ++
  "      node_status[node_id] = CORTEX_WIRE_STATUS_COMPLETED;\n" ++
  "      output_handle[node_id] = payload; break;\n" ++
  "    case CORTEX_WIRE_EFFECT_SKIPPED:\n" ++
  "      node_status[node_id] = CORTEX_WIRE_STATUS_SKIPPED; break;\n" ++
  "    case CORTEX_WIRE_EFFECT_FAILURE:\n" ++
  "      node_status[node_id] = CORTEX_WIRE_STATUS_FAILED; cancel_running(); break;\n" ++
  "    default: return CORTEX_WIRE_COMPLETION_INVALID;\n" ++
  "  }\n" ++
  "  return CORTEX_WIRE_COMPLETION_APPLIED;\n" ++
  "}\n\n" ++
  "cortex_wire_program_v1_terminal_state cortex_wire_program_v1_terminal(void) {\n" ++
  "  if (initialized == 0u) { return CORTEX_WIRE_TERMINAL_ACTIVE; }\n" ++
  "  if (any_status(CORTEX_WIRE_STATUS_FAILED)) { return CORTEX_WIRE_TERMINAL_FAILED; }\n" ++
  "  if (all_settled()) { return CORTEX_WIRE_TERMINAL_COMPLETED; }\n" ++
  "  return CORTEX_WIRE_TERMINAL_ACTIVE;\n" ++
  "}\n\n" ++
  "uint32_t cortex_wire_program_v1_node_count(void) { return CORTEX_WIRE_NODE_COUNT; }\n\n" ++
  "cortex_wire_program_v1_status cortex_wire_program_v1_node_status(uint32_t node_id) {\n" ++
  "  if (node_id >= CORTEX_WIRE_NODE_COUNT) { return CORTEX_WIRE_STATUS_INVALID; }\n" ++
  "  return (cortex_wire_program_v1_status)node_status[node_id];\n" ++
  "}\n\n" ++
  "uint64_t cortex_wire_program_v1_output_handle(uint32_t node_id) {\n" ++
  "  if (node_id >= CORTEX_WIRE_NODE_COUNT) { return 0u; }\n" ++
  "  return output_handle[node_id];\n" ++
  "}\n"

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
  IO.FS.createDirAll outputDirectory
  IO.FS.writeFile (outputDirectory ++ "/program.h") renderHeader
  IO.FS.writeFile (outputDirectory ++ "/program.c") (renderSource validated)
  IO.FS.writeFile
    (outputDirectory ++ "/program.manifest.json")
    (renderManifest validated)

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
