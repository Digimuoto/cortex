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
import Cortex.Capability.Catalog.AdmissionProjection (ContentDigest (..))
import Cortex.Capability.Catalog.AwaitStrategy (AwaitStrategy (..))
import Cortex.Capability.Catalog.ExecutorManifest (AbiKind (..), ContentAddress (..))
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
        rbrAbiKind record `shouldBe` AbiHostActionV1
        rbrStageActionRef record `shouldBe` RuntimeStageActionRef "quantum.realize.braket"
        rbrManifestContentAddress record
          `shouldBe` ContentAddress "host-action:quantum.realize.braket"
        rbrArtifactDigest record
          `shouldBe` ContentDigest "host-action:quantum.realize.braket:v1"

  it "records configured AWS resources as resolved authority fingerprints" $
    case lookupBinding realizeId (braketBindingPack config) of
      Nothing -> expectationFailure "expected a binding"
      Just record ->
        fmap rafName (rbrResolvedAuthorities record)
          `shouldContain` [deviceArn, "us-east-1", "amazon-braket-results", "research"]

  it "distinguishes result buckets in resolved authority fingerprints" $ do
    let otherConfig = config {braketS3Bucket = "amazon-braket-other-results"}
        authorities bindingConfig =
          foldMap rbrResolvedAuthorities (lookupBinding realizeId (braketBindingPack bindingConfig))

    fmap rafName (authorities config)
      `shouldContain` ["amazon-braket-results"]
    fmap rafName (authorities otherConfig)
      `shouldContain` ["amazon-braket-other-results"]
    authorities config `shouldNotBe` authorities otherConfig

  it "does not resolve an unrelated executor" $
    lookupBinding (WireExecutorId "quantum.prepare_zero") (braketBindingPack config)
      `shouldBe` Nothing
