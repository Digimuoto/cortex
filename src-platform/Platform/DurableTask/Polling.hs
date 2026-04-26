{-# LANGUAGE ImportQualifiedPost #-}

-- | Polling utilities for durable task runtimes.
-- Provides jittered delays to prevent thundering-herd synchronization
-- when multiple instances poll at fixed intervals.
module Platform.DurableTask.Polling
  ( threadDelayWithJitter,
    jitterInterval,
  )
where

import Control.Concurrent (threadDelay)
import System.Random qualified as Random

-- | Compute jittered interval bounds given a base interval (microseconds)
-- and a jitter fraction (0.0 to 1.0).
--
-- Returns @(lo, hi)@ where the actual delay is chosen uniformly at random
-- from @[lo, hi]@. When @fraction@ is 0, returns @(base, base)@.
--
-- >>> jitterInterval 5_000_000 0.2
-- (4000000, 6000000)
--
-- >>> jitterInterval 1_000_000 0.0
-- (1000000, 1000000)
jitterInterval :: Int -> Double -> (Int, Int)
jitterInterval base fraction
  | fraction <= 0 = (base, base)
  | otherwise =
      let jitter = round (fromIntegral base * fraction)
       in (max 0 (base - jitter), base + jitter)

-- | Sleep for @base ± (fraction * base)@ microseconds, chosen uniformly
-- at random. When @fraction@ is 0, this is equivalent to 'threadDelay'.
--
-- Typical usage: @threadDelayWithJitter 5_000_000 0.2@ sleeps 4–6 seconds.
threadDelayWithJitter :: Int -> Double -> IO ()
threadDelayWithJitter base fraction = do
  let (lo, hi) = jitterInterval base fraction
  actual <-
    if lo >= hi
      then pure lo
      else Random.randomRIO (lo, hi)
  threadDelay actual
