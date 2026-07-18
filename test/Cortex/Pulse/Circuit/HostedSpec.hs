{- |
Module      : Cortex.Pulse.Circuit.HostedSpec
Description : Unit tests for hosted durable-terminal and interruption mapping.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Pins the durable-state semantics of the Pulse hosted backend: a graceful
shutdown persists an @active@ terminal (durably identical to a crash), only an
operator cancellation persists @cancelled@, and run-stopping worker outcomes
are interruptions rather than engine-visible failures.
-}
module Cortex.Pulse.Circuit.HostedSpec (spec) where

import Data.Map.Strict qualified as Map
import Test.Hspec

import Cortex.Pulse.Circuit.Hosted
  ( HostedCancellation (..)
  , TerminalSettlement (..)
  , effectResolution
  , persistedEngineTerminal
  , pulseStateFromEngine
  , terminalSettlement
  )
import Cortex.Pulse.GraphRuntime (FailureDetail (..), GraphState (..), NodeOutcome (..))
import Cortex.Pulse.Materialization (PersistedGraphState (..))
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Types (defaultRewriteBudget)
import Cortex.Wire.Circuit.Engine
  ( EffectCompletion (..)
  , EngineNodeStatus (..)
  , EngineState (..)
  , EngineTerminalState (..)
  , engineStateSchema
  , parseEngineTerminalState
  , renderEngineTerminalState
  )
import Cortex.Wire.Circuit.Hosted (EffectResolution (..))

import Platform.DurableTask.Types (RunOutcome (..))

baseState :: PersistedGraphState
baseState =
  PersistedGraphState
    { pgsGraphState = GraphState Map.empty Map.empty
    , pgsRemainingRewriteBudget = defaultRewriteBudget
    , pgsAppliedRewriteId = Nothing
    , pgsNodeProvenance = Map.empty
    , pgsTopologyHash = Nothing
    , pgsHostedCheckpointSequence = Nothing
    , pgsHostedTerminalState = Nothing
    , pgsRevision = Nothing
    }

snapshot :: EngineTerminalState -> EngineState
snapshot terminal =
  EngineState
    { esSchema = engineStateSchema
    , esProgramIdentity = "hosted-unit-program"
    , esCheckpointSequence = 2
    , esTerminal = terminal
    , esNodeStatuses = [EnginePending, EnginePending]
    , esOutputHandles = [0, 0]
    }

spec :: Spec
spec = describe "Cortex.Pulse.Circuit.Hosted" $ do
  describe "pulseStateFromEngine terminal persistence" $ do
    let dense = Map.fromList [(0, NodeId "first"), (1, NodeId "second")]
        persistedTerminalFor cancellation terminal =
          fmap
            (.pgsHostedTerminalState)
            (pulseStateFromEngine baseState Map.empty dense cancellation (snapshot terminal))

    it "persists a shutdown-initiated cancel as active (durably identical to a crash)" $
      persistedTerminalFor (Just HostedShutdownCancellation) EngineCancelled
        `shouldBe` Right (Just "active")

    it "persists an operator cancel as cancelled" $
      persistedTerminalFor (Just HostedOperatorCancellation) EngineCancelled
        `shouldBe` Right (Just "cancelled")

    it "persists a successful terminal as completed" $
      persistedTerminalFor Nothing EngineSucceeded
        `shouldBe` Right (Just "completed")

    it "persists a failed terminal as failed even during shutdown" $
      -- A genuine terminal failure is durable regardless of a concurrent
      -- shutdown; only the cancelled terminal is shutdown-sensitive.
      persistedTerminalFor (Just HostedShutdownCancellation) EngineTerminalFailed
        `shouldBe` Right (Just "failed")

  describe "terminal settlement precedence" $ do
    it "keeps a committed completion authoritative over a racing operator cancel" $ do
      let committed = baseState {pgsHostedTerminalState = Just "completed"}
      persistedEngineTerminal committed `shouldBe` Right (Just EngineSucceeded)
      terminalSettlement EngineSucceeded (Just HostedOperatorCancellation) Nothing
        `shouldBe` SettleRunOutcome OutcomeCompleted

    it "does not let concurrent shutdown replace a genuine engine failure" $
      terminalSettlement
        EngineTerminalFailed
        (Just HostedShutdownCancellation)
        (Just OutcomeTimedOut)
        `shouldBe` SettleRunOutcome OutcomeTimedOut

    it "uses shutdown only to refine an engine-cancelled terminal" $ do
      terminalSettlement EngineCancelled (Just HostedShutdownCancellation) Nothing
        `shouldBe` SettleRunOutcome OutcomeShutdown
      terminalSettlement EngineCancelled (Just HostedOperatorCancellation) Nothing
        `shouldBe` CommitOperatorCancellation

  describe "terminal rendering round-trip"
    . it "parses every rendered terminal back to itself"
    $ mapM_
      ( \terminal ->
          parseEngineTerminalState (renderEngineTerminalState terminal) `shouldBe` Right terminal
      )
      [EngineActive, EngineSucceeded, EngineTerminalFailed, EngineCancelled]

  describe "effectResolution" $ do
    it "maps run-stopping outcomes to interruptions the engine never sees" $ do
      effectResolution 0 OutcomeNodeShutdown
        `shouldBe` EffectInterrupted "Pulse is shutting down"
      effectResolution 0 OutcomeNodeRunCancelled
        `shouldBe` EffectInterrupted "run cancelled"

    it "maps genuine failures to failed completions" $
      effectResolution 0 (OutcomeNodeFailed (FailureDetail "boom" "node exploded" False))
        `shouldBe` EffectResolved (EffectFailed "node exploded")
