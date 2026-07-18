{- |
Module      : Cortex.Capability.Executor.Pure
Description : Host binding for the Wire native pure evaluator.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Wire source authors CorePure output equations without @. The compiler lowers
those equations to an internal native pure task, and this module turns that
admitted task node into a runnable Pulse stage.

Cortex substrate modules stay consumer-neutral and keep downstream product policy out of this repo.
-}
module Cortex.Capability.Executor.Pure
  ( PureTaskConfig (..)
  , PureVariantConfig (..)
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
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

import Cortex.Capability.Executor
  ( ExecutorArgumentDecoder (..)
  , ExecutorBindingAuthority (..)
  , ExecutorCodecBoundary (..)
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
  , evaluatePureTaskVariant
  , pureExecutorArgumentSchema
  , pureWireExecutorId
  , pureWireExecutorProjection
  , renderPureEvalError
  , validatePureTaskConfig
  , validatePureVariantTaskConfig
  )
import Cortex.Wire.Runtime
  ( wireInputBundleFromStageInputs
  , wrapWireStageOutputs
  )
import Cortex.Wire.Syntax (CorePureBinding, CorePureExpr, WirePorts)

data PureTaskConfig = PureTaskConfig
  { pureTaskConfigBindings :: ![CorePureBinding]
  , pureTaskConfigWhere :: !(Maybe CorePureExpr)
  , pureTaskConfigOutputs :: !(Map Text CorePureExpr)
  , pureTaskConfigVariant :: !(Maybe PureVariantConfig)
  , pureTaskConfigPorts :: !WirePorts
  , pureTaskConfigTimeoutSeconds :: !(Maybe Int32)
  }
  deriving stock (Eq, Show, Generic)

data PureVariantConfig = PureVariantConfig
  { pureVariantConfigLabels :: ![Text]
  , pureVariantConfigExpression :: !CorePureExpr
  }
  deriving stock (Eq, Show, Generic)

pureExecutorSpec :: ExecutorSpec
pureExecutorSpec =
  ExecutorSpec
    { executorSpecId = pureWireExecutorId
    , executorSpecPorts = pureWireExecutorProjection
    , executorSpecEffect = WireExecutorPure
    , executorSpecArgumentDecoder = ExecutorArgumentJsonSchema pureExecutorArgumentSchema
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
  case validateConfig config of
    Left err -> Left (renderPureEvalError err)
    Right () -> Right config
  where
    validateConfig config =
      case config.pureTaskConfigVariant of
        Nothing ->
          validatePureTaskConfig
            config.pureTaskConfigPorts
            config.pureTaskConfigBindings
            config.pureTaskConfigWhere
            config.pureTaskConfigOutputs
        Just variant ->
          validatePureVariantTaskConfig
            config.pureTaskConfigPorts
            config.pureTaskConfigBindings
            config.pureTaskConfigWhere
            variant.pureVariantConfigLabels
            variant.pureVariantConfigExpression

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
          case evaluateConfig config inputBundle of
            Left err -> fail (T.unpack (renderPureEvalError err))
            Right outputValues ->
              case wrapWireStageOutputs maybeRegistry ctx.scNodeId ctx.scRunId config.pureTaskConfigPorts outputValues of
                Left err -> fail (T.unpack err)
                Right wrappedValue -> pure (StageComplete wrappedValue)
      , sdMemoryStrategy = defaultMemoryStrategy
      }
  where
    evaluateConfig config inputBundle =
      case config.pureTaskConfigVariant of
        Nothing ->
          evaluatePureTaskOutputs
            config.pureTaskConfigPorts
            inputBundle
            config.pureTaskConfigBindings
            config.pureTaskConfigWhere
            config.pureTaskConfigOutputs
        Just variant ->
          evaluatePureTaskVariant
            config.pureTaskConfigPorts
            inputBundle
            config.pureTaskConfigBindings
            config.pureTaskConfigWhere
            variant.pureVariantConfigLabels
            variant.pureVariantConfigExpression

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
  (bindings, whereExpr, outputs, variant) <- parsePureConfig configValue
  timeoutSeconds <- obj Aeson..:? "timeoutSeconds"
  pure
    PureTaskConfig
      { pureTaskConfigBindings = bindings
      , pureTaskConfigWhere = whereExpr
      , pureTaskConfigOutputs = outputs
      , pureTaskConfigVariant = variant
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
  :: Aeson.Value
  -> AesonTypes.Parser
       ([CorePureBinding], Maybe CorePureExpr, Map Text CorePureExpr, Maybe PureVariantConfig)
parsePureConfig = Aeson.withObject "Pure executor config" $ \obj -> do
  let extraKeys =
        [ keyText
        | key <- KeyMap.keys obj
        , let keyText = Key.toText key
        , keyText /= "bindings" && keyText /= "where" && keyText /= "outputs" && keyText /= "variant"
        ]
  case extraKeys of
    [] -> do
      bindings <- obj Aeson..:? "bindings" Aeson..!= []
      whereExpr <- obj Aeson..:? "where"
      outputs <- obj Aeson..:? "outputs"
      variant <- obj Aeson..:? "variant" >>= traverse parseVariantConfig
      case (outputs, variant) of
        (Just outputMap, Nothing) -> pure (bindings, whereExpr, outputMap, Nothing)
        (Nothing, Just variantConfig) -> pure (bindings, whereExpr, Map.empty, Just variantConfig)
        _ -> fail "pure executor config requires exactly one of outputs or variant"
    _ -> fail ("unsupported pure executor config fields: " <> T.unpack (T.intercalate ", " extraKeys))

parseVariantConfig :: Aeson.Value -> AesonTypes.Parser PureVariantConfig
parseVariantConfig = Aeson.withObject "Pure variant config" $ \obj -> do
  let keys = Set.fromList (fmap Key.toText (KeyMap.keys obj))
  if keys /= Set.fromList ["labels", "expression"]
    then fail "pure variant config fields must be exactly labels and expression"
    else PureVariantConfig <$> obj Aeson..: "labels" <*> obj Aeson..: "expression"
