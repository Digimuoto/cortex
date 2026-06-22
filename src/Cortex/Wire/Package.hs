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
  , mergeNamespaceRegistries
  , lookupNamespace
  , namespaceRegistryNamespaces
  , stdNamespaceEntry
  , stdOnlyRegistry
  , WirePackage (..)
  , packageNamespaceRegistry
  , wireCompileEnvWithPackages
  , PackageConflict (..)
  , packageConflicts
  , renderPackageConflict
  )
where

import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)

import Cortex.Wire.Contract (WireCompileEnv (..), WireContractRegistry (..), WireContractSpec (..))
import Cortex.Wire.Executor
  ( WireExecutorProjection (..)
  , WireExecutorRegistry (..)
  , wireExecutorIdToText
  )
import Cortex.Wire.Package.Registry
import Cortex.Wire.Std (stdIoContractIdForName, stdIoExecutorIdForLeaf, stdIoNamespace)

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

{- | Add inert Wire packages to a compile environment. This supplies the `use`
namespace registry and makes package contracts/executor projections available to
strict compilation, but it grants no runtime authority.
-}
wireCompileEnvWithPackages :: [WirePackage] -> WireCompileEnv -> WireCompileEnv
wireCompileEnvWithPackages packages env =
  env
    { wireCompileEnvNamespaceRegistry =
        Just
          ( mergeNamespaceRegistries
              (fromMaybe stdOnlyRegistry env.wireCompileEnvNamespaceRegistry)
              packageNamespaceRegistry'
          )
    , wireCompileEnvExecutorRegistry =
        mergeExecutorRegistry env.wireCompileEnvExecutorRegistry packageExecutorRegistry
    , wireCompileEnvContractRegistry =
        Just (mergeContractRegistry env.wireCompileEnvContractRegistry packageContractRegistry)
    }
  where
    packageNamespaceRegistry' =
      packageNamespaceRegistry packages
    packageExecutorRegistry =
      WireExecutorRegistry
        ( firstWins
            [ (projection.wireExecutorProjectionId, projection)
            | projection <- concatMap wpExecutorProjections packages
            ]
        )
    packageContractRegistry =
      WireContractRegistry
        ( firstWins
            [ (spec.wireContractSpecId, spec)
            | spec <- concatMap wpContractSpecs packages
            ]
        )

{- | Keep the first binding for a duplicate key, matching the namespace registry's
@Map.fromListWith (\\_ existing -> existing)@. Composition uses one precedence
direction across namespaces, executor projections, and contract specs; real
collisions are surfaced by 'packageConflicts', not silently last-write-wins.
-}
firstWins :: Ord k => [(k, v)] -> Map.Map k v
firstWins = Map.fromListWith (\_ existing -> existing)

mergeExecutorRegistry :: WireExecutorRegistry -> WireExecutorRegistry -> WireExecutorRegistry
mergeExecutorRegistry (WireExecutorRegistry existing) (WireExecutorRegistry packageEntries) =
  WireExecutorRegistry (existing <> packageEntries)

mergeContractRegistry :: Maybe WireContractRegistry -> WireContractRegistry -> WireContractRegistry
mergeContractRegistry maybeExisting (WireContractRegistry packageEntries) =
  case maybeExisting of
    Nothing -> WireContractRegistry packageEntries
    Just (WireContractRegistry existing) -> WireContractRegistry (existing <> packageEntries)

{- | A composition conflict: one identifier claimed by more than one Wire package.
Composition is left-biased (existing wins) and would otherwise silently drop the
loser, so a caller composing externally loaded manifests should reject a non-empty
'packageConflicts' result rather than pick a winner (ADR 0060 conflict-detection slice).
-}
data PackageConflict
  = DuplicatePackageId !Text
  | DuplicateNamespace !Text
  | DuplicateExecutorId !Text
  | DuplicateContractId !Text
  deriving stock (Eq, Show)

renderPackageConflict :: PackageConflict -> Text
renderPackageConflict = \case
  DuplicatePackageId packageId -> "duplicate package id " <> packageId
  DuplicateNamespace namespace -> "duplicate namespace " <> namespace
  DuplicateExecutorId executorId -> "duplicate executor id " <> executorId
  DuplicateContractId contractId -> "duplicate contract id " <> contractId

{- | Every identifier claimed by more than one package among @packages@: package ids,
exported namespaces, executor projection ids, and contract ids. An empty result means
the packages compose without collision.
-}
packageConflicts :: [WirePackage] -> [PackageConflict]
packageConflicts packages =
  concat
    [ DuplicatePackageId <$> duplicates [package.wpId | package <- packages]
    , DuplicateNamespace
        <$> duplicates [entry.nsNamespace | package <- packages, entry <- package.wpNamespaceEntries]
    , DuplicateExecutorId
        <$> duplicates
          [ wireExecutorIdToText projection.wireExecutorProjectionId
          | package <- packages
          , projection <- package.wpExecutorProjections
          ]
    , DuplicateContractId
        <$> duplicates [spec.wireContractSpecId | package <- packages, spec <- package.wpContractSpecs]
    ]
  where
    duplicates :: Eq a => [a] -> [a]
    duplicates xs = nub [x | x <- xs, length (filter (== x) xs) > 1]
