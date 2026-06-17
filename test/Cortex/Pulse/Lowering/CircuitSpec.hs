{- |
Module      : Cortex.Pulse.Lowering.CircuitSpec
Description : Tests for the realize-frontier lowering decision core (ADR 0059 §2/§3).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Lowering admits the frontier, resolves the binding pack (typed @missing runtime
binding@ when absent — the ADR 0054 invariant), and produces a deterministic fused
plan + idempotency key carrying the binding's await strategy.
-}
module Cortex.Pulse.Lowering.CircuitSpec (spec) where

import Data.Text (Text)
import Test.Hspec

import Cortex.Capability.BindingPack (HostBindingPack (..))
import Cortex.Capability.Catalog.AdmissionProjection (ContentDigest (..), ProjectionVersion (..))
import Cortex.Capability.Catalog.AwaitStrategy
  ( AwaitStrategy (..)
  , IsolationExpectation (..)
  , ReplayClass (..)
  )
import Cortex.Capability.Catalog.ExecutorManifest (AbiKind (..), ContentAddress (..))
import Cortex.Capability.Catalog.RuntimeBindingRecord
import Cortex.Pulse.Lowering.Circuit
import Cortex.Pulse.Lowering.FusedPlan
  ( FusedMeasurement (..)
  , FusedOp (..)
  , fusedPlan
  , fusedPlanDigest
  )
import Cortex.Pulse.Rewrite.Contract (CollectedNode (..))
import Cortex.Wire.Executor (WireExecutorId (..))

realizeId :: WireExecutorId
realizeId = WireExecutorId "quantum.realize"

binding :: RuntimeBindingRecord
binding =
  RuntimeBindingRecord
    { rbrBindingId = "braket-pack/quantum.realize"
    , rbrBindingVersion = "1"
    , rbrExecutorId = realizeId
    , rbrProjectionVersion = ProjectionVersion "1"
    , rbrStageActionRef = RuntimeStageActionRef "quantum.realize.braket"
    , rbrManifestContentAddress = ContentAddress "sha256:m"
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

braketPack :: HostBindingPack
braketPack = HostBindingPack "braket-pack" ["quantum.braket"] [binding]

emptyPack :: HostBindingPack
emptyPack = HostBindingPack "empty" [] []

node :: Text -> CollectedNode Text WireExecutorId AwaitStrategy
node n = CollectedNode n (Just (WireExecutorId "quantum.braket", SubmitParkResume))

ops :: [FusedOp]
ops = [FusedOp "cnot" [0, 1] [], FusedOp "measure_z" [0] []]

measurements :: [FusedMeasurement]
measurements = [FusedMeasurement 0 "s01"]

spec :: Spec
spec = describe "lowerRealizeFrontier" $ do
  it "fails with missing runtime binding when no pack resolves the realize executor" $
    lowerRealizeFrontier emptyPack realizeId [node "g0"] ops measurements
      `shouldBe` Left (LoweringMissingRuntimeBinding realizeId)

  it "rejects an inadmissible (mixed-authority) frontier" $ do
    let mixed =
          [ node "g0"
          , CollectedNode "g1" (Just (WireExecutorId "quantum.iqm", SubmitParkResume))
          ]
    case lowerRealizeFrontier braketPack realizeId mixed ops measurements of
      Left (LoweringInadmissibleFrontier _) -> pure ()
      other -> expectationFailure ("expected inadmissible frontier, got " <> show other)

  it "lowers an admissible bound frontier to a deterministic plan carrying the await strategy" $
    case lowerRealizeFrontier braketPack realizeId [node "g0", node "g1"] ops measurements of
      Left err -> expectationFailure (show err)
      Right lowered -> do
        lrAwaitStrategy lowered `shouldBe` SubmitParkResume
        lrIdempotencyKey lowered `shouldBe` fusedPlanDigest (fusedPlan ops measurements)
        rbrStageActionRef (lrBinding lowered) `shouldBe` RuntimeStageActionRef "quantum.realize.braket"
