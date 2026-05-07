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
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Test.Hspec

import Cortex.Pulse.Node (NodeId (..))
import Cortex.Wire

spec :: Spec
spec = describe "Cortex.Wire runtime egress" $ do
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

producer :: NodeId
producer = NodeId "classifier"

runId :: UUID.UUID
runId = UUID.fromWords 0 0 0 0

scorePorts :: WirePorts
scorePorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs = Map.singleton "score" (WireOutputPort "Score")
    }

dualScorePorts :: WirePorts
dualScorePorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs =
        Map.fromList
          [ ("accepted", WireOutputPort "Score")
          , ("rejected", WireOutputPort "Score")
          ]
    }

textPorts :: WirePorts
textPorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs = Map.singleton "message" (WireOutputPort "Message")
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
        , wireContractSpecExamples = []
        }
    , WireContractSpec
        { wireContractSpecId = "Other"
        , wireContractSpecPayloadKind = WirePayloadJson
        , wireContractSpecDescription = "Other payload."
        , wireContractSpecRecordFields = Nothing
        , wireContractSpecSchema = Nothing
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
