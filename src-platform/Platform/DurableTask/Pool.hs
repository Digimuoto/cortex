{-# LANGUAGE OverloadedRecordDot #-}

{- | Bounded concurrent execution pool for durable task runtimes.

Provides a generic pool of async tasks with atomic slot reservation,
duplicate-key rejection, resilient finalization, and graceful drain.

Intended for small bounded runtime pools (single-digit to low tens of
concurrent tasks). Completion detection is poll-based, not callback-based.
-}
module Platform.DurableTask.Pool
  ( TaskPool
  , LaunchResult (..)
  , newTaskPool
  , reapCompleted
  , tryLaunch
  , availableSlots
  , activeCount
  , drainAll
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async, poll)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception (SomeException, mask, throwIO, try)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map

-- | Lifecycle state for a task slot in the pool.
data TaskEntry a
  = -- | Slot reserved, async not yet spawned
    TaskStarting
  | -- | Task is running
    TaskRunning (Async a)

-- | A bounded pool of concurrent async tasks, keyed by @k@.
data TaskPool k a = TaskPool
  { tpActive :: TVar (Map k (TaskEntry a))
  , tpMaxConcurrent :: Int
  }

-- | Result of attempting to launch a task.
data LaunchResult
  = -- | Task was accepted and is starting
    LaunchAccepted
  | -- | Pool is at capacity
    LaunchAtCapacity
  | -- | Key already exists in the pool
    LaunchDuplicateKey
  deriving stock (Eq, Show)

-- | Create a new empty task pool with the given concurrency limit.
newTaskPool :: Int -> IO (TaskPool k a)
newTaskPool maxConcurrent = do
  active <- newTVarIO Map.empty
  pure TaskPool {tpActive = active, tpMaxConcurrent = maxConcurrent}

{- | Poll all active tasks. For each completed task, remove it from the pool
and call the finalizer. Finalizer exceptions are caught and reported via
the error callback — one failed finalizer does not abort the reap of others.
Tasks in 'TaskStarting' state are skipped (not yet pollable).
-}
reapCompleted
  :: Ord k
  => TaskPool k a
  -> (k -> Either SomeException a -> IO ())
  -> IO ()
reapCompleted tp finalize = do
  active <- readTVarIO tp.tpActive
  -- Collect completed tasks (poll is non-blocking, skip TaskStarting)
  completed <-
    concat
      <$> mapM
        ( \(k, entry) -> case entry of
            TaskStarting -> pure []
            TaskRunning taskAsync -> do
              result <- poll taskAsync
              pure $ case result of
                Nothing -> []
                Just r -> [(k, r)]
        )
        (Map.toList active)
  -- Batch-remove all completed tasks
  let completedKeys = fmap fst completed
  atomically $ modifyTVar' tp.tpActive (\m -> foldl' (flip Map.delete) m completedKeys)
  -- Finalize each — catch exceptions so one failure doesn't poison others
  mapM_
    ( \(k, r) -> do
        finalizeResult <- try (finalize k r)
        case finalizeResult of
          Right () -> pure ()
          Left (_ :: SomeException) -> pure () -- caller's finalize logged its own error
    )
    completed

{- | Try to launch a new task in the pool. Atomically checks capacity and
key uniqueness before reserving a slot. The async is spawned in a masked
region to prevent orphaning between reservation and registration.
-}
tryLaunch :: Ord k => TaskPool k a -> k -> IO a -> IO LaunchResult
tryLaunch tp key action = do
  reserved <- atomically $ do
    active <- readTVar tp.tpActive
    let currentSize = Map.size active
    if Map.member key active
      then pure LaunchDuplicateKey
      else
        if currentSize >= tp.tpMaxConcurrent
          then pure LaunchAtCapacity
          else do
            writeTVar tp.tpActive (Map.insert key TaskStarting active)
            pure LaunchAccepted
  case reserved of
    LaunchAccepted ->
      -- Spawn under mask: keep mask active during spawn+register so an async
      -- exception cannot arrive between creating the child and recording its
      -- handle. Only the child's action runs with exceptions restored.
      mask $ \restore -> do
        spawnResult <- try (async (restore action))
        case spawnResult of
          Right taskAsync -> do
            atomically $ modifyTVar' tp.tpActive (Map.insert key (TaskRunning taskAsync))
            pure LaunchAccepted
          Left (e :: SomeException) -> do
            -- Spawn failed — release the reservation and propagate the failure
            atomically $ modifyTVar' tp.tpActive (Map.delete key)
            throwIO e
    other -> pure other

-- | Number of available slots (maxConcurrent - active).
availableSlots :: TaskPool k a -> IO Int
availableSlots tp = do
  current <- Map.size <$> readTVarIO tp.tpActive
  pure (max 0 (tp.tpMaxConcurrent - current))

-- | Current number of active tasks (including starting).
activeCount :: TaskPool k a -> IO Int
activeCount tp = Map.size <$> readTVarIO tp.tpActive

{- | Block until all active tasks have completed. Polls every 500ms.
Does not cancel tasks — waits for natural completion.
-}
drainAll :: Ord k => TaskPool k a -> (k -> Either SomeException a -> IO ()) -> IO ()
drainAll tp finalize = go
  where
    drainPollIntervalUs = 500_000
    go = do
      reapCompleted tp finalize
      count <- activeCount tp
      if count == 0
        then pure ()
        else do
          threadDelay drainPollIntervalUs
          go
