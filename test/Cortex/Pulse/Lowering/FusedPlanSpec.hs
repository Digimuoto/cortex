{- |
Module      : Cortex.Pulse.Lowering.FusedPlanSpec
Description : Tests for the canonical fused-plan serializer (ADR 0059 §2/§3).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The digest is deterministic, independent of measurement input order (sorted), and
sensitive to operation order (gate order is physically meaningful). This is the
idempotency-key stability property the submit/park/resume protocol relies on.
-}
module Cortex.Pulse.Lowering.FusedPlanSpec (spec) where

import Test.Hspec

import Cortex.Pulse.Lowering.FusedPlan

ops :: [FusedOp]
ops =
  [ FusedOp "prepare_zero" [0] []
  , FusedOp "x" [0] []
  , FusedOp "cnot" [0, 1] []
  ]

measurements :: [FusedMeasurement]
measurements = [FusedMeasurement 1 "s12", FusedMeasurement 0 "s01"]

spec :: Spec
spec = describe "fusedPlanDigest" $ do
  it "is deterministic for the same plan" $
    fusedPlanDigest (fusedPlan ops measurements)
      `shouldBe` fusedPlanDigest (fusedPlan ops measurements)

  it "is independent of measurement input order (measurements are sorted)" $
    fusedPlanDigest (fusedPlan ops measurements)
      `shouldBe` fusedPlanDigest (fusedPlan ops (reverse measurements))

  it "is sensitive to operation order (gate order is physical)" $
    fusedPlanDigest (fusedPlan ops measurements)
      `shouldNotBe` fusedPlanDigest (fusedPlan (reverse ops) measurements)

  it "sorts measurements canonically in the payload" $
    fmap fmOutput (fpMeasurements (fusedPlan ops measurements)) `shouldBe` ["s01", "s12"]
