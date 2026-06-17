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
  )
where

import Data.List (find)
import Data.Text (Text)
import GHC.Generics (Generic)

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
-}
lookupBinding :: WireExecutorId -> HostBindingPack -> Maybe RuntimeBindingRecord
lookupBinding executorId pack =
  find ((== executorId) . rbrExecutorId) (hbpRuntimeBindings pack)
