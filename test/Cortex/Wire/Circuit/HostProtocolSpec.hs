{- |
Module      : Cortex.Wire.Circuit.HostProtocolSpec
Description : Exhaustive finite checks for the pure hosted protocol policy.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Exhaustively exercises the finite lifecycle decisions that the IO-backed
hosted event loop delegates to the pure protocol policy.
-}
module Cortex.Wire.Circuit.HostProtocolSpec (spec) where

import Test.Hspec

import Cortex.Wire.Circuit.Engine
  ( EngineTerminalState (..)
  )
import Cortex.Wire.Circuit.HostProtocol

spec :: Spec
spec = describe "hosted process protocol policy" $ do
  it "never forwards a completion after cancellation" $
    mapM_
      ( \candidateState ->
          transition candidateState ResolvedCompletionArrived
            `shouldBe` DropCompletion
      )
      [ state
          { protocolCancellationSent = True
          , protocolAwaitingCheckpoint = awaiting
          , protocolInterruptedCount = interrupted
          }
      | awaiting <- [False, True]
      , interrupted <- [0, 1]
      ]

  it "preserves an outstanding engine deadline across unrelated traffic" $ do
    transition
      state {protocolAwaitingCheckpoint = True}
      SuccessorRequested
      `shouldBe` StartSuccessor KeepDeadline
    transition
      state {protocolCancellationSent = True}
      (CheckpointReceived EngineActive)
      `shouldBe` CommitCheckpoint KeepDeadline

  it "keeps cancellation and engine deadlines as separate obligations" $
    transition state (InterruptedCompletionArrived True)
      `shouldBe` AwaitCancellation EnsureDeadline

  it "requires committed checkpoint authority before terminal" $ do
    transition
      state {protocolCommittedTerminal = Nothing}
      (TerminalReceived EngineSucceeded)
      `shouldBe` ProtocolFault "engine emitted terminal before a committed checkpoint"
    transition
      state {protocolCommittedTerminal = Just EngineCancelled}
      (TerminalReceived EngineSucceeded)
      `shouldBe` ProtocolFault "terminal event disagrees with the committed checkpoint"

  it "lets a committed terminal survive either child exit kind" $
    mapM_
      ( \exitKind ->
          transition
            state {protocolTerminalSeen = Just EngineSucceeded}
            (ChildExited exitKind)
            `shouldBe` FinishCommittedTerminal
      )
      [ChildExitSuccess, ChildExitAbnormal]

  it "drops buffered completions when cancellation crosses checkpoint acknowledgement" $
    transition
      state
        { protocolCancellationSent = True
        , protocolBufferedCompletionCount = 2
        }
      (CheckpointAcknowledged EngineActive)
      `shouldBe` DropBufferedCompletions

  it "suppresses successors after cancellation or interruption" $ do
    transition
      state
        { protocolCommittedTerminal = Just EngineActive
        , protocolCancellationSent = True
        }
      SuccessorRequested
      `shouldBe` SuppressSuccessor
    transition
      state
        { protocolCommittedTerminal = Just EngineActive
        , protocolInterruptedCount = 1
        }
      SuccessorRequested
      `shouldBe` SuppressSuccessor
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
