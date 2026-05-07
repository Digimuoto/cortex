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
  , stdIoReadFileExecutorId
  , stdIoWriteFileExecutorId
  , stdIoExecutorLeaves
  , stdIoExecutorIds
  , stdIoExecutorIdForLeaf
  , isStdIoExecutorId
  , stdIoCommandShapeMessage
  , stdIoCommandSpecContractId
  , stdIoCommandResultContractId
  , stdIoReadFileShapeMessage
  , stdIoStdinShapeMessage
  , stdIoStdoutShapeMessage
  , stdIoWriteFileShapeMessage
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

stdIoReadFileExecutorId :: Text
stdIoReadFileExecutorId = "std.io.readFile"

stdIoWriteFileExecutorId :: Text
stdIoWriteFileExecutorId = "std.io.writeFile"

-- Leaf names are authored inside `use std.io.{...}`; canonical ids are the
-- executor targets stored in compiled artifacts and runtime registries.
stdIoExecutorLeaves :: Set Text
stdIoExecutorLeaves =
  Set.fromList ["stdin", "stdout", "command", "readFile", "writeFile"]

stdIoExecutorIds :: Set Text
stdIoExecutorIds =
  Set.fromList
    [ stdIoStdinExecutorId
    , stdIoStdoutExecutorId
    , stdIoCommandExecutorId
    , stdIoReadFileExecutorId
    , stdIoWriteFileExecutorId
    ]

stdIoExecutorIdForLeaf :: Text -> Maybe Text
stdIoExecutorIdForLeaf = \case
  "stdin" -> Just stdIoStdinExecutorId
  "stdout" -> Just stdIoStdoutExecutorId
  "command" -> Just stdIoCommandExecutorId
  "readFile" -> Just stdIoReadFileExecutorId
  "writeFile" -> Just stdIoWriteFileExecutorId
  _ -> Nothing

isStdIoExecutorId :: Text -> Bool
isStdIoExecutorId executorId =
  executorId `Set.member` stdIoExecutorIds

stdIoStdinShapeMessage :: Text
stdIoStdinShapeMessage =
  "std.io.stdin expects zero input ports and exactly one output port."

stdIoStdoutShapeMessage :: Text
stdIoStdoutShapeMessage =
  "std.io.stdout expects exactly one input port and zero output ports."

stdIoCommandShapeMessage :: Text
stdIoCommandShapeMessage =
  "std.io.command expects zero or one input port and zero or one output port."

stdIoReadFileShapeMessage :: Text
stdIoReadFileShapeMessage =
  "std.io.readFile expects zero or one input port and exactly one output port."

stdIoWriteFileShapeMessage :: Text
stdIoWriteFileShapeMessage =
  "std.io.writeFile expects exactly one input port and zero output ports."

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
      , wireContractSpecRecordFields = Nothing
      , wireContractSpecSchema = Nothing
      , wireContractSpecExamples = []
      }
  , WireContractSpec
      { wireContractSpecId = stdIoCommandResultContractId
      , wireContractSpecPayloadKind = WirePayloadJson
      , wireContractSpecDescription = "Standard argv-based local command result."
      , wireContractSpecRecordFields = Nothing
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
  , stdIoProjection stdIoReadFileExecutorId
  , stdIoProjection stdIoWriteFileExecutorId
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
