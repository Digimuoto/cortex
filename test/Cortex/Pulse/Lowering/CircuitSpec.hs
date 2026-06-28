{- |
Module      : Cortex.Pulse.Lowering.CircuitSpec
Description : Tests for the external-call frontier lowering decision core.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Lowering admits the frontier, resolves the binding pack (typed @missing runtime
binding@ when absent — the ADR 0054 invariant), and produces a deterministic
payload + idempotency key carrying the binding's await strategy.
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
import Cortex.Pulse.Lowering.ExternalCallPayload
  ( ExternalCallOutput (..)
  , ExternalCallStep (..)
  , externalCallPayload
  , externalCallPayloadDigest
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

steps :: [ExternalCallStep]
steps = [ExternalCallStep "cnot" ["wire:0", "wire:1"] [], ExternalCallStep "measure_z" ["wire:0"] []]

outputs :: [ExternalCallOutput]
outputs = [ExternalCallOutput (Just "wire:0") "s01"]

spec :: Spec
spec = describe "lowerExternalCallFrontier" $ do
  it "fails with missing runtime binding when no pack resolves the realize executor" $
    lowerExternalCallFrontier emptyPack realizeId [node "g0"] steps outputs
      `shouldBe` Left (LoweringMissingRuntimeBinding realizeId)

  it "rejects an inadmissible (mixed-authority) frontier" $ do
    let mixed =
          [ node "g0"
          , CollectedNode "g1" (Just (WireExecutorId "quantum.iqm", SubmitParkResume))
          ]
    case lowerExternalCallFrontier braketPack realizeId mixed steps outputs of
      Left (LoweringInadmissibleFrontier _) -> pure ()
      other -> expectationFailure ("expected inadmissible frontier, got " <> show other)

  it "lowers an admissible bound frontier to a deterministic plan carrying the await strategy" $
    case lowerExternalCallFrontier braketPack realizeId [node "g0", node "g1"] steps outputs of
      Left err -> expectationFailure (show err)
      Right lowered -> do
        lrAwaitStrategy lowered `shouldBe` SubmitParkResume
        lrIdempotencyKey lowered `shouldBe` externalCallPayloadDigest (externalCallPayload steps outputs)
        rbrStageActionRef (lrBinding lowered) `shouldBe` RuntimeStageActionRef "quantum.realize.braket"
