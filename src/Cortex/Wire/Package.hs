{- |
Module      : Cortex.Wire.Package
Description : ADR 0054 Wire packages and the namespace registry `use` resolves against.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

A Wire package is inert compile-time vocabulary (ADR 0054): it exports namespaces
that resolve @use@ leaves to canonical executor and contract ids, plus the executor
projections and contract specs the compiler checks against. Importing a Wire package
never grants runtime authority — only a host binding pack (Capability layer) does.

The 'NamespaceRegistry' is the composition @use@ resolves against. @std.io@ is just
the first namespace in it, not a special case (it is wrapped as a 'NamespaceEntry'
over the existing 'Cortex.Wire.Std' lookups). This module stays in the Wire layer:
it carries 'WireExecutorProjection', not the richer Capability catalog projection.
-}
module Cortex.Wire.Package
  ( NamespaceEntry (..)
  , NamespaceRegistry
  , namespaceRegistryFromEntries
  , lookupNamespace
  , namespaceRegistryNamespaces
  , stdNamespaceEntry
  , stdOnlyRegistry
  , WirePackage (..)
  , packageNamespaceRegistry
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import Cortex.Wire.Contract (WireContractSpec)
import Cortex.Wire.Executor (WireExecutorProjection)
import Cortex.Wire.Std (stdIoContractIdForName, stdIoExecutorIdForLeaf, stdIoNamespace)

{- | One importable namespace. Resolution is by function so an entry can be backed
by the hardcoded @std.io@ lookups or by a package's maps without enumeration.
-}
data NamespaceEntry = NamespaceEntry
  { nsNamespace :: !Text
  , nsResolveExecutorLeaf :: !(Text -> Maybe Text)
  -- ^ @use ns.{@leaf}@ → canonical executor id.
  , nsResolveContract :: !(Text -> Maybe Text)
  -- ^ @use ns.{Name}@ → canonical contract id.
  }

{- | The set of importable namespaces, keyed by namespace text (e.g. @std.io@,
@quantum.core@). Later entries do not override earlier ones.
-}
newtype NamespaceRegistry = NamespaceRegistry (Map Text NamespaceEntry)

namespaceRegistryFromEntries :: [NamespaceEntry] -> NamespaceRegistry
namespaceRegistryFromEntries entries =
  NamespaceRegistry (Map.fromList [(nsNamespace e, e) | e <- entries])

lookupNamespace :: Text -> NamespaceRegistry -> Maybe NamespaceEntry
lookupNamespace ns (NamespaceRegistry m) = Map.lookup ns m

namespaceRegistryNamespaces :: NamespaceRegistry -> [Text]
namespaceRegistryNamespaces (NamespaceRegistry m) = Map.keys m

-- | @std.io@ as a namespace entry, wrapping the existing 'Cortex.Wire.Std' lookups.
stdNamespaceEntry :: NamespaceEntry
stdNamespaceEntry =
  NamespaceEntry
    { nsNamespace = stdIoNamespace
    , nsResolveExecutorLeaf = stdIoExecutorIdForLeaf
    , nsResolveContract = stdIoContractIdForName
    }

{- | The registry containing only @std.io@ — today's compile-time default before any
downstream Wire package is composed in (ADR 0059 phase P6 threads packages in).
-}
stdOnlyRegistry :: NamespaceRegistry
stdOnlyRegistry = namespaceRegistryFromEntries [stdNamespaceEntry]

{- | An inert downstream Wire package (ADR 0054): the namespaces it exports for
@use@, the executor projections, and the contract specs the compiler checks against.
No credentials, no runnable action.
-}
data WirePackage = WirePackage
  { wpId :: !Text
  , wpNamespaceEntries :: ![NamespaceEntry]
  , wpExecutorProjections :: ![WireExecutorProjection]
  , wpContractSpecs :: ![WireContractSpec]
  }

-- | Compose @std.io@ with the given Wire packages into one registry.
packageNamespaceRegistry :: [WirePackage] -> NamespaceRegistry
packageNamespaceRegistry packages =
  namespaceRegistryFromEntries (stdNamespaceEntry : concatMap wpNamespaceEntries packages)
