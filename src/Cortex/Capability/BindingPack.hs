{- |
Module      : Cortex.Capability.BindingPack
Description : ADR 0054 host runtime binding pack — the only artifact with runtime authority.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

A host runtime binding pack (ADR 0054) is the sole artifact that carries runtime
authority. It depends on one or more Wire packages (never the reverse), resolves
their declared executor requirements against concrete host authority, and mints the
ADR 0053 runtime binding records a runnable Circuit carries into Pulse dispatch.

This module defines the inert descriptor; a concrete pack (e.g. the Braket pack,
ADR 0059 phase P7) supplies the runnable @StageAction@s the records reference.
-}
module Cortex.Capability.BindingPack
  ( HostBindingPack (..)
  , lookupBinding
  , lookupBindingForVersion
  )
where

import Data.List (find)
import Data.Text (Text)
import GHC.Generics (Generic)

import Cortex.Capability.Catalog.AdmissionProjection (ProjectionVersion)
import Cortex.Capability.Catalog.RuntimeBindingRecord (RuntimeBindingRecord (..))
import Cortex.Wire.Executor (WireExecutorId)

data HostBindingPack = HostBindingPack
  { hbpIdentity :: !Text
  -- ^ The pack's identity (e.g. @braket-pack@).
  , hbpWirePackageDeps :: ![Text]
  -- ^ Ids of the Wire packages this pack binds (dependency is one-way: pack → package).
  , hbpRuntimeBindings :: ![RuntimeBindingRecord]
  -- ^ The minted binding records, one per executor id this pack resolves.
  }
  deriving stock (Eq, Show, Generic)

{- | Resolve an executor id to its minted runtime binding record, if this pack binds it.
A missing result is the @missing runtime binding@ condition (ADR 0054): compile
succeeds without a pack; only runnable Pulse lowering fails.

This returns the first record for the executor id. A pack should hold at most one record
per @(executor id, projection version)@; when the caller knows the projection version the
circuit was compiled against, prefer 'lookupBindingForVersion'. Threading that version
through realize lowering depends on the Wire executor projection carrying a version (the
ADR 0060 versioning slice), so this id-only lookup is the call-site entry point for now.
-}
lookupBinding :: WireExecutorId -> HostBindingPack -> Maybe RuntimeBindingRecord
lookupBinding executorId pack =
  find ((== executorId) . rbrExecutorId) (hbpRuntimeBindings pack)

{- | Resolve an executor id at a specific admission-projection version. This is the
binding key ADR 0053 specifies — @(executor id, projection version)@ — so two records
for the same executor at different projection versions resolve unambiguously rather than
by list order.
-}
lookupBindingForVersion
  :: WireExecutorId -> ProjectionVersion -> HostBindingPack -> Maybe RuntimeBindingRecord
lookupBindingForVersion executorId projectionVersion pack =
  find matchesKey (hbpRuntimeBindings pack)
  where
    matchesKey record =
      rbrExecutorId record == executorId
        && rbrProjectionVersion record == projectionVersion
