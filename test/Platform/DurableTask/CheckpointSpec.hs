{-# LANGUAGE OverloadedStrings #-}

module Platform.DurableTask.CheckpointSpec (spec) where

import Data.Aeson qualified as Aeson
import Platform.DurableTask.Checkpoint
  ( CheckpointCompatibilityFailure (..),
    buildCheckpointEnvelope,
    parseCheckpointEnvelope,
    validateCheckpointEnvelope,
  )
import Test.Hspec

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
