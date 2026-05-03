{- |
Module      : Cortex.Wire.PureSpec
Description : Tests for Cortex.Wire.Pure.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Wire.PureSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific, scientific)
import Data.Set qualified as Set
import Data.Text (Text)
import Test.Hspec

import Cortex.Pulse.Node (NodeId (..))
import Cortex.Wire
  ( CorePureBinOp (..)
  , CorePureBinding (..)
  , CorePureBuiltinAuthority (..)
  , CorePureBuiltinAuthorityReport (..)
  , CorePureExpr (..)
  , CorePureField (..)
  , CorePureLiteral (..)
  , CorePureStaticContext (..)
  , PureEvalError (..)
  , WireInputBundle
  , WireInputCardinality (..)
  , WireInputPort (..)
  , WireOutputPort (..)
  , WirePayloadKind (..)
  , WirePorts (..)
  , WireValue (..)
  , bindPureInputValues
  , corePureBuiltinAuthorityFree
  , corePureBuiltinAuthorityReport
  , corePureBuiltinSignature
  , corePureStaticContextFromBindings
  , corePureWhereStaticFields
  , evaluatePreparedPureTaskOutputs
  , evaluatePureTaskOutputs
  , mkWireValue
  , preparePureTaskOutputs
  , validatePurePorts
  , wireInputBundleFromStageInputs
  )

spec :: Spec
spec = describe "Cortex.Wire.Pure" $ do
  it "evaluates CorePure bindings over JSON objects and emits explicit output values" $ do
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      scoreBindings
      Nothing
      (Map.singleton "score" scoreOutputExpr)
      `shouldBe` Right
        ( Map.singleton
            "score"
            ( Aeson.object
                [ "total" Aeson..= Aeson.Number (scientific 55 (-2))
                , "count" Aeson..= Aeson.Number 2
                ]
            )
        )

  it "evaluates a prepared CorePure task without revalidating static task shape" $ do
    let outputExprs = Map.singleton "score" scoreOutputExpr
        expected =
          Right
            ( Map.singleton
                "score"
                ( Aeson.object
                    [ "total" Aeson..= Aeson.Number (scientific 55 (-2))
                    , "count" Aeson..= Aeson.Number 2
                    ]
                )
            )
    case preparePureTaskOutputs scorePorts scoreBindings Nothing outputExprs of
      Left evalError -> expectationFailure ("expected prepared task but got " <> show evalError)
      Right preparedTask ->
        evaluatePreparedPureTaskOutputs preparedTask scoreInputs `shouldBe` expected

  it "rejects invalid prepared CorePure tasks before evaluation" $
    preparePureTaskOutputs
      scorePorts
      scoreBindings
      Nothing
      (Map.singleton "confidence" scoreOutputExpr)
      `shouldBe` Left (PureOutputPortsMismatch ["score"] ["confidence"])

  it "binds a single unlabeled input as in" $ do
    let ports =
          WirePorts
            { wirePortsInputs =
                Map.singleton
                  "in"
                  WireInputPort
                    { wireInputPortAccepts = ["Payload"]
                    , wireInputPortCardinality = WireInputCardinalityOne
                    , wireInputPortRequired = False
                    }
            , wirePortsOutputs =
                Map.singleton "out" WireOutputPort {wireOutputPortContract = "Float"}
            }
        inputBundle =
          wireInputBundleFromStageInputs $
            Map.singleton
              (NodeId "source")
              ( Aeson.toJSON
                  ( ( mkWireValue
                        "Payload"
                        WirePayloadJson
                        (Just "source")
                        (Aeson.object ["value" Aeson..= Aeson.Number 4])
                    )
                      { wireValuePort = Just "out"
                      }
                  )
              )
    evaluatePureTaskOutputs
      ports
      inputBundle
      []
      Nothing
      (Map.singleton "out" (bin CorePureDivide (field (var "in") "value") (num 2)))
      `shouldBe` Right (Map.singleton "out" (Aeson.Number 2))

  it "accepts pure port declarations with multiple output equations" $
    validatePurePorts
      multiOutputPorts
      (Map.fromList [("accepted", CorePureList []), ("rejected", CorePureList [])])
      `shouldBe` Right ()

  it "rejects missing variables" $
    evaluatePureTaskOutputs scorePorts scoreInputs [] Nothing (Map.singleton "score" (var "unknown"))
      `shouldBe` Left (PureMissingVariable "unknown")

  it "rejects divide by zero" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      (Map.singleton "score" (bin CorePureDivide (num 1) (num 0)))
      `shouldBe` Left PureDivisionByZero

  it "rejects duplicate CorePure binding names in the same scope" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [binding "dup" (num 1), binding "dup" (num 2)]
      Nothing
      (Map.singleton "score" (var "dup"))
      `shouldBe` Left (PureDuplicateBinding "dup")

  it "rejects duplicate CorePure lambda parameters" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      (Map.singleton "score" (CorePureCall (CorePureLambda ("x" :| ["x"]) (var "x")) [num 1, num 2]))
      `shouldBe` Left (PureDuplicateLambdaParam "x")

  it "lets CorePure lambda parameters shadow captured bindings" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [ binding "x" (num 1)
      , binding "f" (lambda ("x" :| []) (var "x"))
      ]
      Nothing
      (Map.singleton "score" (call (var "f") [num 2]))
      `shouldBe` Right (Map.singleton "score" (Aeson.Number 2))

  it "preserves applied CorePure lambda arguments across partial application" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [ binding "x" (num 100)
      , binding
          "adder"
          (lambda ("x" :| ["y"]) (bin CorePureAdd (var "x") (var "y")))
      , binding "addTwo" (call (var "adder") [num 2])
      ]
      Nothing
      (Map.singleton "score" (call (var "addTwo") [num 3]))
      `shouldBe` Right (Map.singleton "score" (Aeson.Number 5))

  it "rejects duplicate CorePure record literal paths before evaluation" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( CorePureIf
              (CorePureLit (CorePureBool False))
              ( CorePureRecord
                  [ CorePureField ("a" :| []) (num 1)
                  , CorePureField ("a" :| []) (num 2)
                  ]
              )
              (num 0)
          )
      )
      `shouldBe` Left (PureDuplicateRecordFieldPath ["a"] ["a"])

  it "rejects duplicate CorePure record literal paths inside bindings and where clauses" $ do
    let duplicateRecord =
          CorePureRecord
            [ CorePureField ("a" :| []) (num 1)
            , CorePureField ("a" :| []) (num 2)
            ]
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [binding "bad" duplicateRecord]
      Nothing
      (Map.singleton "score" (var "bad"))
      `shouldBe` Left (PureDuplicateRecordFieldPath ["a"] ["a"])
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      (Just duplicateRecord)
      (Map.singleton "score" (num 0))
      `shouldBe` Left (PureDuplicateRecordFieldPath ["a"] ["a"])

  it "rejects CorePure record literal prefix conflicts in both orders" $ do
    let nestedAfterScalar =
          CorePureRecord
            [ CorePureField ("a" :| []) (num 1)
            , CorePureField ("a" :| ["b"]) (num 2)
            ]
        scalarAfterNested =
          CorePureRecord
            [ CorePureField ("a" :| ["b"]) (num 2)
            , CorePureField ("a" :| []) (num 1)
            ]
    evaluatePureTaskOutputs scorePorts scoreInputs [] Nothing (Map.singleton "score" nestedAfterScalar)
      `shouldBe` Left (PureDuplicateRecordFieldPath ["a"] ["a", "b"])
    evaluatePureTaskOutputs scorePorts scoreInputs [] Nothing (Map.singleton "score" scalarAfterNested)
      `shouldBe` Left (PureDuplicateRecordFieldPath ["a", "b"] ["a"])

  it "permits sibling nested CorePure record literal paths" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( CorePureRecord
              [ CorePureField ("a" :| ["b"]) (num 1)
              , CorePureField ("a" :| ["c"]) (num 2)
              ]
          )
      )
      `shouldBe` Right
        ( Map.singleton
            "score"
            (Aeson.object ["a" Aeson..= Aeson.object ["b" Aeson..= numJson 1, "c" Aeson..= numJson 2]])
        )

  it "keeps explicit CorePure record merge right-biased" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( bin
              CorePureMerge
              (CorePureRecord [CorePureField ("a" :| []) (num 1)])
              (CorePureRecord [CorePureField ("a" :| []) (num 2)])
          )
      )
      `shouldBe` Right (Map.singleton "score" (Aeson.object ["a" Aeson..= numJson 2]))

  it "zips arrays into fst/snd pair records in argument order" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( call
              (var "zip")
              [ CorePureList [num 1, num 2]
              , CorePureList [num 10, num 20]
              ]
          )
      )
      `shouldBe` Right
        ( Map.singleton
            "score"
            ( Aeson.toJSON
                [ Aeson.object ["fst" Aeson..= Aeson.Number 1, "snd" Aeson..= Aeson.Number 10]
                , Aeson.object ["fst" Aeson..= Aeson.Number 2, "snd" Aeson..= Aeson.Number 20]
                ]
            )
        )

  it "keeps CorePure zipWith truncation behavior" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( call
              (var "zipWith")
              [ lambda ("left" :| ["right"]) (bin CorePureAdd (var "left") (var "right"))
              , CorePureList [num 1, num 2, num 3]
              , CorePureList [num 10, num 20]
              ]
          )
      )
      `shouldBe` Right (Map.singleton "score" (Aeson.toJSON [Aeson.Number 11, Aeson.Number 22]))

  it "keeps CorePure map field-projection errors explicit" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( call
              (var "map")
              [ lambda ("item" :| []) (field (var "item") "score")
              , CorePureList [CorePureRecord [CorePureField ("other" :| []) (num 1)]]
              ]
          )
      )
      `shouldBe` Left (PureFieldMissing "score")

  it "filters CorePure records with boolean and numeric field predicates" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( call
              (var "filter")
              [ lambda
                  ("item" :| [])
                  ( bin
                      CorePureAnd
                      (field (var "item") "active")
                      (bin CorePureGreaterThanOrEqual (field (var "item") "score") (num (scientific 65 (-2))))
                  )
              , CorePureList
                  [ record [("active", bool True), ("score", num (scientific 8 (-1)))]
                  , record [("active", bool False), ("score", num (scientific 9 (-1)))]
                  , record [("active", bool True), ("score", num (scientific 4 (-1)))]
                  ]
              ]
          )
      )
      `shouldBe` Right
        ( Map.singleton
            "score"
            ( Aeson.toJSON
                [Aeson.object ["active" Aeson..= True, "score" Aeson..= Aeson.Number (scientific 8 (-1))]]
            )
        )

  it "keeps CorePure filter predicate short-circuit behavior" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( call
              (var "filter")
              [ lambda
                  ("item" :| [])
                  ( bin
                      CorePureAnd
                      (field (var "item") "active")
                      (bin CorePureGreaterThanOrEqual (field (var "item") "score") (num (scientific 65 (-2))))
                  )
              , CorePureList [record [("active", bool False)]]
              ]
          )
      )
      `shouldBe` Right (Map.singleton "score" (Aeson.toJSON ([] :: [Aeson.Value])))

  it "keeps CorePure filter predicate field errors explicit" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( call
              (var "filter")
              [ lambda
                  ("item" :| [])
                  ( bin
                      CorePureAnd
                      (field (var "item") "active")
                      (bin CorePureGreaterThanOrEqual (field (var "item") "score") (num (scientific 65 (-2))))
                  )
              , CorePureList [record [("active", bool True)]]
              ]
          )
      )
      `shouldBe` Left (PureFieldMissing "score")

  it "summarizes filtered CorePure numeric fields" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [ binding
          "eligible"
          ( call
              (var "filter")
              [ lambda
                  ("item" :| [])
                  ( bin
                      CorePureAnd
                      (field (var "item") "active")
                      (bin CorePureGreaterThanOrEqual (field (var "item") "score") (num (scientific 65 (-2))))
                  )
              , CorePureList
                  [ record [("active", bool True), ("score", num (scientific 8 (-1)))]
                  , record [("active", bool False)]
                  , record [("active", bool True), ("score", num (scientific 4 (-1)))]
                  ]
              ]
          )
      , binding
          "scores"
          ( call
              (var "map")
              [ lambda ("item" :| []) (field (var "item") "score")
              , var "eligible"
              ]
          )
      ]
      Nothing
      ( Map.singleton
          "score"
          ( record
              [ ("accepted", call (var "length") [var "eligible"])
              , ("total", call (var "sum") [var "scores"])
              ]
          )
      )
      `shouldBe` Right
        ( Map.singleton
            "score"
            ( Aeson.object
                [ "accepted" Aeson..= Aeson.Number 1
                , "total" Aeson..= Aeson.Number (scientific 8 (-1))
                ]
            )
        )

  it "keeps CorePure filtered summary projection errors explicit" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [ binding
          "eligible"
          ( call
              (var "filter")
              [ lambda
                  ("item" :| [])
                  ( bin
                      CorePureAnd
                      (field (var "item") "active")
                      (bin CorePureGreaterThanOrEqual (field (var "item") "threshold") (num (scientific 65 (-2))))
                  )
              , CorePureList [record [("active", bool True), ("threshold", num (scientific 8 (-1)))]]
              ]
          )
      , binding
          "scores"
          ( call
              (var "map")
              [ lambda ("item" :| []) (field (var "item") "score")
              , var "eligible"
              ]
          )
      ]
      Nothing
      ( Map.singleton
          "score"
          ( record
              [ ("accepted", call (var "length") [var "eligible"])
              , ("total", call (var "sum") [var "scores"])
              ]
          )
      )
      `shouldBe` Left (PureFieldMissing "score")

  it "does not drop extra CorePure filtered summary fields" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [ binding
          "eligible"
          ( call
              (var "filter")
              [ lambda
                  ("item" :| [])
                  ( bin
                      CorePureAnd
                      (field (var "item") "active")
                      (bin CorePureGreaterThanOrEqual (field (var "item") "score") (num (scientific 65 (-2))))
                  )
              , CorePureList
                  [ record [("active", bool True), ("score", num (scientific 8 (-1)))]
                  ]
              ]
          )
      , binding
          "scores"
          ( call
              (var "map")
              [ lambda ("item" :| []) (field (var "item") "score")
              , var "eligible"
              ]
          )
      ]
      Nothing
      ( Map.singleton
          "score"
          ( record
              [ ("accepted", call (var "length") [var "eligible"])
              , ("total", call (var "sum") [var "scores"])
              , ("extra", num 7)
              ]
          )
      )
      `shouldBe` Right
        ( Map.singleton
            "score"
            ( Aeson.object
                [ "accepted" Aeson..= Aeson.Number 1
                , "total" Aeson..= Aeson.Number (scientific 8 (-1))
                , "extra" Aeson..= Aeson.Number 7
                ]
            )
        )

  it "summarizes mapped CorePure numeric expressions" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [ binding
          "adjusted"
          ( call
              (var "map")
              [ lambda
                  ("item" :| [])
                  ( call
                      (var "clamp")
                      [ num 0
                      , num 3
                      , bin
                          CorePureMultiply
                          (call (var "abs") [field (var "item") "delta"])
                          (field (var "item") "impact")
                      ]
                  )
              , CorePureList
                  [ record [("delta", num (-2)), ("impact", num (scientific 5 (-1)))]
                  , record [("delta", num 10), ("impact", num (scientific 5 (-1)))]
                  ]
              ]
          )
      ]
      Nothing
      ( Map.singleton
          "score"
          ( record
              [ ("total", call (var "sum") [var "adjusted"])
              , ("count", call (var "length") [var "adjusted"])
              ]
          )
      )
      `shouldBe` Right
        ( Map.singleton
            "score"
            ( Aeson.object
                [ "total" Aeson..= Aeson.Number 4
                , "count" Aeson..= Aeson.Number 2
                ]
            )
        )

  it "keeps CorePure mapped summary field errors explicit" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [ binding
          "adjusted"
          ( call
              (var "map")
              [ lambda
                  ("item" :| [])
                  (bin CorePureMultiply (field (var "item") "delta") (field (var "item") "impact"))
              , CorePureList [record [("delta", num 1)]]
              ]
          )
      ]
      Nothing
      ( Map.singleton
          "score"
          ( record
              [ ("total", call (var "sum") [var "adjusted"])
              , ("count", call (var "length") [var "adjusted"])
              ]
          )
      )
      `shouldBe` Left (PureFieldMissing "impact")

  it "keeps CorePure mapped summary divide-by-zero errors explicit" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [ binding
          "adjusted"
          ( call
              (var "map")
              [ lambda
                  ("item" :| [])
                  (bin CorePureDivide (field (var "item") "delta") (field (var "item") "impact"))
              , CorePureList [record [("delta", num 1), ("impact", num 0)]]
              ]
          )
      ]
      Nothing
      ( Map.singleton
          "score"
          ( record
              [ ("total", call (var "sum") [var "adjusted"])
              , ("count", call (var "length") [var "adjusted"])
              ]
          )
      )
      `shouldBe` Left PureDivisionByZero

  it "does not drop extra CorePure mapped summary fields" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [ binding
          "adjusted"
          ( call
              (var "map")
              [ lambda ("item" :| []) (field (var "item") "score")
              , CorePureList [record [("score", num (scientific 8 (-1)))]]
              ]
          )
      ]
      Nothing
      ( Map.singleton
          "score"
          ( record
              [ ("total", call (var "sum") [var "adjusted"])
              , ("count", call (var "length") [var "adjusted"])
              , ("extra", num 7)
              ]
          )
      )
      `shouldBe` Right
        ( Map.singleton
            "score"
            ( Aeson.object
                [ "total" Aeson..= Aeson.Number (scientific 8 (-1))
                , "count" Aeson..= Aeson.Number 1
                , "extra" Aeson..= Aeson.Number 7
                ]
            )
        )

  it "maps CorePure numeric field expressions with builtin calls" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( call
              (var "map")
              [ lambda
                  ("item" :| [])
                  ( call
                      (var "clamp")
                      [ num 0
                      , num 3
                      , bin
                          CorePureMultiply
                          (call (var "abs") [field (var "item") "delta"])
                          (field (var "item") "impact")
                      ]
                  )
              , CorePureList
                  [ record [("delta", num (-2)), ("impact", num (scientific 5 (-1)))]
                  , record [("delta", num 10), ("impact", num (scientific 5 (-1)))]
                  ]
              ]
          )
      )
      `shouldBe` Right (Map.singleton "score" (Aeson.toJSON [Aeson.Number 1, Aeson.Number 3]))

  it "keeps CorePure numeric map field errors explicit" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( call
              (var "map")
              [ lambda
                  ("item" :| [])
                  (bin CorePureMultiply (field (var "item") "delta") (field (var "item") "impact"))
              , CorePureList [record [("delta", num 1)]]
              ]
          )
      )
      `shouldBe` Left (PureFieldMissing "impact")

  it "keeps CorePure numeric map divide-by-zero errors explicit" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( call
              (var "map")
              [ lambda
                  ("item" :| [])
                  (bin CorePureDivide (field (var "item") "delta") (field (var "item") "impact"))
              , CorePureList [record [("delta", num 1), ("impact", num 0)]]
              ]
          )
      )
      `shouldBe` Left PureDivisionByZero

  it "keeps CorePure map identity over object values" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( call
              (var "map")
              [ lambda ("item" :| []) (var "item")
              , CorePureList [record [("delta", num (-2)), ("impact", num 1)]]
              ]
          )
      )
      `shouldBe` Right
        ( Map.singleton
            "score"
            (Aeson.toJSON [Aeson.object ["delta" Aeson..= Aeson.Number (-2), "impact" Aeson..= Aeson.Number 1]])
        )

  it "does not specialize CorePure numeric map calls when builtins are shadowed" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [binding "abs" (lambda ("value" :| []) (num 42))]
      Nothing
      ( Map.singleton
          "score"
          ( call
              (var "map")
              [ lambda ("item" :| []) (call (var "abs") [field (var "item") "delta"])
              , CorePureList [record [("delta", num (-2))]]
              ]
          )
      )
      `shouldBe` Right (Map.singleton "score" (Aeson.toJSON [Aeson.Number 42]))

  it "does not specialize CorePure mapped summaries when lambda params shadow numeric builtins" $
    mapM_
      ( \(builtinName, body) ->
          evaluatePureTaskOutputs
            scorePorts
            scoreInputs
            [ binding
                "adjusted"
                ( call
                    (var "map")
                    [ lambda (builtinName :| []) body
                    , CorePureList [record [("delta", num (-2))]]
                    ]
                )
            ]
            Nothing
            ( Map.singleton
                "score"
                ( record
                    [ ("total", call (var "sum") [var "adjusted"])
                    , ("count", call (var "length") [var "adjusted"])
                    ]
                )
            )
            `shouldBe` Left (PureFunctionExpected "object")
      )
      [ ("abs", call (var "abs") [field (var "abs") "delta"])
      , ("min", call (var "min") [field (var "min") "delta", num 0])
      , ("max", call (var "max") [field (var "max") "delta", num 0])
      , ("clamp", call (var "clamp") [num 0, num 3, field (var "clamp") "delta"])
      ]

  it "keeps CorePure zipWith numeric divide-by-zero errors explicit" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( call
              (var "zipWith")
              [ lambda ("left" :| ["right"]) (bin CorePureDivide (var "left") (var "right"))
              , CorePureList [num 1]
              , CorePureList [num 0]
              ]
          )
      )
      `shouldBe` Left PureDivisionByZero

  it "does not inspect unused CorePure zipWith numeric operands" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      ( Map.singleton
          "score"
          ( call
              (var "zipWith")
              [ lambda ("left" :| ["right"]) (bin CorePureAdd (var "left") (var "left"))
              , CorePureList [num 1]
              , CorePureList [str "unused"]
              ]
          )
      )
      `shouldBe` Right (Map.singleton "score" (Aeson.toJSON [Aeson.Number 2]))

  it "keeps the CorePure builtin authority-review signature explicit" $
    corePureBuiltinSignature
      `shouldBe` [ ("map", 2)
                 , ("fmap", 2)
                 , ("filter", 2)
                 , ("zip", 2)
                 , ("zipWith", 3)
                 , ("length", 1)
                 , ("sum", 1)
                 , ("all", 2)
                 , ("any", 2)
                 , ("min", 2)
                 , ("max", 2)
                 , ("abs", 1)
                 , ("clamp", 3)
                 , ("concat", 1)
                 , ("toString", 1)
                 , ("joinWith", 2)
                 , ("toJson", 1)
                 ]

  it "keeps the CorePure builtin authority report closed and authority-free" $ do
    corePureBuiltinAuthorityFree `shouldBe` True
    let authorityRows =
          [ ( report.corePureBuiltinAuthorityName
            , report.corePureBuiltinAuthorityArity
            , report.corePureBuiltinAuthority
            )
          | report <- corePureBuiltinAuthorityReport
          ]
    authorityRows
      `shouldBe` [ ("map", 2, CorePureBuiltinPureValue)
                 , ("fmap", 2, CorePureBuiltinPureValue)
                 , ("filter", 2, CorePureBuiltinPureValue)
                 , ("zip", 2, CorePureBuiltinPureValue)
                 , ("zipWith", 3, CorePureBuiltinPureValue)
                 , ("length", 1, CorePureBuiltinPureValue)
                 , ("sum", 1, CorePureBuiltinPureValue)
                 , ("all", 2, CorePureBuiltinPureValue)
                 , ("any", 2, CorePureBuiltinPureValue)
                 , ("min", 2, CorePureBuiltinPureValue)
                 , ("max", 2, CorePureBuiltinPureValue)
                 , ("abs", 1, CorePureBuiltinPureValue)
                 , ("clamp", 3, CorePureBuiltinPureValue)
                 , ("concat", 1, CorePureBuiltinPureValue)
                 , ("toString", 1, CorePureBuiltinPureValue)
                 , ("joinWith", 2, CorePureBuiltinPureValue)
                 , ("toJson", 1, CorePureBuiltinPureValue)
                 ]

  it "establishes CorePure static context from top-level record bindings" $ do
    let bindings =
          [ binding "base" (CorePureRecord [CorePureField ("a" :| []) (num 1)])
          , binding "alias" (var "base")
          , binding
              "merged"
              ( bin
                  CorePureMerge
                  (var "alias")
                  (CorePureRecord [CorePureField ("b" :| []) (num 2)])
              )
          , binding "scalar" (num 10)
          ]
        expectedContext =
          CorePureStaticContext
            ( Map.fromList
                [ ("alias", Set.singleton "a")
                , ("base", Set.singleton "a")
                , ("merged", Set.fromList ["a", "b"])
                ]
            )
    corePureStaticContextFromBindings bindings `shouldBe` Right expectedContext
    corePureWhereStaticFields expectedContext (var "merged")
      `shouldBe` Right (Set.fromList ["a", "b"])
    corePureWhereStaticFields expectedContext (var "scalar")
      `shouldBe` Left PureStaticFieldSetUndeterminable

  it "rejects node-local CorePure let bindings that shadow static records" $ do
    case corePureStaticContextFromBindings
      [binding "known" (CorePureRecord [CorePureField ("a" :| []) (num 1)])] of
      Left err ->
        expectationFailure ("expected static context, got: " <> show err)
      Right staticContext -> do
        let localShadow =
              CorePureLet
                (binding "known" (CorePureRecord [CorePureField ("z" :| []) (num 2)]) :| [])
                (var "known")
        corePureWhereStaticFields staticContext localShadow
          `shouldBe` Left (PureStaticLetShadowsStatic "known")

  it "allows where fields to shadow top-level delayed bindings" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [binding "shared" (num 1)]
      (Just (CorePureRecord [CorePureField ("shared" :| []) (num 2)]))
      (Map.singleton "score" (var "shared"))
      `shouldBe` Right (Map.singleton "score" (Aeson.Number 2))

  it "opens merged where records into output scope" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      ( Just
          ( bin
              CorePureMerge
              (CorePureRecord [CorePureField ("left" :| []) (num 1)])
              (CorePureRecord [CorePureField ("right" :| []) (num 2)])
          )
      )
      (Map.singleton "score" (bin CorePureAdd (var "left") (var "right")))
      `shouldBe` Right (Map.singleton "score" (Aeson.Number 3))

  it "rejects where expressions that do not evaluate to records" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      (Just (num 1))
      (Map.singleton "score" (num 1))
      `shouldBe` Left (PureWhereExpectedRecord "number")

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
                  { wireInputPortAccepts = ["EvidenceSet"]
                  , wireInputPortCardinality = WireInputCardinalityOne
                  , wireInputPortRequired = False
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
                  [
                    ( "Float_1"
                    , WireInputPort
                        { wireInputPortAccepts = ["Float"]
                        , wireInputPortCardinality = WireInputCardinalityOne
                        , wireInputPortRequired = False
                        }
                    )
                  ,
                    ( "Float_2"
                    , WireInputPort
                        { wireInputPortAccepts = ["Float"]
                        , wireInputPortCardinality = WireInputCardinalityOne
                        , wireInputPortRequired = False
                        }
                    )
                  ]
            , wirePortsOutputs =
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
                    { wireInputPortAccepts = ["Float"]
                    , wireInputPortCardinality = WireInputCardinalityMany
                    , wireInputPortRequired = False
                    }
            }
        multiContractPorts =
          scorePorts
            { wirePortsInputs =
                Map.singleton
                  "value"
                  WireInputPort
                    { wireInputPortAccepts = ["Float", "Score"]
                    , wireInputPortCardinality = WireInputCardinalityOne
                    , wireInputPortRequired = False
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
          [ labeledJsonInput "evidence" "EvidenceSet"
          , labeledJsonInput "weights" "WeightSet"
          ]
    , wirePortsOutputs =
        Map.singleton "score" WireOutputPort {wireOutputPortContract = "ScoreSet"}
    }

multiOutputPorts :: WirePorts
multiOutputPorts =
  WirePorts
    { wirePortsInputs =
        Map.singleton "evidence" (snd (labeledJsonInput "evidence" "EvidenceSet"))
    , wirePortsOutputs =
        Map.fromList
          [ ("accepted", WireOutputPort {wireOutputPortContract = "AcceptedSet"})
          , ("rejected", WireOutputPort {wireOutputPortContract = "RejectedSet"})
          ]
    }

labeledJsonInput :: Text -> Text -> (Text, WireInputPort)
labeledJsonInput portName contractId =
  ( portName
  , WireInputPort
      { wireInputPortAccepts = [contractId]
      , wireInputPortCardinality = WireInputCardinalityOne
      , wireInputPortRequired = False
      }
  )

scoreInputs :: WireInputBundle
scoreInputs =
  wireInputBundleFromStageInputs $
    Map.fromList
      [ (NodeId "evidence", wireValue "EvidenceSet" "evidence" evidenceValue)
      , (NodeId "weights", wireValue "WeightSet" "weights" weightsValue)
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
        Aeson..= [ Aeson.object ["score" Aeson..= Aeson.Number (scientific 8 (-1))]
                 , Aeson.object ["score" Aeson..= Aeson.Number (scientific 6 (-1))]
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
      { corePureBindingName = "scores"
      , corePureBindingExpr =
          call
            (var "map")
            [ lambda ("item" :| []) (field (var "item") "score")
            , field (var "evidence") "items"
            ]
      }
  , CorePureBinding
      { corePureBindingName = "weighted"
      , corePureBindingExpr =
          call
            (var "zipWith")
            [ lambda ("score" :| ["weight"]) (bin CorePureMultiply (var "score") (var "weight"))
            , var "scores"
            , field (var "weights") "values"
            ]
      }
  ]

scoreOutputExpr :: CorePureExpr
scoreOutputExpr =
  CorePureRecord
    [ CorePureField ("total" :| []) (call (var "sum") [var "weighted"])
    , CorePureField ("count" :| []) (call (var "length") [var "weighted"])
    ]

binding :: Text -> CorePureExpr -> CorePureBinding
binding name expr =
  CorePureBinding {corePureBindingName = name, corePureBindingExpr = expr}

num :: Scientific -> CorePureExpr
num =
  CorePureLit . CorePureNumber

str :: Text -> CorePureExpr
str =
  CorePureLit . CorePureString

bool :: Bool -> CorePureExpr
bool =
  CorePureLit . CorePureBool

var :: Text -> CorePureExpr
var =
  CorePureIdent

field :: CorePureExpr -> Text -> CorePureExpr
field =
  CorePureFieldAccess

lambda :: NonEmpty Text -> CorePureExpr -> CorePureExpr
lambda =
  CorePureLambda

call :: CorePureExpr -> [CorePureExpr] -> CorePureExpr
call =
  CorePureCall

bin :: CorePureBinOp -> CorePureExpr -> CorePureExpr -> CorePureExpr
bin =
  CorePureBinary

record :: [(Text, CorePureExpr)] -> CorePureExpr
record fields =
  CorePureRecord [CorePureField (fieldName :| []) fieldExpr | (fieldName, fieldExpr) <- fields]

numJson :: Scientific -> Aeson.Value
numJson =
  Aeson.Number
