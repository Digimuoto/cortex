{- |
Module      : Platform.DurableTask.ErrorSpec
Description : Tests for Platform.DurableTask.Error.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Platform.DurableTask.ErrorSpec (spec) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Test.Hspec

import Platform.DurableTask.Error (logDbFailure, logDbFailure_)

spec :: Spec
spec = describe "Platform.DurableTask.Error" $ do
  describe "logDbFailure_" $ do
    it "calls callback on Left" $ do
      ref <- newIORef Nothing
      logDbFailure_ (writeIORef ref . Just) (pure (Left "db timeout"))
      readIORef ref `shouldReturn` Just "db timeout"

    it "does nothing on Right" $ do
      ref <- newIORef Nothing
      logDbFailure_ (writeIORef ref . Just) (pure (Right (42 :: Int)))
      readIORef ref `shouldReturn` Nothing

  describe "logDbFailure" $ do
    it "returns Just on Right" $ do
      ref <- newIORef False
      result <- logDbFailure (\_ -> writeIORef ref True) (pure (Right (42 :: Int)))
      result `shouldBe` Just 42
      readIORef ref `shouldReturn` False

    it "returns Nothing and calls callback on Left" $ do
      ref <- newIORef Nothing
      result <-
        logDbFailure (writeIORef ref . Just) (pure (Left "connection refused") :: IO (Either String Int))
      result `shouldBe` Nothing
      readIORef ref `shouldReturn` Just "connection refused"
