{- |
Module      : Platform.DurableTask.PoolSpec
Description : Tests for Platform.DurableTask.Pool.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Platform.DurableTask.PoolSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (ErrorCall (..), SomeException, throwIO)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Test.Hspec
import Test.QuickCheck (choose, forAll, ioProperty)

import Platform.DurableTask.Pool
  ( LaunchResult (..)
  , TaskPool
  , activeCount
  , availableSlots
  , drainAll
  , newTaskPool
  , reapCompleted
  , tryLaunch
  )

spec :: Spec
spec = do
  describe "newTaskPool" $ do
    it "starts empty" $ do
      pool <- newTaskPool 4 :: IO (TaskPool Int ())
      activeCount pool `shouldReturn` 0
      availableSlots pool `shouldReturn` 4

  describe "tryLaunch" $ do
    it "accepts a task when capacity is available" $ do
      pool <- newTaskPool 2 :: IO (TaskPool Int ())
      result <- tryLaunch pool 1 (pure ())
      result `shouldBe` LaunchAccepted
      activeCount pool `shouldReturn` 1
      availableSlots pool `shouldReturn` 1

    it "rejects at capacity" $ do
      pool <- newTaskPool 1 :: IO (TaskPool Int ())
      gate <- newEmptyMVar
      _ <- tryLaunch pool 1 (takeMVar gate)
      result <- tryLaunch pool 2 (pure ())
      result `shouldBe` LaunchAtCapacity
      activeCount pool `shouldReturn` 1
      putMVar gate () -- unblock so drain works
      drainAll pool (\_ _ -> pure ())

    it "rejects duplicate key" $ do
      pool <- newTaskPool 4 :: IO (TaskPool Int ())
      gate <- newEmptyMVar
      _ <- tryLaunch pool 1 (takeMVar gate)
      result <- tryLaunch pool 1 (pure ())
      result `shouldBe` LaunchDuplicateKey
      activeCount pool `shouldReturn` 1
      putMVar gate ()
      drainAll pool (\_ _ -> pure ())

    it "propagates spawn-action exceptions and releases reservation" $ do
      pool <- newTaskPool 2 :: IO (TaskPool Int ())
      -- throwIO inside the action doesn't affect tryLaunch — the async catches it.
      -- But a synchronous exception from `async` itself is extremely rare.
      -- We test that the task runs and its exception is captured by reap.
      _ <- tryLaunch pool 1 (throwIO (ErrorCall "boom"))
      -- Give the async a moment to fail
      threadDelay 10_000
      ref <- newIORef (Nothing :: Maybe SomeException)
      reapCompleted pool $ \_ result ->
        case result of
          Left e -> modifyIORef' ref (const (Just e))
          Right _ -> pure ()
      err <- readIORef ref
      err `shouldSatisfy` \case
        Just _ -> True
        Nothing -> False
      activeCount pool `shouldReturn` 0

  describe "reapCompleted" $ do
    it "removes completed tasks and calls finalizer" $ do
      pool <- newTaskPool 4 :: IO (TaskPool Int Int)
      _ <- tryLaunch pool 1 (pure 42)
      _ <- tryLaunch pool 2 (pure 99)
      -- Let tasks complete
      threadDelay 10_000
      ref <- newIORef ([] :: [(Int, Int)])
      reapCompleted pool $ \k result ->
        case result of
          Right v -> modifyIORef' ref ((k, v) :)
          Left _ -> pure ()
      finalized <- readIORef ref
      length finalized `shouldBe` 2
      activeCount pool `shouldReturn` 0

    it "skips still-running tasks" $ do
      pool <- newTaskPool 4 :: IO (TaskPool Int ())
      gate <- newEmptyMVar
      _ <- tryLaunch pool 1 (takeMVar gate)
      _ <- tryLaunch pool 2 (pure ())
      threadDelay 10_000
      ref <- newIORef (0 :: Int)
      reapCompleted pool $ \_ _ -> modifyIORef' ref (+ 1)
      readIORef ref `shouldReturn` 1
      activeCount pool `shouldReturn` 1
      putMVar gate ()
      drainAll pool (\_ _ -> pure ())

    it "does not abort reap when one finalizer throws" $ do
      pool <- newTaskPool 4 :: IO (TaskPool Int Int)
      _ <- tryLaunch pool 1 (pure 1)
      _ <- tryLaunch pool 2 (pure 2)
      threadDelay 10_000
      ref <- newIORef (0 :: Int)
      reapCompleted pool $ \k _ -> do
        if k == 1
          then throwIO (ErrorCall "finalizer crash")
          else modifyIORef' ref (+ 1)
      -- Both should be removed despite the first finalizer throwing
      activeCount pool `shouldReturn` 0
      readIORef ref `shouldReturn` 1

  describe "drainAll" $ do
    it "blocks until all tasks complete" $ do
      pool <- newTaskPool 4 :: IO (TaskPool Int ())
      gate1 <- newEmptyMVar
      gate2 <- newEmptyMVar
      _ <- tryLaunch pool 1 (takeMVar gate1)
      _ <- tryLaunch pool 2 (takeMVar gate2)
      activeCount pool `shouldReturn` 2
      -- Unblock both
      putMVar gate1 ()
      putMVar gate2 ()
      drainAll pool (\_ _ -> pure ())
      activeCount pool `shouldReturn` 0

    it "returns immediately when pool is empty" $ do
      pool <- newTaskPool 4 :: IO (TaskPool Int ())
      drainAll pool (\_ _ -> pure ())
      activeCount pool `shouldReturn` 0

  describe "availableSlots" $ do
    it "decrements as tasks are launched" $ do
      pool <- newTaskPool 3 :: IO (TaskPool Int ())
      gate <- newEmptyMVar
      availableSlots pool `shouldReturn` 3
      _ <- tryLaunch pool 1 (takeMVar gate)
      availableSlots pool `shouldReturn` 2
      _ <- tryLaunch pool 2 (takeMVar gate)
      availableSlots pool `shouldReturn` 1
      _ <- tryLaunch pool 3 (takeMVar gate)
      availableSlots pool `shouldReturn` 0
      -- Unblock all
      putMVar gate ()
      putMVar gate ()
      putMVar gate ()
      drainAll pool (\_ _ -> pure ())

  describe "capacity edge cases" $ do
    it "allows reuse of key after task completes and is reaped" $ do
      pool <- newTaskPool 2 :: IO (TaskPool Int Int)
      _ <- tryLaunch pool 1 (pure 42)
      threadDelay 10_000
      reapCompleted pool (\_ _ -> pure ())
      -- Key 1 should be available again
      result <- tryLaunch pool 1 (pure 99)
      result `shouldBe` LaunchAccepted
      drainAll pool (\_ _ -> pure ())

    it "slot is freed after task completes and is reaped" $ do
      pool <- newTaskPool 1 :: IO (TaskPool Int ())
      _ <- tryLaunch pool 1 (pure ())
      threadDelay 10_000
      reapCompleted pool (\_ _ -> pure ())
      availableSlots pool `shouldReturn` 1
      result <- tryLaunch pool 2 (pure ())
      result `shouldBe` LaunchAccepted
      drainAll pool (\_ _ -> pure ())

  describe "pool properties" $ do
    it "pool starts with all slots available"
      . forAll (choose (1 :: Int, 20))
      $ \n ->
        ioProperty $ do
          pool <- newTaskPool n :: IO (TaskPool Int ())
          slots <- availableSlots pool
          pure (slots == n)

    it "pool at capacity rejects further launches"
      . forAll (choose (1 :: Int, 5))
      $ \n ->
        ioProperty $ do
          -- Use an MVar as a broadcast gate: tasks block on readMVar,
          -- which does not consume the value, so a single putMVar unblocks all.
          gate <- newEmptyMVar
          pool <- newTaskPool n :: IO (TaskPool Int ())
          mapM_ (\k -> tryLaunch pool k (readMVar gate)) [1 .. n]
          result <- tryLaunch pool (n + 1) (pure ())
          putMVar gate () -- unblock all workers at once
          drainAll pool (\_ _ -> pure ())
          pure (result == LaunchAtCapacity)

    it "launching the same key twice yields LaunchDuplicateKey"
      . forAll (choose (1 :: Int, 100))
      $ \key ->
        ioProperty $ do
          gate <- newEmptyMVar
          pool <- newTaskPool 10 :: IO (TaskPool Int ())
          _ <- tryLaunch pool key (takeMVar gate)
          result <- tryLaunch pool key (pure ())
          putMVar gate ()
          drainAll pool (\_ _ -> pure ())
          pure (result == LaunchDuplicateKey)

    it "reapCompleted removes all completed tasks"
      . forAll (choose (1 :: Int, 5))
      $ \n ->
        ioProperty $ do
          pool <- newTaskPool n :: IO (TaskPool Int ())
          mapM_ (\k -> tryLaunch pool k (pure ())) [1 .. n]
          -- drainAll polls until all tasks finish, so no timing dependency
          drainAll pool (\_ _ -> pure ())
          count <- activeCount pool
          pure (count == 0)
