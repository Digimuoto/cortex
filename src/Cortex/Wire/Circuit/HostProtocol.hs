{- |
Module      : Cortex.Wire.Circuit.HostProtocol
Description : Pure lifecycle policy for the hosted Wire process protocol.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The hosted engine owns circuit scheduling, but the process host owns a second
state machine: checkpoint acknowledgement, worker completion serialization,
cancellation, watchdogs, terminal authority, and child exit. Keeping those
decisions pure makes concurrency crossings reviewable and gives the TLA+ model
in @formal/HostedProtocol.tla@ a concrete implementation target.

Each input has its own result type. The IO loop therefore handles every legal
decision exhaustively instead of recovering from an impossible action at
runtime.
-}
module Cortex.Wire.Circuit.HostProtocol
  ( CancellationDeadlineUpdate (..)
  , CancellationDeadlines (..)
  , CancellationDecision (..)
  , CheckpointAcknowledgementDecision (..)
  , CheckpointDeadlines (..)
  , CheckpointDecision (..)
  , ChildExitDecision (..)
  , CompletionDropReason (..)
  , DeadlineKind (..)
  , DeadlineDecision (..)
  , EngineDeadlineUpdate (..)
  , InterruptedCompletionDecision (..)
  , ProtocolView (..)
  , ResolvedCompletionDecision (..)
  , ShutdownDeadlines (..)
  , SuccessorDecision (..)
  , TerminalDecision (..)
  , decideCancellation
  , decideCheckpoint
  , decideCheckpointAcknowledgement
  , decideChildExit
  , decideDeadline
  , decideInterruptedCompletion
  , decideResolvedCompletion
  , decideSuccessor
  , decideTerminal
  )
where

import Data.Text (Text)
import System.Exit (ExitCode (..))

import Cortex.Wire.Circuit.Engine
  ( EngineTerminalState (..)
  )

data EngineDeadlineUpdate
  = KeepEngineDeadline
  | ClearEngineDeadline
  | ArmFreshEngineDeadline
  | EnsureEngineDeadline
  deriving stock (Eq, Show)

data CancellationDeadlineUpdate
  = KeepCancellationDeadline
  | ClearCancellationDeadline
  | EnsureCancellationDeadline
  deriving stock (Eq, Show)

data CancellationDeadlines = CancellationDeadlines
  { cancellationEngineDeadline :: !EngineDeadlineUpdate
  , cancellationFollowUpDeadline :: !CancellationDeadlineUpdate
  }
  deriving stock (Eq, Show)

data CheckpointDeadlines = CheckpointDeadlines
  { checkpointEngineDeadline :: !EngineDeadlineUpdate
  , checkpointCancellationDeadline :: !CancellationDeadlineUpdate
  }
  deriving stock (Eq, Show)

data ShutdownDeadlines = ShutdownDeadlines
  { shutdownEngineDeadline :: !EngineDeadlineUpdate
  , shutdownCancellationDeadline :: !CancellationDeadlineUpdate
  }
  deriving stock (Eq, Show)

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

data CompletionDropReason
  = DroppedAfterCancellation
  | DroppedAfterTerminalCheckpoint
  | DroppedDuringInterruption
  deriving stock (Eq, Show)

data CancellationDecision
  = IgnoreCancellation
  | SendCancellation !CancellationDeadlines
  deriving stock (Eq, Show)

data SuccessorDecision
  = SuccessorFault !Text
  | SuppressSuccessor
  | StartSuccessor !EngineDeadlineUpdate
  deriving stock (Eq, Show)

data ResolvedCompletionDecision
  = DropResolvedCompletion !CompletionDropReason
  | BufferResolvedCompletion
  | ForwardResolvedCompletion !EngineDeadlineUpdate
  deriving stock (Eq, Show)

data InterruptedCompletionDecision
  = DropInterruptedCompletion !CompletionDropReason
  | InterruptedCompletionFault !Text
  | AwaitCancellation !CancellationDeadlineUpdate
  deriving stock (Eq, Show)

data CheckpointDecision
  = CheckpointFault !Text
  | CommitCheckpoint !CheckpointDeadlines
  deriving stock (Eq, Show)

data CheckpointAcknowledgementDecision
  = DropBufferedCompletions !CompletionDropReason
  | DispatchBufferedCompletion !EngineDeadlineUpdate
  | AwaitEngineOutput !EngineDeadlineUpdate
  | AwaitWorkers
  deriving stock (Eq, Show)

data TerminalDecision
  = TerminalFault !Text
  | SendShutdown !ShutdownDeadlines
  | CancelWorkersAndSendShutdown !ShutdownDeadlines
  deriving stock (Eq, Show)

data ChildExitDecision
  = FinishCommittedTerminal
  | ChildExitFault !Text
  deriving stock (Eq, Show)

data DeadlineDecision
  = FinishDeadlineTerminal
  | DeadlineFault !Text
  deriving stock (Eq, Show)

data DeadlineKind
  = EngineDeadline
  | CancellationDeadline
  deriving stock (Eq, Show)

decideCancellation :: ProtocolView -> CancellationDecision
decideCancellation state
  | terminalObserved state = IgnoreCancellation
  | committedTerminal state = IgnoreCancellation
  | state.protocolCancellationSent = IgnoreCancellation
  | otherwise =
      SendCancellation
        CancellationDeadlines
          { cancellationEngineDeadline = EnsureEngineDeadline
          , cancellationFollowUpDeadline = ClearCancellationDeadline
          }

decideSuccessor :: ProtocolView -> SuccessorDecision
decideSuccessor state = case state.protocolCommittedTerminal of
  Nothing -> SuccessorFault "engine requested an effect before its initial checkpoint was committed"
  Just terminal
    | terminal /= EngineActive ->
        SuccessorFault "engine requested an effect after a terminal checkpoint was committed"
    | state.protocolCancellationSent -> SuppressSuccessor
    | state.protocolInterruptedCount /= 0 -> SuppressSuccessor
    | otherwise ->
        StartSuccessor
          ( if state.protocolAwaitingCheckpoint
              then KeepEngineDeadline
              else ClearEngineDeadline
          )

decideResolvedCompletion :: ProtocolView -> ResolvedCompletionDecision
decideResolvedCompletion state
  | committedTerminal state = DropResolvedCompletion DroppedAfterTerminalCheckpoint
  | state.protocolCancellationSent = DropResolvedCompletion DroppedAfterCancellation
  | state.protocolInterruptedCount /= 0 = DropResolvedCompletion DroppedDuringInterruption
  | state.protocolAwaitingCheckpoint = BufferResolvedCompletion
  | otherwise = ForwardResolvedCompletion ArmFreshEngineDeadline

decideInterruptedCompletion :: ProtocolView -> Bool -> InterruptedCompletionDecision
decideInterruptedCompletion state cancellationWatcherInstalled
  | not cancellationWatcherInstalled =
      InterruptedCompletionFault
        "effect reported interruption but no cancellation watcher is installed"
  | committedTerminal state = DropInterruptedCompletion DroppedAfterTerminalCheckpoint
  | state.protocolCancellationSent = DropInterruptedCompletion DroppedAfterCancellation
  | otherwise = AwaitCancellation EnsureCancellationDeadline

decideCheckpoint :: ProtocolView -> EngineTerminalState -> CheckpointDecision
decideCheckpoint state terminal
  | terminalObserved state = CheckpointFault "engine emitted a checkpoint after terminal"
  | committedTerminal state =
      CheckpointFault "engine emitted a checkpoint after a terminal checkpoint was committed"
  | terminal == EngineSucceeded && outstanding /= 0 =
      CheckpointFault "engine emitted a succeeded checkpoint with host effects still outstanding"
  | otherwise =
      CommitCheckpoint
        CheckpointDeadlines
          { checkpointEngineDeadline =
              if state.protocolCancellationSent && terminal == EngineActive
                then KeepEngineDeadline
                else ClearEngineDeadline
          , checkpointCancellationDeadline =
              if terminal == EngineActive
                then KeepCancellationDeadline
                else ClearCancellationDeadline
          }
  where
    outstanding =
      state.protocolWorkerCount
        + state.protocolInterruptedCount
        + state.protocolBufferedCompletionCount

decideCheckpointAcknowledgement
  :: ProtocolView
  -> EngineTerminalState
  -> CheckpointAcknowledgementDecision
decideCheckpointAcknowledgement state terminal
  | terminal /= EngineActive && state.protocolBufferedCompletionCount /= 0 =
      DropBufferedCompletions DroppedAfterTerminalCheckpoint
  | terminal /= EngineActive = AwaitEngineOutput ArmFreshEngineDeadline
  | state.protocolInterruptedCount /= 0
      && state.protocolBufferedCompletionCount /= 0 =
      DropBufferedCompletions DroppedDuringInterruption
  | state.protocolCancellationSent && state.protocolBufferedCompletionCount /= 0 =
      DropBufferedCompletions DroppedAfterCancellation
  | state.protocolBufferedCompletionCount /= 0 =
      DispatchBufferedCompletion ArmFreshEngineDeadline
  | state.protocolCancellationSent = AwaitEngineOutput EnsureEngineDeadline
  | state.protocolWorkerCount == 0 && state.protocolInterruptedCount == 0 =
      AwaitEngineOutput ArmFreshEngineDeadline
  | otherwise = AwaitWorkers

decideTerminal :: ProtocolView -> EngineTerminalState -> TerminalDecision
decideTerminal state terminal
  | terminalObserved state = TerminalFault "engine emitted duplicate terminal"
  | terminal == EngineActive = TerminalFault "engine emitted an active terminal event"
  | otherwise = case state.protocolCommittedTerminal of
      Nothing -> TerminalFault "engine emitted terminal before a committed checkpoint"
      Just committed
        | committed /= terminal ->
            TerminalFault "terminal event disagrees with the committed checkpoint"
        | state.protocolAwaitingCheckpoint ->
            TerminalFault "engine emitted terminal before checkpoint acknowledgement"
        | terminal == EngineSucceeded && outstanding /= 0 ->
            TerminalFault "engine emitted succeeded terminal with host effects still outstanding"
        | terminal /= EngineSucceeded && outstanding /= 0 ->
            CancelWorkersAndSendShutdown shutdownDeadlines
        | otherwise -> SendShutdown shutdownDeadlines
  where
    outstanding =
      state.protocolWorkerCount
        + state.protocolInterruptedCount
        + state.protocolBufferedCompletionCount
    shutdownDeadlines =
      ShutdownDeadlines
        { shutdownEngineDeadline = ArmFreshEngineDeadline
        , shutdownCancellationDeadline = ClearCancellationDeadline
        }

decideChildExit :: ProtocolView -> ExitCode -> ChildExitDecision
decideChildExit state exitKind
  | terminalObserved state = FinishCommittedTerminal
  | ExitSuccess <- exitKind = ChildExitFault "hosted engine exited before a terminal event"
  | ExitFailure _ <- exitKind = ChildExitFault "hosted engine exited unexpectedly"

decideDeadline :: DeadlineKind -> ProtocolView -> DeadlineDecision
decideDeadline deadlineKind state
  | terminalObserved state = FinishDeadlineTerminal
  | otherwise =
      DeadlineFault
        ( case deadlineKind of
            EngineDeadline ->
              "hosted engine unresponsive: mandated protocol output did not arrive within the response deadline"
            CancellationDeadline ->
              "host cancellation did not follow an interrupted effect within the response deadline"
        )

terminalObserved :: ProtocolView -> Bool
terminalObserved state = case state.protocolTerminalSeen of
  Nothing -> False
  Just _terminal -> True

committedTerminal :: ProtocolView -> Bool
committedTerminal ProtocolView {protocolCommittedTerminal = Just terminal} = terminal /= EngineActive
committedTerminal _state = False
