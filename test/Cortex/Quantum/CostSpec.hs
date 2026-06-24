{- |
Module      : Cortex.Quantum.CostSpec
Description : Embedded Amazon Braket cost estimates.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Checks the embedded Braket cost estimates across the QPU, managed-simulator,
price-override, and unknown-device cases.
-}
module Cortex.Quantum.CostSpec (spec) where

import Data.Text (Text)
import Test.Hspec

import Cortex.Quantum.Cost
  ( CostOverrides (..)
  , TaskMeta (..)
  , costEstimateText
  , estimateTaskCost
  , noCostOverrides
  )

garnetArn :: Text
garnetArn = "arn:aws:braket:eu-north-1::device/qpu/iqm/Garnet"

sv1Arn :: Text
sv1Arn = "arn:aws:braket:::device/quantum-simulator/amazon/sv1"

spec :: Spec
spec =
  describe "Braket cost estimates" $ do
    it "prices a QPU task as per-task plus per-shot" $
      costEstimateText (estimateTaskCost noCostOverrides garnetArn 100 Nothing)
        `shouldBe` Just "0.445"

    it "leaves a managed simulator unpriced before completion" $
      costEstimateText (estimateTaskCost noCostOverrides sv1Arn 100 Nothing)
        `shouldBe` Nothing

    it "prices a completed managed simulator by billed duration" $
      costEstimateText
        (estimateTaskCost noCostOverrides sv1Arn 100 (Just (TaskMeta (Just 100) (Just 120))))
        `shouldBe` Just "0.15"

    it "refuses a one-sided price override" $
      costEstimateText (estimateTaskCost (CostOverrides (Just 0.5) Nothing Nothing) garnetArn 100 Nothing)
        `shouldBe` Nothing

    it "applies a complete price override using the requested shots" $
      costEstimateText
        (estimateTaskCost (CostOverrides (Just 0.5) (Just 0.01) Nothing) sv1Arn 100 Nothing)
        `shouldBe` Just "1.5"

    it "reports an unavailable estimate for an unknown device" $
      costEstimateText
        (estimateTaskCost noCostOverrides "arn:aws:braket:::device/qpu/unknown/foo" 100 Nothing)
        `shouldBe` Nothing
