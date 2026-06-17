{- |
Module      : Cortex.Capability.Catalog.ExecutorManifest
Description : ADR 0053 executor manifest — the runnable-artifact descriptor.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The executor manifest is produced by an executor package and consumed by the build
system and host runtime binding (ADR 0053). It is still inert: it names an artifact,
its ABI, its provenance, and the projection it implements, but it grants no authority
on its own — only a host binding pack turns a manifest into a runtime binding record.

Pulse never consumes manifests directly.
-}
module Cortex.Capability.Catalog.ExecutorManifest
  ( ExecutorManifest (..)
  , AbiKind (..)
  , ContentAddress (..)
  , OutputCommitPolicy (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

import Cortex.Capability.Catalog.AdmissionProjection
  ( ContentDigest
  , ProjectionVersion
  )
import Cortex.Capability.Catalog.AwaitStrategy (IsolationExpectation, ReplayClass)
import Cortex.Wire.Executor (WireExecutorId)

newtype ContentAddress = ContentAddress {unContentAddress :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

{- | The driver/ABI kind through which the host invokes the artifact. @host-action-v1@
is one option, not the required mechanism (ADR 0059 §3).
-}
data AbiKind
  = AbiHostActionV1
  | AbiSubprocessJsonl
  | AbiInProcessNative
  | AbiWasmComponent
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

{- | How the executor's outputs are committed relative to its effect (informs the
replay class for @submit_park_resume@ external calls).
-}
data OutputCommitPolicy
  = CommitOnComplete
  | CommitViaAttemptRecord
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ExecutorManifest = ExecutorManifest
  { emSchemaVersion :: !Text
  , emContentAddress :: !ContentAddress
  , emSignature :: !(Maybe Text)
  , emExecutorId :: !WireExecutorId
  , emProjectionVersion :: !ProjectionVersion
  , emProjectionDigest :: !ContentDigest
  , emArtifactRef :: !ContentAddress
  , emArtifactDigest :: !ContentDigest
  , emAbiKind :: !AbiKind
  , emAbiVersion :: !Text
  , emAbiDriverIdentity :: !Text
  , emProvenance :: !(Maybe Text)
  , emPermissions :: ![Text]
  , emIsolationExpectation :: !IsolationExpectation
  , emReplayClass :: !ReplayClass
  , emOutputCommitPolicy :: !OutputCommitPolicy
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
