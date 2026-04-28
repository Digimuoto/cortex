{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Host binding for the first-slice Wire @pure executor.
--
-- The executor remains registered host authority. Wire source may select and
-- configure @pure, but this module is what turns an admitted task node into a
-- runnable Pulse stage.
module Cortex.Capability.Executor.Pure
  ( PureTaskConfig (..),
    pureExecutorSpec,
    pureTaskConfigFromMetadata,
    bindPureTaskNode,
  )
where

import Cortex.Capability.Executor
  ( ExecutorBindingAuthority (..),
    ExecutorCodecBoundary (..),
    ExecutorConfigDecoder (..),
    ExecutorSpec (..),
  )
import Cortex.Pulse.Memory.Types (defaultMemoryStrategy)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( StageActionId (..),
    StageDefinition (..),
    StageReplaySafety (..),
    StageResult (..),
    scInputs,
    scNodeId,
    scRunId,
    stageTemplateId,
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..), CircuitTaskNode (..))
import Cortex.Wire.Contract (WireContractRegistry, wirePortsFromMetadataValue)
import Cortex.Wire.Executor (WireExecutorEffect (..))
import Cortex.Wire.Pure
  ( evaluatePureTaskOutput,
    pureExecutorConfigSchema,
    pureWireExecutorId,
    pureWireExecutorProjection,
    renderPureEvalError,
  )
import Cortex.Wire.Runtime
  ( wireInputBundleFromStageInputs,
    wrapWireStageResult,
  )
import Cortex.Wire.Syntax (WirePorts)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as AesonTypes
import Data.Int (Int32)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

data PureTaskConfig = PureTaskConfig
  { pureTaskConfigExpression :: !Text,
    pureTaskConfigPorts :: !WirePorts,
    pureTaskConfigTimeoutSeconds :: !(Maybe Int32)
  }
  deriving stock (Eq, Show, Generic)

pureExecutorSpec :: ExecutorSpec
pureExecutorSpec =
  ExecutorSpec
    { executorSpecId = pureWireExecutorId,
      executorSpecPorts = pureWireExecutorProjection,
      executorSpecEffect = WireExecutorPure,
      executorSpecConfigDecoder = ExecutorConfigJsonSchema pureExecutorConfigSchema,
      executorSpecRequirements = Set.empty,
      executorSpecCodecBoundary =
        ExecutorCodecBoundary
          { executorCodecInputContracts = Set.empty,
            executorCodecOutputContracts = Set.empty
          },
      executorSpecBindingAuthority = ExecutorHostBound
    }

pureTaskConfigFromMetadata :: CircuitTaskNode -> Either Text PureTaskConfig
pureTaskConfigFromMetadata taskNode =
  case AesonTypes.parseEither parsePureTaskMetadata taskNode.circuitTaskNodeMetadata of
    Left err -> Left (T.pack err)
    Right config -> Right config

bindPureTaskNode :: Maybe WireContractRegistry -> CircuitTaskNode -> Either Text (StageDefinition NodeId)
bindPureTaskNode maybeRegistry taskNode = do
  config <- pureTaskConfigFromMetadata taskNode
  let stageId = nodeIdFromCircuitRef taskNode.circuitTaskNodeRef
  pure
    StageDefinition
      { sdStageId = stageId,
        sdTemplateId = stageTemplateId stageId,
        sdActionId = StageActionId "wire.pure.numeric-v1",
        sdReplaySafety = SafeToReplay,
        sdReplayPolicyOverride = Nothing,
        sdTimeoutSeconds = config.pureTaskConfigTimeoutSeconds,
        sdRetryPolicy = Nothing,
        sdAction = \ctx -> do
          let inputBundle = wireInputBundleFromStageInputs ctx.scInputs
          case evaluatePureTaskOutput config.pureTaskConfigPorts inputBundle config.pureTaskConfigExpression of
            Left err -> fail (T.unpack (renderPureEvalError err))
            Right outputValue ->
              case wrapWireStageResult maybeRegistry ctx.scNodeId ctx.scRunId config.pureTaskConfigPorts (StageComplete outputValue) of
                Left err -> fail (T.unpack err)
                Right wrappedResult -> pure wrappedResult,
        sdMemoryStrategy = defaultMemoryStrategy
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
  expressionText <- parsePureConfig configValue
  timeoutSeconds <- obj Aeson..:? "timeoutSeconds"
  pure
    PureTaskConfig
      { pureTaskConfigExpression = expressionText,
        pureTaskConfigPorts = ports,
        pureTaskConfigTimeoutSeconds = timeoutSeconds
      }

parsePureExecutor :: Aeson.Value -> AesonTypes.Parser ()
parsePureExecutor = Aeson.withObject "Pure executor metadata" $ \obj -> do
  kind <- obj Aeson..: "kind"
  target <- obj Aeson..: "target"
  case (kind :: Text, target :: Text) of
    ("native", "pure") -> pure ()
    _ -> fail "task node does not reference the native pure executor"

parsePureConfig :: Aeson.Value -> AesonTypes.Parser Text
parsePureConfig = Aeson.withObject "Pure executor config" $ \obj -> do
  let extraKeys =
        [ keyText
        | key <- KeyMap.keys obj,
          let keyText = Key.toText key,
          keyText /= "expr"
        ]
  case extraKeys of
    [] -> obj Aeson..: "expr"
    _ -> fail ("unsupported pure executor config fields: " <> T.unpack (T.intercalate ", " extraKeys))
