{- |
Module      : Cortex.Wire.RuntimeSpec
Description : Tests for Wire runtime boundary egress.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Exercises the public runtime wrapper surface. The implementation is routed through the private
node-boundary normal-form module, but these tests intentionally assert only public behavior.
-}
module Cortex.Wire.RuntimeSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Test.Hspec

import Cortex.Pulse.Memory (defaultMemoryStrategy, discardMemoryHandle)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( StageActionId (..)
  , StageContext (..)
  , StageDefinition (..)
  , StageReplaySafety (..)
  , StageResult (..)
  , stageTemplateId
  )
import Cortex.Pulse.Rewrite (BudgetContext (..))
import Cortex.Pulse.Types (defaultRewriteBudget)
import Cortex.Wire

spec :: Spec
spec = describe "Cortex.Wire runtime egress" $ do
  describe "exclusive variant egress boundary" $ do
    it "rejects committing zero variants" $
      wrapWireStageOutputs (Just scoreRegistry) producer runId variantPorts Map.empty
        `shouldBeLeftContaining` "must commit exactly one variant"

    it "rejects committing more than one variant" $
      wrapWireStageOutputs
        (Just scoreRegistry)
        producer
        runId
        variantPorts
        (Map.fromList [("accepted", Aeson.Number 1), ("rejected", Aeson.Number 2)])
        `shouldBeLeftContaining` "must commit exactly one variant"

    it "rejects an undeclared variant label" $
      wrapWireStageOutputs
        (Just scoreRegistry)
        producer
        runId
        variantPorts
        (Map.singleton "unknown" (Aeson.Number 1))
        `shouldBeLeftContaining` "is not a declared variant"

  describe "one-record executor argument boundary" $ do
    let schema =
          WireExecutorArgumentSchema $
            Aeson.object
              [ "type" Aeson..= ("object" :: Text)
              , "required" Aeson..= ["payload" :: Text]
              , "additionalProperties" Aeson..= False
              , "properties"
                  Aeson..= Aeson.object
                    [ "payload" Aeson..= Aeson.object ["type" Aeson..= ("string" :: Text)]
                    ]
              ]

    it "returns the evaluated record unchanged after schema validation" $ do
      let argument = Aeson.object ["payload" Aeson..= ("hello" :: Text)]
      validateWireExecutorArgument schema argument `shouldBe` Right argument

    it "rejects invalid arguments before a host binding can be invoked" $
      validateWireExecutorArgument schema (Aeson.object ["payload" Aeson..= (7 :: Int)])
        `shouldBeLeftContaining` "expected string at $.payload"

    it "rejects non-record values even for unchecked executor projections" $
      validateWireExecutorArgument WireExecutorArgumentUnchecked (Aeson.String "raw")
        `shouldBeLeftContaining` "must be a normalized JSON object"

  describe "ADR 0095 ingress argument evaluation" $ do
    it "evaluates a port-referencing argument from the typed input bundle" $ do
      let bundle = wireInputBundleFromStageInputs topicStageInputs
      evaluateWireExecutorArgument topicPorts topicArgumentSpec bundle
        `shouldBe` Right
          ( Aeson.object
              [ "payload" Aeson..= ("hello" :: Text)
              , "cfg" Aeson..= Aeson.object ["mode" Aeson..= ("safe" :: Text)]
              , "tag" Aeson..= ("r-1" :: Text)
              ]
          )

    it "reports a typed error when a referenced input port value is missing" $ do
      let bundle = wireInputBundleFromStageInputs Map.empty
      case evaluateWireExecutorArgument topicPorts topicArgumentSpec bundle of
        Left evalError -> renderPureEvalError evalError `shouldSatisfy` T.isInfixOf "topic"
        Right value -> expectationFailure ("expected Left, got " <> show value)

    -- Executor ingress is not the pure-node JSON-only boundary: every payload
    -- kind the egress boundary validated crosses into the argument unchanged.
    it "passes text payloads through ingress evaluation unchanged" $ do
      let bundle = wireInputBundleFromStageInputs textStageInputs
      evaluateWireExecutorArgument textNodePorts textArgumentSpec bundle
        `shouldBe` Right (Aeson.object ["payload" Aeson..= ("plain body" :: Text)])

    it "passes artifact_ref payloads through ingress evaluation unchanged" $ do
      let refValue =
            Aeson.object
              [ "artifact_id" Aeson..= ("art-1" :: Text)
              , "digest" Aeson..= ("sha256:abc" :: Text)
              ]
          bundle =
            wireInputBundleFromStageInputs $
              Map.singleton
                (NodeId "source")
                ( Aeson.toJSON $
                    (mkWireValue "Ref" WirePayloadArtifactRef (Just "source") refValue)
                      { wireValuePort = Just "ref"
                      }
                )
      evaluateWireExecutorArgument refNodePorts refArgumentSpec bundle
        `shouldBe` Right (Aeson.object ["payload" Aeson..= refValue])

    it "round-trips the compiled argument envelope through metadata decoding" $ do
      let metadata =
            Aeson.object
              [ "argument"
                  Aeson..= Aeson.object
                    [ "value" Aeson..= topicArgumentSpec.wireExecutorArgumentExpr
                    , "bindings" Aeson..= topicArgumentSpec.wireExecutorArgumentBindings
                    , "where" Aeson..= topicArgumentSpec.wireExecutorArgumentWhere
                    ]
              ]
      wireExecutorArgumentSpecFromMetadata metadata `shouldBe` Right topicArgumentSpec

    it "rejects unknown executor argument envelope fields" $ do
      let metadata =
            Aeson.object
              [ "argument"
                  Aeson..= Aeson.object
                    [ "value" Aeson..= topicArgumentSpec.wireExecutorArgumentExpr
                    , "config" Aeson..= Aeson.object []
                    ]
              ]
      wireExecutorArgumentSpecFromMetadata metadata
        `shouldBeLeftContaining` "unsupported executor argument envelope fields: config"

    it "delivers the validated ingress argument to the binding unchanged" $ do
      received <- newIORef ([] :: [Aeson.Value])
      let stageDef =
            wrapWireStageDefinition
              (Just topicRegistry)
              topicArgumentSchema
              topicArgumentEvaluator
              topicNodePorts
              ( \argument _ctx -> do
                  modifyIORef' received (argument :)
                  pure (StageComplete (Aeson.object ["score" Aeson..= (1 :: Int)]))
              )
              baseTopicStageDefinition
      result <- stageDef.sdAction topicStageContext
      case result of
        StageComplete value -> do
          wireValue <- requireAesonSuccess (Aeson.fromJSON value :: Aeson.Result WireValue)
          wireValue.wireValueContract `shouldBe` "Score"
        other -> expectationFailure ("expected StageComplete, got " <> showStageResult other)
      seen <- readIORef received
      seen
        `shouldBe` [ Aeson.object
                       [ "payload" Aeson..= ("hello" :: Text)
                       , "cfg" Aeson..= Aeson.object ["mode" Aeson..= ("safe" :: Text)]
                       , "tag" Aeson..= ("r-1" :: Text)
                       ]
                   ]

    it "fails the stage before host invocation when the evaluated argument violates the schema" $ do
      invoked <- newIORef (0 :: Int)
      let rejectingSchema =
            WireExecutorArgumentSchema $
              Aeson.object
                [ "type" Aeson..= ("object" :: Text)
                , "required" Aeson..= ["payload" :: Text]
                , "properties"
                    Aeson..= Aeson.object
                      ["payload" Aeson..= Aeson.object ["type" Aeson..= ("integer" :: Text)]]
                ]
          stageDef =
            wrapWireStageDefinition
              (Just topicRegistry)
              rejectingSchema
              topicArgumentEvaluator
              topicNodePorts
              ( \_argument _ctx -> do
                  modifyIORef' invoked (+ 1)
                  pure (StageComplete (Aeson.object ["score" Aeson..= (1 :: Int)]))
              )
              baseTopicStageDefinition
      result <- stageDef.sdAction topicStageContext
      case result of
        StageFail errType message -> do
          errType `shouldBe` "executor_argument_validation_failure"
          message `shouldSatisfy` T.isInfixOf "expected integer at $.payload"
        other -> expectationFailure ("expected StageFail, got " <> showStageResult other)
      invocations <- readIORef invoked
      invocations `shouldBe` 0

    it "fails the stage without invoking the host when argument evaluation fails" $ do
      invoked <- newIORef (0 :: Int)
      let stageDef =
            wrapWireStageDefinition
              (Just topicRegistry)
              topicArgumentSchema
              (const (Left "input port topic produced no value"))
              topicNodePorts
              ( \_argument _ctx -> do
                  modifyIORef' invoked (+ 1)
                  pure (StageComplete (Aeson.object ["score" Aeson..= (1 :: Int)]))
              )
              baseTopicStageDefinition
      result <- stageDef.sdAction topicStageContext
      case result of
        StageFail errType message -> do
          errType `shouldBe` "executor_argument_validation_failure"
          message `shouldSatisfy` T.isInfixOf "produced no value"
        other -> expectationFailure ("expected StageFail, got " <> showStageResult other)
      readIORef invoked `shouldReturn` 0

    it "rejects malformed argument envelopes with named causes" $ do
      wireExecutorArgumentSpecFromMetadata (Aeson.object [])
        `shouldBeLeftContaining` "missing the argument envelope"
      wireExecutorArgumentSpecFromMetadata (Aeson.object ["argument" Aeson..= ("raw" :: Text)])
        `shouldBeLeftContaining` "must be a JSON object"
      wireExecutorArgumentSpecFromMetadata
        ( Aeson.object
            [ "argument"
                Aeson..= Aeson.object ["value" Aeson..= True, "extra" Aeson..= True]
            ]
        )
        `shouldBeLeftContaining` "unsupported executor argument envelope fields: extra"
      wireExecutorArgumentSpecFromMetadata
        (Aeson.object ["argument" Aeson..= Aeson.object []])
        `shouldBeLeftContaining` "missing the value field"

  it "wraps raw single-output JSON through the declared output port" $ do
    result <-
      requireRight $
        wrapWireStageOutput
          (Just scoreRegistry)
          producer
          runId
          scorePorts
          (Aeson.object ["score" Aeson..= (7 :: Int)])
    wireValue <- requireAesonSuccess (Aeson.fromJSON result :: Aeson.Result WireValue)
    wireValue.wireValueContract `shouldBe` "Score"
    wireValue.wireValuePort `shouldBe` Just "score"
    wireValue.wireValueProducer `shouldBe` Just "classifier"

  it "wraps pure output maps as explicit WireValueSet values" $ do
    result <-
      requireRight $
        wrapWireStageOutputs
          (Just scoreRegistry)
          producer
          runId
          dualScorePorts
          (Map.fromList [("accepted", Aeson.Number 1), ("rejected", Aeson.Number 0)])
    WireValueSet values <- requireAesonSuccess (Aeson.fromJSON result :: Aeson.Result WireValueSet)
    fmap (.wireValuePort) values `shouldBe` [Just "accepted", Just "rejected"]
    fmap (.wireValueContract) values `shouldBe` ["Score", "Score"]

  it "rejects pure output maps with missing ports" $
    wrapWireStageOutputs
      (Just scoreRegistry)
      producer
      runId
      dualScorePorts
      (Map.singleton "accepted" (Aeson.Number 1))
      `shouldBeLeftContaining` "returned pure output ports {accepted}, expected {accepted, rejected}"

  it "rejects explicit WireValue outputs whose port declares another contract" $ do
    let wrong =
          Aeson.toJSON $
            (mkWireValue "Other" WirePayloadJson (Just "classifier") Aeson.Null)
              { wireValuePort = Just "score"
              }
    wrapWireStageOutput (Just scoreRegistry) producer runId scorePorts wrong
      `shouldBeLeftContaining` "offers contract Score, but the explicit WireValue declared Other"

  it "rejects explicit WireValue outputs naming an unknown port" $ do
    let wrong =
          Aeson.toJSON $
            (mkWireValue "Score" WirePayloadJson (Just "classifier") Aeson.Null)
              { wireValuePort = Just "missing"
              }
    wrapWireStageOutput (Just scoreRegistry) producer runId scorePorts wrong
      `shouldBeLeftContaining` "Wire output port missing is not offered by this node"

  it "rejects ambiguous explicit WireValue outputs without a port" $ do
    let ambiguous = Aeson.toJSON (mkWireValue "Score" WirePayloadJson (Just "classifier") Aeson.Null)
    wrapWireStageOutput (Just scoreRegistry) producer runId dualScorePorts ambiguous
      `shouldBeLeftContaining` "is offered by multiple output ports"

  it "rejects output payloads that do not match the contract payload kind" $
    wrapWireStageOutput
      (Just textRegistry)
      producer
      runId
      textPorts
      (Aeson.Number 1)
      `shouldBeLeftContaining` "value shape is invalid; expected a JSON string"

  describe "ADR 0085 contract schema enforcement" $ do
    it "accepts json outputs that satisfy the declared schema" $ do
      result <-
        requireRight $
          wrapWireStageOutput
            (Just schemaRegistry)
            producer
            runId
            reportPorts
            (Aeson.object ["title" Aeson..= ("Q1" :: Text)])
      wireValue <- requireAesonSuccess (Aeson.fromJSON result :: Aeson.Result WireValue)
      wireValue.wireValueContract `shouldBe` "Report"

    it "rejects json outputs that violate the declared schema" $
      wrapWireStageOutput
        (Just schemaRegistry)
        producer
        runId
        reportPorts
        (Aeson.object [])
        `shouldBeLeftContaining` "Wire output schema validation: Wire contract Report is missing required property title"

    it "rejects schema violations with a JSON path" $
      wrapWireStageOutput
        (Just schemaRegistry)
        producer
        runId
        reportPorts
        (Aeson.object ["title" Aeson..= (7 :: Int)])
        `shouldBeLeftContaining` "expected string at $.title, got integer"

    it "rejects artifact_ref reference objects that violate the declared schema" $
      wrapWireStageOutput
        (Just schemaRegistry)
        producer
        runId
        reportRefPorts
        (Aeson.object ["digest" Aeson..= ("sha256:abc" :: Text)])
        `shouldBeLeftContaining` "Wire contract ReportRef is missing required property artifact_id"

    it "keeps schema-less contracts on the shallow check only" $ do
      result <-
        requireRight $
          wrapWireStageOutput
            (Just scoreRegistry)
            producer
            runId
            scorePorts
            (Aeson.object ["free" Aeson..= ("form" :: Text)])
      wireValue <- requireAesonSuccess (Aeson.fromJSON result :: Aeson.Result WireValue)
      wireValue.wireValueContract `shouldBe` "Score"

  -- Lean correspondence: mirrors `pureNode_evalOutputs_values_satisfy_outputContracts`
  -- and `pureNode_evalOutputs_values_satisfy_valueContracts` in
  -- `theory/Cortex/Wire/Pure.lean`. The runtime egress wraps a raw output in
  -- a `WireValue` whose declared contract matches the port. The unwrap path
  -- consumed by downstream stages must recover that payload byte-for-byte
  -- without dropping the contract identity, so a wrap-then-unwrap round-trip
  -- pins the contract envelope against accidental drift in either direction.
  it "round-trips wrapped pure outputs through the unwrap path" $ do
    let payload = Aeson.object ["score" Aeson..= (7 :: Int)]
    wrapped <-
      requireRight $
        wrapWireStageOutput
          (Just scoreRegistry)
          producer
          runId
          scorePorts
          payload
    wireValue <- requireAesonSuccess (Aeson.fromJSON wrapped :: Aeson.Result WireValue)
    wireValue.wireValueContract `shouldBe` "Score"
    wireValue.wireValuePort `shouldBe` Just "score"
    wireValue.wireValuePayloadKind `shouldBe` WirePayloadJson
    -- The unwrap path used by downstream stages must recover the raw payload
    -- without leaking the WireValue envelope.
    unwrapWireStageValue wrapped `shouldBe` payload

  it "round-trips wrapped pure output sets through the unwrap path" $ do
    let payloads = Map.fromList [("accepted", Aeson.Number 1), ("rejected", Aeson.Number 0)]
    wrapped <-
      requireRight $
        wrapWireStageOutputs
          (Just scoreRegistry)
          producer
          runId
          dualScorePorts
          payloads
    WireValueSet values <- requireAesonSuccess (Aeson.fromJSON wrapped :: Aeson.Result WireValueSet)
    fmap (.wireValuePort) values `shouldBe` [Just "accepted", Just "rejected"]
    fmap (.wireValueContract) values `shouldBe` ["Score", "Score"]
    -- Reconstructing a stage-input map and unwrapping it must recover the
    -- aggregate payload list without dropping ports or contracts.
    let stageInputs = Map.singleton producer wrapped
        bundle = wireInputBundleFromStageInputs stageInputs
    fmap (.wireValuePort) bundle.wireInputBundleValues
      `shouldBe` [Just "accepted", Just "rejected"]
    fmap (.wireValueContract) bundle.wireInputBundleValues
      `shouldBe` ["Score", "Score"]

  describe "ADR 0062 variant output boundaries" $ do
    it "accepts one labelled variant when two variants share a contract" $ do
      let emitted =
            Aeson.toJSON $
              (mkWireValue "Score" WirePayloadJson (Just "classifier") (Aeson.Number 1))
                { wireValuePort = Just "accepted"
                }
      result <-
        requireRight $
          wrapWireStageOutput (Just scoreRegistry) producer runId variantScorePorts emitted
      wireValue <- requireAesonSuccess (Aeson.fromJSON result :: Aeson.Result WireValue)
      wireValue.wireValuePort `shouldBe` Just "accepted"
      wireValue.wireValueContract `shouldBe` "Score"

    it "rejects more than one variant from a variant-emitting node (WireValueSet)" $ do
      let set =
            Aeson.toJSON $
              WireValueSet
                [ (mkWireValue "Score" WirePayloadJson (Just "classifier") (Aeson.Number 1))
                    { wireValuePort = Just "accepted"
                    }
                , (mkWireValue "Score" WirePayloadJson (Just "classifier") (Aeson.Number 0))
                    { wireValuePort = Just "rejected"
                    }
                ]
      wrapWireStageOutput (Just scoreRegistry) producer runId variantScorePorts set
        `shouldBeLeftContaining` "must commit exactly one variant, not a WireValueSet"

    it "rejects a variant label the node does not declare" $ do
      let emitted =
            Aeson.toJSON $
              (mkWireValue "Score" WirePayloadJson (Just "classifier") (Aeson.Number 1))
                { wireValuePort = Just "maybe"
                }
      wrapWireStageOutput (Just scoreRegistry) producer runId variantScorePorts emitted
        `shouldBeLeftContaining` "is not a declared variant"

    it "rejects a node that mixes an exclusive group with an ordinary output" $ do
      let emitted =
            Aeson.toJSON $
              (mkWireValue "Score" WirePayloadJson (Just "classifier") (Aeson.Number 1))
                { wireValuePort = Just "ok"
                }
      wrapWireStageOutput (Just scoreRegistry) producer runId mixedVariantPorts emitted
        `shouldBeLeftContaining` "must not mix an exclusive output group with ordinary outputs"

producer :: NodeId
producer = NodeId "classifier"

runId :: UUID.UUID
runId = UUID.fromWords 0 0 0 0

{- | One consumed input port plus one output port, mirroring
@node score <- topic: Topic -> score: Score = \@review.score { ... };@.
-}
topicNodePorts :: WirePorts
topicNodePorts =
  WirePorts
    { wirePortsInputs = Map.singleton "topic" topicInputPort
    , wirePortsOutputs = Map.singleton "score" (WireOutputPort "Score" Nothing)
    }

-- | Input-only ports for direct evaluator tests.
topicPorts :: WirePorts
topicPorts =
  WirePorts
    { wirePortsInputs = Map.singleton "topic" topicInputPort
    , wirePortsOutputs = Map.empty
    }

topicInputPort :: WireInputPort
topicInputPort =
  WireInputPort
    { wireInputPortAccepts = ["Topic"]
    , wireInputPortCardinality = WireInputCardinalityOne
    , wireInputPortRequired = True
    }

{- | Argument envelope exercising all three scopes at ingress: the @topic@
input port, a module-level binding (@base@), and a node @where@ field (@tag@).
-}
topicArgumentSpec :: WireExecutorArgumentSpec
topicArgumentSpec =
  WireExecutorArgumentSpec
    { wireExecutorArgumentExpr =
        CorePureRecord
          [ CorePureField ("payload" :| []) (CorePureIdent "topic")
          , CorePureField ("cfg" :| []) (CorePureIdent "base")
          , CorePureField ("tag" :| []) (CorePureIdent "run_tag")
          ]
    , wireExecutorArgumentBindings =
        [ CorePureBinding
            "base"
            (CorePureRecord [CorePureField ("mode" :| []) (CorePureLit (CorePureString "safe"))])
        ]
    , wireExecutorArgumentWhere =
        Just
          (CorePureRecord [CorePureField ("run_tag" :| []) (CorePureLit (CorePureString "r-1"))])
    }

textNodePorts :: WirePorts
textNodePorts =
  WirePorts
    { wirePortsInputs =
        Map.singleton
          "message"
          WireInputPort
            { wireInputPortAccepts = ["Message"]
            , wireInputPortCardinality = WireInputCardinalityOne
            , wireInputPortRequired = True
            }
    , wirePortsOutputs = Map.empty
    }

textArgumentSpec :: WireExecutorArgumentSpec
textArgumentSpec =
  WireExecutorArgumentSpec
    { wireExecutorArgumentExpr =
        CorePureRecord [CorePureField ("payload" :| []) (CorePureIdent "message")]
    , wireExecutorArgumentBindings = []
    , wireExecutorArgumentWhere = Nothing
    }

textStageInputs :: Map.Map NodeId Aeson.Value
textStageInputs =
  Map.singleton
    (NodeId "source")
    ( Aeson.toJSON $
        (mkWireValue "Message" WirePayloadText (Just "source") (Aeson.String "plain body"))
          { wireValuePort = Just "message"
          }
    )

refNodePorts :: WirePorts
refNodePorts =
  WirePorts
    { wirePortsInputs =
        Map.singleton
          "ref"
          WireInputPort
            { wireInputPortAccepts = ["Ref"]
            , wireInputPortCardinality = WireInputCardinalityOne
            , wireInputPortRequired = True
            }
    , wirePortsOutputs = Map.empty
    }

refArgumentSpec :: WireExecutorArgumentSpec
refArgumentSpec =
  WireExecutorArgumentSpec
    { wireExecutorArgumentExpr =
        CorePureRecord [CorePureField ("payload" :| []) (CorePureIdent "ref")]
    , wireExecutorArgumentBindings = []
    , wireExecutorArgumentWhere = Nothing
    }

topicArgumentEvaluator :: WireInputBundle -> Either Text Aeson.Value
topicArgumentEvaluator bundle =
  case evaluateWireExecutorArgument topicNodePorts topicArgumentSpec bundle of
    Left evalError -> Left (renderPureEvalError evalError)
    Right value -> Right value

topicArgumentSchema :: WireExecutorArgumentShape
topicArgumentSchema =
  WireExecutorArgumentSchema $
    Aeson.object
      [ "type" Aeson..= ("object" :: Text)
      , "required" Aeson..= ["payload" :: Text]
      , "properties"
          Aeson..= Aeson.object
            ["payload" Aeson..= Aeson.object ["type" Aeson..= ("string" :: Text)]]
      ]

topicStageInputs :: Map.Map NodeId Aeson.Value
topicStageInputs =
  Map.singleton
    (NodeId "source")
    ( Aeson.toJSON $
        (mkWireValue "Topic" WirePayloadJson (Just "source") (Aeson.String "hello"))
          { wireValuePort = Just "topic"
          }
    )

topicStageContext :: StageContext
topicStageContext =
  StageContext
    { scRunId = UUID.fromWords 0 0 0 0
    , scNodeId = NodeId "score"
    , scInputs = topicStageInputs
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

baseTopicStageDefinition :: StageDefinition NodeId
baseTopicStageDefinition =
  StageDefinition
    { sdStageId = NodeId "score"
    , sdTemplateId = stageTemplateId (NodeId "score")
    , sdActionId = StageActionId "wire.test.topic-score"
    , sdReplaySafety = SafeToReplay
    , sdReplayPolicyOverride = Nothing
    , sdTimeoutSeconds = Nothing
    , sdRetryPolicy = Nothing
    , sdAction = \_ctx -> pure (StageFail "unbound" "base action must be superseded by the wrapper")
    , sdMemoryStrategy = defaultMemoryStrategy
    }

topicRegistry :: WireContractRegistry
topicRegistry =
  wireContractRegistryFromList
    [ WireContractSpec
        { wireContractSpecId = "Topic"
        , wireContractSpecPayloadKind = WirePayloadJson
        , wireContractSpecDescription = "Topic payload."
        , wireContractSpecRecordFields = Nothing
        , wireContractSpecSchema = Nothing
        , wireContractSpecNativeShape = Nothing
        , wireContractSpecExamples = []
        }
    , WireContractSpec
        { wireContractSpecId = "Score"
        , wireContractSpecPayloadKind = WirePayloadJson
        , wireContractSpecDescription = "Score payload."
        , wireContractSpecRecordFields = Nothing
        , wireContractSpecSchema = Nothing
        , wireContractSpecNativeShape = Nothing
        , wireContractSpecExamples = []
        }
    ]

showStageResult :: StageResult NodeId -> String
showStageResult = \case
  StageComplete {} -> "StageComplete"
  StageSuspend {} -> "StageSuspend"
  StageRewrite {} -> "StageRewrite"
  StageLoopStep {} -> "StageLoopStep"
  StageRejectRewrite {} -> "StageRejectRewrite"
  StageFail {} -> "StageFail"

scorePorts :: WirePorts
scorePorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs = Map.singleton "score" (WireOutputPort "Score" Nothing)
    }

variantPorts :: WirePorts
variantPorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs =
        Map.fromList
          [ ("accepted", WireOutputPort "Score" (Just 0))
          , ("rejected", WireOutputPort "Score" (Just 0))
          ]
    }

dualScorePorts :: WirePorts
dualScorePorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs =
        Map.fromList
          [ ("accepted", WireOutputPort "Score" Nothing)
          , ("rejected", WireOutputPort "Score" Nothing)
          ]
    }

textPorts :: WirePorts
textPorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs = Map.singleton "message" (WireOutputPort "Message" Nothing)
    }

{- | An exclusive (sum) output group whose two variants share one contract; only
well-formed because selection is by label, not contract (ADR 0062).
-}
variantScorePorts :: WirePorts
variantScorePorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs =
        Map.fromList
          [
            ( "accepted"
            , WireOutputPort {wireOutputPortContract = "Score", wireOutputPortExclusiveGroup = Just 0}
            )
          ,
            ( "rejected"
            , WireOutputPort {wireOutputPortContract = "Score", wireOutputPortExclusiveGroup = Just 0}
            )
          ]
    }

{- | An invalid variant boundary: an exclusive group mixed with an ordinary output
(ADR 0062 rejects "one selected variant plus side outputs").
-}
mixedVariantPorts :: WirePorts
mixedVariantPorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs =
        Map.fromList
          [ ("ok", WireOutputPort {wireOutputPortContract = "Score", wireOutputPortExclusiveGroup = Just 0})
          , ("audit", WireOutputPort {wireOutputPortContract = "Other", wireOutputPortExclusiveGroup = Nothing})
          ]
    }

scoreRegistry :: WireContractRegistry
scoreRegistry =
  wireContractRegistryFromList
    [ WireContractSpec
        { wireContractSpecId = "Score"
        , wireContractSpecPayloadKind = WirePayloadJson
        , wireContractSpecDescription = "Score payload."
        , wireContractSpecRecordFields = Nothing
        , wireContractSpecSchema = Nothing
        , wireContractSpecNativeShape = Nothing
        , wireContractSpecExamples = []
        }
    , WireContractSpec
        { wireContractSpecId = "Other"
        , wireContractSpecPayloadKind = WirePayloadJson
        , wireContractSpecDescription = "Other payload."
        , wireContractSpecRecordFields = Nothing
        , wireContractSpecSchema = Nothing
        , wireContractSpecNativeShape = Nothing
        , wireContractSpecExamples = []
        }
    ]

textRegistry :: WireContractRegistry
textRegistry =
  wireContractRegistryFromList
    [ WireContractSpec
        { wireContractSpecId = "Message"
        , wireContractSpecPayloadKind = WirePayloadText
        , wireContractSpecDescription = "Text payload."
        , wireContractSpecRecordFields = Nothing
        , wireContractSpecSchema = Nothing
        , wireContractSpecNativeShape = Nothing
        , wireContractSpecExamples = []
        }
    ]

reportPorts :: WirePorts
reportPorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs = Map.singleton "report" (WireOutputPort "Report" Nothing)
    }

reportRefPorts :: WirePorts
reportRefPorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs = Map.singleton "ref" (WireOutputPort "ReportRef" Nothing)
    }

schemaRegistry :: WireContractRegistry
schemaRegistry =
  wireContractRegistryFromList
    [ WireContractSpec
        { wireContractSpecId = "Report"
        , wireContractSpecPayloadKind = WirePayloadJson
        , wireContractSpecDescription = "Report payload."
        , wireContractSpecRecordFields = Nothing
        , wireContractSpecSchema =
            Just
              ( Aeson.object
                  [ "type" Aeson..= ("object" :: Text)
                  , "required" Aeson..= ["title" :: Text]
                  , "properties"
                      Aeson..= Aeson.object
                        ["title" Aeson..= Aeson.object ["type" Aeson..= ("string" :: Text)]]
                  ]
              )
        , wireContractSpecNativeShape = Nothing
        , wireContractSpecExamples = []
        }
    , WireContractSpec
        { wireContractSpecId = "ReportRef"
        , wireContractSpecPayloadKind = WirePayloadArtifactRef
        , wireContractSpecDescription = "Report artifact reference."
        , wireContractSpecRecordFields = Nothing
        , wireContractSpecSchema =
            Just
              ( Aeson.object
                  [ "type" Aeson..= ("object" :: Text)
                  , "required" Aeson..= ["artifact_id" :: Text]
                  ]
              )
        , wireContractSpecNativeShape = Nothing
        , wireContractSpecExamples = []
        }
    ]

requireRight :: (HasCallStack, Show e) => Either e a -> IO a
requireRight = \case
  Left err -> do
    expectationFailure ("expected Right, got " <> show err)
    fail "unreachable after expectationFailure"
  Right value -> pure value

requireAesonSuccess :: HasCallStack => Aeson.Result a -> IO a
requireAesonSuccess = \case
  Aeson.Error err -> do
    expectationFailure ("expected Aeson.Success, got " <> err)
    fail "unreachable after expectationFailure"
  Aeson.Success value -> pure value

shouldBeLeftContaining :: HasCallStack => Either Text a -> Text -> Expectation
shouldBeLeftContaining result needle =
  case result of
    Left err -> err `shouldSatisfy` T.isInfixOf needle
    Right _value -> expectationFailure "expected Left"
