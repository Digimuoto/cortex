{- |
Module      : Cortex.Capability.Executor.PureSpec
Description : Tests for Cortex.Capability.Executor.Pure.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Capability.Executor.PureSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific, scientific)
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Test.Hspec

import Cortex.Capability.Executor (ExecutorSpec (..), executorProjectionRegistry)
import Cortex.Capability.Executor.Pure
  ( bindPureTaskNode
  , pureExecutorSpec
  )
import Cortex.Pulse.Memory (defaultMemoryStrategy, discardMemoryHandle)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( StageContext (..)
  , StageDefinition (..)
  , StageReplaySafety (..)
  , StageResult (..)
  )
import Cortex.Pulse.Rewrite (BudgetContext (..))
import Cortex.Pulse.Types (defaultRewriteBudget)
import Cortex.Wire
  ( CorePureBinOp (..)
  , CorePureExpr (..)
  , CorePureField (..)
  , CorePureLiteral (..)
  , WirePayloadKind (..)
  , WireValue (..)
  , WireValueSet (..)
  , mkWireValue
  )
import Cortex.Wire.Circuit.Artifact
  ( CompiledCircuit (..)
  , CompiledCircuitNode (..)
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..), CircuitTaskNode (..))
import Cortex.Wire.Compile (compileWireTextWithEnv)
import Cortex.Wire.Contract
  ( WireCompileEnv
  , WireContractRegistry
  , WireContractSpec (..)
  , portsMetadataValue
  , strictWireCompileEnv
  , wireContractRegistryFromList
  )
import Cortex.Wire.Executor (WireExecutorEffect (..))
import Cortex.Wire.Syntax
  ( WireInputCardinality (..)
  , WireInputPort (..)
  , WireOutputPort (..)
  , WirePorts (..)
  )

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
        wireValue <- requireSingleWireValue value
        wireValue.wireValueContract `shouldBe` "Float"
        wireValue.wireValuePort `shouldBe` Just "out"
        wireValue.wireValuePayloadKind `shouldBe` WirePayloadJson
        wireValue.wireValueValue `shouldBe` Aeson.Number (scientific 68 (-2))
      other ->
        expectationFailure ("expected StageComplete, got " <> showStageResult other)

  it "decodes node-local where records from task metadata" $ do
    stageDef <- requireRight (bindPureTaskNode (Just floatContractRegistry) whereTaskNode)
    result <- stageDef.sdAction weightedStageContext
    case result of
      StageComplete value -> do
        wireValue <- requireSingleWireValue value
        wireValue.wireValueContract `shouldBe` "Float"
        wireValue.wireValuePort `shouldBe` Just "out"
        wireValue.wireValuePayloadKind `shouldBe` WirePayloadJson
        wireValue.wireValueValue `shouldBe` Aeson.Number (scientific 68 (-2))
      other ->
        expectationFailure ("expected StageComplete, got " <> showStageResult other)

  it "compiles, binds, and deterministically runs a strict pure Wire node" $ do
    compiled <- requireRight (compileWireTextWithEnv pureCompileEnv pureSourceText)
    taskNode <- requireCompiledTask "score" compiled
    stageDef <- requireRight (bindPureTaskNode (Just floatContractRegistry) taskNode)
    first <- stageDef.sdAction scoreStageContext
    second <- stageDef.sdAction scoreStageContext
    case (first, second) of
      (StageComplete firstValue, StageComplete secondValue) -> do
        firstValue `shouldBe` secondValue
        wireValue <- requireSingleWireValue firstValue
        wireValue.wireValueContract `shouldBe` "Float"
        wireValue.wireValuePort `shouldBe` Just "out"
        wireValue.wireValuePayloadKind `shouldBe` WirePayloadJson
        wireValue.wireValueValue `shouldBe` Aeson.Number (scientific 14 (-1))
      (firstResult, secondResult) ->
        expectationFailure
          ( "expected two StageComplete results, got "
              <> showStageResult firstResult
              <> " and "
              <> showStageResult secondResult
          )

  it "evaluates exactly one declared pure sum constructor" $ do
    compiled <- requireRight (compileWireTextWithEnv pureCompileEnv pureSumSourceText)
    taskNode <- requireCompiledTask "classify" compiled
    stageDef <- requireRight (bindPureTaskNode (Just floatContractRegistry) taskNode)
    result <- stageDef.sdAction pureSumStageContext
    case result of
      StageComplete value -> do
        wireValue <- requireAesonSuccess (Aeson.fromJSON value :: Aeson.Result WireValue)
        wireValue.wireValuePort `shouldBe` Just "accepted"
        wireValue.wireValueContract `shouldBe` "Float"
        wireValue.wireValueValue `shouldBe` Aeson.Number (scientific 8 (-1))
      other -> expectationFailure ("expected StageComplete, got " <> showStageResult other)

  it "does not force the non-selected pure sum branch" $ do
    compiled <-
      requireRight
        ( compileWireTextWithEnv
            pureCompileEnv
            ( pureSumProgram
                "if evidence_score >= 0 then accepted evidence_score else rejected (trim evidence_score)"
            )
        )
    taskNode <- requireCompiledTask "classify" compiled
    stageDef <- requireRight (bindPureTaskNode (Just floatContractRegistry) taskNode)
    result <- stageDef.sdAction pureSumStageContext
    case result of
      StageComplete value -> do
        wireValue <- requireAesonSuccess (Aeson.fromJSON value :: Aeson.Result WireValue)
        wireValue.wireValuePort `shouldBe` Just "accepted"
      other -> expectationFailure ("expected StageComplete, got " <> showStageResult other)

  it "rejects pure sum paths that do not return a declared constructor" $
    compileWireTextWithEnv
      pureCompileEnv
      (pureSumProgram "if evidence_score >= 0 then evidence_score else rejected evidence_score")
      `shouldSatisfy` leftContains "Every pure sum control-flow path must return"

  it "rejects pure sum constructors with the wrong arity" $
    compileWireTextWithEnv
      pureCompileEnv
      ( pureSumProgram
          "if evidence_score >= 0 then accepted evidence_score evidence_score else rejected evidence_score"
      )
      `shouldSatisfy` leftContains "requires exactly one payload argument"

  it "rejects bindings that shadow pure sum constructor labels" $
    compileWireTextWithEnv
      pureCompileEnv
      (pureSumProgram "let accepted = x: x; in accepted evidence_score")
      `shouldSatisfy` leftContains "constructor label accepted is shadowed"

  it "rejects invalid pure port declarations before binding a stage" $
    case bindPureTaskNode (Just floatContractRegistry) noOutputTaskNode of
      Left err ->
        err
          `shouldBe` "Pure output equations must match output ports exactly. Expected [], got [out]."
      Right _ ->
        expectationFailure "expected pure task binding to reject missing output ports"

  it "rejects output payload-kind mismatches through the wrapper path" $ do
    stageDef <- requireRight (bindPureTaskNode (Just textFloatContractRegistry) weightedTaskNode)
    stageDef.sdAction weightedStageContext `shouldThrow` anyException

weightedTaskNode :: CircuitTaskNode
weightedTaskNode =
  CircuitTaskNode
    { circuitTaskNodeRef = CircuitNodeRef "weighted_score"
    , circuitTaskNodeLabel = "weighted_score"
    , circuitTaskNodeMetadata =
        Aeson.object
          [ "executor"
              Aeson..= Aeson.object ["kind" Aeson..= ("native" :: Text), "target" Aeson..= ("pure" :: Text)]
          , "ports" Aeson..= portsMetadataValue weightedPorts
          , "config"
              Aeson..= Aeson.object
                [ "outputs" Aeson..= Map.singleton ("out" :: Text) weightedExpression
                ]
          ]
    }

whereTaskNode :: CircuitTaskNode
whereTaskNode =
  weightedTaskNode
    { circuitTaskNodeMetadata =
        Aeson.object
          [ "executor"
              Aeson..= Aeson.object ["kind" Aeson..= ("native" :: Text), "target" Aeson..= ("pure" :: Text)]
          , "ports" Aeson..= portsMetadataValue weightedPorts
          , "config"
              Aeson..= Aeson.object
                [ "where" Aeson..= CorePureRecord [CorePureField ("weighted" :| []) weightedExpression]
                , "outputs" Aeson..= Map.singleton ("out" :: Text) (var "weighted")
                ]
          ]
    }

noOutputTaskNode :: CircuitTaskNode
noOutputTaskNode =
  weightedTaskNode
    { circuitTaskNodeMetadata =
        Aeson.object
          [ "executor"
              Aeson..= Aeson.object ["kind" Aeson..= ("native" :: Text), "target" Aeson..= ("pure" :: Text)]
          , "ports" Aeson..= portsMetadataValue (weightedPorts {wirePortsOutputs = Map.empty})
          , "config"
              Aeson..= Aeson.object
                [ "outputs" Aeson..= Map.singleton ("out" :: Text) weightedExpression
                ]
          ]
    }

weightedExpression :: CorePureExpr
weightedExpression =
  bin
    CorePureAdd
    ( bin
        CorePureAdd
        (bin CorePureMultiply (num (scientific 5 (-1))) (var "evidence_score"))
        (bin CorePureMultiply (num (scientific 3 (-1))) (var "recency_score"))
    )
    (bin CorePureMultiply (num (scientific 2 (-1))) (var "authority_score"))

weightedPorts :: WirePorts
weightedPorts =
  WirePorts
    { wirePortsInputs =
        Map.fromList
          [ labeledFloatInput "evidence_score"
          , labeledFloatInput "recency_score"
          , labeledFloatInput "authority_score"
          ]
    , wirePortsOutputs =
        Map.singleton
          "out"
          WireOutputPort {wireOutputPortContract = "Float", wireOutputPortExclusiveGroup = Nothing}
    }

labeledFloatInput :: Text -> (Text, WireInputPort)
labeledFloatInput portName =
  ( portName
  , WireInputPort
      { wireInputPortAccepts = ["Float"]
      , wireInputPortCardinality = WireInputCardinalityOne
      , wireInputPortRequired = False
      }
  )

weightedStageContext :: StageContext
weightedStageContext =
  StageContext
    { scRunId = UUID.nil
    , scNodeId = NodeId "weighted_score"
    , scInputs =
        Map.fromList
          [ (NodeId "evidence", wireValue "evidence_score" (scientific 8 (-1)))
          , (NodeId "recency", wireValue "recency_score" (scientific 6 (-1)))
          , (NodeId "authority", wireValue "authority_score" (scientific 5 (-1)))
          ]
    , scAttempt = 1
    , scBudgetContext =
        BudgetContext
          { bcInitialBudget = defaultRewriteBudget
          , bcRemainingBudget = defaultRewriteBudget
          }
    , scRewriteRejection = Nothing
    , scRetryFailure = Nothing
    , scMemory = discardMemoryHandle
    , scMemoryStrategy = defaultMemoryStrategy
    }
  where
    wireValue portName number =
      Aeson.toJSON
        ( (mkWireValue "Float" WirePayloadJson (Just portName) (Aeson.Number number))
            { wireValuePort = Just portName
            }
        )

scoreStageContext :: StageContext
scoreStageContext =
  weightedStageContext
    { scNodeId = NodeId "score"
    , scInputs =
        Map.fromList
          [ (NodeId "evidence", wireValue "evidence_score" (scientific 8 (-1)))
          , (NodeId "recency", wireValue "recency_score" (scientific 6 (-1)))
          ]
    }
  where
    wireValue portName number =
      Aeson.toJSON
        ( (mkWireValue "Float" WirePayloadJson (Just portName) (Aeson.Number number))
            { wireValuePort = Just portName
            }
        )

pureCompileEnv :: WireCompileEnv
pureCompileEnv =
  strictWireCompileEnv
    (executorProjectionRegistry [pureExecutorSpec])
    floatContractRegistry

pureSourceText :: Text
pureSourceText =
  T.unlines
    [ "node score"
    , "  <- evidence_score: Float ;"
    , "  <- recency_score: Float ;"
    , "  -> out: Float = evidence_score + recency_score ;"
    , "score"
    ]

pureSumSourceText :: Text
pureSumSourceText =
  pureSumProgram "if evidence_score >= 0 then accepted evidence_score else rejected evidence_score"

pureSumProgram :: Text -> Text
pureSumProgram bodyExpr =
  T.unlines
    [ "node classify"
    , "  <- evidence_score: Float ;"
    , "  -> accepted: Float | rejected: Float = " <> bodyExpr <> ";"
    , "classify"
    ]

pureSumStageContext :: StageContext
pureSumStageContext =
  weightedStageContext
    { scNodeId = NodeId "classify"
    , scInputs =
        Map.singleton
          (NodeId "evidence")
          ( Aeson.toJSON
              ( (mkWireValue "Float" WirePayloadJson (Just "evidence") (Aeson.Number (scientific 8 (-1))))
                  { wireValuePort = Just "evidence_score"
                  }
              )
          )
    }

floatContractRegistry :: WireContractRegistry
floatContractRegistry =
  wireContractRegistryFromList [contractSpec WirePayloadJson]

textFloatContractRegistry :: WireContractRegistry
textFloatContractRegistry =
  wireContractRegistryFromList [contractSpec WirePayloadText]

contractSpec :: WirePayloadKind -> WireContractSpec
contractSpec payloadKind =
  WireContractSpec
    { wireContractSpecId = "Float"
    , wireContractSpecPayloadKind = payloadKind
    , wireContractSpecDescription = "Float"
    , wireContractSpecRecordFields = Nothing
    , wireContractSpecSchema = Nothing
    , wireContractSpecNativeShape = Nothing
    , wireContractSpecExamples = []
    }

requireRight :: Show err => Either err a -> IO a
requireRight = \case
  Right value -> pure value
  Left err -> fail ("expected Right, got " <> show err)

requireAesonSuccess :: Aeson.Result a -> IO a
requireAesonSuccess = \case
  Aeson.Success value -> pure value
  Aeson.Error err -> fail ("expected Aeson.Success, got " <> err)

requireSingleWireValue :: Aeson.Value -> IO WireValue
requireSingleWireValue value = do
  WireValueSet values <- requireAesonSuccess (Aeson.fromJSON value :: Aeson.Result WireValueSet)
  case values of
    [wireValue] -> pure wireValue
    other -> fail ("expected one WireValue, got " <> show (length other))

requireCompiledTask :: Text -> CompiledCircuit -> IO CircuitTaskNode
requireCompiledTask nodeRef compiled =
  case Map.lookup (CircuitNodeRef nodeRef) compiled.compiledCircuitNodes of
    Just (CompiledCircuitTask taskNode) -> pure taskNode
    other -> fail ("expected compiled task node, got " <> show other)

showStageResult :: StageResult NodeId -> String
showStageResult = \case
  StageComplete {} -> "StageComplete"
  StageSuspend {} -> "StageSuspend"
  StageRewrite {} -> "StageRewrite"
  StageLoopStep {} -> "StageLoopStep"
  StageRejectRewrite {} -> "StageRejectRewrite"
  StageFail {} -> "StageFail"

leftContains :: Show err => Text -> Either err value -> Bool
leftContains needle = \case
  Left err -> needle `T.isInfixOf` T.pack (show err)
  Right _ -> False

num :: Scientific -> CorePureExpr
num =
  CorePureLit . CorePureNumber

var :: Text -> CorePureExpr
var =
  CorePureIdent

bin :: CorePureBinOp -> CorePureExpr -> CorePureExpr -> CorePureExpr
bin =
  CorePureBinary
