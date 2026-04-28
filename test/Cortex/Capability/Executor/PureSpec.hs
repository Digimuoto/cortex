{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Capability.Executor.PureSpec (spec) where

import Cortex.Capability.Executor (ExecutorSpec (..))
import Cortex.Capability.Executor.Pure
  ( bindPureTaskNode,
    pureExecutorSpec,
  )
import Cortex.Pulse.Memory (defaultMemoryStrategy, discardMemoryHandle)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( StageContext (..),
    StageDefinition (..),
    StageReplaySafety (..),
    StageResult (..),
  )
import Cortex.Pulse.Rewrite (BudgetContext (..))
import Cortex.Pulse.Types (defaultRewriteBudget)
import Cortex.Wire
  ( WirePayloadKind (..),
    WireValue (..),
    mkWireValue,
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..), CircuitTaskNode (..))
import Cortex.Wire.Contract
  ( WireContractRegistry,
    WireContractSpec (..),
    portsMetadataValue,
    wireContractRegistryFromList,
  )
import Cortex.Wire.Executor (WireExecutorEffect (..))
import Cortex.Wire.Syntax
  ( WireInputCardinality (..),
    WireInputPort (..),
    WireOutputPort (..),
    WirePorts (..),
  )
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Scientific (scientific)
import Data.Text (Text)
import Data.UUID qualified as UUID
import Test.Hspec

spec :: Spec
spec = describe "Cortex.Capability.Executor.Pure" $ do
  it "exports pure executor authority as an inert pure spec" $
    pureExecutorSpec.executorSpecEffect `shouldBe` WireExecutorPure

  it "binds a pure task node to a safe replay Pulse stage" $ do
    stageDef <- requireRight (bindPureTaskNode (Just floatContractRegistry) weightedTaskNode)
    stageDef.sdStageId `shouldBe` NodeId "weighted_score"
    stageDef.sdReplaySafety `shouldBe` SafeToReplay

  it "evaluates and wraps pure stage output with the declared contract" $ do
    stageDef <- requireRight (bindPureTaskNode (Just floatContractRegistry) weightedTaskNode)
    result <- stageDef.sdAction weightedStageContext
    case result of
      StageComplete value -> do
        wireValue <- requireAesonSuccess (Aeson.fromJSON value :: Aeson.Result WireValue)
        wireValue.wireValueContract `shouldBe` "Float"
        wireValue.wireValuePort `shouldBe` Just "out"
        wireValue.wireValuePayloadKind `shouldBe` WirePayloadJson
        wireValue.wireValueValue `shouldBe` Aeson.Number (scientific 68 (-2))
      other ->
        expectationFailure ("expected StageComplete, got " <> showStageResult other)

  it "rejects output payload-kind mismatches through the wrapper path" $ do
    stageDef <- requireRight (bindPureTaskNode (Just textFloatContractRegistry) weightedTaskNode)
    stageDef.sdAction weightedStageContext `shouldThrow` anyException

weightedTaskNode :: CircuitTaskNode
weightedTaskNode =
  CircuitTaskNode
    { circuitTaskNodeRef = CircuitNodeRef "weighted_score",
      circuitTaskNodeLabel = "weighted_score",
      circuitTaskNodeKind = Nothing,
      circuitTaskNodeMetadata =
        Aeson.object
          [ "executor" Aeson..= Aeson.object ["kind" Aeson..= ("native" :: Text), "target" Aeson..= ("pure" :: Text)],
            "ports" Aeson..= portsMetadataValue weightedPorts,
            "config"
              Aeson..= Aeson.object
                [ "expr"
                    Aeson..= ( "0.5 * evidence_score + 0.3 * recency_score + 0.2 * authority_score" ::
                                 Text
                             )
                ]
          ]
    }

weightedPorts :: WirePorts
weightedPorts =
  WirePorts
    { wirePortsInputs =
        Map.fromList
          [ labeledFloatInput "evidence_score",
            labeledFloatInput "recency_score",
            labeledFloatInput "authority_score"
          ],
      wirePortsOutputs =
        Map.singleton "out" WireOutputPort {wireOutputPortContract = "Float"}
    }

labeledFloatInput :: Text -> (Text, WireInputPort)
labeledFloatInput portName =
  ( portName,
    WireInputPort
      { wireInputPortAccepts = ["Float"],
        wireInputPortCardinality = WireInputCardinalityOne,
        wireInputPortRequired = False
      }
  )

weightedStageContext :: StageContext
weightedStageContext =
  StageContext
    { scRunId = UUID.nil,
      scNodeId = NodeId "weighted_score",
      scInputs =
        Map.fromList
          [ (NodeId "evidence", wireValue "evidence_score" (scientific 8 (-1))),
            (NodeId "recency", wireValue "recency_score" (scientific 6 (-1))),
            (NodeId "authority", wireValue "authority_score" (scientific 5 (-1)))
          ],
      scAttempt = 1,
      scBudgetContext =
        BudgetContext
          { bcInitialBudget = defaultRewriteBudget,
            bcRemainingBudget = defaultRewriteBudget
          },
      scRewriteRejection = Nothing,
      scRetryFailure = Nothing,
      scMemory = discardMemoryHandle,
      scMemoryStrategy = defaultMemoryStrategy
    }
  where
    wireValue portName number =
      Aeson.toJSON
        ( (mkWireValue "Float" WirePayloadJson (Just portName) (Aeson.Number number))
            { wireValuePort = Just portName
            }
        )

floatContractRegistry :: WireContractRegistry
floatContractRegistry =
  wireContractRegistryFromList [contractSpec WirePayloadJson]

textFloatContractRegistry :: WireContractRegistry
textFloatContractRegistry =
  wireContractRegistryFromList [contractSpec WirePayloadText]

contractSpec :: WirePayloadKind -> WireContractSpec
contractSpec payloadKind =
  WireContractSpec
    { wireContractSpecId = "Float",
      wireContractSpecPayloadKind = payloadKind,
      wireContractSpecDescription = "Float",
      wireContractSpecSchema = Nothing,
      wireContractSpecExamples = []
    }

requireRight :: (Show err) => Either err a -> IO a
requireRight = \case
  Right value -> pure value
  Left err -> fail ("expected Right, got " <> show err)

requireAesonSuccess :: Aeson.Result a -> IO a
requireAesonSuccess = \case
  Aeson.Success value -> pure value
  Aeson.Error err -> fail ("expected Aeson.Success, got " <> err)

showStageResult :: StageResult NodeId -> String
showStageResult = \case
  StageComplete {} -> "StageComplete"
  StageSuspend {} -> "StageSuspend"
  StageRewrite {} -> "StageRewrite"
  StageRejectRewrite {} -> "StageRejectRewrite"
