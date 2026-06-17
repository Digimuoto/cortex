{- |
Module      : Cortex.Capability.BindingPack.BraketSpec
Description : Tests for the Braket host binding pack (ADR 0059 / 0054).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The minted pack resolves quantum.realize to a submit/park/resume binding carrying
the configured device authority — the ADR 0054 host-binding contract.
-}
module Cortex.Capability.BindingPack.BraketSpec (spec) where

import Data.Text (Text)
import Test.Hspec

import Cortex.Capability.BindingPack (HostBindingPack (..), lookupBinding)
import Cortex.Capability.BindingPack.Braket
import Cortex.Capability.Catalog.AwaitStrategy (AwaitStrategy (..))
import Cortex.Capability.Catalog.ExecutorManifest (AbiKind (..))
import Cortex.Capability.Catalog.RuntimeBindingRecord
import Cortex.Wire.Executor (WireExecutorId (..))

config :: BraketConfig
config =
  BraketConfig
    { braketRegion = "us-east-1"
    , braketDeviceArn = "arn:aws:braket:::device/qpu/ionq/Aria-1"
    , braketS3Bucket = "amazon-braket-results"
    , braketProfile = Just "research"
    }

realizeId :: WireExecutorId
realizeId = WireExecutorId "quantum.realize"

deviceArn :: Text
deviceArn = "arn:aws:braket:::device/qpu/ionq/Aria-1"

spec :: Spec
spec = describe "braketBindingPack" $ do
  it "declares a one-way dependency on the quantum.braket Wire package" $
    hbpWirePackageDeps (braketBindingPack config) `shouldBe` ["quantum.braket"]

  it "resolves quantum.realize to a submit/park/resume binding" $
    case lookupBinding realizeId (braketBindingPack config) of
      Nothing -> expectationFailure "expected a binding for quantum.realize"
      Just record -> do
        rbrAcceptedAwaitStrategy record `shouldBe` SubmitParkResume
        rbrAbiKind record `shouldBe` AbiSubprocessJsonl
        rbrStageActionRef record `shouldBe` RuntimeStageActionRef "quantum.realize.braket"

  it "records the configured device as a resolved authority fingerprint" $
    case lookupBinding realizeId (braketBindingPack config) of
      Nothing -> expectationFailure "expected a binding"
      Just record ->
        fmap rafName (rbrResolvedAuthorities record) `shouldContain` [deviceArn]

  it "does not resolve an unrelated executor" $
    lookupBinding (WireExecutorId "quantum.prepare_zero") (braketBindingPack config)
      `shouldBe` Nothing
