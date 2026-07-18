{- |
Module      : Cortex.Pulse.Executor.Resume
Description : Pulse runtime support for resume.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Executor.Resume
  ( materializedTopologyForAdmin
  , resumeFromPersistedState
  )
where

import Control.Concurrent.STM (TVar, newTVarIO)
import Control.Monad (foldM, forM_, when)
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.Int (Int32, Int64)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.UUID (UUID)
import Rel8 (Result)

import Cortex.Algebra.Graph (Relation (..))
import Cortex.Pulse.Database qualified as PulseDB
import Cortex.Pulse.Executor.Events (ExecutorEvent (..))
import Cortex.Pulse.Executor.Frontier (resolveDeliveredSignals)
import Cortex.Pulse.Executor.Outcome
  ( handleSettled
  , handleStuck
  )
import Cortex.Pulse.Executor.Persistence
  ( SuspendSettlementResult (..)
  , failRun
  , recordRunEvent
  , requireGraphStatePersist
  , settleSuspend
  )
import Cortex.Pulse.Executor.ReplayPolicy (enforceGraphReplayPolicy)
import Cortex.Pulse.Executor.Types (RunTVars (..), mkStageEnv)
import Cortex.Pulse.GraphRuntime
  ( GraphState (..)
  , StepResult (..)
  , classifyGraphState
  , recoverPersistedGraphState
  , renderRecoveryPreconditionErrors
  , stepResultState
  )
import Cortex.Pulse.Iteration (LoopControl)
import Cortex.Pulse.Materialization
  ( MaterializationHashMode (..)
  , NodeProvenance
  , PersistedGraphState (..)
  , PersistedRewrite (..)
  , applyPlannedRewrite
  , authorizeExternalReplayWithControl
  , authorizeWitnessedReplayWithControl
  , computeTopologyHash
  , decodeOptionalJsonValue
  , hydratePersistedRewriteRow
  , hydratePersistedRewriteRowForAdmin
  , initialProvenance
  , materializePlannedRewrite
  , reconcileGraphState
  , resolveRewriteDeltaAndCost
  )
import Cortex.Pulse.Node (NodeId, unNodeId)
import Cortex.Pulse.Plan
import Cortex.Pulse.PlanHydration
  ( RewriteError (..)
  , renderRewriteError
  , rewriteErrorType
  )
import Cortex.Pulse.Query qualified as Q
import Cortex.Pulse.Rewrite
  ( AdmissionMode (..)
  , admitRewriteDelta
  , admittedDelta
  , admittedRemainingBudget
  )
import Cortex.Pulse.Schema (PulseTaskDefinitionRow (..))
import Cortex.Pulse.Types (PulseConfig)

import Platform.Database qualified as DB
import Platform.DurableTask.Types (RunOutcome (..))
import Platform.Observability (emitObsEvent)

materializedTopologyForAdmin
  :: Maybe SomeStagePlan
  -> DB.Pool
  -> UUID
  -> Maybe Int32
  -> Maybe Int64
  -> IO (Either Text (Maybe (Relation NodeId)))
materializedTopologyForAdmin maybeStagePlan pool runId mRuntimeVersion mAppliedRewriteId =
  case maybeStagePlan of
    Nothing -> pure (Right Nothing)
    Just (SomeStagePlan initialStagePlan _) ->
      let expectedRuntimeVersion = initialStagePlan.spCheckpointRuntimeVersion
          versionOk = case mRuntimeVersion of
            Just rv -> fromIntegral rv == expectedRuntimeVersion
            Nothing -> True
          watermark = fromMaybe 0 mAppliedRewriteId
       in if not versionOk
            then
              let actualRv = maybe 0 fromIntegral mRuntimeVersion :: Int
               in pure . Left $
                    "Graph state runtime_version mismatch. Expected "
                      <> T.pack (show expectedRuntimeVersion)
                      <> ", got "
                      <> T.pack (show actualRv)
            else
              if watermark <= 0
                then pure (Right (Just (spTopology initialStagePlan)))
                else do
                  rewritesResult <- PulseDB.withConnection pool $ Q.readGraphRewritesUpTo runId watermark
                  pure $ do
                    rewriteRows <- first T.pack rewritesResult
                    let applyOne plan rewriteRow = first renderRewriteError $ do
                          persistedRewrite <- hydratePersistedRewriteRowForAdmin rewriteRow
                          (delta, _rewriteCost) <- resolveRewriteDeltaAndCost persistedRewrite plan
                          pure (applyPlannedRewrite delta plan)
                    (Just . spTopology) <$> foldM applyOne initialStagePlan rewriteRows

resumeFromPersistedState
  :: StableStageId stageId
  => DB.Pool
  -> PulseConfig
  -> TVar Bool
  -> UUID
  -> PulseTaskDefinitionRow Result
  -> StagePlan stageId
  -> Q.PulseGraphStateSnapshot
  -> ( StagePlan stageId
       -> PersistedGraphState
       -> Map.Map LoopInstanceKey LoopControl
       -> [NodeId]
       -> IO RunOutcome
     )
  -> IO RunOutcome
resumeFromPersistedState pool pulseConfig shutdownFlag runId task initialStagePlan persistedSnapshot continueWithResumedState = do
  let expectedRuntimeVersion = initialStagePlan.spCheckpointRuntimeVersion

  rewritesResult <- PulseDB.withConnection pool $ Q.readGraphRewrites runId
  case ( rewritesResult
       , Aeson.fromJSON persistedSnapshot.pgssNodeStatuses
       , Aeson.fromJSON persistedSnapshot.pgssNodeOutputs
       ) of
    (Right rewriteRows, Aeson.Success statuses, Aeson.Success outputs) -> do
      let watermark = fromMaybe 0 persistedSnapshot.pgssAppliedRewriteId
          (materializedRows, pendingRows) = span (\(rewriteId, _, _, _, _, _, _) -> rewriteId <= watermark) rewriteRows
          applyOne (plan, remainingBudget, loopControls) rewriteRow = do
            persistedRewrite <- hydratePersistedRewriteRow plan rewriteRow
            (delta, _rewriteCost) <- resolveRewriteDeltaAndCost persistedRewrite plan
            case persistedRewrite.prAdmissionMode of
              -- Witnessed self-append steps replay gas-neutral, but are re-run
              -- through the same authorization gate as the live/pending paths so a
              -- mislabeled or invalid pre-watermark row cannot reconstruct
              -- unauthorized topology on resume.
              AdmissionWitnessed -> do
                loopControls' <- authorizeWitnessedReplayWithControl plan persistedRewrite delta loopControls
                pure (applyPlannedRewrite delta plan, remainingBudget, loopControls')
              -- Externally-driven steps (ADR 0088) replay gas-neutral through
              -- their own control-aware gate; the admitted-step count is
              -- reconstructed from the journal exactly like the loop index.
              AdmissionExternal -> do
                loopControls' <- authorizeExternalReplayWithControl plan persistedRewrite delta loopControls
                pure (applyPlannedRewrite delta plan, remainingBudget, loopControls')
              AdmissionGassed -> do
                admitted <-
                  first RewriteBudgetExhausted $
                    admitRewriteDelta remainingBudget delta
                pure
                  (applyPlannedRewrite (admittedDelta admitted) plan, admittedRemainingBudget admitted, loopControls)
      case foldM
        applyOne
        (initialStagePlan, initialStagePlan.spInitialRewriteBudget, initialLoopControls initialStagePlan)
        materializedRows of
        Left rewriteErr -> failResume (rewriteErrorType rewriteErr) (renderRewriteError rewriteErr)
        Right (materializedStagePlan, reconstructedRemainingBudget, materializedLoopControls) -> do
          let versionOk = case persistedSnapshot.pgssRuntimeVersion of
                Just rv -> fromIntegral rv == expectedRuntimeVersion
                Nothing -> True
          if not versionOk
            then do
              let actualRv = maybe 0 fromIntegral persistedSnapshot.pgssRuntimeVersion :: Int
                  errMsg =
                    "Graph state runtime_version mismatch. Expected "
                      <> T.pack (show expectedRuntimeVersion)
                      <> ", got "
                      <> T.pack (show actualRv)
              emitObsEvent $ EvtResumeGraphVersionMismatch runId errMsg
              failResume "graph_state_runtime_version_mismatch" errMsg
            else do
              when (isNothing persistedSnapshot.pgssRuntimeVersion) $
                emitObsEvent (EvtResumeGraphNoVersion runId)
              let decodedRemainingBudget =
                    decodeOptionalJsonValue
                      "persisted remaining rewrite budget"
                      persistedSnapshot.pgssRemainingRewriteBudget
              case decodedRemainingBudget of
                Left errMsg -> failResume "graph_state_parse_failed" errMsg
                Right mRemainingRewriteBudget -> do
                  let gs0 = GraphState {gsNodeStatuses = statuses, gsNodeOutputs = outputs}
                      decodedProvenance :: Either Text (Maybe NodeProvenance)
                      decodedProvenance = decodeOptionalJsonValue "persisted node provenance" persistedSnapshot.pgssNodeProvenance
                  restoredProvenance <-
                    case decodedProvenance of
                      Right (Just prov) -> pure prov
                      Right Nothing -> pure (initialProvenance (spTopology materializedStagePlan))
                      Left errMsg -> do
                        emitObsEvent $ EvtResumeGraphParseFailed runId ("node provenance decode failed: " <> errMsg)
                        pure (initialProvenance (spTopology materializedStagePlan))
                  let persistedState0 =
                        PersistedGraphState
                          { pgsGraphState = gs0
                          , pgsRemainingRewriteBudget = fromMaybe reconstructedRemainingBudget mRemainingRewriteBudget
                          , pgsAppliedRewriteId = persistedSnapshot.pgssAppliedRewriteId
                          , pgsNodeProvenance = restoredProvenance
                          , pgsTopologyHash = persistedSnapshot.pgssTopologyHash
                          , pgsHostedCheckpointSequence = persistedSnapshot.pgssHostedCheckpointSequence
                          , pgsHostedTerminalState = persistedSnapshot.pgssHostedTerminalState
                          , pgsRevision = Just persistedSnapshot.pgssRevision
                          }
                      topology0 = spTopology materializedStagePlan
                  case reconcileGraphState topology0 gs0 of
                    Left rewriteErr -> failResume (rewriteErrorType rewriteErr) (renderRewriteError rewriteErr)
                    Right gsReconciled -> do
                      let reconciledState = persistedState0 {pgsGraphState = gsReconciled}
                          materializePending (plan, persistedState, loopControls) rewriteRow = do
                            persistedRewrite <- hydratePersistedRewriteRow plan rewriteRow
                            (delta, _rewriteCost) <- resolveRewriteDeltaAndCost persistedRewrite plan
                            loopControls' <- case persistedRewrite.prAdmissionMode of
                              AdmissionWitnessed ->
                                authorizeWitnessedReplayWithControl plan persistedRewrite delta loopControls
                              AdmissionExternal ->
                                authorizeExternalReplayWithControl plan persistedRewrite delta loopControls
                              AdmissionGassed ->
                                Right loopControls
                            (plan', persistedState') <-
                              materializePlannedRewrite
                                DeferTopologyHash
                                False
                                persistedRewrite
                                delta
                                plan
                                persistedState
                            pure (plan', persistedState', loopControls')
                      case foldM
                        materializePending
                        (materializedStagePlan, reconciledState, materializedLoopControls)
                        pendingRows of
                        Left rewriteErr -> failResume (rewriteErrorType rewriteErr) (renderRewriteError rewriteErr)
                        Right (stagePlan, materializedState, loopControls) -> do
                          -- The env built here is only used for
                          -- 'requireGraphStatePersist' below; the
                          -- memory factory is driven from transient
                          -- TVars that never see a stage execution.
                          -- The real memory handle is constructed by
                          -- the 'continueWithResumedState' callback
                          -- against its own TVars.
                          let expectedHash = computeTopologyHash (spTopology stagePlan)
                              materializedStateWithHash =
                                materializedState {pgsTopologyHash = Just expectedHash}
                          transientGs <- newTVarIO materializedStateWithHash
                          transientCompletedAt <- newTVarIO Map.empty
                          transientTopology <- newTVarIO (spTopology stagePlan)
                          transientLoopControls <- newTVarIO loopControls
                          let transientTVars =
                                RunTVars
                                  { rvGsVar = transientGs
                                  , rvNodeCompletedAtVar = transientCompletedAt
                                  , rvTopologyVar = transientTopology
                                  , rvLoopControlsVar = transientLoopControls
                                  }
                              env = mkStageEnv pool pulseConfig shutdownFlag runId task stagePlan transientTVars
                          -- Compare against the DB-persisted hash, not the replayed
                          -- materializedState hash (which was recomputed during replay
                          -- and would always match).
                          case persistedSnapshot.pgssTopologyHash of
                            Just dbHash
                              | dbHash /= expectedHash ->
                                  emitObsEvent $ EvtResumeIntegrityMismatch runId expectedHash dbHash
                            _ -> pure ()
                          gs1 <- resolveDeliveredSignals pool runId materializedStateWithHash.pgsGraphState
                          case recoverPersistedGraphState (spTopology stagePlan) gs1 of
                            Left validationErrors ->
                              failResume
                                "graph_state_recovery_preconditions_failed"
                                (renderRecoveryPreconditionErrors validationErrors)
                            Right recoveryStep -> do
                              let persistedState =
                                    materializedStateWithHash
                                      { pgsGraphState = stepResultState recoveryStep
                                      }
                              if persistedState /= persistedState0
                                then do
                                  persistFailed <- requireGraphStatePersist env persistedState
                                  case persistFailed of
                                    Left outcome -> pure outcome
                                    Right persistedState' -> continueAfterRecovery env stagePlan loopControls persistedState' recoveryStep
                                else
                                  continueAfterRecovery env stagePlan loopControls persistedState recoveryStep
    _ ->
      failResume
        "graph_state_parse_failed"
        "Failed to parse persisted graph state or rewrite lineage; cannot safely resume"
  where
    failResume errType errMsg = do
      emitObsEvent $ EvtResumeGraphParseFailed runId errMsg
      now <- getCurrentTime
      failRun pool runId now errType errMsg True
      pure OutcomeFailed

    continueAfterReplay stagePlan loopControls persistedState frontier = do
      blocked <- enforceGraphReplayPolicy pool runId stagePlan frontier
      case blocked of
        Just outcome -> pure outcome
        Nothing -> continueWithResumedState stagePlan persistedState loopControls frontier

    continueAfterRecovery env stagePlan loopControls persistedState recoveryStep = do
      emitObsEvent $ EvtResumeGraph runId
      case recoveryStep of
        Progressing _ frontier -> continueAfterReplay stagePlan loopControls persistedState frontier
        Settled gs outcome -> handleSettled env gs outcome
        Suspended _gs -> do
          settlement <- settleSuspend env persistedState
          case settlement of
            Left outcome -> pure outcome
            Right (SuspendSettlementParked _persistedState') -> do
              emitObsEvent $ EvtRunSuspended runId
              recordRunEvent
                env
                "run.suspended"
                Q.RunEventInfo
                "Run suspended, waiting on external signal"
                Nothing
              pure OutcomeSuspended
            Right (SuspendSettlementResolved persistedState' resolvedSignals) -> do
              forM_ resolvedSignals $ \(nodeId, signalName) ->
                emitObsEvent $ EvtSignalResolved runId signalName (unNodeId nodeId)
              continueAfterRecovery
                env
                stagePlan
                loopControls
                persistedState'
                (classifyGraphState (spTopology stagePlan) persistedState'.pgsGraphState)
        Stuck gs diag -> handleStuck env runId gs diag
