{- |
Module      : Cortex.Capability.Catalog.RuntimeBindingRecord
Description : ADR 0053 runtime binding record — the minted, authority-bearing binding.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

A runtime binding record is what a host runtime binding pack mints (ADR 0053/0054)
when it resolves an executor manifest against concrete host authority. It is the
record a runnable Circuit carries into Pulse dispatch. Pulse reads only the opaque
action reference and the accepted replay/await metadata; it does not interpret the
backend (ADR 0059 §3).

This module stays Pulse-free: the bound action is named by an opaque text reference
('RuntimeStageActionRef'), so the catalog layer does not depend on the Pulse runtime.
-}
module Cortex.Capability.Catalog.RuntimeBindingRecord
  ( RuntimeBindingRecord (..)
  , RuntimeStageActionRef (..)
  , ResolvedAuthorityFingerprint (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

import Cortex.Capability.Catalog.AdmissionProjection (ContentDigest, ProjectionVersion)
import Cortex.Capability.Catalog.AwaitStrategy (AwaitStrategy, IsolationExpectation, ReplayClass)
import Cortex.Capability.Catalog.ExecutorManifest (AbiKind, ContentAddress)
import Cortex.Wire.Executor (WireExecutorId)

{- | Opaque reference to the bound Pulse stage action. Kept as text so the catalog
layer does not import the Pulse runtime; the host resolves it to a @StageAction@.
-}
newtype RuntimeStageActionRef = RuntimeStageActionRef {unRuntimeStageActionRef :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

{- | A fingerprint of a resolved authority (provider, tool, model policy, secret
handle) the binding depends on, recorded for provenance without embedding the
authority itself.
-}
data ResolvedAuthorityFingerprint = ResolvedAuthorityFingerprint
  { rafKind :: !Text
  , rafName :: !Text
  , rafDigest :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data RuntimeBindingRecord = RuntimeBindingRecord
  { rbrBindingId :: !Text
  , rbrBindingVersion :: !Text
  , rbrExecutorId :: !WireExecutorId
  , rbrProjectionVersion :: !ProjectionVersion
  , rbrStageActionRef :: !RuntimeStageActionRef
  , rbrManifestContentAddress :: !ContentAddress
  , rbrArtifactDigest :: !ContentDigest
  , rbrAbiKind :: !AbiKind
  , rbrAbiVersion :: !Text
  , rbrAbiDriverDigest :: !ContentDigest
  , rbrBindingPackIdentity :: !Text
  , rbrResolvedAuthorities :: ![ResolvedAuthorityFingerprint]
  , rbrIsolation :: !IsolationExpectation
  , rbrAcceptedReplayClass :: !ReplayClass
  , rbrAcceptedAwaitStrategy :: !AwaitStrategy
  , rbrCompatibilityDigest :: !ContentDigest
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
