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
import Data.Aeson.Key qualified as Key
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific, scientific)
import Data.Scientific qualified as Scientific
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
  ( Gen
  , NonNegative (..)
  , Property
  , arbitrary
  , choose
  , forAll
  , listOf
  , oneof
  , (.&&.)
  , (===)
  )

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
import Cortex.Wire.Pure.Bounds
  ( CostCheck (..)
  , RangePlan
  , checkValueCost
  , clampIndex
  , clampedIndexValue
  , corePureBoundedIterationCap
  , foldAccumulatorValue
  , foldRangePlan
  , iterationCapValue
  , mkFoldAccumulator
  , planRange
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

  it "evaluates division with finite Float64 semantics" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      (Map.singleton "score" (bin CorePureDivide (num 1) (num 3)))
      `shouldBe` Right
        (Map.singleton "score" (Aeson.Number (Scientific.fromFloatDigits (1 / 3 :: Double))))

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

  it "parses JSON strings through fromJson" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      (Map.singleton "score" (call (var "fromJson") [str "{\"b\":2,\"a\":[true,null]}"]))
      `shouldBe` Right
        ( Map.singleton
            "score"
            ( Aeson.object
                [ "a" Aeson..= [Aeson.Bool True, Aeson.Null]
                , "b" Aeson..= Aeson.Number 2
                ]
            )
        )

  it "reports invalid JSON strings from fromJson as typed pure failures" $
    case evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      (Map.singleton "score" (call (var "fromJson") [str "{"])) of
      Left (PureJsonParseError reason) ->
        reason `shouldSatisfy` (not . T.null)
      other ->
        expectationFailure ("expected PureJsonParseError, got: " <> show other)

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
                 , ("fromJson", 1)
                 , ("reverse", 1)
                 , ("sort", 1)
                 , ("sortBy", 2)
                 , ("take", 2)
                 , ("drop", 2)
                 , ("enumerate", 1)
                 , ("mapIndexed", 2)
                 , ("find", 2)
                 , ("findIndex", 2)
                 , ("contains", 2)
                 , ("indexOf", 2)
                 , ("count", 2)
                 , ("split", 2)
                 , ("replace", 3)
                 , ("substring", 3)
                 , ("trim", 1)
                 , ("toLower", 1)
                 , ("toUpper", 1)
                 , ("startsWith", 2)
                 , ("endsWith", 2)
                 , ("strLength", 1)
                 , ("lines", 1)
                 , ("unlines", 1)
                 , ("keys", 1)
                 , ("values", 1)
                 , ("entries", 1)
                 , ("withDefault", 2)
                 , ("isNull", 1)
                 , ("range", 2)
                 , ("fold", 3)
                 , ("foldRight", 3)
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
                 , ("fromJson", 1, CorePureBuiltinPureValue)
                 , ("reverse", 1, CorePureBuiltinPureValue)
                 , ("sort", 1, CorePureBuiltinPureValue)
                 , ("sortBy", 2, CorePureBuiltinPureValue)
                 , ("take", 2, CorePureBuiltinPureValue)
                 , ("drop", 2, CorePureBuiltinPureValue)
                 , ("enumerate", 1, CorePureBuiltinPureValue)
                 , ("mapIndexed", 2, CorePureBuiltinPureValue)
                 , ("find", 2, CorePureBuiltinPureValue)
                 , ("findIndex", 2, CorePureBuiltinPureValue)
                 , ("contains", 2, CorePureBuiltinPureValue)
                 , ("indexOf", 2, CorePureBuiltinPureValue)
                 , ("count", 2, CorePureBuiltinPureValue)
                 , ("split", 2, CorePureBuiltinPureValue)
                 , ("replace", 3, CorePureBuiltinPureValue)
                 , ("substring", 3, CorePureBuiltinPureValue)
                 , ("trim", 1, CorePureBuiltinPureValue)
                 , ("toLower", 1, CorePureBuiltinPureValue)
                 , ("toUpper", 1, CorePureBuiltinPureValue)
                 , ("startsWith", 2, CorePureBuiltinPureValue)
                 , ("endsWith", 2, CorePureBuiltinPureValue)
                 , ("strLength", 1, CorePureBuiltinPureValue)
                 , ("lines", 1, CorePureBuiltinPureValue)
                 , ("unlines", 1, CorePureBuiltinPureValue)
                 , ("keys", 1, CorePureBuiltinPureValue)
                 , ("values", 1, CorePureBuiltinPureValue)
                 , ("entries", 1, CorePureBuiltinPureValue)
                 , ("withDefault", 2, CorePureBuiltinPureValue)
                 , ("isNull", 1, CorePureBuiltinPureValue)
                 , ("range", 2, CorePureBuiltinPureValue)
                 , ("fold", 3, CorePureBuiltinPureValue)
                 , ("foldRight", 3, CorePureBuiltinPureValue)
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

  -- Lean correspondence: mirrors `whereStaticFields_sound` and
  -- `pureNode_evalWhereEnv_localEnv_match` in `theory/Cortex/Wire/Pure.lean`,
  -- which prove that opening `where` fields into the local environment shadows
  -- ambient bindings on a name-by-name basis. The test exercises three layered
  -- bindings of `shared` (top-level delayed, inner `where`, and an unrelated
  -- name) and asserts the inner `where` binding wins for `shared` while the
  -- unrelated outer binding remains visible.
  it "binds where fields name-by-name over outer top-level bindings" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      [ binding "shared" (num 1)
      , binding "untouched" (num 7)
      ]
      ( Just
          ( CorePureRecord
              [ CorePureField ("shared" :| []) (num 2)
              ]
          )
      )
      ( Map.singleton
          "score"
          (bin CorePureAdd (var "shared") (var "untouched"))
      )
      `shouldBe` Right (Map.singleton "score" (Aeson.Number 9))

  -- Lean correspondence: mirrors the closed-builtin authority report in
  -- `theory/Cortex/Wire/Pure.lean` (`closedBuiltinSignature_eq`,
  -- `closedBuiltinEnv_authorityFree`). The CorePure builtin table is closed,
  -- so a CorePure expression that calls an unknown identifier as a function
  -- must surface the same `PureMissingVariable` error path used for any other
  -- unbound name; there is no implicit registry escape hatch.
  it "rejects calls to unknown CorePure builtins as missing variables" $
    evaluatePureTaskOutputs
      scorePorts
      scoreInputs
      []
      Nothing
      (Map.singleton "score" (call (var "unknownBuiltin") [num 1]))
      `shouldBe` Left (PureMissingVariable "unknownBuiltin")

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
      `shouldBe` Right ()
    validatePurePorts scorePorts (Map.singleton "confidence" (num 1))
      `shouldBe` Left (PureOutputPortsMismatch ["score"] ["confidence"])

  describe "batch 1 list, string, record, and bounded-iteration builtins" $ do
    it "reshapes lists with reverse, sort, sortBy, take, and drop" $ do
      evalBuiltin (call (var "reverse") [nums [1, 2, 3]])
        `shouldBe` Right (Aeson.toJSON ([3, 2, 1] :: [Int]))
      evalBuiltin
        (call (var "sort") [CorePureList [num 3, str "a", bool True, num 1, nullLit]])
        `shouldBe` Right
          ( Aeson.toJSON
              [Aeson.Null, Aeson.Bool True, Aeson.Number 1, Aeson.Number 3, Aeson.String "a"]
          )
      evalBuiltin
        ( call
            (var "sortBy")
            [ lambda ("x" :| []) (field (var "x") "k")
            , CorePureList [record [("k", num 2)], record [("k", num 1)]]
            ]
        )
        `shouldBe` Right
          (Aeson.toJSON [Aeson.object ["k" Aeson..= (1 :: Int)], Aeson.object ["k" Aeson..= (2 :: Int)]])
      evalBuiltin (call (var "take") [num 2, nums [1, 2, 3]])
        `shouldBe` Right (Aeson.toJSON ([1, 2] :: [Int]))
      evalBuiltin (call (var "take") [num 9, nums [1, 2]])
        `shouldBe` Right (Aeson.toJSON ([1, 2] :: [Int]))
      evalBuiltin (call (var "drop") [num 5, nums [1, 2]])
        `shouldBe` Right (Aeson.toJSON ([] :: [Int]))

    it "indexes lists with enumerate and mapIndexed" $ do
      evalBuiltin (call (var "enumerate") [strs ["a", "b"]])
        `shouldBe` Right
          ( Aeson.toJSON
              [ Aeson.object ["index" Aeson..= (0 :: Int), "value" Aeson..= ("a" :: Text)]
              , Aeson.object ["index" Aeson..= (1 :: Int), "value" Aeson..= ("b" :: Text)]
              ]
          )
      evalBuiltin
        (call (var "mapIndexed") [lambda ("i" :| ["x"]) (var "i"), strs ["a", "b", "c"]])
        `shouldBe` Right (Aeson.toJSON ([0, 1, 2] :: [Int]))

    it "searches lists with find, findIndex, contains, indexOf, and count" $ do
      let greaterThanOne = lambda ("x" :| []) (bin CorePureGreaterThan (var "x") (num 1))
      evalBuiltin (call (var "find") [greaterThanOne, nums [0, 2, 3]])
        `shouldBe` Right (Aeson.Number 2)
      evalBuiltin (call (var "find") [greaterThanOne, nums [0, 1]])
        `shouldBe` Right Aeson.Null
      evalBuiltin (call (var "findIndex") [greaterThanOne, nums [0, 2, 3]])
        `shouldBe` Right (Aeson.Number 1)
      evalBuiltin (call (var "findIndex") [greaterThanOne, nums [0, 1]])
        `shouldBe` Right (Aeson.Number (-1))
      evalBuiltin (call (var "contains") [num 2, nums [1, 2, 3]])
        `shouldBe` Right (Aeson.Bool True)
      evalBuiltin (call (var "contains") [num 9, nums [1, 2, 3]])
        `shouldBe` Right (Aeson.Bool False)
      evalBuiltin (call (var "indexOf") [num 2, nums [1, 2, 3]])
        `shouldBe` Right (Aeson.Number 1)
      evalBuiltin (call (var "indexOf") [num 9, nums [1, 2, 3]])
        `shouldBe` Right (Aeson.Number (-1))
      evalBuiltin (call (var "count") [greaterThanOne, nums [0, 2, 3]])
        `shouldBe` Right (Aeson.Number 2)

    it "processes strings with split, replace, substring, and case folds" $ do
      evalBuiltin (call (var "split") [str ",", str "a,b,c"])
        `shouldBe` Right (Aeson.toJSON (["a", "b", "c"] :: [Text]))
      evalBuiltin (call (var "split") [str "", str "ab"])
        `shouldBe` Right (Aeson.toJSON (["a", "b"] :: [Text]))
      evalBuiltin (call (var "replace") [str "a", str "X", str "banana"])
        `shouldBe` Right (Aeson.String "bXnXnX")
      evalBuiltin (call (var "replace") [str "", str "X", str "ab"])
        `shouldBe` Right (Aeson.String "ab")
      evalBuiltin (call (var "substring") [num 1, num 3, str "hello"])
        `shouldBe` Right (Aeson.String "el")
      evalBuiltin (call (var "substring") [num 0, num 99, str "hi"])
        `shouldBe` Right (Aeson.String "hi")
      evalBuiltin (call (var "trim") [str "  hi  "])
        `shouldBe` Right (Aeson.String "hi")
      evalBuiltin (call (var "toLower") [str "AbC"]) `shouldBe` Right (Aeson.String "abc")
      evalBuiltin (call (var "toUpper") [str "AbC"]) `shouldBe` Right (Aeson.String "ABC")
      evalBuiltin (call (var "startsWith") [str "ba", str "banana"])
        `shouldBe` Right (Aeson.Bool True)
      evalBuiltin (call (var "endsWith") [str "na", str "banana"])
        `shouldBe` Right (Aeson.Bool True)
      evalBuiltin (call (var "strLength") [str "h\233llo"]) `shouldBe` Right (Aeson.Number 5)
      evalBuiltin (call (var "lines") [str "a\nb"])
        `shouldBe` Right (Aeson.toJSON (["a", "b"] :: [Text]))
      evalBuiltin (call (var "unlines") [strs ["a", "b"]])
        `shouldBe` Right (Aeson.String "a\nb")

    it "reads records with key-sorted keys, values, and entries" $ do
      let object = record [("b", num 2), ("a", num 1)]
      evalBuiltin (call (var "keys") [object])
        `shouldBe` Right (Aeson.toJSON (["a", "b"] :: [Text]))
      evalBuiltin (call (var "values") [object])
        `shouldBe` Right (Aeson.toJSON ([1, 2] :: [Int]))
      evalBuiltin (call (var "entries") [object])
        `shouldBe` Right
          ( Aeson.toJSON
              [ Aeson.object ["key" Aeson..= ("a" :: Text), "value" Aeson..= (1 :: Int)]
              , Aeson.object ["key" Aeson..= ("b" :: Text), "value" Aeson..= (2 :: Int)]
              ]
          )

    it "guards null with withDefault and isNull" $ do
      evalBuiltin (call (var "withDefault") [num 0, nullLit]) `shouldBe` Right (Aeson.Number 0)
      evalBuiltin (call (var "withDefault") [num 0, num 5]) `shouldBe` Right (Aeson.Number 5)
      evalBuiltin (call (var "isNull") [nullLit]) `shouldBe` Right (Aeson.Bool True)
      evalBuiltin (call (var "isNull") [num 0]) `shouldBe` Right (Aeson.Bool False)

    it "iterates with range, fold, and foldRight" $ do
      evalBuiltin (call (var "range") [num 2, num 5])
        `shouldBe` Right (Aeson.toJSON ([2, 3, 4] :: [Int]))
      evalBuiltin (call (var "range") [num 5, num 2])
        `shouldBe` Right (Aeson.toJSON ([] :: [Int]))
      evalBuiltin
        ( call
            (var "fold")
            [lambda ("acc" :| ["x"]) (bin CorePureAdd (var "acc") (var "x")), num 0, nums [1, 2, 3]]
        )
        `shouldBe` Right (Aeson.Number 6)
      evalBuiltin
        ( call
            (var "foldRight")
            [ lambda ("x" :| ["acc"]) (bin CorePureSubtract (var "x") (var "acc"))
            , num 0
            , nums [1, 2, 3]
            ]
        )
        `shouldBe` Right (Aeson.Number 2)

    it "renders a markdown table end to end with range, fold, and string ops" $ do
      -- The capability that currently forces a Haskell report extension: build a
      -- whole Markdown table in pure Wire by folding generated rows with string ops.
      let header = str "| n | square |\n| --- | --- |"
          rowStep =
            lambda
              ("acc" :| ["n"])
              ( call
                  (var "concat")
                  [ CorePureList
                      [ var "acc"
                      , str "\n| "
                      , call (var "toString") [var "n"]
                      , str " | "
                      , call (var "toString") [bin CorePureMultiply (var "n") (var "n")]
                      , str " |"
                      ]
                  ]
              )
      evalBuiltin (call (var "fold") [rowStep, header, call (var "range") [num 1, num 4]])
        `shouldBe` Right
          (Aeson.String "| n | square |\n| --- | --- |\n| 1 | 1 |\n| 2 | 4 |\n| 3 | 9 |")

    it "rejects iteration past the fixed bounded-iteration cap" $ do
      evalBuiltin (call (var "range") [num 0, num 1000001])
        `shouldBe` Left (PureBoundExceeded "range span")
      evalBuiltin
        ( call
            (var "fold")
            [ lambda ("acc" :| ["x"]) (call (var "concat") [CorePureList [var "acc", var "acc"]])
            , str "a"
            , call (var "range") [num 0, num 25]
            ]
        )
        `shouldBe` Left (PureBoundExceeded "fold accumulator")

    it "bounds numeric accumulator growth and range endpoint overflow" $ do
      -- A squaring reducer over a tiny list still grows the accumulator without
      -- limit; the cap must charge the number's magnitude, not count it as one node.
      evalBuiltin
        ( call
            (var "fold")
            [ lambda ("acc" :| ["x"]) (bin CorePureMultiply (var "acc") (var "acc"))
            , num 2
            , call (var "range") [num 0, num 25]
            ]
        )
        `shouldBe` Left (PureBoundExceeded "fold accumulator")
      -- Endpoints near the Int bounds must not overflow the span check into a
      -- small value that slips an astronomically large enumeration through.
      evalBuiltin
        ( call
            (var "range")
            [num (fromIntegral (minBound :: Int)), num (fromIntegral (maxBound :: Int))]
        )
        `shouldBe` Left (PureBoundExceeded "range span")
      evalBuiltin
        ( call
            (var "range")
            [num (fromIntegral (maxBound :: Int)), num (fromIntegral (maxBound :: Int))]
        )
        `shouldBe` Right (Aeson.toJSON ([] :: [Int]))

    it "rejects function accumulators and charges object key growth in fold" $ do
      -- A reducer that returns a closure escapes the JSON cost guard and explodes
      -- only when applied; fold must reduce to a JSON value, not a function.
      evalBuiltin
        ( call
            (var "fold")
            [lambda ("acc" :| ["x"]) (lambda ("y" :| []) (var "y")), num 0, nums [1, 2, 3]]
        )
        `shouldBe` Left (PureTypeMismatch "JSON fold accumulator" "function")
      -- A fold can double an object key each step while the value stays null; the
      -- cost must charge key text, not just enqueue values, or it never trips.
      let firstKey = CorePureIndex (call (var "keys") [var "acc"]) (num 0)
          doubledKey = call (var "concat") [CorePureList [firstKey, firstKey]]
          jsonText = call (var "concat") [CorePureList [str "{\"", doubledKey, str "\":null}"]]
      evalBuiltin
        ( call
            (var "fold")
            [ lambda ("acc" :| ["item"]) (call (var "fromJson") [jsonText])
            , call (var "fromJson") [str "{\"a\":null}"]
            , call (var "range") [num 0, num 25]
            ]
        )
        `shouldBe` Left (PureBoundExceeded "fold accumulator")
      -- The seed is guarded before the reducer runs, so over-cap and function
      -- seeds are rejected up front on both empty and non-empty folds.
      evalBuiltin
        ( call
            (var "fold")
            [lambda ("acc" :| ["x"]) (var "acc"), num (scientific 1 2000000), CorePureList []]
        )
        `shouldBe` Left (PureBoundExceeded "fold accumulator")
      evalBuiltin
        ( call
            (var "fold")
            [lambda ("acc" :| ["x"]) (num 0), num (scientific 1 2000000), nums [1]]
        )
        `shouldBe` Left (PureBoundExceeded "fold accumulator")
      evalBuiltin
        ( call
            (var "fold")
            [lambda ("acc" :| ["x"]) (num 0), lambda ("z" :| []) (str "a"), nums [1]]
        )
        `shouldBe` Left (PureTypeMismatch "JSON fold accumulator" "function")
      -- A number with an exponent at the Int minimum must not slip under the cap:
      -- abs minBound overflows, so the exponent magnitude is taken in Integer.
      evalBuiltin
        ( call
            (var "fold")
            [lambda ("acc" :| ["x"]) (var "acc"), num (scientific 1 minBound), CorePureList []]
        )
        `shouldBe` Left (PureBoundExceeded "fold accumulator")

    it "clamps out-of-Int indices and caps out-of-Int range spans" $ do
      let big = num (scientific 1 20) -- 10^20, beyond the Int range
          negBig = num (scientific (-1) 20) -- -10^20
      evalBuiltin (call (var "take") [big, nums [1, 2, 3]])
        `shouldBe` Right (Aeson.toJSON ([1, 2, 3] :: [Int]))
      evalBuiltin (call (var "drop") [big, nums [1, 2, 3]])
        `shouldBe` Right (Aeson.toJSON ([] :: [Int]))
      evalBuiltin (call (var "substring") [num 0, big, str "hello"])
        `shouldBe` Right (Aeson.String "hello")
      evalBuiltin (call (var "range") [num 0, big])
        `shouldBe` Left (PureBoundExceeded "range span")
      evalBuiltin (call (var "range") [num 0, negBig])
        `shouldBe` Right (Aeson.toJSON ([] :: [Int]))
      -- A small range straddling the Int boundary is measured, not rejected.
      evalBuiltin
        ( call
            (var "range")
            [num (fromIntegral (maxBound :: Int)), num (fromIntegral (maxBound :: Int) + 1)]
        )
        `shouldBe` Right (Aeson.toJSON ([maxBound] :: [Int]))
      evalBuiltin
        ( call
            (var "range")
            [num (fromIntegral (maxBound :: Int) + 1), num (fromIntegral (maxBound :: Int))]
        )
        `shouldBe` Right (Aeson.toJSON ([] :: [Int]))
      -- A genuinely huge exponent is capped by sign, never materialised.
      evalBuiltin (call (var "range") [num 0, num (scientific 1 2000000)])
        `shouldBe` Left (PureBoundExceeded "range span")
      -- Equal or backwards huge endpoints are an empty half-open range, not an
      -- over-cap error: the direction is decided before the cap classification.
      evalBuiltin (call (var "range") [num (scientific 1 2000000), num (scientific 1 2000000)])
        `shouldBe` Right (Aeson.toJSON ([] :: [Int]))
      evalBuiltin (call (var "range") [num (scientific 1 3000000), num (scientific 1 2000000)])
        `shouldBe` Right (Aeson.toJSON ([] :: [Int]))
      -- A small forward span past Int is enumerated by its exact span, not
      -- rejected: range(10^20, 10^20 + 1) is [10^20].
      evalBuiltin
        (call (var "range") [num (scientific 1 20), num (scientific (10 ^ (20 :: Int) + 1) 0)])
        `shouldBe` Right (Aeson.toJSON ([10 ^ (20 :: Int)] :: [Integer]))
      -- Endpoints with exponents near the Int bounds must not overflow the width
      -- comparison: a forward over-cap range stays over-cap, not empty.
      evalBuiltin
        ( call
            (var "range")
            [num (scientific 1 (maxBound - 1)), num (scientific 1 maxBound)]
        )
        `shouldBe` Left (PureBoundExceeded "range span")
      -- Non-integer indices are still rejected.
      evalBuiltin (call (var "take") [num (scientific 15 (-1)), nums [1, 2, 3]])
        `shouldBe` Left (PureTypeMismatch "integer" "number")

  describe "Cortex.Wire.Pure.Bounds typed boundary" $ do
    prop "clampIndex keeps integer indices within [0, upper]" $
      \(n :: Int) (NonNegative upper) ->
        fmap clampedIndexValue (clampIndex upper (fromIntegral n))
          === Just (max 0 (min upper n))

    prop "clampIndex never fails for huge integers and stays within bounds" $
      \(NonNegative upper) ->
        forAll genHugeInteger $ \number ->
          case clampIndex upper number of
            Just clamped ->
              let value = clampedIndexValue clamped in value >= 0 && value <= upper
            Nothing -> False

    prop "clampIndex rejects non-integer indices" $
      \(NonNegative upper) (n :: Integer) ->
        clampIndex upper (scientific (2 * n + 1) (-1)) === Nothing

    prop "planRange classifies in-range spans by the documented semantics" $
      \(start :: Int) (end :: Int) ->
        let capValue = toInteger (iterationCapValue corePureBoundedIterationCap)
            width = toInteger end - toInteger start
            expected
              | width <= 0 = TagEmpty
              | width > capValue = TagOverCap
              | otherwise = TagEnumerate (toInteger start) (toInteger end)
         in fmap
              rangeTag
              (planRange corePureBoundedIterationCap (fromIntegral start) (fromIntegral end))
              === Just expected

    prop "planRange treats equal endpoints as an empty range at any magnitude" $
      forAll
        genHugeInteger
        ( \number ->
            fmap rangeTag (planRange corePureBoundedIterationCap number number) === Just TagEmpty
        )

    prop "mkFoldAccumulator admits exactly within-cap JSON and preserves the value" $
      forAll genBoundedJson withinCapAdmission

    it "checkValueCost charges object keys and number magnitude" $ do
      let capValue = iterationCapValue corePureBoundedIterationCap
          hugeKeyObject =
            Aeson.object [Key.fromText (T.replicate (capValue + 1) "k") Aeson..= Aeson.Null]
      checkValueCost corePureBoundedIterationCap hugeKeyObject `shouldBe` OverLimit
      checkValueCost corePureBoundedIterationCap (Aeson.Number (scientific 1 (capValue + 1)))
        `shouldBe` OverLimit
      checkValueCost corePureBoundedIterationCap (Aeson.Number 5) `shouldBe` WithinLimit

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

nums :: [Scientific] -> CorePureExpr
nums values =
  CorePureList (fmap num values)

strs :: [Text] -> CorePureExpr
strs values =
  CorePureList (fmap str values)

nullLit :: CorePureExpr
nullLit =
  CorePureLit CorePureNull

{- | Integer-valued numbers spanning the Int range and far beyond it (exponent up
to 100000), so clamp/range properties exercise out-of-Int magnitudes.
-}
genHugeInteger :: Gen Scientific
genHugeInteger =
  scientific <$> arbitrary <*> choose (0, 100000)

{- | Observable tag of a 'RangePlan' for property assertions, since the plan's
constructors are hidden behind 'foldRangePlan'.
-}
data RangeTag = TagEmpty | TagEnumerate Integer Integer | TagOverCap
  deriving stock (Eq, Show)

rangeTag :: RangePlan -> RangeTag
rangeTag = foldRangePlan TagEmpty TagEnumerate TagOverCap

{- | Small JSON values for the fold-accumulator cost property: scalars and
shallow numeric arrays, enough to exercise the within/over-cap boundary.
-}
genBoundedJson :: Gen Aeson.Value
genBoundedJson =
  oneof
    [ pure Aeson.Null
    , Aeson.Bool <$> arbitrary
    , Aeson.Number . fromInteger <$> arbitrary
    , Aeson.String . T.pack <$> arbitrary
    , Aeson.toJSON <$> listOf (Aeson.Number . fromInteger <$> (arbitrary :: Gen Integer))
    ]

{- | mkFoldAccumulator admits a JSON value iff its cost is within the cap, and
preserves the value unchanged when it admits it.
-}
withinCapAdmission :: Aeson.Value -> Property
withinCapAdmission value =
  case mkFoldAccumulator corePureBoundedIterationCap value of
    Just accumulator ->
      (foldAccumulatorValue accumulator === value)
        .&&. ( checkValueCost corePureBoundedIterationCap (foldAccumulatorValue accumulator)
                 === WithinLimit
             )
    Nothing ->
      checkValueCost corePureBoundedIterationCap value === OverLimit

{- | Evaluate a single CorePure expression with no inputs, returning the @out@ port
value. Used to exercise individual builtins without per-test port scaffolding.
-}
evalBuiltin :: CorePureExpr -> Either PureEvalError Aeson.Value
evalBuiltin expr =
  (Map.! "out")
    <$> evaluatePureTaskOutputs
      builtinOutPorts
      (wireInputBundleFromStageInputs Map.empty)
      []
      Nothing
      (Map.singleton "out" expr)

builtinOutPorts :: WirePorts
builtinOutPorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs = Map.singleton "out" WireOutputPort {wireOutputPortContract = "Any"}
    }

numJson :: Scientific -> Aeson.Value
numJson =
  Aeson.Number
