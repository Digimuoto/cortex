{- |
Module      : Cortex.Wire.Package.Registry
Description : Wire package namespace registry used by `use` resolution.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The namespace registry is deliberately smaller than a Wire package: it is just
the inert mapping from source `use` leaves to canonical executor and contract
ids. Keeping it dependency-light lets compile environments carry registry data
without depending on package manifests or contract registries.
-}
module Cortex.Wire.Package.Registry
  ( NamespaceEntry (..)
  , NamespaceRegistry
  , namespaceRegistryFromEntries
  , mergeNamespaceRegistries
  , lookupNamespace
  , namespaceRegistryNamespaces
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

{- | One importable namespace. Resolution is by function so an entry can be backed
by hardcoded lookups or by manifest maps without changing `use` semantics.
-}
data NamespaceEntry = NamespaceEntry
  { nsNamespace :: !Text
  , nsResolveExecutorLeaf :: !(Text -> Maybe Text)
  -- ^ @use ns.{@leaf}@ -> canonical executor id.
  , nsResolveContract :: !(Text -> Maybe Text)
  -- ^ @use ns.{Name}@ -> canonical contract id.
  }

instance Eq NamespaceEntry where
  left == right = nsNamespace left == nsNamespace right

instance Show NamespaceEntry where
  show entry = "NamespaceEntry " <> show entry.nsNamespace

{- | The set of importable namespaces, keyed by namespace text such as @std.io@
or @example.core@. Later entries do not override earlier ones.
-}
newtype NamespaceRegistry = NamespaceRegistry (Map Text NamespaceEntry)
  deriving stock (Eq, Show)

namespaceRegistryFromEntries :: [NamespaceEntry] -> NamespaceRegistry
namespaceRegistryFromEntries entries =
  NamespaceRegistry (Map.fromListWith (\_ existing -> existing) [(nsNamespace e, e) | e <- entries])

-- | Left-biased namespace registry merge. Existing entries win on collisions.
mergeNamespaceRegistries :: NamespaceRegistry -> NamespaceRegistry -> NamespaceRegistry
mergeNamespaceRegistries (NamespaceRegistry existing) (NamespaceRegistry added) =
  NamespaceRegistry (existing <> added)

lookupNamespace :: Text -> NamespaceRegistry -> Maybe NamespaceEntry
lookupNamespace ns (NamespaceRegistry m) = Map.lookup ns m

namespaceRegistryNamespaces :: NamespaceRegistry -> [Text]
namespaceRegistryNamespaces (NamespaceRegistry m) = Map.keys m
