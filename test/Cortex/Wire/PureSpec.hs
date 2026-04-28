{-# LANGUAGE OverloadedStrings #-}

module Cortex.Wire.PureSpec (spec) where

import Cortex.Pulse.Node (NodeId (..))
import Cortex.Wire
  ( CorePureBinOp (..),
    CorePureBinding (..),
    CorePureExpr (..),
    CorePureField (..),
    CorePureLiteral (..),
    PureEvalError (..),
    WireInputBundle,
    WireInputCardinality (..),
    WireInputPort (..),
    WireOutputPort (..),
    WirePayloadKind (..),
    WirePorts (..),
    WireValue (..),
    bindPureInputValues,
    evaluatePureTaskOutputs,
    mkWireValue,
    validatePurePorts,
    wireInputBundleFromStageInputs,
  )
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific, scientific)
import Data.Text (Text)
import Test.Hspec

spec :: Spec
spec = describe "Cortex.Wire.Pure" $ do
  it "evaluates CorePure bindings over JSON objects and emits explicit output values" $ do
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      scoreBindings
      (Map.singleton "score" scoreOutputExpr)
      `shouldBe` Right
        ( Map.singleton
            "score"
            ( Aeson.object
                [ "total" Aeson..= Aeson.Number (scientific 55 (-2)),
                  "count" Aeson..= Aeson.Number 2
                ]
            )
        )

  it "binds a single unlabeled input as in" $ do
    let ports =
          WirePorts
            { wirePortsInputs =
                Map.singleton
                  "in"
                  WireInputPort
                    { wireInputPortAccepts = ["Payload"],
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
              ( Aeson.toJSON
                  ( (mkWireValue "Payload" WirePayloadJson (Just "source") (Aeson.object ["value" Aeson..= Aeson.Number 4]))
                      { wireValuePort = Just "out"
                      }
                  )
              )
    evaluatePureTaskOutputs ports inputBundle [] (Map.singleton "out" (bin CorePureDivide (field (var "in") "value") (num 2)))
      `shouldBe` Right (Map.singleton "out" (Aeson.Number 2))

  it "accepts pure port declarations with multiple output equations" $
    validatePurePorts multiOutputPorts (Map.fromList [("accepted", CorePureList []), ("rejected", CorePureList [])])
      `shouldBe` Right ()

  it "rejects missing variables" $
    evaluatePureTaskOutputs scorePorts scoreInputs [] (Map.singleton "score" (var "unknown"))
      `shouldBe` Left (PureMissingVariable "unknown")

  it "rejects divide by zero" $
    evaluatePureTaskOutputs scorePorts scoreInputs [] (Map.singleton "score" (bin CorePureDivide (num 1) (num 0)))
      `shouldBe` Left PureDivisionByZero

  it "rejects non-JSON WireValue inputs" $ do
    let inputBundle =
          wireInputBundleFromStageInputs $
            Map.singleton
              (NodeId "source")
              ( Aeson.toJSON
                  ( (mkWireValue "EvidenceSet" WirePayloadText (Just "source") (Aeson.String "bad"))
                      { wireValuePort = Just "evidence"
                      }
                  )
              )
    bindPureInputValues
      ( scorePorts
          { wirePortsInputs =
              Map.singleton
                "evidence"
                WireInputPort
                  { wireInputPortAccepts = ["EvidenceSet"],
                    wireInputPortCardinality = WireInputCardinalityOne,
                    wireInputPortRequired = False
                  }
          }
      )
      inputBundle
      `shouldBe` Left (PureInputPayloadKindMismatch "evidence" WirePayloadText)

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
    validatePurePorts ports (Map.singleton "out" (num 1))
      `shouldBe` Left (PureInputPortRequiresLabel "Float_1" "Float")

  it "rejects list and multi-contract inputs during port validation" $ do
    let listInputPorts =
          scorePorts
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
          scorePorts
            { wirePortsInputs =
                Map.singleton
                  "value"
                  WireInputPort
                    { wireInputPortAccepts = ["Float", "Score"],
                      wireInputPortCardinality = WireInputCardinalityOne,
                      wireInputPortRequired = False
                    }
            }
    validatePurePorts listInputPorts (Map.singleton "score" (num 1))
      `shouldBe` Left
        (PureInputPortUnsupported "values" "list inputs are not supported by pure output equations")
    validatePurePorts multiContractPorts (Map.singleton "score" (num 1))
      `shouldBe` Left (PureInputPortUnsupported "value" "multiple accepted contracts")

  it "requires output equations to match declared output ports" $ do
    validatePurePorts (scorePorts {wirePortsOutputs = Map.empty}) Map.empty
      `shouldBe` Left
        (PureOutputPortsUnsupported "pure output equations require at least one output port")
    validatePurePorts scorePorts (Map.singleton "confidence" (num 1))
      `shouldBe` Left (PureOutputPortsMismatch ["score"] ["confidence"])

scorePorts :: WirePorts
scorePorts =
  WirePorts
    { wirePortsInputs =
        Map.fromList
          [ labeledJsonInput "evidence" "EvidenceSet",
            labeledJsonInput "weights" "WeightSet"
          ],
      wirePortsOutputs =
        Map.singleton "score" WireOutputPort {wireOutputPortContract = "ScoreSet"}
    }

multiOutputPorts :: WirePorts
multiOutputPorts =
  WirePorts
    { wirePortsInputs =
        Map.singleton "evidence" (snd (labeledJsonInput "evidence" "EvidenceSet")),
      wirePortsOutputs =
        Map.fromList
          [ ("accepted", WireOutputPort {wireOutputPortContract = "AcceptedSet"}),
            ("rejected", WireOutputPort {wireOutputPortContract = "RejectedSet"})
          ]
    }

labeledJsonInput :: Text -> Text -> (Text, WireInputPort)
labeledJsonInput portName contractId =
  ( portName,
    WireInputPort
      { wireInputPortAccepts = [contractId],
        wireInputPortCardinality = WireInputCardinalityOne,
        wireInputPortRequired = False
      }
  )

scoreInputs :: WireInputBundle
scoreInputs =
  wireInputBundleFromStageInputs $
    Map.fromList
      [ (NodeId "evidence", wireValue "EvidenceSet" "evidence" evidenceValue),
        (NodeId "weights", wireValue "WeightSet" "weights" weightsValue)
      ]
  where
    wireValue contractId portName value =
      Aeson.toJSON
        ( (mkWireValue contractId WirePayloadJson (Just portName) value)
            { wireValuePort = Just portName
            }
        )

evidenceValue :: Aeson.Value
evidenceValue =
  Aeson.object
    [ "items"
        Aeson..= [ Aeson.object ["score" Aeson..= Aeson.Number (scientific 8 (-1))],
                   Aeson.object ["score" Aeson..= Aeson.Number (scientific 6 (-1))]
                 ]
    ]

weightsValue :: Aeson.Value
weightsValue =
  Aeson.object
    [ "values" Aeson..= [Aeson.Number (scientific 5 (-1)), Aeson.Number (scientific 25 (-2))]
    ]

scoreBindings :: [CorePureBinding]
scoreBindings =
  [ CorePureBinding
      { corePureBindingName = "scores",
        corePureBindingExpr =
          call
            (var "map")
            [ lambda ["item"] (field (var "item") "score"),
              field (var "evidence") "items"
            ]
      },
    CorePureBinding
      { corePureBindingName = "weighted",
        corePureBindingExpr =
          call
            (var "zipWith")
            [ lambda ["score", "weight"] (bin CorePureMultiply (var "score") (var "weight")),
              var "scores",
              field (var "weights") "values"
            ]
      }
  ]

scoreOutputExpr :: CorePureExpr
scoreOutputExpr =
  CorePureRecord
    [ CorePureField ("total" :| []) (call (var "sum") [var "weighted"]),
      CorePureField ("count" :| []) (call (var "length") [var "weighted"])
    ]

num :: Scientific -> CorePureExpr
num =
  CorePureLit . CorePureNumber

var :: Text -> CorePureExpr
var =
  CorePureIdent

field :: CorePureExpr -> Text -> CorePureExpr
field =
  CorePureFieldAccess

lambda :: [Text] -> CorePureExpr -> CorePureExpr
lambda =
  CorePureLambda

call :: CorePureExpr -> [CorePureExpr] -> CorePureExpr
call =
  CorePureCall

bin :: CorePureBinOp -> CorePureExpr -> CorePureExpr -> CorePureExpr
bin =
  CorePureBinary
