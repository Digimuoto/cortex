{- |
Module      : Cortex.Capability.BindingPack.Braket
Description : The Braket host runtime binding pack for quantum.realize (ADR 0059 / 0054).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The Braket host binding pack (ADR 0054) is the artifact that carries AWS runtime
authority: it depends on the @quantum.braket@ Wire package and mints the ADR 0053
runtime binding record that resolves @quantum.realize@ to a @submit_park_resume@
external-call stage (ADR 0059 §3). The runnable driver — OpenQASM lowering + Braket
submit/poll over @scripts/wire-quantum-braket.py@ — is supplied at the Pulse layer
when the CLI runs; this module owns the inert, authority-bearing binding descriptor
and the config that parameterises it.
-}
module Cortex.Capability.BindingPack.Braket
  ( BraketConfig (..)
  , braketBindingPack
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)

import Cortex.Capability.BindingPack (HostBindingPack (..))
import Cortex.Capability.Catalog.AdmissionProjection (ContentDigest (..), ProjectionVersion (..))
import Cortex.Capability.Catalog.AwaitStrategy
  ( AwaitStrategy (..)
  , IsolationExpectation (..)
  , ReplayClass (..)
  )
import Cortex.Capability.Catalog.ExecutorManifest (AbiKind (..), ContentAddress (..))
import Cortex.Capability.Catalog.RuntimeBindingRecord
import Cortex.Wire.Executor (WireExecutorId (..))
import Cortex.Wire.Quantum (realizeExecutorId)

{- | AWS Braket binding configuration, loaded from @--config@. Inert until the
runnable driver consumes it.
-}
data BraketConfig = BraketConfig
  { braketRegion :: !Text
  , braketDeviceArn :: !Text
  , braketS3Bucket :: !Text
  , braketProfile :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

{- | Mint the Braket binding pack: a single runtime binding record resolving
@quantum.realize@ to a @submit_park_resume@ external-call stage driven through the
subprocess JSONL ABI, isolated in a subprocess sandbox, with an idempotency-keyed
replay class (required for the crash-safe submit protocol). The resolved device ARN
and region are recorded as authority fingerprints for provenance.
-}
braketBindingPack :: BraketConfig -> HostBindingPack
braketBindingPack config =
  HostBindingPack
    { hbpIdentity = "braket-pack"
    , hbpWirePackageDeps = ["quantum.braket"]
    , hbpRuntimeBindings =
        [ RuntimeBindingRecord
            { rbrBindingId = "braket-pack/" <> realizeExecutorId
            , rbrBindingVersion = "1"
            , rbrExecutorId = WireExecutorId realizeExecutorId
            , rbrProjectionVersion = ProjectionVersion "1"
            , rbrStageActionRef = RuntimeStageActionRef "quantum.realize.braket"
            , rbrManifestContentAddress = ContentAddress "wire-quantum-braket.py"
            , rbrArtifactDigest = ContentDigest "braket-driver"
            , rbrAbiKind = AbiSubprocessJsonl
            , rbrAbiVersion = "1"
            , rbrAbiDriverDigest = ContentDigest "braket-driver"
            , rbrBindingPackIdentity = "braket-pack"
            , rbrResolvedAuthorities =
                [ ResolvedAuthorityFingerprint
                    "aws.braket.device"
                    (braketDeviceArn config)
                    (ContentDigest (braketDeviceArn config))
                , ResolvedAuthorityFingerprint
                    "aws.region"
                    (braketRegion config)
                    (ContentDigest (braketRegion config))
                ]
            , rbrIsolation = SubprocessSandbox
            , rbrAcceptedReplayClass = IdempotentWithKey
            , rbrAcceptedAwaitStrategy = SubmitParkResume
            , rbrCompatibilityDigest = ContentDigest "braket-1"
            }
        ]
    }
