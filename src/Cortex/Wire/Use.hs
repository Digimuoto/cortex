{- |
Module      : Cortex.Wire.Use
Description : Shared Wire registry use-scope resolution.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Wire `use` declarations are source-scope declarations. Compilation and local
execution both consume the same resolved scope so registry import semantics do
not drift between build and run paths.
-}
module Cortex.Wire.Use
  ( WireUseError (..)
  , WireUseScope (..)
  , applyWireUseSpec
  , applyWireUseSpecs
  , emptyWireUseScope
  , resolveWireContract
  , resolveWireExecutorQName
  , wireUseDeclaredContracts
  )
where

import Control.Monad (foldM, when)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

import Cortex.Wire.Std
  ( stdIoContractIdForName
  , stdIoExecutorIdForLeaf
  , stdIoExecutorIds
  , stdIoExecutorLeaves
  , stdIoNamespace
  )
import Cortex.Wire.Syntax
  ( QName (..)
  , UseItem (..)
  , UseSpec (..)
  , renderQName
  )

data WireUseError
  = WireUseUnknownNamespace !Text
  | WireUseUnknownItem !Text !Text
  | WireUseDuplicateBinding !Text
  deriving stock (Eq, Show)

data WireUseScope = WireUseScope
  { wireUseExecutors :: !(Map Text Text)
  , wireUseContracts :: !(Map Text Text)
  , wireUseStdExecutorsInScope :: !(Set Text)
  }
  deriving stock (Eq, Show)

emptyWireUseScope :: WireUseScope
emptyWireUseScope =
  WireUseScope
    { wireUseExecutors = Map.empty
    , wireUseContracts = Map.empty
    , wireUseStdExecutorsInScope = Set.empty
    }

applyWireUseSpecs :: (Text -> Bool) -> [UseSpec] -> Either WireUseError WireUseScope
applyWireUseSpecs externalNameTaken =
  foldM (applyWireUseSpec externalNameTaken) emptyWireUseScope

applyWireUseSpec
  :: (Text -> Bool) -> WireUseScope -> UseSpec -> Either WireUseError WireUseScope
applyWireUseSpec externalNameTaken scope useSpec = do
  when (renderQName useSpec.useSpecNamespace /= stdIoNamespace) $
    Left (WireUseUnknownNamespace (renderQName useSpec.useSpecNamespace))
  foldM lowerUseItem scope (NE.toList useSpec.useSpecItems)
  where
    lowerUseItem state = \case
      UseExecutor itemName maybeAlias -> do
        canonical <- stdIoExecutorId itemName
        let localName = fromMaybe itemName maybeAlias
        ensureUseNameFresh localName state
        Right
          state
            { wireUseExecutors = Map.insert localName canonical state.wireUseExecutors
            , wireUseStdExecutorsInScope =
                Set.insert canonical state.wireUseStdExecutorsInScope
            }
      UseContract itemName maybeAlias -> do
        canonical <- stdIoContractId itemName
        let localName = fromMaybe itemName maybeAlias
        ensureUseNameFresh localName state
        Right
          state
            { wireUseContracts = Map.insert localName canonical state.wireUseContracts
            }

    ensureUseNameFresh localName state =
      when (wireUseLocalNameTaken externalNameTaken state localName) $
        Left (WireUseDuplicateBinding localName)

wireUseLocalNameTaken :: (Text -> Bool) -> WireUseScope -> Text -> Bool
wireUseLocalNameTaken externalNameTaken scope localName =
  externalNameTaken localName
    || Map.member localName scope.wireUseExecutors
    || Map.member localName scope.wireUseContracts

stdIoExecutorId :: Text -> Either WireUseError Text
stdIoExecutorId itemName =
  maybe
    (Left (WireUseUnknownItem stdIoNamespace ("@" <> itemName)))
    Right
    (stdIoExecutorIdForLeaf itemName)

stdIoContractId :: Text -> Either WireUseError Text
stdIoContractId itemName =
  maybe
    (Left (WireUseUnknownItem stdIoNamespace itemName))
    Right
    (stdIoContractIdForName itemName)

wireUseDeclaredContracts :: WireUseScope -> Set Text
wireUseDeclaredContracts scope =
  Set.fromList (Map.elems scope.wireUseContracts)

resolveWireContract :: WireUseScope -> Text -> Text
resolveWireContract scope contractName =
  Map.findWithDefault contractName contractName scope.wireUseContracts

resolveWireExecutorQName :: WireUseScope -> QName -> Either Text Text
resolveWireExecutorQName scope qname@(QName segments) =
  case segments of
    localName NE.:| []
      | Just canonical <- Map.lookup localName scope.wireUseExecutors ->
          Right canonical
      | Set.member localName stdIoExecutorLeaves ->
          Left ("@" <> localName)
      | otherwise ->
          Right rendered
    _
      | Set.member rendered stdIoExecutorIds ->
          if Set.member rendered scope.wireUseStdExecutorsInScope
            then Right rendered
            else Left ("@" <> rendered)
      | otherwise ->
          Right rendered
  where
    rendered = renderQName qname
