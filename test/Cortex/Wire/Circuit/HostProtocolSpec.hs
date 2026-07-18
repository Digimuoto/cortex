{- |
Module      : Cortex.Wire.Circuit.HostProtocolSpec
Description : Exhaustive finite checks for the pure hosted protocol policy.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Exercises the race-relevant decisions exported by the pure host lifecycle
policy without involving process handles, timers, or worker payloads.
-}
module Cortex.Wire.Circuit.HostProtocolSpec (spec) where

import System.Exit (ExitCode (..))
import Test.Hspec

import Cortex.Wire.Circuit.Engine
  ( EngineTerminalState (..)
  )
import Cortex.Wire.Circuit.HostProtocol

spec :: Spec
spec = describe "hosted process protocol policy" $ do
  it "never forwards a completion after cancellation or terminal authority" $ do
    decideResolvedCompletion state {protocolCancellationSent = True}
      `shouldBe` DropResolvedCompletion DroppedAfterCancellation
    decideResolvedCompletion state {protocolCommittedTerminal = Just EngineTerminalFailed}
      `shouldBe` DropResolvedCompletion DroppedAfterTerminalCheckpoint
    decideInterruptedCompletion
      state {protocolCommittedTerminal = Just EngineCancelled}
      True
      `shouldBe` DropInterruptedCompletion DroppedAfterTerminalCheckpoint

  it "still faults an interrupted worker without a cancellation watcher after terminal authority" $
    decideInterruptedCompletion
      state {protocolCommittedTerminal = Just EngineTerminalFailed}
      False
      `shouldBe` InterruptedCompletionFault
        "effect reported interruption but no cancellation watcher is installed"

  it "requires active committed authority before starting a successor" $ do
    decideSuccessor state {protocolCommittedTerminal = Nothing}
      `shouldBe` SuccessorFault "engine requested an effect before its initial checkpoint was committed"
    decideSuccessor state {protocolCommittedTerminal = Just EngineSucceeded}
      `shouldBe` SuccessorFault "engine requested an effect after a terminal checkpoint was committed"
    decideSuccessor state {protocolAwaitingCheckpoint = True}
      `shouldBe` StartSuccessor KeepEngineDeadline

  it "rejects checkpoints and duplicate terminal events after terminal authority" $ do
    decideCheckpoint
      state {protocolTerminalSeen = Just EngineSucceeded}
      EngineSucceeded
      `shouldBe` CheckpointFault "engine emitted a checkpoint after terminal"
    decideCheckpoint
      state {protocolCommittedTerminal = Just EngineSucceeded}
      EngineSucceeded
      `shouldBe` CheckpointFault "engine emitted a checkpoint after a terminal checkpoint was committed"
    decideTerminal
      state {protocolTerminalSeen = Just EngineSucceeded}
      EngineSucceeded
      `shouldBe` TerminalFault "engine emitted duplicate terminal"

  it "requires succeeded checkpoints to be host-quiescent" $
    mapM_
      ( \candidate ->
          decideCheckpoint candidate EngineSucceeded
            `shouldBe` CheckpointFault "engine emitted a succeeded checkpoint with host effects still outstanding"
      )
      [ state {protocolWorkerCount = 1}
      , state {protocolInterruptedCount = 1}
      , state {protocolBufferedCompletionCount = 1}
      ]

  it "cancels outstanding host work for failed and cancelled terminals" $
    mapM_
      ( \terminal ->
          decideTerminal
            state
              { protocolCommittedTerminal = Just terminal
              , protocolWorkerCount = 1
              }
            terminal
            `shouldBe` CancelWorkersAndSendShutdown shutdownDeadlines
      )
      [EngineTerminalFailed, EngineCancelled]

  it "never dispatches buffered completions beyond a terminal checkpoint" $ do
    decideCheckpointAcknowledgement
      state {protocolBufferedCompletionCount = 2}
      EngineTerminalFailed
      `shouldBe` DropBufferedCompletions DroppedAfterTerminalCheckpoint
    decideCheckpointAcknowledgement state EngineTerminalFailed
      `shouldBe` AwaitEngineOutput ArmFreshEngineDeadline

  it "drops buffered completions when an interruption is pending" $
    decideCheckpointAcknowledgement
      state
        { protocolInterruptedCount = 1
        , protocolBufferedCompletionCount = 1
        }
      EngineActive
      `shouldBe` DropBufferedCompletions DroppedDuringInterruption

  it "returns explicit deadline policy for buffer dispatch and shutdown" $ do
    decideCheckpointAcknowledgement
      state {protocolBufferedCompletionCount = 1}
      EngineActive
      `shouldBe` DispatchBufferedCompletion ArmFreshEngineDeadline
    decideTerminal
      state {protocolCommittedTerminal = Just EngineSucceeded}
      EngineSucceeded
      `shouldBe` SendShutdown shutdownDeadlines

  it "keeps cancellation and engine deadlines separate and named" $ do
    decideCancellation state
      `shouldBe` SendCancellation
        CancellationDeadlines
          { cancellationEngineDeadline = EnsureEngineDeadline
          , cancellationFollowUpDeadline = ClearCancellationDeadline
          }
    decideInterruptedCompletion state True
      `shouldBe` AwaitCancellation EnsureCancellationDeadline
    decideCheckpoint state {protocolCancellationSent = True} EngineActive
      `shouldBe` CommitCheckpoint
        CheckpointDeadlines
          { checkpointEngineDeadline = KeepEngineDeadline
          , checkpointCancellationDeadline = KeepCancellationDeadline
          }

  it "lets a committed terminal survive either child exit code and watchdog" $ do
    let observed = state {protocolTerminalSeen = Just EngineTerminalFailed}
    mapM_
      (\exitCode -> decideChildExit observed exitCode `shouldBe` FinishCommittedTerminal)
      [ExitSuccess, ExitFailure 1]
    decideDeadline EngineDeadline observed `shouldBe` FinishDeadlineTerminal
    decideDeadline CancellationDeadline observed `shouldBe` FinishDeadlineTerminal

  it "drops buffered completions when cancellation crosses acknowledgement" $
    decideCheckpointAcknowledgement
      state
        { protocolCancellationSent = True
        , protocolBufferedCompletionCount = 2
        }
      EngineActive
      `shouldBe` DropBufferedCompletions DroppedAfterCancellation
  where
    state =
      ProtocolView
        { protocolCommittedTerminal = Just EngineActive
        , protocolAwaitingCheckpoint = False
        , protocolWorkerCount = 0
        , protocolInterruptedCount = 0
        , protocolBufferedCompletionCount = 0
        , protocolTerminalSeen = Nothing
        , protocolCancellationSent = False
        }
    shutdownDeadlines =
      ShutdownDeadlines
        { shutdownEngineDeadline = ArmFreshEngineDeadline
        , shutdownCancellationDeadline = ClearCancellationDeadline
        }
