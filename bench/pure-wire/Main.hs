{- |
Module      : Main
Description : Criterion benchmarks for Wire pure evaluation.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The benchmarks compare the CorePure evaluator against direct Haskell
implementations over the same pre-built JSON-shaped inputs.
-}
module Main (main) where

import Control.DeepSeq (NFData, force)
import Control.Exception (evaluate)
import Control.Monad (forM_, unless)
import Criterion.Main (Benchmark, bench, bgroup, defaultMain, nf)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List qualified as List
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific, scientific)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as Vector
import System.CPUTime (getCPUTime)
import System.Environment (getArgs)
import Text.Printf (printf)

import Cortex.Pulse.Node (NodeId (..))
import Cortex.Wire
  ( CorePureBinOp (..)
  , CorePureBinding (..)
  , CorePureExpr (..)
  , CorePureField (..)
  , CorePureLiteral (..)
  , PreparedPureTask
  , PureEvalError
  , WireInputBundle
  , WireInputCardinality (..)
  , WireInputPort (..)
  , WireOutputPort (..)
  , WirePayloadKind (..)
  , WirePorts (..)
  , WireValue (..)
  , evaluatePreparedPureTaskOutputs
  , mkWireValue
  , preparePureTaskOutputs
  , renderPureEvalError
  , wireInputBundleFromStageInputs
  )

main :: IO ()
main = do
  let workloads =
        [ weightedScoreWorkload 2048
        , weightedScorePipelineWorkload 16
        , weightedScorePipelineWorkload 2048
        , eligibilitySummaryWorkload 2048
        , riskAdjustmentWorkload 2048
        , labelRollupWorkload 512
        ]
  forM_ workloads validateWorkload
  args <- getArgs
  printSummaryUnlessCriterionList args workloads
  defaultMain (fmap workloadBenchmarks workloads)

data PureBenchmarkWorkload = PureBenchmarkWorkload
  { workloadName :: !String
  , workloadWireLabel :: !String
  , workloadHaskellLabel :: !String
  , workloadWire :: Int -> Aeson.Value
  , workloadHaskell :: Int -> Aeson.Value
  }

workloadBenchmarks :: PureBenchmarkWorkload -> Benchmark
workloadBenchmarks workload =
  bgroup
    workload.workloadName
    [ bench workload.workloadWireLabel (nf workload.workloadWire 0)
    , bench workload.workloadHaskellLabel (nf workload.workloadHaskell 0)
    ]

validateWorkload :: PureBenchmarkWorkload -> IO ()
validateWorkload workload = do
  let evaluatedWireValue = workload.workloadWire 0
      haskellValue = workload.workloadHaskell 0
  unless (evaluatedWireValue == haskellValue) $
    fail $
      "Wire pure benchmark workload "
        <> workload.workloadName
        <> " does not match the direct Haskell baseline. Wire="
        <> show evaluatedWireValue
        <> " Haskell="
        <> show haskellValue

printSummaryUnlessCriterionList :: [String] -> [PureBenchmarkWorkload] -> IO ()
printSummaryUnlessCriterionList args workloads
  | criterionMetadataOnly args = pure ()
  | otherwise =
      case selectedWorkloads args workloads of
        [] -> do
          putStrLn "Pure Wire benchmark summary: no workloads matched the supplied selectors."
          putStrLn ""
        selected -> printBenchmarkSummary selected

criterionMetadataOnly :: [String] -> Bool
criterionMetadataOnly =
  any (`elem` ["--list", "-l", "--help", "-h", "--version"])

selectedWorkloads :: [String] -> [PureBenchmarkWorkload] -> [PureBenchmarkWorkload]
selectedWorkloads args workloads =
  case benchmarkSelectors args of
    [] -> workloads
    selectors ->
      [ workload
      | workload <- workloads
      , any (selectorMatchesWorkload workload) selectors
      ]

benchmarkSelectors :: [String] -> [String]
benchmarkSelectors =
  go
  where
    go [] = []
    go (arg : rest)
      | optionConsumesArgument arg =
          go (drop 1 rest)
      | "--" `List.isPrefixOf` arg =
          go rest
      | "-" `List.isPrefixOf` arg =
          go rest
      | otherwise =
          arg : go rest

optionConsumesArgument :: String -> Bool
optionConsumesArgument arg =
  arg
    `elem` [ "-I"
           , "--ci"
           , "-L"
           , "--time-limit"
           , "--resamples"
           , "--regress"
           , "--raw"
           , "-o"
           , "--output"
           , "--csv"
           , "--json"
           , "--junit"
           , "-v"
           , "--verbosity"
           , "-t"
           , "--template"
           , "-n"
           , "--iters"
           , "-m"
           , "--match"
           ]

selectorMatchesWorkload :: PureBenchmarkWorkload -> String -> Bool
selectorMatchesWorkload workload selector =
  any
    (selector `List.isPrefixOf`)
    [ workload.workloadName
    , workload.workloadName <> "/" <> workload.workloadWireLabel
    , workload.workloadName <> "/" <> workload.workloadHaskellLabel
    ]

printBenchmarkSummary :: [PureBenchmarkWorkload] -> IO ()
printBenchmarkSummary workloads = do
  putStrLn "Pure Wire benchmark summary (CPU-time estimate before Criterion)"
  putStrLn "workload                                      wire        haskell     ratio"
  putStrLn "-------------------------------------------- ----------- ----------- --------"
  forM_ workloads $ \workload -> do
    wireSeconds <- measureSummarySeconds workload.workloadWire
    haskellSeconds <- measureSummarySeconds workload.workloadHaskell
    printf
      "%-44s %11s %11s %7.2fx\n"
      workload.workloadName
      (renderSeconds wireSeconds)
      (renderSeconds haskellSeconds)
      (wireSeconds / haskellSeconds)
  putStrLn ""

measureSummarySeconds :: NFData a => (Int -> a) -> IO Double
measureSummarySeconds action =
  go (1 :: Int)
  where
    go iterations = do
      elapsed <- measureIterations iterations
      if elapsed >= summaryMinimumSeconds || iterations >= summaryMaximumIterations
        then pure (elapsed / fromIntegral iterations)
        else go (iterations * 2)

    measureIterations iterations = do
      start <- getCPUTime
      forM_ [0 .. iterations - 1] $ \iteration ->
        evaluate (force (action iteration))
      end <- getCPUTime
      pure (fromIntegral (end - start) / 1e12)

summaryMinimumSeconds :: Double
summaryMinimumSeconds =
  0.05

summaryMaximumIterations :: Int
summaryMaximumIterations =
  1048576

renderSeconds :: Double -> String
renderSeconds seconds
  | seconds < 1e-6 = printf "%.1f ns" (seconds * 1e9)
  | seconds < 1e-3 = printf "%.1f us" (seconds * 1e6)
  | seconds < 1 = printf "%.2f ms" (seconds * 1e3)
  | otherwise = printf "%.2f s" seconds

data JsonInputSpec = JsonInputSpec
  { inputPortName :: !Text
  , inputContract :: !Text
  , inputJson :: !Aeson.Value
  }

mkPureWorkload
  :: String
  -> [JsonInputSpec]
  -> Text
  -> [CorePureBinding]
  -> CorePureExpr
  -> (Int -> Aeson.Value)
  -> PureBenchmarkWorkload
mkPureWorkload name inputSpecs outputContract bindings outputExpr haskellEval =
  PureBenchmarkWorkload
    { workloadName = name
    , workloadWireLabel = "wire-corepure-json"
    , workloadHaskellLabel = "haskell-json"
    , workloadWire = runPreparedPure name preparedTask inputs
    , workloadHaskell = haskellEval
    }
  where
    preparedTask =
      prepareBenchmarkTask
        name
        [(spec.inputPortName, spec.inputContract) | spec <- inputSpecs]
        outputContract
        bindings
        outputExpr
    inputs =
      wireInputBundle inputSpecs

runPreparedPure :: String -> PreparedPureTask -> WireInputBundle -> Int -> Aeson.Value
runPreparedPure name preparedTask inputs salt
  | salt == minBound = Aeson.Null
  | otherwise =
      case evaluatePreparedPureTaskOutputs preparedTask inputs of
        Right outputs ->
          case Map.lookup "result" outputs of
            Just value -> value
            Nothing -> error ("pure Wire benchmark " <> name <> " did not produce result output")
        Left evalError ->
          error (T.unpack (renderBenchmarkEvalError name evalError))
{-# NOINLINE runPreparedPure #-}

renderBenchmarkEvalError :: String -> PureEvalError -> Text
renderBenchmarkEvalError name evalError =
  "pure Wire benchmark "
    <> T.pack name
    <> " failed: "
    <> renderPureEvalError evalError

prepareBenchmarkTask
  :: String
  -> [(Text, Text)]
  -> Text
  -> [CorePureBinding]
  -> CorePureExpr
  -> PreparedPureTask
prepareBenchmarkTask name inputSpecs outputContract bindings outputExpr =
  case preparePureTaskOutputs ports bindings Nothing outputExprs of
    Right task -> task
    Left evalError -> error (T.unpack (renderBenchmarkEvalError name evalError))
  where
    ports =
      WirePorts
        { wirePortsInputs =
            Map.fromList
              [ labeledJsonInput portName contractId
              | (portName, contractId) <- inputSpecs
              ]
        , wirePortsOutputs =
            Map.singleton "result" WireOutputPort {wireOutputPortContract = outputContract}
        }
    outputExprs =
      Map.singleton "result" outputExpr

wireInputBundle :: [JsonInputSpec] -> WireInputBundle
wireInputBundle inputSpecs =
  wireInputBundleFromStageInputs $
    Map.fromList
      [ (NodeId spec.inputPortName, wireValue spec)
      | spec <- inputSpecs
      ]

labeledJsonInput :: Text -> Text -> (Text, WireInputPort)
labeledJsonInput portName contractId =
  ( portName
  , WireInputPort
      { wireInputPortAccepts = [contractId]
      , wireInputPortCardinality = WireInputCardinalityOne
      , wireInputPortRequired = False
      }
  )

wireValue :: JsonInputSpec -> Aeson.Value
wireValue spec =
  Aeson.toJSON
    ( (mkWireValue spec.inputContract WirePayloadJson (Just spec.inputPortName) spec.inputJson)
        { wireValuePort = Just spec.inputPortName
        }
    )

data WeightedScoreFixture = WeightedScoreFixture
  { weightedScoreEvidenceJson :: !Aeson.Value
  , weightedScoreWeightsJson :: !Aeson.Value
  }

weightedScoreFixture :: Int -> WeightedScoreFixture
weightedScoreFixture itemCount =
  WeightedScoreFixture
    { weightedScoreEvidenceJson = evidenceJson
    , weightedScoreWeightsJson = weightsJson
    }
  where
    scores =
      [ scientific (fromIntegral ((index `mod` 97) + 3)) (-2)
      | index <- [0 .. itemCount - 1]
      ]
    weights =
      [ scientific (fromIntegral ((index `mod` 13) + 1)) (-1)
      | index <- [0 .. itemCount - 1]
      ]
    evidenceJson =
      Aeson.object
        [ "items"
            Aeson..= Aeson.Array
              ( Vector.fromList
                  [ Aeson.object ["score" Aeson..= Aeson.Number score]
                  | score <- scores
                  ]
              )
        ]
    weightsJson =
      Aeson.object
        [ "values" Aeson..= Aeson.Array (Vector.fromList (fmap Aeson.Number weights))
        ]

weightedScoreWorkload :: Int -> PureBenchmarkWorkload
weightedScoreWorkload itemCount =
  mkPureWorkload
    ("weighted-score/" <> show itemCount <> "-items")
    [ JsonInputSpec "evidence" "EvidenceSet" fixture.weightedScoreEvidenceJson
    , JsonInputSpec "weights" "WeightSet" fixture.weightedScoreWeightsJson
    ]
    "ScoreSummary"
    weightedScoreBindings
    weightedScoreOutputExpr
    ( \salt ->
        haskellWeightedScore
          (guardJsonInput salt fixture.weightedScoreEvidenceJson)
          (guardJsonInput salt fixture.weightedScoreWeightsJson)
    )
  where
    fixture = weightedScoreFixture itemCount

weightedScorePipelineWorkload :: Int -> PureBenchmarkWorkload
weightedScorePipelineWorkload itemCount =
  PureBenchmarkWorkload
    { workloadName = "weighted-score-pipeline/" <> show itemCount <> "-items"
    , workloadWireLabel = "wire-corepure-nodes"
    , workloadHaskellLabel = "haskell-json"
    , workloadWire =
        runWeightedScorePipeline pipeline
    , workloadHaskell =
        \salt ->
          haskellWeightedScore
            (guardJsonInput salt fixture.weightedScoreEvidenceJson)
            (guardJsonInput salt fixture.weightedScoreWeightsJson)
    }
  where
    fixture = weightedScoreFixture itemCount
    pipeline =
      WeightedScorePipeline
        { pipelineScoreProjectionTask =
            prepareBenchmarkTask
              "weighted-score-pipeline/project-scores"
              [("evidence", "EvidenceSet")]
              "ScoreVector"
              []
              scoreProjectionOutputExpr
        , pipelineWeightApplicationTask =
            prepareBenchmarkTask
              "weighted-score-pipeline/apply-weights"
              [("scores", "ScoreVector"), ("weights", "WeightSet")]
              "WeightedScoreVector"
              []
              weightApplicationOutputExpr
        , pipelineScoreSummaryTask =
            prepareBenchmarkTask
              "weighted-score-pipeline/summarize"
              [("weighted", "WeightedScoreVector")]
              "ScoreSummary"
              []
              scoreSummaryOutputExpr
        , pipelineEvidenceJson = fixture.weightedScoreEvidenceJson
        , pipelineWeightsJson = fixture.weightedScoreWeightsJson
        }

data WeightedScorePipeline = WeightedScorePipeline
  { pipelineScoreProjectionTask :: !PreparedPureTask
  , pipelineWeightApplicationTask :: !PreparedPureTask
  , pipelineScoreSummaryTask :: !PreparedPureTask
  , pipelineEvidenceJson :: !Aeson.Value
  , pipelineWeightsJson :: !Aeson.Value
  }

scoreProjectionOutputExpr :: CorePureExpr
scoreProjectionOutputExpr =
  call
    (var "map")
    [ lambda ("item" :| []) (field (var "item") "score")
    , field (var "evidence") "items"
    ]

weightApplicationOutputExpr :: CorePureExpr
weightApplicationOutputExpr =
  call
    (var "zipWith")
    [ lambda ("score" :| ["weight"]) (bin CorePureMultiply (var "score") (var "weight"))
    , var "scores"
    , field (var "weights") "values"
    ]

scoreSummaryOutputExpr :: CorePureExpr
scoreSummaryOutputExpr =
  record
    [ ("total", call (var "sum") [var "weighted"])
    , ("count", call (var "length") [var "weighted"])
    ]

runWeightedScorePipeline
  :: WeightedScorePipeline
  -> Int
  -> Aeson.Value
runWeightedScorePipeline pipeline salt
  | salt == minBound = Aeson.Null
  | otherwise =
      let scores =
            runPreparedPureNode
              "weighted-score-pipeline/project-scores"
              pipeline.pipelineScoreProjectionTask
              [JsonInputSpec "evidence" "EvidenceSet" pipeline.pipelineEvidenceJson]
          weighted =
            runPreparedPureNode
              "weighted-score-pipeline/apply-weights"
              pipeline.pipelineWeightApplicationTask
              [ JsonInputSpec "scores" "ScoreVector" scores
              , JsonInputSpec "weights" "WeightSet" pipeline.pipelineWeightsJson
              ]
       in runPreparedPureNode
            "weighted-score-pipeline/summarize"
            pipeline.pipelineScoreSummaryTask
            [JsonInputSpec "weighted" "WeightedScoreVector" weighted]
{-# NOINLINE runWeightedScorePipeline #-}

runPreparedPureNode :: String -> PreparedPureTask -> [JsonInputSpec] -> Aeson.Value
runPreparedPureNode name preparedTask inputSpecs =
  case evaluatePreparedPureTaskOutputs preparedTask (wireInputBundle inputSpecs) of
    Right outputs ->
      case Map.lookup "result" outputs of
        Just value -> value
        Nothing -> error ("pure Wire benchmark " <> name <> " did not produce result output")
    Left evalError ->
      error (T.unpack (renderBenchmarkEvalError name evalError))
{-# NOINLINE runPreparedPureNode #-}

weightedScoreBindings :: [CorePureBinding]
weightedScoreBindings =
  [ binding
      "scores"
      ( call
          (var "map")
          [ lambda ("item" :| []) (field (var "item") "score")
          , field (var "evidence") "items"
          ]
      )
  , binding
      "weighted"
      ( call
          (var "zipWith")
          [ lambda ("score" :| ["weight"]) (bin CorePureMultiply (var "score") (var "weight"))
          , var "scores"
          , field (var "weights") "values"
          ]
      )
  ]

weightedScoreOutputExpr :: CorePureExpr
weightedScoreOutputExpr =
  record
    [ ("total", call (var "sum") [var "weighted"])
    , ("count", call (var "length") [var "weighted"])
    ]

haskellWeightedScore :: Aeson.Value -> Aeson.Value -> Aeson.Value
haskellWeightedScore evidenceJson weightsJson =
  let scores = fmap (numberField "score") (arrayField "items" evidenceJson)
      weights = fmap numberValue (arrayField "values" weightsJson)
      weighted = zipWith (*) scores weights
      total = List.foldl' (+) 0 weighted
   in summaryValue total (length weighted)

eligibilitySummaryWorkload :: Int -> PureBenchmarkWorkload
eligibilitySummaryWorkload itemCount =
  mkPureWorkload
    ("eligibility-summary/" <> show itemCount <> "-applications")
    [JsonInputSpec "applications" "ApplicationSet" applicationsJson]
    "EligibilitySummary"
    eligibilityBindings
    eligibilityOutputExpr
    (\salt -> haskellEligibilitySummary (guardJsonInput salt applicationsJson))
  where
    applicationsJson =
      Aeson.object
        [ "items"
            Aeson..= Aeson.Array
              ( Vector.fromList
                  [ Aeson.object
                      [ "score" Aeson..= Aeson.Number (scientific (fromIntegral (((index * 37) `mod` 100) + 1)) (-2))
                      , "active" Aeson..= Aeson.Bool (index `mod` 5 /= 0)
                      ]
                  | index <- [0 .. itemCount - 1]
                  ]
              )
        ]

eligibilityBindings :: [CorePureBinding]
eligibilityBindings =
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
          , field (var "applications") "items"
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

eligibilityOutputExpr :: CorePureExpr
eligibilityOutputExpr =
  record
    [ ("accepted", call (var "length") [var "eligible"])
    , ("total", call (var "sum") [var "scores"])
    ]

haskellEligibilitySummary :: Aeson.Value -> Aeson.Value
haskellEligibilitySummary applicationsJson =
  let eligible =
        [ item
        | item <- arrayField "items" applicationsJson
        , boolField "active" item
        , numberField "score" item >= scientific 65 (-2)
        ]
      scores = fmap (numberField "score") eligible
      total = List.foldl' (+) 0 scores
   in Aeson.object
        [ "accepted" Aeson..= Aeson.Number (fromIntegral (length eligible))
        , "total" Aeson..= Aeson.Number total
        ]

riskAdjustmentWorkload :: Int -> PureBenchmarkWorkload
riskAdjustmentWorkload itemCount =
  mkPureWorkload
    ("risk-adjustment/" <> show itemCount <> "-exposures")
    [JsonInputSpec "exposures" "RiskExposureSet" exposuresJson]
    "RiskAdjustmentSummary"
    riskAdjustmentBindings
    riskAdjustmentOutputExpr
    (\salt -> haskellRiskAdjustment (guardJsonInput salt exposuresJson))
  where
    exposuresJson =
      Aeson.object
        [ "items"
            Aeson..= Aeson.Array
              ( Vector.fromList
                  [ Aeson.object
                      [ "delta"
                          Aeson..= Aeson.Number
                            (scientific (fromIntegral (((index * 17) `mod` 700) - 200)) (-2))
                      , "impact"
                          Aeson..= Aeson.Number
                            (scientific (fromIntegral (((index * 11) `mod` 40) + 1)) (-2))
                      ]
                  | index <- [0 .. itemCount - 1]
                  ]
              )
        ]

riskAdjustmentBindings :: [CorePureBinding]
riskAdjustmentBindings =
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
          , field (var "exposures") "items"
          ]
      )
  ]

riskAdjustmentOutputExpr :: CorePureExpr
riskAdjustmentOutputExpr =
  record
    [ ("total", call (var "sum") [var "adjusted"])
    , ("count", call (var "length") [var "adjusted"])
    ]

haskellRiskAdjustment :: Aeson.Value -> Aeson.Value
haskellRiskAdjustment exposuresJson =
  let adjusted =
        [ clampScientific 0 3 (abs (numberField "delta" item) * numberField "impact" item)
        | item <- arrayField "items" exposuresJson
        ]
      total = List.foldl' (+) 0 adjusted
   in summaryValue total (length adjusted)

labelRollupWorkload :: Int -> PureBenchmarkWorkload
labelRollupWorkload itemCount =
  mkPureWorkload
    ("label-rollup/" <> show itemCount <> "-labels")
    [JsonInputSpec "labels" "LabelSet" labelsJson]
    "LabelSummary"
    []
    labelRollupOutputExpr
    (\salt -> haskellLabelRollup (guardJsonInput salt labelsJson))
  where
    labelsJson =
      Aeson.object
        [ "items"
            Aeson..= Aeson.Array
              ( Vector.fromList
                  [ Aeson.String ("tag-" <> T.pack (show (index `mod` 128)))
                  | index <- [0 .. itemCount - 1]
                  ]
              )
        ]

labelRollupOutputExpr :: CorePureExpr
labelRollupOutputExpr =
  record
    [ ("summary", call (var "joinWith") [str "|", field (var "labels") "items"])
    , ("count", call (var "length") [field (var "labels") "items"])
    ]

haskellLabelRollup :: Aeson.Value -> Aeson.Value
haskellLabelRollup labelsJson =
  let labels = fmap textValue (arrayField "items" labelsJson)
   in Aeson.object
        [ "summary" Aeson..= Aeson.String (T.intercalate "|" labels)
        , "count" Aeson..= Aeson.Number (fromIntegral (length labels))
        ]

arrayField :: Text -> Aeson.Value -> [Aeson.Value]
arrayField fieldName value =
  case objectField fieldName value of
    Aeson.Array values -> Vector.toList values
    other -> error ("pure Wire benchmark field " <> T.unpack fieldName <> " is not an array: " <> show other)

objectField :: Text -> Aeson.Value -> Aeson.Value
objectField fieldName = \case
  Aeson.Object object ->
    case KeyMap.lookup (Key.fromText fieldName) object of
      Just value -> value
      Nothing -> error ("pure Wire benchmark object is missing field " <> T.unpack fieldName)
  other -> error ("pure Wire benchmark expected object but got " <> show other)

numberField :: Text -> Aeson.Value -> Scientific
numberField fieldName =
  numberValue . objectField fieldName

boolField :: Text -> Aeson.Value -> Bool
boolField fieldName value =
  case objectField fieldName value of
    Aeson.Bool bool -> bool
    other -> error ("pure Wire benchmark field " <> T.unpack fieldName <> " is not boolean: " <> show other)

numberValue :: Aeson.Value -> Scientific
numberValue = \case
  Aeson.Number number -> number
  other -> error ("pure Wire benchmark expected number but got " <> show other)

textValue :: Aeson.Value -> Text
textValue = \case
  Aeson.String text -> text
  other -> error ("pure Wire benchmark expected string but got " <> show other)

summaryValue :: Scientific -> Int -> Aeson.Value
summaryValue total count =
  Aeson.object
    [ "total" Aeson..= Aeson.Number total
    , "count" Aeson..= Aeson.Number (fromIntegral count)
    ]

clampScientific :: Scientific -> Scientific -> Scientific -> Scientific
clampScientific minimumValue maximumValue value =
  max minimumValue (min maximumValue value)

guardJsonInput :: Int -> Aeson.Value -> Aeson.Value
guardJsonInput salt value
  | salt == minBound = Aeson.Null
  | otherwise = value
{-# NOINLINE guardJsonInput #-}

binding :: Text -> CorePureExpr -> CorePureBinding
binding name expr =
  CorePureBinding {corePureBindingName = name, corePureBindingExpr = expr}

record :: [(Text, CorePureExpr)] -> CorePureExpr
record fields =
  CorePureRecord [CorePureField (fieldName :| []) fieldExpr | (fieldName, fieldExpr) <- fields]

num :: Scientific -> CorePureExpr
num =
  CorePureLit . CorePureNumber

str :: Text -> CorePureExpr
str =
  CorePureLit . CorePureString

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
