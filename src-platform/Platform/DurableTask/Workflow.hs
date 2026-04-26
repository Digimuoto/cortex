-- |
-- Module      : Platform.DurableTask.Workflow
-- Description : Reusable worker loop skeleton
-- Copyright   : (c) Julius Koskela, 2026
-- License     : MIT
--
-- Generic workflow step abstraction for worker loops. Captures the common
-- "plan → execute → persist" shape without hiding domain-specific ADTs.
--
-- Workers define concrete types for @item@, @plan@, and @result@, then
-- use 'runWorkflowStep' to execute the standard sequence. Error handling
-- and scheduling decisions live in the @wsPersist@ callback.
--
-- Example (from a scheduled job executor):
--
-- @
-- jobStep :: WorkflowStep ClaimedJob JobType JobResult
-- jobStep = WorkflowStep
--   { wsPlan    = \\job -> pure (jobType job)
--   , wsExecute = \\job _plan -> runJobWithTimeout job
--   , wsPersist = \\job result -> persistJobResult job result >> advanceSchedule job result
--   }
-- @
module Platform.DurableTask.Workflow
  ( -- * Workflow Step
    WorkflowStep (..),
    runWorkflowStep,

    -- * Workflow Step with error handling
    runWorkflowStepCatch,
  )
where

import Control.Exception (SomeException, fromException, throwIO, try)
import GHC.IO.Exception (AsyncException)

-- | A single step in a worker loop: plan, execute, persist.
--
-- Domain ADTs (e.g. @JobResult@, @ReconcileAction@) stay concrete — the
-- workflow skeleton only abstracts the orchestration shape.
data WorkflowStep item plan result = WorkflowStep
  { -- | Classify or plan: inspect the item and decide what to do.
    wsPlan :: item -> IO plan,
    -- | Execute: carry out the planned action.
    wsExecute :: item -> plan -> IO result,
    -- | Persist: write the result (status update, emit events, reschedule).
    wsPersist :: item -> result -> IO ()
  }

-- | Run a workflow step: plan → execute → persist.
runWorkflowStep :: WorkflowStep item plan result -> item -> IO result
runWorkflowStep ws item = do
  plan <- wsPlan ws item
  result <- wsExecute ws item plan
  wsPersist ws item result
  pure result

-- | Run a workflow step with synchronous exception handling.
--
-- If 'wsExecute' throws a synchronous exception, it is caught and returned
-- as @Left@. Async exceptions ('AsyncException') are re-thrown immediately
-- to preserve clean shutdown/cancellation semantics.
--
-- 'wsPlan' exceptions propagate uncaught — planning failures indicate a
-- programming error, not a recoverable runtime condition.
--
-- 'wsPersist' is called in both success and failure paths.
runWorkflowStepCatch ::
  WorkflowStep item plan (Either SomeException result) ->
  item ->
  IO (Either SomeException result)
runWorkflowStepCatch ws item = do
  plan <- wsPlan ws item
  result <- trySyncOnly (wsExecute ws item plan)
  let flatResult = case result of
        Left exc -> Left exc
        Right inner -> inner
  wsPersist ws item flatResult
  pure flatResult

-- | Like 'try' but re-throws async exceptions.
trySyncOnly :: IO a -> IO (Either SomeException a)
trySyncOnly action = do
  result <- try action
  case result of
    Left exc
      | isAsyncException exc -> throwIO exc
      | otherwise -> pure (Left exc)
    Right val -> pure (Right val)

isAsyncException :: SomeException -> Bool
isAsyncException e = case fromException e :: Maybe AsyncException of
  Just _ -> True
  Nothing -> False
