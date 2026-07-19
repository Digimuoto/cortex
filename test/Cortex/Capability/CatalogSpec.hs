{- |
Module      : Cortex.Capability.CatalogSpec
Description : Tests for the ADR 0053 executor catalog types.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

JSON round-trips (including the hand-written port codec), content-digest
determinism, and the runtime binding record.
-}
module Cortex.Capability.CatalogSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy (ByteString)
import Data.List qualified as List
import Test.Hspec

import Cortex.Capability.Catalog.AdmissionProjection
import Cortex.Capability.Catalog.AwaitStrategy
import Cortex.Capability.Catalog.ExecutorManifest (AbiKind (..), ContentAddress (..))
import Cortex.Capability.Catalog.RuntimeBindingRecord
import Cortex.Wire.Executor (WireExecutorId (..))

-- A realize-style projection authored as JSON (the port constructors live in the
-- library-internal Cortex.Wire.AST, so the test exercises the public FromJSON path
-- rather than importing hidden modules — this also covers the port codec directly).
sampleProjectionJSON :: ByteString
sampleProjectionJSON =
  "{\"executorId\":\"quantum.realize\"\
  \,\"projectionVersion\":\"1\"\
  \,\"ports\":{\"inputs\":{\"shots\":{\"accepts\":[\"ShotCount\"],\"cardinality\":\"one\",\"required\":true}}\
  \,\"outputs\":{\"s01\":{\"contract\":\"MeasurementResult\"},\"s12\":{\"contract\":\"MeasurementResult\"}}}\
  \,\"configSchemaRef\":{\"tag\":\"ConfigSchemaName\",\"contents\":\"braket-config\"}\
  \,\"requirementSlots\":[{\"rsCapabilityKind\":\"provider\",\"rsBindingName\":\"braket\"\
  \,\"rsConfigSelector\":\"config.device\",\"rsPermissionClass\":\"aws.braket\"}]\
  \,\"replayClass\":\"idempotent_with_key\"\
  \,\"isolationExpectation\":\"subprocess_sandbox\"\
  \,\"effect\":\"host_effect\"\
  \,\"awaitStrategy\":\"submit_park_resume\"}"

sampleProjection :: AdmissionProjection
sampleProjection =
  either (error . ("sampleProjection decode: " <>)) id (Aeson.eitherDecode sampleProjectionJSON)

roundTrips :: (Eq a, Show a, Aeson.ToJSON a, Aeson.FromJSON a) => a -> Expectation
roundTrips x = Aeson.eitherDecode (Aeson.encode x) `shouldBe` Right x

sampleBinding :: RuntimeBindingRecord
sampleBinding =
  RuntimeBindingRecord
    { rbrBindingId = "braket-pack/quantum.realize"
    , rbrBindingVersion = "1"
    , rbrExecutorId = WireExecutorId "quantum.realize"
    , rbrProjectionVersion = ProjectionVersion "1"
    , rbrStageActionRef = RuntimeStageActionRef "quantum.realize.braket"
    , rbrManifestContentAddress = ContentAddress "sha256:manifest"
    , rbrArtifactDigest = ContentDigest "d"
    , rbrAbiKind = AbiSubprocessJsonl
    , rbrAbiVersion = "1"
    , rbrAbiDriverDigest = ContentDigest "dd"
    , rbrBindingPackIdentity = "braket-pack"
    , rbrResolvedAuthorities = []
    , rbrIsolation = SubprocessSandbox
    , rbrAcceptedReplayClass = IdempotentWithKey
    , rbrAcceptedAwaitStrategy = SubmitParkResume
    , rbrCompatibilityDigest = ContentDigest "c"
    }

spec :: Spec
spec = do
  describe "AdmissionProjection JSON" $ do
    it "round-trips through JSON, including ports" $
      roundTrips sampleProjection
    it "round-trips the await strategy / replay / isolation enums" $ do
      roundTrips Synchronous
      roundTrips SubmitParkResume
      roundTrips IdempotentWithKey
      roundTrips SubprocessSandbox
    it "retains v1 config projections while emitting v2 argument projections" $ do
      let v2Projection =
            admissionProjectionWithArgumentShapeRef
              (ArgumentShapeName "braket-argument")
              sampleProjection
      roundTrips v2Projection
      apProjectionVersion v2Projection `shouldBe` currentProjectionVersion
      apArgumentShapeRef v2Projection `shouldBe` ArgumentShapeName "braket-argument"
      case Aeson.toJSON v2Projection of
        Aeson.Object object -> do
          KeyMap.member "argumentShapeRef" object `shouldBe` True
          KeyMap.member "configSchemaRef" object `shouldBe` False
        other -> expectationFailure ("expected projection object, got " <> show other)
    it "rejects malformed projection JSON with named causes" $ do
      baseObject <-
        case Aeson.toJSON sampleProjection of
          Aeson.Object object -> pure object
          other -> fail ("expected projection object, got " <> show other)
      let decodeWith adjust =
            Aeson.fromJSON (Aeson.Object (adjust baseObject))
              :: Aeson.Result AdmissionProjection
          failsWith needle result =
            case result of
              Aeson.Error err -> needle `List.isInfixOf` err
              Aeson.Success _ -> False
      let argumentRef =
            Aeson.object
              ["tag" Aeson..= ("ArgumentShapeName" :: String), "contents" Aeson..= ("x" :: String)]
      decodeWith (KeyMap.insert "argumentShapeRef" argumentRef)
        `shouldSatisfy` failsWith "cannot define both configSchemaRef and argumentShapeRef"
      decodeWith
        (KeyMap.insert "projectionVersion" (Aeson.String "2") . KeyMap.delete "configSchemaRef")
        `shouldSatisfy` failsWith "missing argumentShapeRef"
      decodeWith (KeyMap.insert "projectionVersion" (Aeson.String "3"))
        `shouldSatisfy` failsWith "unsupported admission projection version"

  describe "admissionProjectionDigest" $ do
    it "is deterministic for the same projection" $
      admissionProjectionDigest sampleProjection
        `shouldBe` admissionProjectionDigest sampleProjection
    it "changes when a defining field changes" $
      admissionProjectionDigest sampleProjection
        `shouldNotBe` admissionProjectionDigest sampleProjection {apAwaitStrategy = Synchronous}

  describe "RuntimeBindingRecord JSON" $
    it "round-trips" (roundTrips sampleBinding)
