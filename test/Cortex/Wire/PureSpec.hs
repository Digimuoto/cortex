{-# LANGUAGE OverloadedStrings #-}

module Cortex.Wire.PureSpec (spec) where

import Cortex.Pulse.Node (NodeId (..))
import Cortex.Wire
  ( PureEvalError (..),
    WireInputBundle,
    WireInputCardinality (..),
    WireInputPort (..),
    WireOutputPort (..),
    WirePayloadKind (..),
    WirePorts (..),
    WireValue (..),
    bindPureInputVariables,
    evaluatePureTaskOutput,
    mkWireValue,
    validatePurePorts,
    wireInputBundleFromStageInputs,
  )
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Scientific (scientific)
import Data.Text (Text)
import Test.Hspec

spec :: Spec
spec = describe "Cortex.Wire.Pure" $ do
  it "evaluates a weighted score over labeled same-contract WireValue inputs" $ do
    evaluatePureTaskOutput
      weightedScorePorts
      weightedScoreInputs
      "0.5 * evidence_score + 0.3 * recency_score + 0.2 * authority_score"
      `shouldBe` Right (Aeson.Number (scientific 68 (-2)))

  it "binds a single unlabeled input as in" $ do
    let ports =
          WirePorts
            { wirePortsInputs =
                Map.singleton
                  "in"
                  WireInputPort
                    { wireInputPortAccepts = ["Float"],
                      wireInputPortCardinality = WireInputCardinalityOne,
                      wireInputPortRequired = False
                    },
              wirePortsOutputs =
                Map.singleton "out" WireOutputPort {wireOutputPortContract = "Float"}
            }
        inputBundle =
          wireInputBundleFromStageInputs $
            Map.singleton
              (NodeId "source")
              (Aeson.toJSON ((mkWireValue "Float" WirePayloadJson (Just "source") (Aeson.Number 4)) {wireValuePort = Just "out"}))
    evaluatePureTaskOutput ports inputBundle "in / 2"
      `shouldBe` Right (Aeson.Number 2)

  it "accepts first-slice pure port declarations" $
    validatePurePorts weightedScorePorts `shouldBe` Right ()

  it "rejects missing variables" $
    evaluatePureTaskOutput weightedScorePorts weightedScoreInputs "unknown + 1"
      `shouldBe` Left (PureMissingVariable "unknown")

  it "rejects divide by zero" $
    evaluatePureTaskOutput weightedScorePorts weightedScoreInputs "evidence_score / (recency_score - recency_score)"
      `shouldBe` Left PureDivisionByZero

  it "rejects non-numeric JSON input values" $ do
    let inputBundle =
          wireInputBundleFromStageInputs $
            Map.singleton
              (NodeId "source")
              ( Aeson.toJSON
                  ( (mkWireValue "Float" WirePayloadJson (Just "source") (Aeson.String "bad"))
                      { wireValuePort = Just "evidence_score"
                      }
                  )
              )
    bindPureInputVariables
      ( weightedScorePorts
          { wirePortsInputs =
              Map.singleton
                "evidence_score"
                WireInputPort
                  { wireInputPortAccepts = ["Float"],
                    wireInputPortCardinality = WireInputCardinalityOne,
                    wireInputPortRequired = False
                  }
          }
      )
      inputBundle
      `shouldBe` Left (PureInputNonNumeric "evidence_score" (Aeson.String "bad"))

  it "requires labels for repeated same-contract generated inputs" $ do
    let ports =
          WirePorts
            { wirePortsInputs =
                Map.fromList
                  [ ( "Float_1",
                      WireInputPort
                        { wireInputPortAccepts = ["Float"],
                          wireInputPortCardinality = WireInputCardinalityOne,
                          wireInputPortRequired = False
                        }
                    ),
                    ( "Float_2",
                      WireInputPort
                        { wireInputPortAccepts = ["Float"],
                          wireInputPortCardinality = WireInputCardinalityOne,
                          wireInputPortRequired = False
                        }
                    )
                  ],
              wirePortsOutputs =
                Map.singleton "out" WireOutputPort {wireOutputPortContract = "Float"}
            }
    validatePurePorts ports
      `shouldBe` Left (PureInputPortRequiresLabel "Float_1" "Float")

  it "rejects list and multi-contract inputs during port validation" $ do
    let listInputPorts =
          weightedScorePorts
            { wirePortsInputs =
                Map.singleton
                  "values"
                  WireInputPort
                    { wireInputPortAccepts = ["Float"],
                      wireInputPortCardinality = WireInputCardinalityMany,
                      wireInputPortRequired = False
                    }
            }
        multiContractPorts =
          weightedScorePorts
            { wirePortsInputs =
                Map.singleton
                  "value"
                  WireInputPort
                    { wireInputPortAccepts = ["Float", "Score"],
                      wireInputPortCardinality = WireInputCardinalityOne,
                      wireInputPortRequired = False
                    }
            }
    validatePurePorts listInputPorts
      `shouldBe` Left
        (PureInputPortUnsupported "values" "list inputs are not supported in the first pure evaluator slice")
    validatePurePorts multiContractPorts
      `shouldBe` Left (PureInputPortUnsupported "value" "multiple accepted contracts")

  it "requires exactly one output port during port validation" $ do
    validatePurePorts (weightedScorePorts {wirePortsOutputs = Map.empty})
      `shouldBe` Left
        (PureOutputPortsUnsupported "numeric pure executor requires exactly one output port, but declared 0")
    validatePurePorts
      ( weightedScorePorts
          { wirePortsOutputs =
              Map.fromList
                [ ("score", WireOutputPort {wireOutputPortContract = "Float"}),
                  ("confidence", WireOutputPort {wireOutputPortContract = "Float"})
                ]
          }
      )
      `shouldBe` Left
        (PureOutputPortsUnsupported "numeric pure executor requires exactly one output port, but declared 2")

weightedScorePorts :: WirePorts
weightedScorePorts =
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

weightedScoreInputs :: WireInputBundle
weightedScoreInputs =
  wireInputBundleFromStageInputs $
    Map.fromList
      [ (NodeId "evidence", wireValue "evidence_score" (scientific 8 (-1))),
        (NodeId "recency", wireValue "recency_score" (scientific 6 (-1))),
        (NodeId "authority", wireValue "authority_score" (scientific 5 (-1)))
      ]
  where
    wireValue portName number =
      Aeson.toJSON
        ( (mkWireValue "Float" WirePayloadJson (Just portName) (Aeson.Number number))
            { wireValuePort = Just portName
            }
        )
