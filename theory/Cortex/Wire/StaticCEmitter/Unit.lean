import Cortex.Wire.StaticCEmitter
import Cortex.Wire.StaticCEmitter.Layout

namespace Cortex.Wire.StaticCEmitter

open Cortex.Wire.C11

private def exportedEnum (name : Name) (members : List (Name × Int)) : TypeDecl :=
  .enumeration
    { name
    , members := members.map fun member => { name := member.1, value := member.2 }
    , visibility := .exported
    }

private def exportedStruct (name : Name) (fields : List (Name × CType)) : TypeDecl :=
  .structure
    { name
    , fields := fields.map fun field => { name := field.1, ty := field.2 }
    , visibility := .exported
    }

private def exportedFunctionAlias
    (name : Name)
    (result : CType)
    (params : List (Name × CType)) : TypeDecl :=
  .functionAlias
    { name
    , result
    , params := params.map fun param => { name := param.1, ty := param.2 }
    , visibility := .exported
    }

def staticTypes : List TypeDecl :=
  [ exportedEnum "cortex_wire_program_v1_status"
      [ ("CORTEX_WIRE_STATUS_PENDING", 0)
      , ("CORTEX_WIRE_STATUS_RUNNING", 1)
      , ("CORTEX_WIRE_STATUS_COMPLETED", 2)
      , ("CORTEX_WIRE_STATUS_FAILED", 3)
      , ("CORTEX_WIRE_STATUS_SKIPPED", 4)
      , ("CORTEX_WIRE_STATUS_INVALID", 255)
      ]
  , exportedEnum "cortex_wire_program_v1_effect_kind"
      [ ("CORTEX_WIRE_EFFECT_ACCEPTED_ASYNC", 0)
      , ("CORTEX_WIRE_EFFECT_SUCCESS", 1)
      , ("CORTEX_WIRE_EFFECT_SKIPPED", 2)
      , ("CORTEX_WIRE_EFFECT_FAILURE", 3)
      ]
  , exportedStruct "cortex_wire_program_v1_effect_result"
      [ ("kind", .named "cortex_wire_program_v1_effect_kind"), ("payload_handle", .u64) ]
  , exportedFunctionAlias "cortex_wire_program_v1_effect_begin_fn"
      (.named "cortex_wire_program_v1_effect_result")
      [("node_id", .u32), ("context", .pointer .void false)]
  , exportedFunctionAlias "cortex_wire_program_v1_effect_cancel_fn"
      .void [("node_id", .u32), ("context", .pointer .void false)]
  , exportedStruct "cortex_wire_program_v1_effect_api"
      [ ("effect_begin", .named "cortex_wire_program_v1_effect_begin_fn")
      , ("effect_cancel", .named "cortex_wire_program_v1_effect_cancel_fn")
      , ("context", .pointer .void false)
      ]
  , exportedEnum "cortex_wire_program_v1_drive_result"
      [ ("CORTEX_WIRE_DRIVE_AWAITING_COMPLETIONS", 0)
      , ("CORTEX_WIRE_DRIVE_COMPLETED", 1)
      , ("CORTEX_WIRE_DRIVE_FAILED", 2)
      , ("CORTEX_WIRE_DRIVE_STUCK", 3)
      , ("CORTEX_WIRE_DRIVE_ABI_ERROR", 4)
      ]
  , exportedEnum "cortex_wire_program_v1_completion_result"
      [ ("CORTEX_WIRE_COMPLETION_APPLIED", 0)
      , ("CORTEX_WIRE_COMPLETION_STALE", 1)
      , ("CORTEX_WIRE_COMPLETION_INVALID", 2)
      ]
  , exportedEnum "cortex_wire_program_v1_terminal_state"
      [ ("CORTEX_WIRE_TERMINAL_ACTIVE", 0)
      , ("CORTEX_WIRE_TERMINAL_COMPLETED", 1)
      , ("CORTEX_WIRE_TERMINAL_FAILED", 2)
      ]
  , .define "CORTEX_WIRE_ENGINE_STATE_SCHEMA_VERSION" (.unsigned 1)
  , exportedFunctionAlias "cortex_wire_engine_v1_effect_request_fn"
      .void [("node_id", .u32), ("context", .pointer .void false)]
  , exportedFunctionAlias "cortex_wire_engine_v1_effect_cancel_fn"
      .void [("node_id", .u32), ("context", .pointer .void false)]
  , exportedStruct "cortex_wire_engine_v1_host_api"
      [ ("effect_request", .named "cortex_wire_engine_v1_effect_request_fn")
      , ("effect_cancel", .named "cortex_wire_engine_v1_effect_cancel_fn")
      , ("context", .pointer .void false)
      ]
  , exportedEnum "cortex_wire_engine_v1_terminal_state"
      [ ("CORTEX_WIRE_ENGINE_TERMINAL_ACTIVE", 0)
      , ("CORTEX_WIRE_ENGINE_TERMINAL_COMPLETED", 1)
      , ("CORTEX_WIRE_ENGINE_TERMINAL_FAILED", 2)
      , ("CORTEX_WIRE_ENGINE_TERMINAL_CANCELLED", 3)
      ]
  , exportedStruct "cortex_wire_engine_v1_state_header"
      [ ("schema_version", .u32)
      , ("node_count", .u32)
      , ("checkpoint_sequence", .u64)
      , ("terminal", .named "cortex_wire_engine_v1_terminal_state")
      ]
  , exportedEnum "cortex_wire_engine_v1_state_result"
      [ ("CORTEX_WIRE_ENGINE_STATE_OK", 0)
      , ("CORTEX_WIRE_ENGINE_STATE_INVALID", 1)
      , ("CORTEX_WIRE_ENGINE_STATE_IDENTITY_MISMATCH", 2)
      , ("CORTEX_WIRE_ENGINE_STATE_CANCEL_DEFERRED", 3)
      ]
  , exportedEnum "cortex_wire_engine_v1_drive_result"
      [ ("CORTEX_WIRE_ENGINE_DRIVE_CHECKPOINT_REQUIRED", 0)
      , ("CORTEX_WIRE_ENGINE_DRIVE_AWAITING_COMPLETIONS", 1)
      , ("CORTEX_WIRE_ENGINE_DRIVE_TERMINAL", 2)
      , ("CORTEX_WIRE_ENGINE_DRIVE_STUCK", 3)
      , ("CORTEX_WIRE_ENGINE_DRIVE_ABI_ERROR", 4)
      ]
  ]

private def withParamNames (params : List Param) (names : List Name) : List Param :=
  List.zipWith (fun param name => { param with name }) params names

private def headerParamsFor (function : CFunction) : Option (List Param) :=
  match function.name with
  | "cortex_wire_program_v1_complete" | "cortex_wire_engine_v1_complete" =>
      some (withParamNames function.params ["node_id", "outcome", "payload_handle"])
  | "cortex_wire_engine_v1_export_state" =>
      some (withParamNames function.params ["header", "statuses", "output_handles", "capacity"])
  | "cortex_wire_engine_v1_import_state" =>
      some (withParamNames function.params
        ["api", "program_identity", "header", "statuses", "output_handles", "capacity"])
  | _name => none

private def functionLayout (name : Name) : Option ConcreteLayout :=
  (staticFunctionLayouts.find? fun pair => pair.1 == name).map Prod.snd

private def withImportComment (function : CFunction) : CFunction :=
  if function.name == "cortex_wire_engine_v1_import_state" then
    { function with body := function.body.map fun statements =>
        statements.take 13 ++
          [ .comment
              [ "The cancel latch is session state, not exported state: a deferred"
              , "cancel does not survive export/import. The host re-issues the cancel"
              , "after a restore because the cancellation request itself is durable"
              , "on the host side."
              ]
          ] ++ statements.drop 13 }
  else function

def staticFunctionsWithHeaderComments : List CFunction :=
  staticFunctions.map fun function =>
    let withComment := withImportComment function
    { withComment with
      headerParams := headerParamsFor function
      concreteLayout := functionLayout function.name
      headerComments :=
        if function.name == "cortex_wire_program_v1_node_status" then
          [ "After terminal failure, an undispatched node may remain PENDING until the next init."
          , "Use cortex_wire_program_v1_terminal() for the overall run result."
          ]
        else [] }

private def arrayValues (values : List Nat) : Initializer :=
  .list ((if values.isEmpty then [0] else values).map Expr.unsigned)

def staticGlobals
    (nodeCount storageCount : Nat)
    (offsets predecessorNodes topologicalOrder : List Nat)
    (programIdentity : String) : List Global :=
  [ { name := "cortex_wire_node_count", ty := .u32, isConst := true, blankAfter := true
    , initial := some (.expression (.unsigned nodeCount)) }
  , { name := "predecessor_offsets", ty := .array offsets.length .u32, isConst := true
    , initial := some (arrayValues offsets) }
  , { name := "predecessor_nodes"
    , ty := .array (Nat.max 1 predecessorNodes.length) .u32, isConst := true
    , initial := some (arrayValues predecessorNodes) }
  , { name := "topological_order", ty := .array storageCount .u32, isConst := true
    , initial := some (arrayValues topologicalOrder) }
  , { name := "node_status", ty := .namedArray "CORTEX_WIRE_STORAGE_COUNT" .u8 }
  , { name := "output_handle", ty := .namedArray "CORTEX_WIRE_STORAGE_COUNT" .u64 }
  , { name := "frontier_snapshot", ty := .namedArray "CORTEX_WIRE_STORAGE_COUNT" .u8 }
  , { name := "effect_api", ty := .named "cortex_wire_program_v1_effect_api" }
  , { name := "initialized", ty := .u8 }
  , { name := "driving", ty := .u8 }
  , { name := "terminal_failed", ty := .u8 }
  , { name := "engine_checkpoint_sequence", ty := .u64 }
  , { name := "engine_checkpoint_pending", ty := .u8 }
  , { name := "engine_cancel_requested", ty := .u8 }
  , { name := "engine_terminal", ty := .named "cortex_wire_engine_v1_terminal_state" }
  , { name := "engine_host_api", ty := .named "cortex_wire_engine_v1_host_api" }
  , { name := "engine_program_identity", ty := .unsizedArray .char, isConst := true
    , initial := some (.expression (.string programIdentity)) }
  ]

def translationUnit
    (nodeCount storageCount : Nat)
    (offsets predecessorNodes topologicalOrder : List Nat)
    (programIdentity : String) : TranslationUnit :=
  { schema := "cortex.wire.program-manifest/v1"
  , identity := programIdentity
  , headerGuard := "CORTEX_WIRE_PROGRAM_V1_H"
  , headerIncludes := ["stdint.h"]
  , defines := [("CORTEX_WIRE_STORAGE_COUNT", .unsigned storageCount)]
  , orderedTypes := staticTypes
  , headerLayout := some staticHeaderLayout
  , globals := staticGlobals nodeCount storageCount offsets predecessorNodes topologicalOrder
      programIdentity
  , functions := staticFunctionsWithHeaderComments
  }

end Cortex.Wire.StaticCEmitter
