{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Pulse.Executor.Outcome
  ( handleGraphOutcome,
    handleSettled,
    handleSuspended,
    handleStuck,
  )
where

import Cortex.Pulse.Executor.Events (ExecutorEvent (..))
import Cortex.Pulse.Executor.Persistence
  ( failRun,
    recordRunEvent,
    requireTx,
  )
import Cortex.Pulse.Executor.Types (StageEnv (..))
import Cortex.Pulse.GraphRuntime
  ( GraphState,
    StuckDiagnostic (..),
  )
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Query qualified as Q
import Data.Aeson qualified as Aeson
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.UUID (UUID)
import Platform.Database qualified as DB
import Platform.DurableTask.Types (RunOutcome (..))
import Platform.Observability (emitObsEvent)

handleGraphOutcome :: StageEnv -> GraphState Aeson.Value -> RunOutcome -> IO RunOutcome
handleGraphOutcome env gs = \case
  OutcomeSuspended -> handleSuspended env gs
  OutcomeFailed -> handleSettled env gs OutcomeFailed
  OutcomeCompleted -> handleSettled env gs OutcomeCompleted
  OutcomeTimedOut -> handleSettled env gs OutcomeTimedOut
  OutcomeShutdown -> handleSettled env gs OutcomeShutdown
  OutcomeCancelled -> handleSettled env gs OutcomeCancelled

handleSettled :: StageEnv -> GraphState Aeson.Value -> RunOutcome -> IO RunOutcome
handleSettled env _gs = \case
  OutcomeFailed -> do
    now <- getCurrentTime
    recordRunEvent env "run.failed.settled" Q.RunEventError "Graph settled with failures" Nothing
    failRun env.sePool env.seRunId now "graph_settled_with_failures" "Graph settled with failures" False
    pure OutcomeFailed
  OutcomeCompleted -> do
    now <- getCurrentTime
    completionResult <-
      requireTx env.sePool env.seRunId "update_run_completed"
        . DB.runTransaction env.sePool
        $ Q.updateRunCompleted env.seRunId now
    case completionResult of
      Nothing -> pure OutcomeFailed
      Just () -> do
        emitObsEvent $ EvtTaskCompleted env.seRunId
        recordRunEvent env "run.completed" Q.RunEventInfo "All stages completed successfully" Nothing
        pure OutcomeCompleted
  OutcomeTimedOut -> pure OutcomeTimedOut
  OutcomeShutdown -> pure OutcomeShutdown
  OutcomeCancelled -> pure OutcomeCancelled
  OutcomeSuspended -> pure OutcomeSuspended

handleSuspended :: StageEnv -> GraphState Aeson.Value -> IO RunOutcome
handleSuspended env _gs = do
  waitResult <-
    requireTx env.sePool env.seRunId "update_run_waiting"
      . DB.runTransaction env.sePool
      $ Q.updateRunWaiting env.seRunId
  case waitResult of
    Nothing -> pure OutcomeFailed
    Just () -> do
      emitObsEvent $ EvtRunSuspended env.seRunId
      recordRunEvent env "run.suspended" Q.RunEventInfo "Run suspended, waiting on external signal" Nothing
      pure OutcomeSuspended

handleStuck :: StageEnv -> UUID -> GraphState Aeson.Value -> StuckDiagnostic -> IO RunOutcome
handleStuck env runId _gs diag = do
  let diagnostic =
        Aeson.object
          [ "pending_nodes" Aeson..= fmap unNodeId (sdPendingNodes diag),
            "failed_nodes" Aeson..= fmap unNodeId (sdFailedNodes diag),
            "stuck_on_failed" Aeson..= [Aeson.object ["node" Aeson..= unNodeId n, "blocked_by" Aeson..= fmap unNodeId bs] | (n, bs) <- sdStuckOnFailed diag]
          ]
      errMsg =
        "No ready nodes and graph not settled. "
          <> T.pack (show (length (sdPendingNodes diag)))
          <> " pending, "
          <> T.pack (show (length (sdFailedNodes diag)))
          <> " failed"
  now <- getCurrentTime
  recordRunEvent env "run.stuck" Q.RunEventError errMsg (Just diagnostic)
  failRun env.sePool runId now "graph_stuck" errMsg False
  pure OutcomeFailed
