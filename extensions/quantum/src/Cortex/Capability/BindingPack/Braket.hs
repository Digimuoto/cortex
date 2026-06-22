{- |
Module      : Cortex.Capability.BindingPack.Braket
Description : The Braket host runtime binding pack for quantum.realize (ADR 0059 / 0054).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The Braket host binding pack (ADR 0054) is the artifact that carries AWS runtime
authority: it depends on the @quantum.braket@ Wire package and mints the ADR 0053
runtime binding record that resolves @quantum.realize@ to a host-supplied
@submit_park_resume@ stage action (ADR 0059 §3). This module owns the inert,
authority-bearing binding descriptor and the config that parameterises it; it does
not claim a subprocess driver artifact until that artifact is packaged.
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

realizeExecutorId :: Text
realizeExecutorId = "quantum.realize"

braketStageAction :: RuntimeStageActionRef
braketStageAction = RuntimeStageActionRef "quantum.realize.braket"

braketHostActionAddress :: ContentAddress
braketHostActionAddress = ContentAddress "host-action:quantum.realize.braket"

braketHostActionDigest :: ContentDigest
braketHostActionDigest = ContentDigest "host-action:quantum.realize.braket:v1"

{- | AWS Braket binding configuration, loaded from @--config@. Inert until the
runnable host action consumes it.
-}
data BraketConfig = BraketConfig
  { braketRegion :: !Text
  , braketDeviceArn :: !Text
  , braketS3Bucket :: !Text
  , braketProfile :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

{- | Mint the Braket binding pack: a single runtime binding record resolving
@quantum.realize@ to a @submit_park_resume@ external-call stage driven through an
opaque host action, isolated in a subprocess sandbox by host policy, with an
idempotency-keyed replay class (required for the crash-safe submit protocol). The
resolved AWS device, region, result bucket, and optional profile selector are
recorded as authority fingerprints for provenance.
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
            , rbrStageActionRef = braketStageAction
            , rbrManifestContentAddress = braketHostActionAddress
            , rbrArtifactDigest = braketHostActionDigest
            , rbrAbiKind = AbiHostActionV1
            , rbrAbiVersion = "1"
            , rbrAbiDriverDigest = braketHostActionDigest
            , rbrBindingPackIdentity = "braket-pack"
            , rbrResolvedAuthorities = braketResolvedAuthorities config
            , rbrIsolation = SubprocessSandbox
            , rbrAcceptedReplayClass = IdempotentWithKey
            , rbrAcceptedAwaitStrategy = SubmitParkResume
            , rbrCompatibilityDigest = ContentDigest "braket-1"
            }
        ]
    }

braketResolvedAuthorities :: BraketConfig -> [ResolvedAuthorityFingerprint]
braketResolvedAuthorities config =
  [ ResolvedAuthorityFingerprint
      "aws.braket.device"
      (braketDeviceArn config)
      (ContentDigest (braketDeviceArn config))
  , ResolvedAuthorityFingerprint
      "aws.region"
      (braketRegion config)
      (ContentDigest (braketRegion config))
  , ResolvedAuthorityFingerprint
      "aws.s3.bucket"
      (braketS3Bucket config)
      (ContentDigest (braketS3Bucket config))
  ]
    <> profileAuthority
  where
    profileAuthority =
      case braketProfile config of
        Nothing -> []
        Just profile ->
          [ ResolvedAuthorityFingerprint
              "aws.profile"
              profile
              (ContentDigest profile)
          ]
