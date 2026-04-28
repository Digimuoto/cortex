{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Pulse.Executor.ReplayPolicy
  ( enforceGraphReplayPolicy
  )
where

import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.UUID (UUID)

import Cortex.Pulse.Executor.Events (ExecutorEvent (..))
import Cortex.Pulse.Executor.Persistence (failRun)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( ReplayPolicy (..)
  , StageDefinition (..)
  , StagePlan (..)
  , StageReplaySafety (..)
  )
import Cortex.Pulse.Query (PulseStageLogDetail (..))
import Cortex.Pulse.Query qualified as Q

import Platform.Database qualified as DB
import Platform.DurableTask.Types (RunOutcome (..))
import Platform.Observability (emitObsEvent)

enforceGraphReplayPolicy
  :: DB.Pool
  -> UUID
  -> StagePlan stageId
  -> [NodeId]
  -> IO (Maybe RunOutcome)
enforceGraphReplayPolicy pool runId stagePlan = go
  where
    defs = spDefinitions stagePlan
    defaultPolicy = spReplayPolicy stagePlan

    go [] = pure Nothing
    go (nid : rest) =
      case Map.lookup nid defs of
        Nothing -> go rest
        Just stageDef
          | stageDef.sdReplaySafety == SafeToReplay -> go rest
          | otherwise -> do
              let policy = fromMaybe defaultPolicy stageDef.sdReplayPolicyOverride
                  stageName = unNodeId nid
              stageLogResult <- DB.withConnection pool $ Q.listStageLogDetails runId
              case stageLogResult of
                Left err ->
                  case policy of
                    ReplayPolicyWarn -> do
                      emitObsEvent $ EvtReplayCheckFailed runId stageName (T.pack err)
                      go rest
                    _ -> do
                      emitObsEvent $ EvtReplayCheckDbFailed runId stageName (replayPolicyToText policy) (T.pack err)
                      now <- getCurrentTime
                      failRun
                        pool
                        runId
                        now
                        "replay_check_failed"
                        ("Cannot verify replay safety for irreversible stage: " <> stageName)
                        True
                      pure (Just OutcomeFailed)
                Right stageLogs ->
                  let priorLogs = filter (\logEntry -> logEntry.psldStageName == stageName) stageLogs
                   in if null priorLogs
                        then go rest
                        else applyReplayPolicy pool runId policy stageName priorLogs

applyReplayPolicy
  :: DB.Pool
  -> UUID
  -> ReplayPolicy
  -> Text
  -> [PulseStageLogDetail]
  -> IO (Maybe RunOutcome)
applyReplayPolicy pool runId policy stageName priorLogs = do
  let priorStatuses = fmap (.psldStatus) priorLogs
      priorAttempts = length priorLogs
      policyText = replayPolicyToText policy
  case policy of
    ReplayPolicyWarn -> do
      emitObsEvent $ EvtReplayIrreversibleWarn runId stageName priorStatuses priorAttempts policyText
      pure Nothing
    ReplayPolicyBlockResume -> do
      emitObsEvent $ EvtReplayBlocked runId stageName priorStatuses priorAttempts policyText
      now <- getCurrentTime
      failRun
        pool
        runId
        now
        "replay_blocked"
        ("Irreversible stage has prior execution history: " <> stageName)
        False
      pure (Just OutcomeFailed)
    ReplayPolicyRequireOperatorOverride -> do
      emitObsEvent $ EvtReplayBlockedNeedsOverride runId stageName priorStatuses priorAttempts policyText
      now <- getCurrentTime
      failRun
        pool
        runId
        now
        "replay_blocked_operator_override_required"
        ("Irreversible stage requires operator override: " <> stageName)
        False
      pure (Just OutcomeFailed)

replayPolicyToText :: ReplayPolicy -> Text
replayPolicyToText = \case
  ReplayPolicyWarn -> "warn"
  ReplayPolicyBlockResume -> "block_resume"
  ReplayPolicyRequireOperatorOverride -> "require_operator_override"
