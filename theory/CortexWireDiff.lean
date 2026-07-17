/-!
## Overview

Lean reference interpreter for the ADR 0091 three-way differential suite. It
replays the shared scenario corpus emitted by `wire differential emit` through
the restricted static-target semantics and prints one canonical trace line per
scenario. The generated freestanding C harness and the Haskell `GraphRuntime`
driver replay the same corpus; byte equality of the three trace streams is the
acceptance gate.

## Context

This executable mirrors the semantics pinned in `Cortex/Wire/StaticC.lean`
(status lattice, readiness over predecessor rows, failure closure, completion
application, and closed-state classification) but is written in core Lean only,
with no Mathlib dependency, so its native closure stays independent of the
proof model — exactly like the `cortex-wire-c` host compiler. The `StaticC`
lemmas certify the local operators; this interpreter and the differential gate
tie the whole `drive` transition to the generated C. The corrected v1 lifecycle
is modelled here: dispatch marks a node running immediately before its begin,
a sibling failure never strands an undispatched node running, terminal failure
latches and cancels running siblings once, and post-terminal completions are
rejected.
-/

namespace Cortex.Wire.Diff

/-- Effect-kind, drive-result, completion-result, and status codes match the
generated C ABI exactly. -/
private def statusPending : Nat := 0
private def statusRunning : Nat := 1
private def statusCompleted : Nat := 2
private def statusFailed : Nat := 3
private def statusSkipped : Nat := 4

private def driveAwaiting : Nat := 0
private def driveCompleted : Nat := 1
private def driveFailed : Nat := 2
private def driveStuck : Nat := 3

private def completionApplied : Nat := 0
private def completionStale : Nat := 1
private def completionInvalid : Nat := 2

private def effectAsync : Nat := 0
private def effectSuccess : Nat := 1
private def effectSkipped : Nat := 2
private def effectFailure : Nat := 3

private structure Scenario where
  id : String
  nodeCount : Nat
  edges : List (Nat × Nat)
  beginKind : Array Nat
  beginPayload : Array Nat
  completions : List (Nat × Nat × Nat)

private structure MState where
  status : Array Nat
  output : Array (Option Nat)
  terminal : Bool
  deriving Inhabited

/-! ### Parsing the flat scenario grammar -/

private def parseNatList (field : String) : List Nat :=
  if field == "-" then []
  else (field.splitOn ",").filterMap (·.toNat?)

private def parseEdges (field : String) : List (Nat × Nat) :=
  if field == "-" then []
  else
    (field.splitOn ",").filterMap fun token =>
      match token.splitOn ":" with
      | [a, b] =>
        match a.toNat?, b.toNat? with
        | some source, some target => some (source, target)
        | _, _ => none
      | _other => none

private def parseCompletions (field : String) : List (Nat × Nat × Nat) :=
  if field == "-" then []
  else
    (field.splitOn ",").filterMap fun token =>
      match token.splitOn ":" with
      | [a, b, c] =>
        match a.toNat?, b.toNat?, c.toNat? with
        | some node, some outcome, some payload => some (node, outcome, payload)
        | _, _, _ => none
      | _other => none

private def parseScenario (line : String) : Option Scenario :=
  match line.splitOn " " with
  | [id, nodeCountField, edgesField, beginField, payloadField, completionsField] =>
    match nodeCountField.toNat? with
    | some nodeCount =>
      some
        { id := id
          nodeCount := nodeCount
          edges := parseEdges edgesField
          beginKind := (parseNatList beginField).toArray
          beginPayload := (parseNatList payloadField).toArray
          completions := parseCompletions completionsField }
    | none => none
  | _other => none

/-! ### Restricted target semantics -/

private def unblocks (code : Nat) : Bool :=
  code == statusCompleted || code == statusSkipped

private def predecessors (edges : List (Nat × Nat)) (node : Nat) : List Nat :=
  (edges.filter fun edge => edge.2 == node).map (·.1)

private def nodeReady (edges : List (Nat × Nat)) (status : Array Nat) (node : Nat) : Bool :=
  status.getD node statusPending == statusPending &&
    (predecessors edges node).all fun predecessor =>
      unblocks (status.getD predecessor statusPending)

private def anyStatus (nodeCount : Nat) (status : Array Nat) (expected : Nat) : Bool :=
  (List.range nodeCount).any fun node => status.getD node statusPending == expected

private def allSettled (nodeCount : Nat) (status : Array Nat) : Bool :=
  (List.range nodeCount).all fun node =>
    let code := status.getD node statusPending
    code == statusCompleted || code == statusFailed || code == statusSkipped

/-- One failure-closure sweep: mark every pending node with a failed predecessor
failed. Fixed-point iteration converges within `nodeCount` sweeps because each
non-trivial sweep marks at least one more node failed. -/
private def propagateSweep
    (nodeCount : Nat) (edges : List (Nat × Nat)) (status : Array Nat) : Array Nat :=
  (List.range nodeCount).foldl
    (fun acc node =>
      if acc.getD node statusPending == statusPending &&
          (predecessors edges node).any (fun p => acc.getD p statusPending == statusFailed)
        then acc.set! node statusFailed
        else acc)
    status

/-- Failure closure to a fixed point, bounded by `nodeCount` sweeps. Matches the
Haskell `propagateFailure` reachability closure. -/
private def propagate
    (nodeCount : Nat) (edges : List (Nat × Nat)) (status : Array Nat) (fuel : Nat) : Array Nat :=
  match fuel with
  | 0 => status
  | fuel + 1 =>
    let next := propagateSweep nodeCount edges status
    if next == status then status else propagate nodeCount edges next fuel

/-- Cancel every running node once by moving it to failed. -/
private def latchTerminalFailure (nodeCount : Nat) (status : Array Nat) : Array Nat :=
  (List.range nodeCount).foldl
    (fun acc node =>
      if acc.getD node statusPending == statusRunning then acc.set! node statusFailed else acc)
    status

/-- Dispatch the frontier snapshot in order: mark running, then begin; stop at
the first node that begins failed, leaving later members pending. -/
private def dispatchFrontier
    (beginKind beginPayload : Array Nat)
    (frontier : List Nat)
    (status : Array Nat)
    (output : Array (Option Nat)) : Array Nat × Array (Option Nat) :=
  match frontier with
  | [] => (status, output)
  | node :: rest =>
    let running := status.set! node statusRunning
    let kind := beginKind.getD node effectFailure
    let (status', output') :=
      if kind == effectAsync then (running, output)
      else if kind == effectSuccess then
        (running.set! node statusCompleted, output.set! node (some (beginPayload.getD node 0)))
      else if kind == effectSkipped then (running.set! node statusSkipped, output)
      else (running.set! node statusFailed, output)
    if status'.getD node statusPending == statusFailed then (status', output')
    else dispatchFrontier beginKind beginPayload rest status' output'

/-- The inner `drive` loop over the restricted target machine.

Each iteration that dispatches removes at least one node from the pending set, so
the loop settles within `nodeCount + 1` iterations; `fuel` bounds it structurally.
-/
private def driveLoop
    (sc : Scenario)
    (status : Array Nat)
    (output : Array (Option Nat))
    (fuel : Nat) : Nat × MState :=
  match fuel with
  | 0 => (driveStuck, { status := status, output := output, terminal := false })
  | fuel + 1 =>
    let closed := propagate sc.nodeCount sc.edges status sc.nodeCount
    if anyStatus sc.nodeCount closed statusFailed then
      (driveFailed,
        { status := latchTerminalFailure sc.nodeCount closed, output := output, terminal := true })
    else
      let frontier := (List.range sc.nodeCount).filter (nodeReady sc.edges closed)
      if frontier.isEmpty then
        if anyStatus sc.nodeCount closed statusRunning then
          (driveAwaiting, { status := closed, output := output, terminal := false })
        else if allSettled sc.nodeCount closed then
          (driveCompleted, { status := closed, output := output, terminal := false })
        else
          (driveStuck, { status := closed, output := output, terminal := false })
      else
        let (status', output') :=
          dispatchFrontier sc.beginKind sc.beginPayload frontier closed output
        driveLoop sc status' output' fuel

/-- One `drive` call over the restricted target machine. -/
private def driveOnce (sc : Scenario) (state : MState) : Nat × MState :=
  if state.terminal then (driveFailed, state)
  else driveLoop sc state.status state.output (sc.nodeCount + 1)

/-- Apply one completion to a running node, including post-terminal rejection. -/
private def applyCompletion
    (sc : Scenario) (node outcome payload : Nat) (state : MState) : Nat × MState :=
  if state.terminal then (completionStale, state)
  else if node ≥ sc.nodeCount then (completionInvalid, state)
  else if state.status.getD node statusPending != statusRunning then (completionStale, state)
  else if outcome == effectSuccess then
    (completionApplied,
      { state with
        status := state.status.set! node statusCompleted
        output := state.output.set! node (some payload) })
  else if outcome == effectSkipped then
    (completionApplied, { state with status := state.status.set! node statusSkipped })
  else if outcome == effectFailure then
    (completionApplied, { state with status := state.status.set! node statusFailed })
  else (completionInvalid, state)

/-! ### Trace rendering -/

private def renderStatusVec (nodeCount : Nat) (status : Array Nat) : String :=
  String.intercalate ","
    ((List.range nodeCount).map fun i => toString (status.getD i statusPending))

private def renderOutputVec (nodeCount : Nat) (output : Array (Option Nat)) : String :=
  String.intercalate ","
    ((List.range nodeCount).map fun i =>
      match output.getD i none with
      | some value => toString value
      | none => "n")

private def driveToken (sc : Scenario) (result : Nat) (state : MState) : String :=
  "D" ++ toString result ++ ":" ++ renderStatusVec sc.nodeCount state.status ++ ":" ++
    renderOutputVec sc.nodeCount state.output

private def completionToken (node outcome payload result : Nat) : String :=
  "C" ++ toString node ++ "," ++ toString outcome ++ "," ++ toString payload ++ ":" ++
    toString result

/-- Deliver remaining completions after a terminal drive, recording each as a
rejected post-terminal event, without driving again. -/
private def drainCompletions
    (sc : Scenario)
    (state : MState)
    (events : List (Nat × Nat × Nat))
    (steps : List String) : List String × MState :=
  match events with
  | [] => (steps, state)
  | (node, outcome, payload) :: rest =>
    let (result, state') := applyCompletion sc node outcome payload state
    drainCompletions sc state' rest (completionToken node outcome payload result :: steps)

/-- Drive-and-complete loop, mirroring the reference harness.

The only recursive branch consumes one completion event, so the loop terminates
on `events.length`. -/
private def runLoop
    (sc : Scenario)
    (state : MState)
    (events : List (Nat × Nat × Nat))
    (steps : List String) : List String × Nat × MState :=
  let (result, state') := driveOnce sc state
  let steps' := driveToken sc result state' :: steps
  if result == driveAwaiting then
    match events with
    | [] => (steps', result, state')
    | (node, outcome, payload) :: rest =>
      let (cResult, state'') := applyCompletion sc node outcome payload state'
      runLoop sc state'' rest (completionToken node outcome payload cResult :: steps')
  else
    let (steps'', state'') := drainCompletions sc state' events steps'
    (steps'', result, state'')
  termination_by events.length
  decreasing_by simp_wf

/-- Replay a whole scenario, mirroring the reference harness loop. -/
private def runScenario (sc : Scenario) : String :=
  let initial : MState :=
    { status := Array.replicate sc.nodeCount statusPending
      output := Array.replicate sc.nodeCount none
      terminal := false }
  let (steps, terminal, final) := runLoop sc initial sc.completions []
  String.intercalate "\t"
    [ sc.id
    , String.intercalate " " steps.reverse
    , toString terminal
    , renderStatusVec sc.nodeCount final.status
    , renderOutputVec sc.nodeCount final.output ]

/-! ### Entry point -/

private def runCorpus (corpusDir : String) : IO Unit := do
  let scenarioPath := corpusDir ++ "/scenarios-all.txt"
  let contents ← IO.FS.readFile scenarioPath
  let lines := contents.splitOn "\n" |>.filter (fun line => line != "")
  let traces := lines.filterMap fun line =>
    (parseScenario line).map runScenario
  if traces.length != lines.length then
    throw (IO.userError s!"failed to parse {lines.length - traces.length} scenario lines")
  IO.FS.writeFile (corpusDir ++ "/lean-traces.txt") (String.intercalate "\n" traces ++ "\n")

def main (args : List String) : IO UInt32 := do
  match args with
  | [corpusDir] =>
    try
      runCorpus corpusDir
      IO.println s!"emitted Lean differential traces to {corpusDir}/lean-traces.txt"
      pure 0
    catch error =>
      IO.eprintln s!"cortex-wire-diff: {error}"
      pure 1
  | _args =>
    IO.eprintln "usage: cortex-wire-diff CORPUS_DIR"
    pure 2

end Cortex.Wire.Diff

def main (args : List String) : IO UInt32 :=
  Cortex.Wire.Diff.main args
