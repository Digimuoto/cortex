import Cortex.Wire.NativePure.C

/-!
## Generated NativePure v2 dispatch engine

This additive engine is the checkpoint gate around authority-free NativePure
region adapters. It deliberately knows no host context, worker registry, tool
catalogue, or executor binding. The hosted scheduler owns effect and select
policy; this generated layer enforces the observable ordering boundary:

1. a predecessor result is checkpointed and acknowledged;
2. one pure region runs synchronously;
3. its result becomes the next checkpoint;
4. that checkpoint is acknowledged before a downstream effect may start.

Region implementations and this engine are emitted as separate translation
units. The only link between them is the generated `const void *`/`void *`
adapter whose concrete frame casts remain in the region-owned unit.
-/

namespace Cortex.Wire.NativePure.C.Engine

open Cortex.Wire.C11

structure Region where
  unitId : Nat
  dispatchName : Name
  deriving DecidableEq, Repr

structure Program where
  identity : String
  planDigest : String
  regions : List Region
  deriving Repr

private def unique : List String → Bool
  | [] => true
  | value :: rest => !rest.contains value && unique rest

private def regionsValid (regions : List Region) : Bool :=
  regions.zipIdx.all (fun entry =>
    entry.1.unitId == entry.2 && validIdentifier entry.1.dispatchName) &&
      unique (regions.map (·.dispatchName))

private def digestPrefix (digest : String) : String :=
  String.ofList (digest.toList.take 16)

private def symbolPrefix (program : Program) : Name :=
  "cortex_np_engine_" ++ digestPrefix program.planDigest

private def stateName (program : Program) : Name := symbolPrefix program ++ "_state"

private def statusName (program : Program) : Name := symbolPrefix program ++ "_status"

private def functionName (program : Program) (suffix : String) : Name :=
  symbolPrefix program ++ "_" ++ suffix

private def statePointer (program : Program) (readOnly : Bool := false) : CType :=
  .pointer (.named (stateName program)) readOnly

private def protocolFailure (program : Program) : Cortex.Wire.C11.Expr :=
  .ident (symbolPrefix program ++ "_PROTOCOL")

private def okStatus (program : Program) : Cortex.Wire.C11.Expr :=
  .ident (symbolPrefix program ++ "_OK")

private def stateField (name : Name) : Cortex.Wire.C11.Expr :=
  .pointerField (.ident "state") name

private def invalidState : Cortex.Wire.C11.Expr :=
  let base :=
    .binary .logicalOr
      (.binary .equal (.ident "state") .null)
      (stateField "failed")
  .binary .logicalOr base (stateField "awaiting_checkpoint")

private def rejectInvalid (program : Program) : Stmt :=
  .branch invalidState
    [.returnValue (protocolFailure program)] []

private def adapterPrototype (region : Region) : CFunction :=
  { name := region.dispatchName
  , result := .u32
  , params :=
      [ { name := "input", ty := .pointer .void true }
      , { name := "output", ty := .pointer .void false }
      ]
  , body := none
  , visibility := .internal }

private def initFunction (program : Program) : CFunction :=
  { name := functionName program "init"
  , result := .u32
  , params := [{ name := "state", ty := statePointer program }]
  , body := some
      [ .branch (.binary .equal (.ident "state") .null)
          [.returnValue (protocolFailure program)] []
      , .assign (stateField "checkpoint_sequence") (.unsigned 1)
      , .assign (stateField "awaiting_checkpoint") (.bool true)
      , .assign (stateField "failed") (.bool false)
      , .returnValue (okStatus program)
      ]
  , visibility := .exported
  , comments := ["Require acknowledgement of the initial predecessor checkpoint."] }

/-- Deliberately omits the `failed` guard every other entry point applies
(`rejectInvalid`): the checkpoint produced by a failed dispatch must still be
durably acknowledged so the failure record itself survives a restart, even
though every subsequent entry point (`dispatch`, `effect_completed`,
`can_request_effect`) keeps rejecting once `failed` is set. Acknowledging a
failed run's checkpoint does not resume it. -/
private def checkpointCommittedFunction (program : Program) : CFunction :=
  { name := functionName program "checkpoint_committed"
  , result := .u32
  , params :=
      [ { name := "state", ty := statePointer program }
      , { name := "sequence", ty := .u64 }
      ]
  , body := some
      [ .branch
          (.binary .logicalOr
            (.binary .equal (.ident "state") .null)
            (.unary .logicalNot (stateField "awaiting_checkpoint")))
          [.returnValue (protocolFailure program)] []
      , .branch
          (.binary .notEqual (.ident "sequence") (stateField "checkpoint_sequence"))
          [.returnValue (protocolFailure program)] []
      , .assign (stateField "awaiting_checkpoint") (.bool false)
      , .returnValue (okStatus program)
      ]
  , visibility := .exported }

private def effectCompletedFunction (program : Program) : CFunction :=
  { name := functionName program "effect_completed"
  , result := .u32
  , params := [{ name := "state", ty := statePointer program }]
  , body := some
      [ rejectInvalid program
      , .assign (stateField "checkpoint_sequence")
          (.binary .add (stateField "checkpoint_sequence") (.unsigned 1))
      , .assign (stateField "awaiting_checkpoint") (.bool true)
      , .returnValue (okStatus program)
      ]
  , visibility := .exported
  , comments := ["Turn a completed effect result into the next checkpoint boundary."] }

private def canRequestEffectFunction (program : Program) : CFunction :=
  { name := functionName program "can_request_effect"
  , result := .u32
  , params := [{ name := "state", ty := statePointer program true }]
  , body := some
      [ rejectInvalid program
      , .returnValue (okStatus program)
      ]
  , visibility := .exported }

private def dispatchCase (program : Program) (region : Region) : SwitchCase :=
  { value := .unsigned region.unitId
  , body :=
      [ .block
          [ .local
              { name := "status"
              , ty := .u32
              , initial := some
                  (.call (.ident region.dispatchName) [.ident "input", .ident "output"])
              }
          , .branch (.binary .notEqual (.ident "status") (okStatus program))
              [.assign (stateField "failed") (.bool true)] []
          , .assign (stateField "checkpoint_sequence")
              (.binary .add (stateField "checkpoint_sequence") (.unsigned 1))
          , .assign (stateField "awaiting_checkpoint") (.bool true)
          , .returnValue (.ident "status")
          ]
      ] }

private def dispatchFunction (program : Program) : CFunction :=
  { name := functionName program "dispatch"
  , result := .u32
  , params :=
      [ { name := "state", ty := statePointer program }
      , { name := "unit_id", ty := .u32 }
      , { name := "input", ty := .pointer .void true }
      , { name := "output", ty := .pointer .void false }
      ]
  , body := some
      [ rejectInvalid program
      , .switch (.ident "unit_id") (program.regions.map (dispatchCase program))
          [.returnValue (.ident (symbolPrefix program ++ "_INVALID_UNIT"))]
      ]
  , visibility := .exported
  , comments :=
      ["Run exactly one authority-free region and require its result checkpoint."] }

private def engineState (program : Program) : StructDecl :=
  { name := stateName program
  , visibility := .exported
  , fields :=
      [ { name := "checkpoint_sequence", ty := .u64 }
      , { name := "awaiting_checkpoint", ty := .bool }
      , { name := "failed", ty := .bool }
      , { name := "padding_0", ty := .array 6 .u8 }
      ] }

private def engineStatus (program : Program) : EnumDecl :=
  { name := statusName program
  , visibility := .exported
  , members :=
      -- Every region's own dispatch function returns Status.code, and
      -- dispatchCase compares that raw uint32_t against this engine-owned
      -- `_OK`; deriving the value from Status.ok.code (rather than a second
      -- hardcoded 0) keeps the two encodings tied together at the Lean
      -- source level instead of by C-level numeric coincidence.
      [ { name := symbolPrefix program ++ "_OK", value := Status.code .ok }
      , { name := symbolPrefix program ++ "_INVALID_UNIT", value := 6 }
      , { name := symbolPrefix program ++ "_PROTOCOL", value := 7 }
      ] }

def translationUnit (program : Program) : Except String TranslationUnit := do
  if program.identity.isEmpty then throw "NativePure engine identity must not be empty"
  if program.planDigest.isEmpty then throw "NativePure engine plan digest must not be empty"
  if !validIdentifier (symbolPrefix program) then
    throw "NativePure engine plan digest does not form a valid symbol prefix"
  if !regionsValid program.regions then
    throw "NativePure engine regions must have dense IDs and unique valid dispatch names"
  let symbolBase := symbolPrefix program
  let state := engineState program
  pure
    { schema := "cortex.wire.native-pure-engine/v2"
    , identity := program.identity
    , headerGuard := symbolBase ++ "_V2_H"
    , localHeader := symbolBase ++ ".h"
    , orderedTypes := [.enumeration (engineStatus program), .structure state]
    , functions := program.regions.map adapterPrototype ++
        [ initFunction program
        , checkpointCommittedFunction program
        , effectCompletedFunction program
        , canRequestEffectFunction program
        , dispatchFunction program
        ]
    , assertions :=
        [ { condition := .binary .equal (.sizeof (.named state.name)) (.unsigned 16)
          , message := state.name ++ " size" }
        , { condition := .binary .equal (.alignof (.named state.name)) (.unsigned 8)
          , message := state.name ++ " alignment" }
        , { condition := .binary .equal
              (.offsetof (.named state.name) "checkpoint_sequence") (.unsigned 0)
          , message := state.name ++ ".checkpoint_sequence offset" }
        , { condition := .binary .equal
              (.offsetof (.named state.name) "awaiting_checkpoint") (.unsigned 8)
          , message := state.name ++ ".awaiting_checkpoint offset" }
        , { condition := .binary .equal
              (.offsetof (.named state.name) "failed") (.unsigned 9)
          , message := state.name ++ ".failed offset" }
        ]
    , layouts :=
        [ { name := state.name, size := 16, alignment := 8
          , fields :=
              [ { name := "checkpoint_sequence", offset := 0, size := 8 }
              , { name := "awaiting_checkpoint", offset := 8, size := 1 }
              , { name := "failed", offset := 9, size := 1 }
              ]
          }
        ]
    , resources := [{ name := "region_count", value := program.regions.length }]
    }

def compile (program : Program) : Except String ValidatedTranslationUnit := do
  C11.validate (← translationUnit program)

def render (program : Program) : Except String RenderedArtifacts := do
  renderArtifacts <$> compile program

end Cortex.Wire.NativePure.C.Engine
