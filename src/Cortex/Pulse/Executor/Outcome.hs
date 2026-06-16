{- |
Module      : Cortex.Pulse.Executor.Outcome
Description : Pulse runtime support for outcome.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Executor.Outcome
  ( handleGraphOutcome
  , handleSettled
  , handleStuck
  )
where

import Data.Aeson qualified as Aeson
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.UUID (UUID)

import Cortex.Pulse.Database qualified as PulseDB
import Cortex.Pulse.Executor.Events (ExecutorEvent (..))
import Cortex.Pulse.Executor.Persistence
  ( failRun
  , recordRunEvent
  , requireTx
  )
import Cortex.Pulse.Executor.Types (StageEnv (..))
import Cortex.Pulse.GraphRuntime
  ( GraphState
  , StuckDiagnostic (..)
  )
import Cortex.Pulse.Node (unNodeId)
import Cortex.Pulse.Query qualified as Q

import Platform.DurableTask.Types (RunOutcome (..))
import Platform.Observability (emitObsEvent)

handleGraphOutcome :: StageEnv -> GraphState Aeson.Value -> RunOutcome -> IO RunOutcome
handleGraphOutcome env gs = \case
  OutcomeSuspended -> pure OutcomeSuspended
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
        . PulseDB.runTransaction env.sePool
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

handleStuck :: StageEnv -> UUID -> GraphState Aeson.Value -> StuckDiagnostic -> IO RunOutcome
handleStuck env runId _gs diag = do
  let diagnostic =
        Aeson.object
          [ "pending_nodes" Aeson..= fmap unNodeId (sdPendingNodes diag)
          , "failed_nodes" Aeson..= fmap unNodeId (sdFailedNodes diag)
          , "stuck_on_failed"
              Aeson..= [ Aeson.object ["node" Aeson..= unNodeId n, "blocked_by" Aeson..= fmap unNodeId bs]
                       | (n, bs) <- sdStuckOnFailed diag
                       ]
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
