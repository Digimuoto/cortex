{- |
Module      : Cortex.Wire.Std
Description : Standard Wire namespaces, contracts, and executor projections.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

The standard catalog is a source-level dependency vocabulary. Hosts still decide
which executor bodies are bound at runtime through their executor registries.
-}
module Cortex.Wire.Std
  ( stdIoNamespace
  , stdIoStdinExecutorId
  , stdIoStdoutExecutorId
  , stdIoCommandExecutorId
  , stdIoExecutorLeaves
  , stdIoExecutorIdForLeaf
  , isStdIoExecutorId
  , stdIoCommandSpecContractId
  , stdIoCommandResultContractId
  , stdIoContractIdForName
  , stdIoContractSpecs
  , stdIoContractRegistry
  , stdIoExecutorProjections
  , stdIoExecutorRegistry
  , stdIoCompileEnv
  )
where

import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)

import Cortex.Wire.AST (WirePorts (..))
import Cortex.Wire.Contract
  ( WireCompileEnv (..)
  , WireContractRegistry
  , WireContractSpec (..)
  , WireProjectionMode (..)
  , emptyWireCompileEnv
  , wireContractRegistryFromList
  )
import Cortex.Wire.Executor
  ( WireExecutorConfigShape (..)
  , WireExecutorEffect (..)
  , WireExecutorId (..)
  , WireExecutorPortPolicy (..)
  , WireExecutorProjection (..)
  , WireExecutorRegistry
  , wireExecutorRegistryFromList
  )
import Cortex.Wire.Value (WirePayloadKind (..))

stdIoNamespace :: Text
stdIoNamespace = "std.io"

stdIoStdinExecutorId :: Text
stdIoStdinExecutorId = "std.io.stdin"

stdIoStdoutExecutorId :: Text
stdIoStdoutExecutorId = "std.io.stdout"

stdIoCommandExecutorId :: Text
stdIoCommandExecutorId = "std.io.command"

stdIoExecutorLeaves :: Set Text
stdIoExecutorLeaves =
  Set.fromList ["stdin", "stdout", "command"]

stdIoExecutorIdForLeaf :: Text -> Maybe Text
stdIoExecutorIdForLeaf = \case
  "stdin" -> Just stdIoStdinExecutorId
  "stdout" -> Just stdIoStdoutExecutorId
  "command" -> Just stdIoCommandExecutorId
  _ -> Nothing

isStdIoExecutorId :: Text -> Bool
isStdIoExecutorId executorId =
  executorId
    `Set.member` Set.fromList
      [ stdIoStdinExecutorId
      , stdIoStdoutExecutorId
      , stdIoCommandExecutorId
      ]

stdIoCommandSpecContractId :: Text
stdIoCommandSpecContractId = "std.io.CommandSpec.v1"

stdIoCommandResultContractId :: Text
stdIoCommandResultContractId = "std.io.CommandResult.v1"

stdIoContractIdForName :: Text -> Maybe Text
stdIoContractIdForName = \case
  "CommandSpec" -> Just stdIoCommandSpecContractId
  "CommandResult" -> Just stdIoCommandResultContractId
  _ -> Nothing

stdIoContractSpecs :: [WireContractSpec]
stdIoContractSpecs =
  [ WireContractSpec
      { wireContractSpecId = stdIoCommandSpecContractId
      , wireContractSpecPayloadKind = WirePayloadJson
      , wireContractSpecDescription = "Standard argv-based local command request."
      , wireContractSpecSchema = Nothing
      , wireContractSpecExamples = []
      }
  , WireContractSpec
      { wireContractSpecId = stdIoCommandResultContractId
      , wireContractSpecPayloadKind = WirePayloadJson
      , wireContractSpecDescription = "Standard argv-based local command result."
      , wireContractSpecSchema = Nothing
      , wireContractSpecExamples = []
      }
  ]

stdIoContractRegistry :: WireContractRegistry
stdIoContractRegistry =
  wireContractRegistryFromList stdIoContractSpecs

stdIoExecutorProjections :: [WireExecutorProjection]
stdIoExecutorProjections =
  [ stdIoProjection stdIoStdinExecutorId
  , stdIoProjection stdIoStdoutExecutorId
  , stdIoProjection stdIoCommandExecutorId
  ]

stdIoExecutorRegistry :: WireExecutorRegistry
stdIoExecutorRegistry =
  wireExecutorRegistryFromList stdIoExecutorProjections

stdIoCompileEnv :: WireCompileEnv
stdIoCompileEnv =
  emptyWireCompileEnv
    { wireCompileEnvExecutorRegistry = stdIoExecutorRegistry
    , wireCompileEnvProjectionMode = WireProjectionPermissive
    , wireCompileEnvContractRegistry = Just stdIoContractRegistry
    }

stdIoProjection :: Text -> WireExecutorProjection
stdIoProjection executorId =
  WireExecutorProjection
    { wireExecutorProjectionId = WireExecutorId executorId
    , wireExecutorProjectionPorts = emptyStdIoPorts
    , wireExecutorProjectionVocabulary =
        Set.fromList
          [ stdIoCommandSpecContractId
          , stdIoCommandResultContractId
          ]
    , wireExecutorProjectionEffect = WireExecutorHostEffect
    , wireExecutorProjectionConfigShape = WireExecutorConfigUnchecked
    , wireExecutorProjectionPortPolicy = WireExecutorAuthorDeclaredPorts
    }

emptyStdIoPorts :: WirePorts
emptyStdIoPorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs = Map.empty
    }
