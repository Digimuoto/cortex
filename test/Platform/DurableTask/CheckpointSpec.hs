{- |
Module      : Platform.DurableTask.CheckpointSpec
Description : Tests for Platform.DurableTask.Checkpoint.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Platform.DurableTask.CheckpointSpec (spec) where

import Data.Aeson qualified as Aeson
import Test.Hspec

import Platform.DurableTask.Checkpoint
  ( CheckpointCompatibilityFailure (..)
  , buildCheckpointEnvelope
  , parseCheckpointEnvelope
  , validateCheckpointEnvelope
  )

spec :: Spec
spec = do
  describe "checkpoint envelope compatibility" $ do
    it "round-trips a compatible checkpoint envelope" $ do
      let payload = Aeson.object ["completed_cases" Aeson..= (3 :: Int)]
          rawEnvelope =
            Aeson.toJSON $
              buildCheckpointEnvelope "paper_portfolio_cycle" 1 1 "planner" payload
      case parseCheckpointEnvelope rawEnvelope of
        Left err ->
          expectationFailure ("Expected checkpoint envelope to parse, got: " <> show err)
        Right envelope ->
          validateCheckpointEnvelope "paper_portfolio_cycle" 1 1 "planner" envelope
            `shouldBe` Right payload

    it "rejects runtime-version mismatches explicitly" $ do
      let rawEnvelope =
            Aeson.toJSON $
              buildCheckpointEnvelope "paper_portfolio_cycle" 1 2 "planner" Aeson.Null
      case parseCheckpointEnvelope rawEnvelope of
        Left err ->
          expectationFailure ("Expected checkpoint envelope to parse, got: " <> show err)
        Right envelope ->
          validateCheckpointEnvelope "paper_portfolio_cycle" 1 1 "planner" envelope
            `shouldBe` Left (CheckpointRuntimeVersionMismatch 1 2)

    it "rejects checkpoint-name mismatches explicitly" $ do
      let rawEnvelope =
            Aeson.toJSON $
              buildCheckpointEnvelope "paper_portfolio_cycle" 1 1 "analyst" Aeson.Null
      case parseCheckpointEnvelope rawEnvelope of
        Left err ->
          expectationFailure ("Expected checkpoint envelope to parse, got: " <> show err)
        Right envelope ->
          validateCheckpointEnvelope "paper_portfolio_cycle" 1 1 "planner" envelope
            `shouldBe` Left (CheckpointNameMismatch "planner" "analyst")
