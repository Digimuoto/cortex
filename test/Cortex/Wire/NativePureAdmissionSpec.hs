{- |
Module      : Cortex.Wire.NativePureAdmissionSpec
Description : NativePure candidate admission and resource-bound tests.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

These specs pin the ephemeral admission model used before normalized artifacts
and maximal fusion are introduced by later NativePure epic slices.
-}
module Cortex.Wire.NativePureAdmissionSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Cortex.Wire
  ( CircuitNodeRef (..)
  , EndpointRef (..)
  , NativeLayout (..)
  , NativePureAnfBinding (..)
  , NativePureAnfBlock (..)
  , NativePureAnfOp (..)
  , NativePureArtifactError (..)
  , NativePureFusedRegion (..)
  , NativePureNormalizedInput (..)
  , NativePurePlan (..)
  , NativePureRegionBoundary (..)
  , NativePureRegionEdge (..)
  , NativePureRegionOutput (..)
  , NativePureRegionSumBoundary (..)
  , NativePureSsaEquation (..)
  , NativePureSsaInput (..)
  , NativePureSsaStep (..)
  , NativePureSsaValueRef (..)
  , NativeShape (..)
  , NativeShapeProjection (..)
  , RealizationArtifact (..)
  , RealizationRuntimeKind (..)
  , RealizationRuntimeUnit (..)
  , WireCompileEnv
  , WireContractRegistry
  , WireContractSpec (..)
  , WireExecutorConfigShape (..)
  , WireExecutorEffect (..)
  , WireExecutorId (..)
  , WireExecutorPortPolicy (..)
  , WireExecutorProjection (..)
  , WirePayloadKind (..)
  , WirePorts (..)
  , compileWireTextWithEnv
  , nativePureNormalizedInputSchema
  , nativePurePlanSchema
  , normalizeNativePureInput
  , pureWireExecutorProjection
  , realizationArtifactSchema
  , realizeNativePurePlan
  , strictWireCompileEnv
  , wireContractRegistryFromList
  , wireExecutorRegistryFromList
  )
import Cortex.Wire.NativePure.Admission
  ( NativePureAccess (..)
  , NativePureAdmissionError (..)
  , NativePureBoundary (..)
  , NativePureBounds (..)
  , NativePureCandidates (..)
  , NativePureKernelCandidate (..)
  , NativePureOutputBoundary (..)
  , NativePureRegion (..)
  , NativePureVariantCandidate (..)
  , admitNativePureCandidates
  )

spec :: Spec
spec = do
  admissionSpec
  artifactSpec

admissionSpec :: Spec
admissionSpec = describe "NativePure candidate admission" $ do
  it "admits a strictly shaped pure node with exact regions and bounds" $ do
    compiled <- requireRight (compileWireTextWithEnv nativeEnv pureProgram)
    candidates <- requireRight (admitNativePureCandidates nativeRegistry compiled)
    kernel <- requireSingleKernel candidates
    kernel.nativePureKernelCandidateRef `shouldBe` CircuitNodeRef "increment"
    fmap (.nativePureRegionAccess) kernel.nativePureKernelCandidateRegions
      `shouldBe` [NativePureRead, NativePureWrite]
    fmap (.nativePureRegionName) kernel.nativePureKernelCandidateRegions
      `shouldBe` ["input.score", "output.result"]
    kernel.nativePureKernelCandidateBounds
      `shouldBe` NativePureBounds 24 0 8 16 3

  it "rejects a crossing contract without native_shape" $ do
    compiled <- requireRight (compileWireTextWithEnv unshapedEnv pureProgram)
    admitNativePureCandidates unshapedRegistry compiled
      `shouldSatisfy` \case
        Left NativePureMissingShape {} -> True
        _ -> False

  it "admits a declared exclusive sum as one tagged output boundary" $ do
    compiled <- requireRight (compileWireTextWithEnv sumEnv sumProgram)
    candidates <- requireRight (admitNativePureCandidates sumRegistry compiled)
    kernel <- requireSingleKernel candidates
    kernel.nativePureKernelCandidateOutput `shouldSatisfy` \case
      NativePureSum _ variants ->
        fmap (.nativePureBoundaryLabel) variants == ["accepted", "rejected"]
      _ -> False
    fmap (.nativePureVariantCandidateLabels) kernel.nativePureKernelCandidateVariant
      `shouldBe` Just ["accepted", "rejected"]
    fmap (.nativePureRegionName) kernel.nativePureKernelCandidateRegions
      `shouldBe` ["input.score", "output.variant"]
    fmap (.nativePureRegionCapacity) kernel.nativePureKernelCandidateRegions
      `shouldBe` [8, 16]

  it "keeps effectful tasks outside the candidate set" $ do
    compiled <- requireRight (compileWireTextWithEnv mixedEnv mixedProgram)
    candidates <- requireRight (admitNativePureCandidates nativeRegistry compiled)
    fmap (.nativePureKernelCandidateRef) candidates.nativePureCandidatesKernels
      `shouldBe` [CircuitNodeRef "increment"]

  it "rejects division outside the certified basis" $
    rejectedReason nativeRegistry nativeEnv divisionProgram `shouldSatisfy` T.isInfixOf "division"

  it "rejects builtin calls outside the certified basis" $
    rejectedReason nativeRegistry nativeEnv builtinCallProgram
      `shouldSatisfy` T.isInfixOf "builtin calls"

  it "rejects unary negate without a kernel representation" $
    rejectedReason nativeRegistry nativeEnv negateProgram `shouldSatisfy` T.isInfixOf "negate"

  it "rejects a fractional literal crossing an i64 shape" $
    rejectedReason nativeRegistry nativeEnv fractionalProgram `shouldSatisfy` T.isInfixOf "fractional"

  it "rejects checked arithmetic crossing a non-i64 shape" $
    rejectedReason boolRegistry boolEnv boolArithmeticProgram
      `shouldSatisfy` T.isInfixOf "checked arithmetic produces i64"

  it "rejects derived comparisons outside the eq/lt basis" $
    rejectedReason boolRegistry boolEnv derivedComparisonProgram
      `shouldSatisfy` T.isInfixOf "derived comparison"

  it "rejects record merge outside the certified basis" $
    rejectedReason recordRegistry recordEnv mergeProgram `shouldSatisfy` T.isInfixOf "record merge"

  it "rejects a worst-case checkpoint above the hosted 2 MiB ceiling" $ do
    compiled <- requireRight (compileWireTextWithEnv bigTextEnv bigTextProgram)
    admitNativePureCandidates bigTextRegistry compiled
      `shouldSatisfy` \case
        Left NativePureCheckpointTooLarge {} -> True
        _ -> False

  it "counts UTF-8 literal bytes and exact structural steps" $ do
    compiled <- requireRight (compileWireTextWithEnv textEnv textProgram)
    candidates <- requireRight (admitNativePureCandidates textRegistry compiled)
    kernel <- requireSingleKernel candidates
    kernel.nativePureKernelCandidateBounds.nativePureBoundStaticBytes `shouldBe` 2
    kernel.nativePureKernelCandidateBounds.nativePureBoundSteps `shouldBe` 1

  it "includes inter-field padding in product output bounds" $ do
    compiled <- requireRight (compileWireTextWithEnv paddedProductEnv paddedProductProgram)
    candidates <- requireRight (admitNativePureCandidates paddedProductRegistry compiled)
    kernel <- requireSingleKernel candidates
    kernel.nativePureKernelCandidateBounds.nativePureBoundOutputBytes `shouldBe` 16
    kernel.nativePureKernelCandidateBounds.nativePureBoundCheckpointBytes `shouldBe` 24

  it "preserves invalid shape diagnostics instead of reporting resource overflow" $ do
    compiled <- requireRight (compileWireTextWithEnv invalidShapeEnv invalidShapeProgram)
    admitNativePureCandidates invalidShapeRegistry compiled
      `shouldSatisfy` \case
        Left NativePureInvalidShape {} -> True
        _ -> False

artifactSpec :: Spec
artifactSpec = describe "NativePure normalized realization" $ do
  it "fuses a maximal connected pure component with exact typed crossings and SSA" $ do
    (normalized, plan) <- requirePlan fusionRegistry fusionEnv fusedProgram
    nativePureNormalizedInputSchema `shouldBe` "cortex.wire.native-pure-input/v1"
    realizationArtifactSchema `shouldBe` "cortex.wire.realization-artifact/v1"
    nativePurePlanSchema `shouldBe` "cortex.wire.native-pure-plan/v1"
    normalized.nativePureNormalizedReferentIdentity `shouldBe` plan.nativePurePlanProgramIdentity
    region <- requireSingleRegion plan
    region.nativePureFusedRegionSources
      `shouldBe` [CircuitNodeRef "first", CircuitNodeRef "second"]
    fmap (.nativePureRegionBoundaryEndpoint) region.nativePureFusedRegionInputs
      `shouldBe` [EndpointRef (CircuitNodeRef "first") (Just "score")]
    fmap productOutputEndpoint region.nativePureFusedRegionOutputs
      `shouldBe` [Just (EndpointRef (CircuitNodeRef "second") (Just "result"))]
    fmap (.nativePureRegionBoundaryShape) region.nativePureFusedRegionInputs
      `shouldBe` [NativeI64]
    region.nativePureFusedRegionInternalEdges
      `shouldBe` [ NativePureRegionEdge
                     (EndpointRef (CircuitNodeRef "first") (Just "mid"))
                     (EndpointRef (CircuitNodeRef "second") (Just "mid"))
                 ]
    fmap (.nativePureSsaStepSource) region.nativePureFusedRegionSsa
      `shouldBe` [CircuitNodeRef "first", CircuitNodeRef "second"]
    case region.nativePureFusedRegionSsa of
      [firstStep, secondStep] -> do
        firstStep.nativePureSsaStepPrelude `shouldBe` []
        case firstStep.nativePureSsaStepEquations of
          [equation] -> do
            length equation.nativePureSsaEquationAnf.nativePureAnfBlockBindings `shouldBe` 2
            fmap (.nativePureAnfBindingOp) equation.nativePureSsaEquationAnf.nativePureAnfBlockBindings
              `shouldSatisfy` \case
                [NativePureAnfLiteral _, NativePureAnfBinary {}] -> True
                _ -> False
          _ -> expectationFailure "expected one first-step equation"
        fmap (.nativePureSsaInputValue) secondStep.nativePureSsaStepInputs
          `shouldBe` [NativePureSsaValueRef "first.output.mid"]
      steps -> expectationFailure ("expected two SSA steps, got " <> show (length steps))
    let artifact = plan.nativePurePlanRealization
    Map.elems artifact.realizationArtifactSourceToRuntime
      `shouldBe` ["native-pure/0000", "native-pure/0000"]
    Map.elems artifact.realizationArtifactRuntimeUnits
      `shouldBe` [ RealizationRuntimeUnit
                     "native-pure/0000"
                     RealizationPureRegion
                     [CircuitNodeRef "first", CircuitNodeRef "second"]
                 ]
    artifact.realizationArtifactRuntimeEdges `shouldBe` Set.empty

  it "preserves an exclusive sum exit as one tagged aggregate and fusion boundary" $ do
    (_, plan) <- requirePlan sumRegistry sumEnv sumProgram
    region <- requireSingleRegion plan
    case region.nativePureFusedRegionOutputs of
      [NativePureRegionExclusiveSum sumBoundary] -> do
        sumBoundary.nativePureRegionSumSource `shouldBe` CircuitNodeRef "classify"
        fmap (.nativePureRegionBoundaryEndpoint) sumBoundary.nativePureRegionSumVariants
          `shouldBe` [ EndpointRef (CircuitNodeRef "classify") (Just "accepted")
                     , EndpointRef (CircuitNodeRef "classify") (Just "rejected")
                     ]
        sumBoundary.nativePureRegionSumShape
          `shouldBe` NativeSum (Map.fromList [("accepted", NativeI64), ("rejected", NativeI64)])
        sumBoundary.nativePureRegionSumLayout.nativeLayoutSize `shouldBe` 16
        case region.nativePureFusedRegionSsa of
          [step] ->
            case step.nativePureSsaStepEquations of
              [equation] ->
                case reverse equation.nativePureSsaEquationAnf.nativePureAnfBlockBindings of
                  binding : _ ->
                    binding.nativePureAnfBindingOp `shouldSatisfy` \case
                      NativePureAnfIf {} -> True
                      _ -> False
                  [] -> expectationFailure "expected a sum ANF result binding"
              _ -> expectationFailure "expected one sum equation"
          _ -> expectationFailure "expected one sum SSA step"
      outputs -> expectationFailure ("expected one exclusive-sum output, got " <> show outputs)

  it "keeps effects as preserved units and splits pure regions around them" $ do
    (_, plan) <- requirePlan fusionRegistry fusionMixedEnv splitByEffectProgram
    fmap (.nativePureFusedRegionSources) plan.nativePurePlanRegions
      `shouldBe` [[CircuitNodeRef "first"], [CircuitNodeRef "second"]]
    let artifact = plan.nativePurePlanRealization
    fmap (.realizationRuntimeUnitKind) (Map.elems artifact.realizationArtifactRuntimeUnits)
      `shouldBe` [RealizationPureRegion, RealizationPureRegion, RealizationPreservedNode]
    artifact.realizationArtifactRuntimeEdges
      `shouldBe` Set.fromList
        [ ("native-pure/0000", "source/review")
        , ("source/review", "native-pure/0001")
        ]
    Map.keysSet artifact.realizationArtifactSourceToRuntime
      `shouldBe` Set.fromList [CircuitNodeRef "first", CircuitNodeRef "review", CircuitNodeRef "second"]

  it "produces stable normalized, realization, and plan digests" $ do
    (normalizedA, planA) <- requirePlan fusionRegistry fusionEnv fusedProgram
    (normalizedB, planB) <- requirePlan fusionRegistry fusionEnv fusedProgram
    normalizedA.nativePureNormalizedDigest `shouldBe` normalizedB.nativePureNormalizedDigest
    planA.nativePurePlanRealization.realizationArtifactDigest
      `shouldBe` planB.nativePurePlanRealization.realizationArtifactDigest
    planA.nativePurePlanDigest `shouldBe` planB.nativePurePlanDigest

  it "elaborates lets, records, projections, conditionals, and boolean operations to typed ANF" $ do
    (_, plan) <- requirePlan anfRegistry anfEnv anfProgram
    region <- requireSingleRegion plan
    region.nativePureFusedRegionSsa `shouldSatisfy` \case
      [recordStep, projectionStep] ->
        let recordOps =
              concatMap
                (fmap (.nativePureAnfBindingOp) . (.nativePureAnfBlockBindings) . (.nativePureSsaEquationAnf))
                recordStep.nativePureSsaStepEquations
            projectionOps =
              concatMap
                (fmap (.nativePureAnfBindingOp) . (.nativePureAnfBlockBindings) . (.nativePureSsaEquationAnf))
                projectionStep.nativePureSsaStepEquations
         in any isRecordOp recordOps && any isIfOp projectionOps
      _ -> False

  it "rejects normalized input whose canonical content no longer matches its digest" $ do
    compiled <- requireRight (compileWireTextWithEnv fusionEnv fusedProgram)
    normalized <- requireRight (normalizeNativePureInput fusionRegistry compiled)
    realizeNativePurePlan normalized {nativePureNormalizedProgramId = "tampered"}
      `shouldSatisfy` \case
        Left (NativePureArtifactDigestMismatch "normalized input") -> True
        _ -> False

requirePlan
  :: WireContractRegistry
  -> WireCompileEnv
  -> Text
  -> IO (NativePureNormalizedInput, NativePurePlan)
requirePlan registryValue env program = do
  compiled <- requireRight (compileWireTextWithEnv env program)
  normalized <- requireRight (normalizeNativePureInput registryValue compiled)
  plan <- requireRight (realizeNativePurePlan normalized)
  pure (normalized, plan)

requireSingleRegion :: NativePurePlan -> IO NativePureFusedRegion
requireSingleRegion plan =
  case plan.nativePurePlanRegions of
    [region] -> pure region
    regions -> fail ("expected one NativePure region, got " <> show (length regions))

productOutputEndpoint :: NativePureRegionOutput -> Maybe EndpointRef
productOutputEndpoint = \case
  NativePureRegionProductField boundary -> Just boundary.nativePureRegionBoundaryEndpoint
  NativePureRegionExclusiveSum {} -> Nothing

isRecordOp :: NativePureAnfOp -> Bool
isRecordOp NativePureAnfRecord {} = True
isRecordOp _ = False

isIfOp :: NativePureAnfOp -> Bool
isIfOp NativePureAnfIf {} = True
isIfOp _ = False

requireSingleKernel :: NativePureCandidates -> IO NativePureKernelCandidate
requireSingleKernel candidates =
  case candidates.nativePureCandidatesKernels of
    [kernel] -> pure kernel
    kernels -> fail ("expected one NativePure kernel candidate, got " <> show (length kernels))

rejectedReason :: WireContractRegistry -> WireCompileEnv -> Text -> Text
rejectedReason registryValue env program =
  case compileWireTextWithEnv env program of
    Left compileError -> "compile failed before NativePure admission: " <> T.pack (show compileError)
    Right compiled ->
      case admitNativePureCandidates registryValue compiled of
        Left (NativePureUnsupportedExpression _ reason) -> reason
        Left other -> "unexpected NativePure rejection: " <> T.pack (show other)
        Right _ -> "unexpected NativePure admission"

pureProgram :: Text
pureProgram =
  T.unlines
    [ "contract Score;"
    , "contract Result;"
    , "node increment"
    , "  <- score: Score;"
    , "  -> result: Result = score + 1;"
    , "increment"
    ]

divisionProgram :: Text
divisionProgram = replaceBody "score / 2"

builtinCallProgram :: Text
builtinCallProgram = replaceBody "sum([score])"

negateProgram :: Text
negateProgram = replaceBody "-score"

fractionalProgram :: Text
fractionalProgram = replaceBody "if score < 0 then 0.5 else 1"

replaceBody :: Text -> Text
replaceBody body =
  T.unlines
    [ "contract Score;"
    , "contract Result;"
    , "node candidate"
    , "  <- score: Score;"
    , "  -> result: Result = " <> body <> ";"
    , "candidate"
    ]

boolArithmeticProgram :: Text
boolArithmeticProgram =
  T.unlines
    [ "contract Score;"
    , "contract Flag;"
    , "node gate"
    , "  <- score: Score;"
    , "  -> flag: Flag = score + 1;"
    , "gate"
    ]

derivedComparisonProgram :: Text
derivedComparisonProgram =
  T.unlines
    [ "contract Score;"
    , "contract Flag;"
    , "node compare"
    , "  <- score: Score;"
    , "  -> flag: Flag = score >= 0;"
    , "compare"
    ]

mergeProgram :: Text
mergeProgram =
  T.unlines
    [ "contract Score;"
    , "contract ResultRecord;"
    , "node merge_record"
    , "  <- score: Score;"
    , "  -> result: ResultRecord = { value = score; } // { value = 1; };"
    , "merge_record"
    ]

sumProgram :: Text
sumProgram =
  T.unlines
    [ "contract Score;"
    , "contract Decision;"
    , "contract RejectReason;"
    , "node classify"
    , "  <- score: Score;"
    , "  -> accepted: Decision | rejected: RejectReason ="
    , "    if score < 0 then rejected score else accepted score;"
    , "classify"
    ]

mixedProgram :: Text
mixedProgram =
  T.unlines
    [ "contract Score;"
    , "contract Result;"
    , "node increment"
    , "  <- score: Score;"
    , "  -> result: Result = score + 1;"
    , "node store"
    , "  <- result: Result;"
    , "  = @report.store {} (result);"
    , "increment => store"
    ]

fusedProgram :: Text
fusedProgram =
  T.unlines
    [ "contract Score;"
    , "contract Mid;"
    , "contract Result;"
    , "node first"
    , "  <- score: Score;"
    , "  -> mid: Mid = score + 1;"
    , "node second"
    , "  <- mid: Mid;"
    , "  -> result: Result = mid + 1;"
    , "first => second"
    ]

splitByEffectProgram :: Text
splitByEffectProgram =
  T.unlines
    [ "contract Score;"
    , "contract Mid;"
    , "contract Reviewed;"
    , "contract Result;"
    , "node first"
    , "  <- score: Score;"
    , "  -> mid: Mid = score + 1;"
    , "node review"
    , "  <- mid: Mid;"
    , "  -> reviewed: Reviewed;"
    , "  = @report.review {} (mid);"
    , "node second"
    , "  <- reviewed: Reviewed;"
    , "  -> result: Result = reviewed + 1;"
    , "first => review => second"
    ]

anfProgram :: Text
anfProgram =
  T.unlines
    [ "contract Score;"
    , "contract Pair;"
    , "contract Result;"
    , "node construct"
    , "  <- score: Score;"
    , "  -> pair: Pair = let adjusted = score + 1; in"
    , "    { flag = !(score < 0); value = adjusted; };"
    , "node project"
    , "  <- pair: Pair;"
    , "  -> result: Result = if pair.flag then pair.value else 0;"
    , "construct => project"
    ]

bigTextProgram :: Text
bigTextProgram =
  T.unlines
    [ "contract Blob;"
    , "contract BlobCopy;"
    , "node copy"
    , "  <- blob: Blob;"
    , "  -> result: BlobCopy = blob;"
    , "copy"
    ]

textProgram :: Text
textProgram =
  T.unlines
    [ "contract TextResult;"
    , "node literal -> result: TextResult = \"é\";"
    , "literal"
    ]

paddedProductProgram :: Text
paddedProductProgram =
  T.unlines
    [ "contract Score;"
    , "contract Flag;"
    , "contract Total;"
    , "node split"
    , "  <- score: Score;"
    , "  -> flag: Flag = score < 0;"
    , "  -> total: Total = score;"
    , "split"
    ]

invalidShapeProgram :: Text
invalidShapeProgram =
  T.unlines
    [ "contract BadText;"
    , "node invalid -> result: BadText = \"x\";"
    , "invalid"
    ]

nativeEnv
  , unshapedEnv
  , sumEnv
  , boolEnv
  , recordEnv
  , bigTextEnv
  , textEnv
  , paddedProductEnv
  , invalidShapeEnv
    :: WireCompileEnv
nativeEnv = strictEnv nativeRegistry [pureWireExecutorProjection]
unshapedEnv = strictEnv unshapedRegistry [pureWireExecutorProjection]
sumEnv = strictEnv sumRegistry [pureWireExecutorProjection]
boolEnv = strictEnv boolRegistry [pureWireExecutorProjection]
recordEnv = strictEnv recordRegistry [pureWireExecutorProjection]
bigTextEnv = strictEnv bigTextRegistry [pureWireExecutorProjection]
textEnv = strictEnv textRegistry [pureWireExecutorProjection]
paddedProductEnv = strictEnv paddedProductRegistry [pureWireExecutorProjection]
invalidShapeEnv = strictEnv invalidShapeRegistry [pureWireExecutorProjection]

mixedEnv :: WireCompileEnv
mixedEnv = strictEnv nativeRegistry [pureWireExecutorProjection, storeExecutorProjection]

fusionEnv, fusionMixedEnv :: WireCompileEnv
fusionEnv = strictEnv fusionRegistry [pureWireExecutorProjection]
fusionMixedEnv = strictEnv fusionRegistry [pureWireExecutorProjection, reviewExecutorProjection]

anfEnv :: WireCompileEnv
anfEnv = strictEnv anfRegistry [pureWireExecutorProjection]

strictEnv :: WireContractRegistry -> [WireExecutorProjection] -> WireCompileEnv
strictEnv contractRegistry projections =
  strictWireCompileEnv (wireExecutorRegistryFromList projections) contractRegistry

nativeRegistry
  , fusionRegistry
  , anfRegistry
  , unshapedRegistry
  , sumRegistry
  , boolRegistry
  , recordRegistry
  , bigTextRegistry
  , textRegistry
  , paddedProductRegistry
  , invalidShapeRegistry
    :: WireContractRegistry
nativeRegistry = shapedRegistry [("Score", NativeI64), ("Result", NativeI64)]
fusionRegistry =
  shapedRegistry
    [ ("Score", NativeI64)
    , ("Mid", NativeI64)
    , ("Reviewed", NativeI64)
    , ("Result", NativeI64)
    ]
anfRegistry =
  shapedRegistry
    [ ("Score", NativeI64)
    , ("Pair", NativeRecord (Map.fromList [("flag", NativeBool), ("value", NativeI64)]))
    , ("Result", NativeI64)
    ]
unshapedRegistry =
  wireContractRegistryFromList
    [contract "Score" Nothing, contract "Result" Nothing]
sumRegistry =
  shapedRegistry [("Score", NativeI64), ("Decision", NativeI64), ("RejectReason", NativeI64)]
boolRegistry = shapedRegistry [("Score", NativeI64), ("Flag", NativeBool)]
recordRegistry =
  shapedRegistry
    [ ("Score", NativeI64)
    , ("ResultRecord", NativeRecord (Map.singleton "value" NativeI64))
    ]
bigTextRegistry = shapedRegistry [("Blob", NativeText 1100000), ("BlobCopy", NativeText 1100000)]
textRegistry = shapedRegistry [("TextResult", NativeText 8)]
paddedProductRegistry =
  shapedRegistry [("Score", NativeI64), ("Flag", NativeBool), ("Total", NativeI64)]
invalidShapeRegistry =
  wireContractRegistryFromList
    [contract "BadText" (Just (NativeShapeProjection (NativeText 0)))]

shapedRegistry :: [(Text, NativeShape)] -> WireContractRegistry
shapedRegistry entries =
  wireContractRegistryFromList
    [contract contractId (Just (NativeShapeProjection shape)) | (contractId, shape) <- entries]

contract :: Text -> Maybe NativeShapeProjection -> WireContractSpec
contract contractId nativeShape =
  WireContractSpec
    { wireContractSpecId = contractId
    , wireContractSpecPayloadKind = WirePayloadJson
    , wireContractSpecDescription = contractId
    , wireContractSpecRecordFields = Nothing
    , wireContractSpecSchema = Nothing
    , wireContractSpecNativeShape = nativeShape
    , wireContractSpecExamples = []
    }

storeExecutorProjection :: WireExecutorProjection
storeExecutorProjection =
  WireExecutorProjection
    { wireExecutorProjectionId = WireExecutorId "report.store"
    , wireExecutorProjectionPorts = WirePorts Map.empty Map.empty
    , wireExecutorProjectionVocabulary = Set.empty
    , wireExecutorProjectionEffect = WireExecutorHostEffect
    , wireExecutorProjectionConfigShape = WireExecutorConfigUnchecked
    , wireExecutorProjectionPortPolicy = WireExecutorAuthorDeclaredPorts
    }

reviewExecutorProjection :: WireExecutorProjection
reviewExecutorProjection =
  storeExecutorProjection {wireExecutorProjectionId = WireExecutorId "report.review"}

requireRight :: Show err => Either err value -> IO value
requireRight = \case
  Right value -> pure value
  Left err -> fail ("expected Right, got " <> show err)
