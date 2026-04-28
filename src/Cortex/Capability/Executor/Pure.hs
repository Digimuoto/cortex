{- |
Module      : Cortex.Capability.Executor.Pure
Description : Host binding for the Wire native pure evaluator.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Wire source authors pure output equations without @. The compiler lowers
those equations to an internal native pure task, and this module turns that
admitted task node into a runnable Pulse stage.

Cortex substrate modules stay consumer-neutral and keep downstream product policy out of this repo.
-}
module Cortex.Capability.Executor.Pure
  ( PureTaskConfig (..)
  , pureExecutorSpec
  , pureTaskConfigFromMetadata
  , bindPureTaskNode
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as AesonTypes
import Data.Int (Int32)
import Data.Map.Strict (Map)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

import Cortex.Capability.Executor
  ( ExecutorBindingAuthority (..)
  , ExecutorCodecBoundary (..)
  , ExecutorConfigDecoder (..)
  , ExecutorSpec (..)
  )
import Cortex.Pulse.Memory.Types (defaultMemoryStrategy)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( StageActionId (..)
  , StageDefinition (..)
  , StageReplaySafety (..)
  , StageResult (..)
  , scInputs
  , scNodeId
  , scRunId
  , stageTemplateId
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..), CircuitTaskNode (..))
import Cortex.Wire.Contract (WireContractRegistry, wirePortsFromMetadataValue)
import Cortex.Wire.Executor (WireExecutorEffect (..))
import Cortex.Wire.Pure
  ( evaluatePureTaskOutputs
  , pureExecutorConfigSchema
  , pureWireExecutorId
  , pureWireExecutorProjection
  , renderPureEvalError
  , validatePurePorts
  )
import Cortex.Wire.Runtime
  ( wireInputBundleFromStageInputs
  , wrapWireStageOutputs
  )
import Cortex.Wire.Syntax (CorePureBinding, CorePureExpr, WirePorts)

data PureTaskConfig = PureTaskConfig
  { pureTaskConfigBindings :: ![CorePureBinding]
  , pureTaskConfigLocalBindings :: ![CorePureBinding]
  , pureTaskConfigOutputs :: !(Map Text CorePureExpr)
  , pureTaskConfigPorts :: !WirePorts
  , pureTaskConfigTimeoutSeconds :: !(Maybe Int32)
  }
  deriving stock (Eq, Show, Generic)

pureExecutorSpec :: ExecutorSpec
pureExecutorSpec =
  ExecutorSpec
    { executorSpecId = pureWireExecutorId
    , executorSpecPorts = pureWireExecutorProjection
    , executorSpecEffect = WireExecutorPure
    , executorSpecConfigDecoder = ExecutorConfigJsonSchema pureExecutorConfigSchema
    , executorSpecRequirements = Set.empty
    , executorSpecCodecBoundary =
        ExecutorCodecBoundary
          { executorCodecInputContracts = Set.empty
          , executorCodecOutputContracts = Set.empty
          }
    , executorSpecBindingAuthority = ExecutorHostBound
    }

pureTaskConfigFromMetadata :: CircuitTaskNode -> Either Text PureTaskConfig
pureTaskConfigFromMetadata taskNode = do
  config <-
    case AesonTypes.parseEither parsePureTaskMetadata taskNode.circuitTaskNodeMetadata of
      Left err -> Left (T.pack err)
      Right parsedConfig -> Right parsedConfig
  case validatePurePorts config.pureTaskConfigPorts config.pureTaskConfigOutputs of
    Left err -> Left (renderPureEvalError err)
    Right () -> Right config

bindPureTaskNode
  :: Maybe WireContractRegistry -> CircuitTaskNode -> Either Text (StageDefinition NodeId)
bindPureTaskNode maybeRegistry taskNode = do
  config <- pureTaskConfigFromMetadata taskNode
  let stageId = nodeIdFromCircuitRef taskNode.circuitTaskNodeRef
  pure
    StageDefinition
      { sdStageId = stageId
      , sdTemplateId = stageTemplateId stageId
      , sdActionId = StageActionId "wire.pure.core-v1"
      , sdReplaySafety = SafeToReplay
      , sdReplayPolicyOverride = Nothing
      , sdTimeoutSeconds = config.pureTaskConfigTimeoutSeconds
      , sdRetryPolicy = Nothing
      , sdAction = \ctx -> do
          let inputBundle = wireInputBundleFromStageInputs ctx.scInputs
          case evaluatePureTaskOutputs
            config.pureTaskConfigPorts
            inputBundle
            config.pureTaskConfigBindings
            config.pureTaskConfigLocalBindings
            config.pureTaskConfigOutputs of
            Left err -> fail (T.unpack (renderPureEvalError err))
            Right outputValues ->
              case wrapWireStageOutputs maybeRegistry ctx.scNodeId ctx.scRunId config.pureTaskConfigPorts outputValues of
                Left err -> fail (T.unpack err)
                Right wrappedValue -> pure (StageComplete wrappedValue)
      , sdMemoryStrategy = defaultMemoryStrategy
      }

nodeIdFromCircuitRef :: CircuitNodeRef -> NodeId
nodeIdFromCircuitRef nodeRef =
  NodeId nodeRef.unCircuitNodeRef

parsePureTaskMetadata :: Aeson.Value -> AesonTypes.Parser PureTaskConfig
parsePureTaskMetadata = Aeson.withObject "Pure task metadata" $ \obj -> do
  executorValue <- obj Aeson..: "executor"
  parsePureExecutor executorValue
  portsValue <- obj Aeson..: "ports"
  ports <-
    case wirePortsFromMetadataValue portsValue of
      Right parsedPorts -> pure parsedPorts
      Left err -> fail (T.unpack err)
  configValue <- obj Aeson..: "config"
  (bindings, localBindings, outputs) <- parsePureConfig configValue
  timeoutSeconds <- obj Aeson..:? "timeoutSeconds"
  pure
    PureTaskConfig
      { pureTaskConfigBindings = bindings
      , pureTaskConfigLocalBindings = localBindings
      , pureTaskConfigOutputs = outputs
      , pureTaskConfigPorts = ports
      , pureTaskConfigTimeoutSeconds = timeoutSeconds
      }

parsePureExecutor :: Aeson.Value -> AesonTypes.Parser ()
parsePureExecutor = Aeson.withObject "Pure executor metadata" $ \obj -> do
  kind <- obj Aeson..: "kind"
  target <- obj Aeson..: "target"
  case (kind :: Text, target :: Text) of
    ("native", "pure") -> pure ()
    _ -> fail "task node does not reference the native pure executor"

parsePureConfig
  :: Aeson.Value -> AesonTypes.Parser ([CorePureBinding], [CorePureBinding], Map Text CorePureExpr)
parsePureConfig = Aeson.withObject "Pure executor config" $ \obj -> do
  let extraKeys =
        [ keyText
        | key <- KeyMap.keys obj
        , let keyText = Key.toText key
        , keyText /= "bindings" && keyText /= "localBindings" && keyText /= "outputs"
        ]
  case extraKeys of
    [] -> do
      bindings <- obj Aeson..:? "bindings" Aeson..!= []
      localBindings <- obj Aeson..:? "localBindings" Aeson..!= []
      outputs <- obj Aeson..: "outputs"
      pure (bindings, localBindings, outputs)
    _ -> fail ("unsupported pure executor config fields: " <> T.unpack (T.intercalate ", " extraKeys))
