{- |
Module      : Cortex.Wire.Circuit.HostProtocol
Description : Pure lifecycle policy for the hosted Wire process protocol.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The hosted engine owns circuit scheduling, but the process host owns a second
state machine: checkpoint acknowledgement, worker completion serialization,
cancellation, watchdogs, terminal authority, and child exit.  Keeping those
decisions as a pure transition policy makes the concurrency crossings
reviewable and gives the TLA+ model in @formal/HostedProtocol.tla@ a concrete
implementation target.

This module deliberately carries no handles, callbacks, timers, or worker
payloads.  'ProtocolView' is the lifecycle projection of the IO loop and
'transition' selects its next authoritative action.  The caller performs that
action and then projects its new state before the next transition.
-}
module Cortex.Wire.Circuit.HostProtocol
  ( ChildExitKind (..)
  , DeadlineUpdate (..)
  , ProtocolAction (..)
  , ProtocolEvent (..)
  , ProtocolView (..)
  , transition
  )
where

import Data.Text (Text)

import Cortex.Wire.Circuit.Engine
  ( EngineTerminalState (..)
  )

{- | Whether process exit itself was successful.  Terminal authority is
intentionally separate: once terminal is committed and observed, either
exit kind finishes with that committed result.
-}
data ChildExitKind
  = ChildExitSuccess
  | ChildExitAbnormal
  deriving stock (Eq, Show)

-- | How an IO-backed deadline changes across one pure protocol transition.
data DeadlineUpdate
  = KeepDeadline
  | ClearDeadline
  | ArmFreshDeadline
  | EnsureDeadline
  deriving stock (Eq, Show)

-- | Race-relevant lifecycle facts projected from the process loop.
data ProtocolView = ProtocolView
  { protocolCommittedTerminal :: !(Maybe EngineTerminalState)
  , protocolAwaitingCheckpoint :: !Bool
  , protocolWorkerCount :: !Int
  , protocolInterruptedCount :: !Int
  , protocolBufferedCompletionCount :: !Int
  , protocolTerminalSeen :: !(Maybe EngineTerminalState)
  , protocolCancellationSent :: !Bool
  }
  deriving stock (Eq, Show)

-- | Inputs whose disposition previously lived in interleaved IO branches.
data ProtocolEvent
  = CancellationRequested
  | SuccessorRequested
  | ResolvedCompletionArrived
  | InterruptedCompletionArrived !Bool
  | CheckpointReceived !EngineTerminalState
  | CheckpointAcknowledged !EngineTerminalState
  | TerminalReceived !EngineTerminalState
  | ChildExited !ChildExitKind
  | EngineDeadlineExpired
  | CancellationDeadlineExpired
  deriving stock (Eq, Show)

-- | Authoritative next action selected by the pure host protocol.
data ProtocolAction
  = IgnoreInput
  | SendCancellation !DeadlineUpdate !DeadlineUpdate
  | StartSuccessor !DeadlineUpdate
  | SuppressSuccessor
  | ForwardCompletion !DeadlineUpdate
  | BufferCompletion
  | DropCompletion
  | AwaitCancellation !DeadlineUpdate
  | CommitCheckpoint !DeadlineUpdate
  | DispatchBufferedCompletion
  | DropBufferedCompletions
  | AwaitTerminal !DeadlineUpdate
  | AwaitCancellationCheckpoint !DeadlineUpdate
  | AwaitEngineProgress !DeadlineUpdate
  | AwaitWorkers
  | SendShutdown
  | CancelWorkersAndSendShutdown
  | FinishCommittedTerminal
  | ProtocolFault !Text
  deriving stock (Eq, Show)

-- | Pure transition policy for host-owned lifecycle decisions.
transition :: ProtocolView -> ProtocolEvent -> ProtocolAction
transition state = \case
  CancellationRequested
    | terminalObserved -> IgnoreInput
    | state.protocolCancellationSent -> IgnoreInput
    | otherwise -> SendCancellation EnsureDeadline ClearDeadline
  SuccessorRequested
    | not hasCommittedCheckpoint ->
        ProtocolFault "engine requested an effect before its initial checkpoint was committed"
    | terminalObserved -> ProtocolFault "engine requested an effect after terminal"
    | state.protocolCancellationSent -> SuppressSuccessor
    | state.protocolInterruptedCount /= 0 -> SuppressSuccessor
    | otherwise ->
        StartSuccessor
          ( if state.protocolAwaitingCheckpoint
              then KeepDeadline
              else ClearDeadline
          )
  ResolvedCompletionArrived
    | state.protocolCancellationSent -> DropCompletion
    | state.protocolInterruptedCount /= 0 -> DropCompletion
    | state.protocolAwaitingCheckpoint -> BufferCompletion
    | otherwise -> ForwardCompletion ArmFreshDeadline
  InterruptedCompletionArrived cancellationWatcherInstalled
    | state.protocolCancellationSent -> DropCompletion
    | not cancellationWatcherInstalled ->
        ProtocolFault "effect reported interruption but no cancellation watcher is installed"
    | otherwise -> AwaitCancellation EnsureDeadline
  CheckpointReceived terminal ->
    CommitCheckpoint
      ( if state.protocolCancellationSent && terminal == EngineActive
          then KeepDeadline
          else ClearDeadline
      )
  CheckpointAcknowledged terminal
    | state.protocolCancellationSent
        && state.protocolBufferedCompletionCount /= 0 ->
        DropBufferedCompletions
    | state.protocolBufferedCompletionCount /= 0 -> DispatchBufferedCompletion
    | terminal /= EngineActive -> AwaitTerminal ArmFreshDeadline
    | state.protocolCancellationSent -> AwaitCancellationCheckpoint EnsureDeadline
    | state.protocolWorkerCount == 0
        && state.protocolInterruptedCount == 0 ->
        AwaitEngineProgress ArmFreshDeadline
    | otherwise -> AwaitWorkers
  TerminalReceived terminal ->
    case state.protocolCommittedTerminal of
      Nothing -> ProtocolFault "engine emitted terminal before a committed checkpoint"
      Just committedTerminal
        | committedTerminal /= terminal ->
            ProtocolFault "terminal event disagrees with the committed checkpoint"
        | state.protocolAwaitingCheckpoint ->
            ProtocolFault "engine emitted terminal before checkpoint acknowledgement"
        | terminal == EngineCancelled && state.protocolCancellationSent ->
            CancelWorkersAndSendShutdown
        | state.protocolWorkerCount /= 0 ->
            ProtocolFault "engine emitted terminal with effects still running"
        | state.protocolInterruptedCount /= 0 ->
            ProtocolFault "engine emitted terminal with interrupted effects outstanding"
        | state.protocolBufferedCompletionCount /= 0 ->
            ProtocolFault "engine emitted terminal with buffered completions"
        | otherwise -> SendShutdown
  ChildExited exitKind
    | terminalObserved -> FinishCommittedTerminal
    | exitKind == ChildExitSuccess ->
        ProtocolFault "hosted engine exited before a terminal event"
    | otherwise -> ProtocolFault "hosted engine exited unexpectedly"
  EngineDeadlineExpired
    | terminalObserved -> FinishCommittedTerminal
    | otherwise ->
        ProtocolFault
          "hosted engine unresponsive: mandated protocol output did not arrive within the response deadline"
  CancellationDeadlineExpired ->
    ProtocolFault
      "host cancellation did not follow an interrupted effect within the response deadline"
  where
    hasCommittedCheckpoint = case state.protocolCommittedTerminal of
      Nothing -> False
      Just _terminal -> True
    terminalObserved = case state.protocolTerminalSeen of
      Nothing -> False
      Just _terminal -> True
