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

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
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
  , NativePureFusionMode (..)
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
  , WireExecutorArgumentShape (..)
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
  , realizeNativePurePlanWithMode
  , renderNativePurePlanModule
  , strictWireCompileEnv
  , validateNativePurePlan
  , validateRealizationArtifact
  , wireContractRegistryFromList
  , wireExecutorRegistryFromList
  )
import Cortex.Wire.AdmissionArtifact (wireAdmissionMetadataKey)
import Cortex.Wire.Circuit.Compiled (CompiledCircuit (..), CompiledCircuitNode (..))
import Cortex.Wire.Circuit.IR (CircuitTaskNode (..))
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

  it "rejects f64 literals until concrete C literal emission joins the certified basis" $
    rejectedReason f64Registry f64Env f64LiteralProgram
      `shouldSatisfy` T.isInfixOf "binary64 literals"

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

  it "rejects an input port that shadows a CorePure builtin" $ do
    compiled <- requireRight (compileWireTextWithEnv nativeEnv builtinInputProgram)
    admitNativePureCandidates nativeRegistry compiled
      `shouldSatisfy` \case
        Left NativePureBuiltinShadowedInput {} -> True
        _ -> False

  it "rejects a fractional literal binding instead of deferring to render time" $
    rejectedReason f64Registry f64Env f64BindingProgram
      `shouldSatisfy` T.isInfixOf "binary64 literals"

  it "rejects a compiled circuit without an admission artifact" $ do
    compiled <- requireRight (compileWireTextWithEnv nativeEnv pureProgram)
    admitNativePureCandidates nativeRegistry compiled {compiledCircuitMetadata = Aeson.Null}
      `shouldBe` Left NativePureMissingAdmissionArtifact

  it "carries the decoder cause for malformed admission metadata" $ do
    compiled <- requireRight (compileWireTextWithEnv nativeEnv pureProgram)
    let corrupted =
          withCircuitMetadataKey wireAdmissionMetadataKey (Aeson.String "garbage") compiled
    case admitNativePureCandidates nativeRegistry corrupted of
      Left (NativePureMalformedAdmissionArtifact reason) ->
        reason `shouldSatisfy` (not . T.null)
      other ->
        expectationFailure ("expected a malformed admission artifact, got " <> show other)

  it "renders binding causes for circuits failing unified admission" $ do
    compiled <- requireRight (compileWireTextWithEnv nativeEnv pureProgram)
    let broken =
          compiled
            { compiledCircuitNodes =
                Map.delete (CircuitNodeRef "increment") compiled.compiledCircuitNodes
            }
    case admitNativePureCandidates nativeRegistry broken of
      Left (NativePureCircuitAdmissionRejected reason) -> do
        reason `shouldSatisfy` T.isInfixOf "does not bind to the compiled circuit"
        reason `shouldSatisfy` T.isInfixOf "increment"
        reason `shouldSatisfy` (not . T.isInfixOf "fromList")
      other ->
        expectationFailure ("expected a rejected unified admission, got " <> show other)

  it "rejects pure task metadata without a config object" $ do
    compiled <- requireRight (compileWireTextWithEnv nativeEnv pureProgram)
    let mutated = mapTaskMetadata (CircuitNodeRef "increment") (KeyMap.delete "config") compiled
    admitNativePureCandidates nativeRegistry mutated
      `shouldSatisfy` \case
        Left NativePureMalformedMetadata {} -> True
        _ -> False

  it "rejects admission against a registry missing a crossing contract" $ do
    compiled <- requireRight (compileWireTextWithEnv nativeEnv pureProgram)
    admitNativePureCandidates missingScoreRegistry compiled
      `shouldSatisfy` \case
        Left NativePureMissingContract {} -> True
        _ -> False

  it "rejects an outputs config over an exclusive boundary" $ do
    compiled <- requireRight (compileWireTextWithEnv paddedProductEnv paddedProductProgram)
    let markExclusive = \case
          Aeson.Array entries -> Aeson.Array (fmap markFlag entries)
          other -> other
        markFlag = \case
          Aeson.Object port
            | KeyMap.lookup "name" port == Just (Aeson.String "flag") ->
                Aeson.Object (KeyMap.insert "exclusiveGroup" (Aeson.Number 0) port)
          other -> other
        mutated =
          mapTaskMetadata
            (CircuitNodeRef "split")
            (adjustKey "ports" (adjustObjectPath ["outputs"] markExclusive))
            compiled
    admitNativePureCandidates paddedProductRegistry mutated
      `shouldSatisfy` \case
        Left NativePureSumRequiresVariant {} -> True
        _ -> False

  it "rejects a variant config over a product boundary" $ do
    sumCompiled <- requireRight (compileWireTextWithEnv sumEnv sumProgram)
    variantValue <-
      maybe (fail "expected a compiled variant config") pure $
        lookupTaskConfigKey (CircuitNodeRef "classify") "variant" sumCompiled
    compiled <- requireRight (compileWireTextWithEnv nativeEnv pureProgram)
    let mutated =
          mapTaskMetadata
            (CircuitNodeRef "increment")
            (KeyMap.insert "config" (Aeson.object ["variant" Aeson..= variantValue]))
            compiled
    admitNativePureCandidates nativeRegistry mutated
      `shouldSatisfy` \case
        Left NativePureVariantRequiresSum {} -> True
        _ -> False

  it "rejects output equations that do not match the declared boundary" $ do
    compiled <- requireRight (compileWireTextWithEnv nativeEnv pureProgram)
    let renameResult = \case
          Aeson.Object outputs ->
            case KeyMap.lookup "result" outputs of
              Just equation ->
                Aeson.Object (KeyMap.insert "wrong" equation (KeyMap.delete "result" outputs))
              Nothing -> Aeson.Object outputs
          other -> other
        mutated =
          mapTaskMetadata
            (CircuitNodeRef "increment")
            (adjustKey "config" (adjustObjectPath ["outputs"] renameResult))
            compiled
    admitNativePureCandidates nativeRegistry mutated
      `shouldSatisfy` \case
        Left NativePureOutputEquationMismatch {} -> True
        _ -> False

  it "rejects input byte totals that overflow the resource bounds" $ do
    compiled <- requireRight (compileWireTextWithEnv hugeEnv hugePairProgram)
    admitNativePureCandidates hugeRegistry compiled
      `shouldSatisfy` \case
        Left NativePureResourceOverflow {} -> True
        _ -> False

  it "rejects a combined output boundary whose layout overflows" $ do
    compiled <- requireRight (compileWireTextWithEnv hugeEnv hugeDupProgram)
    admitNativePureCandidates hugeRegistry compiled
      `shouldSatisfy` \case
        Left NativePureInvalidOutputBoundary {} -> True
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

  it "offers an unfused diagnostic plan with identical typed source coverage" $ do
    (normalized, maximalPlan) <- requirePlan fusionRegistry fusionEnv fusedProgram
    unfusedPlan <- requireRight (realizeNativePurePlanWithMode NativePureUnfused normalized)
    maximalPlan.nativePurePlanFusionMode `shouldBe` NativePureMaximalFusion
    unfusedPlan.nativePurePlanFusionMode `shouldBe` NativePureUnfused
    fmap (.nativePureFusedRegionSources) unfusedPlan.nativePurePlanRegions
      `shouldBe` [[CircuitNodeRef "first"], [CircuitNodeRef "second"]]
    Map.keysSet unfusedPlan.nativePurePlanRealization.realizationArtifactSourceToRuntime
      `shouldBe` Map.keysSet maximalPlan.nativePurePlanRealization.realizationArtifactSourceToRuntime
    unfusedPlan.nativePurePlanRealization.realizationArtifactRuntimeEdges
      `shouldBe` Set.singleton ("native-pure/0000", "native-pure/0001")
    unfusedPlan.nativePurePlanDigest `shouldNotBe` maximalPlan.nativePurePlanDigest

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

  it "hands a fused typed plan to Lean without a second semantic decoder" $ do
    (normalized, plan) <- requirePlan fusionRegistry fusionEnv fusedProgram
    rendered <-
      requireRight
        (renderNativePurePlanModule "Cortex.Wire.NativePure.Generated.Fused" normalized plan)
    rendered `shouldSatisfy` T.isInfixOf "import Cortex.Wire.NativePure.C.Engine"
    rendered `shouldSatisfy` T.isInfixOf ".add"
    rendered `shouldSatisfy` T.isInfixOf "C.renderDispatchable"
    rendered `shouldSatisfy` T.isInfixOf "Engine.render engineProgram"
    rendered `shouldSatisfy` T.isInfixOf plan.nativePurePlanDigest
    region <- requireSingleRegion plan
    region.nativePureFusedRegionBounds `shouldBe` NativePureBounds 48 0 16 32 17
    rendered `shouldSatisfy` T.isInfixOf "maxSteps := 17"

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

  it "splits effectful diamonds into convex regions instead of cyclic quotients" $ do
    (_, plan) <- requirePlan fusionRegistry fusionMixedEnv effectDiamondProgram
    fmap (.nativePureFusedRegionSources) plan.nativePurePlanRegions
      `shouldBe` [ [CircuitNodeRef "carry", CircuitNodeRef "second"]
                 , [CircuitNodeRef "first"]
                 ]
    plan.nativePurePlanRealization.realizationArtifactRuntimeEdges
      `shouldBe` Set.fromList
        [ ("native-pure/0001", "native-pure/0000")
        , ("native-pure/0001", "source/review")
        , ("source/review", "native-pure/0000")
        ]

  it "keeps unfused source coverage identical on effectful diamonds" $ do
    compiled <- requireRight (compileWireTextWithEnv fusionMixedEnv effectDiamondProgram)
    normalized <- requireRight (normalizeNativePureInput fusionRegistry compiled)
    fusedPlan <- requireRight (realizeNativePurePlan normalized)
    unfusedPlan <- requireRight (realizeNativePurePlanWithMode NativePureUnfused normalized)
    Map.keysSet unfusedPlan.nativePurePlanRealization.realizationArtifactSourceToRuntime
      `shouldBe` Map.keysSet fusedPlan.nativePurePlanRealization.realizationArtifactSourceToRuntime

  it "cuts exclusive-sum consumers out of the producer's region" $ do
    (_, plan) <- requirePlan sumDiamondRegistry sumDiamondEnv sumDiamondProgram
    fmap (.nativePureFusedRegionSources) plan.nativePurePlanRegions
      `shouldBe` [ [CircuitNodeRef "carry", CircuitNodeRef "consume"]
                 , [CircuitNodeRef "seed", CircuitNodeRef "classify"]
                 ]

  it "rejects realization forgeries and tampered digests with named gates" $ do
    (normalized, plan) <- requirePlan fusionRegistry fusionEnv fusedProgram
    let artifact = plan.nativePurePlanRealization
    validateRealizationArtifact
      normalized
      artifact {realizationArtifactReferentIdentity = "tampered"}
      `shouldBe` Left (NativePureArtifactDigestMismatch "realization referent")
    validateRealizationArtifact
      normalized
      artifact {realizationArtifactInputDigest = "tampered"}
      `shouldBe` Left (NativePureArtifactDigestMismatch "realization input")
    (diamondNormalized, diamondPlan) <-
      requirePlan fusionRegistry fusionMixedEnv effectDiamondProgram
    let diamondArtifact = diamondPlan.nativePurePlanRealization
    validateRealizationArtifact
      diamondNormalized
      diamondArtifact {realizationArtifactRuntimeEdges = Set.empty}
      `shouldSatisfy` \case
        Left (NativePureArtifactDigestMismatch "realization artifact") -> True
        Left NativePureArtifactRealizationMismatch -> True
        _ -> False
    let remapKey units =
          case Map.toAscList units of
            (runtimeRef, unit) : _ ->
              Map.insert "forged/9999" unit (Map.delete runtimeRef units)
            [] -> units
        remapped =
          artifact
            { realizationArtifactRuntimeUnits =
                remapKey artifact.realizationArtifactRuntimeUnits
            }
    validateRealizationArtifact normalized remapped
      `shouldSatisfy` \case
        Left (NativePureArtifactMissingRuntimeUnit _) -> True
        Left (NativePureArtifactRuntimeInverseMismatch _) -> True
        _ -> False
    validateNativePurePlan normalized plan {nativePurePlanDigest = "tampered"}
      `shouldBe` Left (NativePureArtifactDigestMismatch "NativePure plan")

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
    , "  <- score: Score"
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

f64LiteralProgram :: Text
f64LiteralProgram =
  T.unlines
    [ "contract Measurement;"
    , "node literal -> result: Measurement = 0.5;"
    , "literal"
    ]

f64BindingProgram :: Text
f64BindingProgram =
  T.unlines
    [ "contract Measurement;"
    , "node literal -> result: Measurement = let x = 0.5; in x;"
    , "literal"
    ]

builtinInputProgram :: Text
builtinInputProgram =
  T.unlines
    [ "contract Score;"
    , "contract Result;"
    , "node candidate"
    , "  <- sum: Score"
    , "  -> result: Result = sum + 1;"
    , "candidate"
    ]

hugePairProgram :: Text
hugePairProgram =
  T.unlines
    [ "contract Huge;"
    , "node pair"
    , "  <- a: Huge"
    , "  <- b: Huge"
    , "  -> left: Huge = a;"
    , "  -> right: Huge = b;"
    , "pair"
    ]

hugeDupProgram :: Text
hugeDupProgram =
  T.unlines
    [ "contract Huge;"
    , "node dup"
    , "  <- blob: Huge"
    , "  -> left: Huge = blob;"
    , "  -> right: Huge = blob;"
    , "dup"
    ]

replaceBody :: Text -> Text
replaceBody body =
  T.unlines
    [ "contract Score;"
    , "contract Result;"
    , "node candidate"
    , "  <- score: Score"
    , "  -> result: Result = " <> body <> ";"
    , "candidate"
    ]

boolArithmeticProgram :: Text
boolArithmeticProgram =
  T.unlines
    [ "contract Score;"
    , "contract Flag;"
    , "node gate"
    , "  <- score: Score"
    , "  -> flag: Flag = score + 1;"
    , "gate"
    ]

derivedComparisonProgram :: Text
derivedComparisonProgram =
  T.unlines
    [ "contract Score;"
    , "contract Flag;"
    , "node compare"
    , "  <- score: Score"
    , "  -> flag: Flag = score >= 0;"
    , "compare"
    ]

mergeProgram :: Text
mergeProgram =
  T.unlines
    [ "contract Score;"
    , "contract ResultRecord;"
    , "node merge_record"
    , "  <- score: Score"
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
    , "  <- score: Score"
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
    , "  <- score: Score"
    , "  -> result: Result = score + 1;"
    , "node store"
    , "  <- result: Result"
    , "  = @report.store result;"
    , "increment => store"
    ]

fusedProgram :: Text
fusedProgram =
  T.unlines
    [ "contract Score;"
    , "contract Mid;"
    , "contract Result;"
    , "node first"
    , "  <- score: Score"
    , "  -> mid: Mid = score + 1;"
    , "node second"
    , "  <- mid: Mid"
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
    , "  <- score: Score"
    , "  -> mid: Mid = score + 1;"
    , "node review"
    , "  <- mid: Mid"
    , "  -> reviewed: Reviewed"
    , "  = @report.review mid;"
    , "node second"
    , "  <- reviewed: Reviewed"
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
    , "  <- score: Score"
    , "  -> pair: Pair = let adjusted = score + 1; in"
    , "    { flag = !(score < 0); value = adjusted; };"
    , "node project"
    , "  <- pair: Pair"
    , "  -> result: Result = if pair.flag then pair.value else 0;"
    , "construct => project"
    ]

effectDiamondProgram :: Text
effectDiamondProgram =
  T.unlines
    [ "contract Score;"
    , "contract Mid;"
    , "contract MidCopy;"
    , "contract Reviewed;"
    , "contract Result;"
    , "node first"
    , "  <- score: Score;"
    , "  -> mid: Mid = score + 1;"
    , "  -> spare: MidCopy = score + 1;"
    , "node review"
    , "  <- mid: Mid;"
    , "  -> reviewed: Reviewed;"
    , "  = @report.review {} (mid);"
    , "node carry"
    , "  <- spare: MidCopy;"
    , "  -> carried: MidCopy = spare;"
    , "node second"
    , "  <- carried: MidCopy;"
    , "  <- reviewed: Reviewed;"
    , "  -> result: Result = carried + reviewed;"
    , "first => (review <> carry) => second"
    ]

sumDiamondProgram :: Text
sumDiamondProgram =
  T.unlines
    [ "contract Score;"
    , "contract Mid;"
    , "contract MidCopy;"
    , "contract Decision;"
    , "contract RejectReason;"
    , "contract Result;"
    , "node seed"
    , "  <- score: Score;"
    , "  -> mid: Mid = score + 1;"
    , "  -> spare: MidCopy = score + 1;"
    , "node classify"
    , "  <- mid: Mid;"
    , "  -> accepted: Decision | rejected: RejectReason ="
    , "    if mid < 0 then rejected mid else accepted mid;"
    , "node carry"
    , "  <- spare: MidCopy;"
    , "  -> carried: MidCopy = spare;"
    , "node consume"
    , "  <- carried: MidCopy;"
    , "  <- accepted: Decision;"
    , "  -> result: Result = carried + accepted;"
    , "seed => (classify <> carry) => consume"
    ]

bigTextProgram :: Text
bigTextProgram =
  T.unlines
    [ "contract Blob;"
    , "contract BlobCopy;"
    , "node copy"
    , "  <- blob: Blob"
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
    , "  <- score: Score"
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
  , f64Env
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
f64Env = strictEnv f64Registry [pureWireExecutorProjection]

hugeEnv :: WireCompileEnv
hugeEnv = strictEnv hugeRegistry [pureWireExecutorProjection]

mixedEnv :: WireCompileEnv
mixedEnv = strictEnv nativeRegistry [pureWireExecutorProjection, storeExecutorProjection]

fusionEnv, fusionMixedEnv :: WireCompileEnv
fusionEnv = strictEnv fusionRegistry [pureWireExecutorProjection]
fusionMixedEnv = strictEnv fusionRegistry [pureWireExecutorProjection, reviewExecutorProjection]

anfEnv :: WireCompileEnv
anfEnv = strictEnv anfRegistry [pureWireExecutorProjection]

sumDiamondEnv :: WireCompileEnv
sumDiamondEnv = strictEnv sumDiamondRegistry [pureWireExecutorProjection]

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
  , f64Registry
    :: WireContractRegistry
nativeRegistry = shapedRegistry [("Score", NativeI64), ("Result", NativeI64)]
fusionRegistry =
  shapedRegistry
    [ ("Score", NativeI64)
    , ("Mid", NativeI64)
    , ("MidCopy", NativeI64)
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
f64Registry = shapedRegistry [("Measurement", NativeF64)]

missingScoreRegistry :: WireContractRegistry
missingScoreRegistry = shapedRegistry [("Result", NativeI64)]

{- | Each layout is individually valid (about 2^63 bytes), so overflow appears
only when admission combines boundaries.
-}
sumDiamondRegistry :: WireContractRegistry
sumDiamondRegistry =
  shapedRegistry
    [ ("Score", NativeI64)
    , ("Mid", NativeI64)
    , ("MidCopy", NativeI64)
    , ("Decision", NativeI64)
    , ("RejectReason", NativeI64)
    , ("Result", NativeI64)
    ]

hugeRegistry :: WireContractRegistry
hugeRegistry =
  shapedRegistry [("Huge", NativeVector 268435456 (NativeVector 4294967295 NativeU64))]

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
    , wireExecutorProjectionArgumentShape = WireExecutorArgumentUnchecked
    , wireExecutorProjectionPortPolicy = WireExecutorAuthorDeclaredPorts
    }

reviewExecutorProjection :: WireExecutorProjection
reviewExecutorProjection =
  storeExecutorProjection {wireExecutorProjectionId = WireExecutorId "report.review"}

requireRight :: Show err => Either err value -> IO value
requireRight = \case
  Right value -> pure value
  Left err -> fail ("expected Right, got " <> show err)

withCircuitMetadataKey :: Text -> Aeson.Value -> CompiledCircuit -> CompiledCircuit
withCircuitMetadataKey key value compiled =
  case compiled.compiledCircuitMetadata of
    Aeson.Object metadata ->
      compiled
        { compiledCircuitMetadata = Aeson.Object (KeyMap.insert (Key.fromText key) value metadata)
        }
    other -> compiled {compiledCircuitMetadata = other}

mapTaskMetadata
  :: CircuitNodeRef
  -> (KeyMap.KeyMap Aeson.Value -> KeyMap.KeyMap Aeson.Value)
  -> CompiledCircuit
  -> CompiledCircuit
mapTaskMetadata nodeRef adjustMetadata compiled =
  compiled {compiledCircuitNodes = Map.adjust adjustNode nodeRef compiled.compiledCircuitNodes}
  where
    adjustNode = \case
      CompiledCircuitTask taskNode ->
        CompiledCircuitTask
          taskNode
            { circuitTaskNodeMetadata =
                case taskNode.circuitTaskNodeMetadata of
                  Aeson.Object metadata -> Aeson.Object (adjustMetadata metadata)
                  other -> other
            }
      other -> other

adjustKey
  :: Key.Key
  -> (Aeson.Value -> Aeson.Value)
  -> KeyMap.KeyMap Aeson.Value
  -> KeyMap.KeyMap Aeson.Value
adjustKey key adjustValue objectValue =
  case KeyMap.lookup key objectValue of
    Just value -> KeyMap.insert key (adjustValue value) objectValue
    Nothing -> objectValue

adjustObjectPath :: [Text] -> (Aeson.Value -> Aeson.Value) -> Aeson.Value -> Aeson.Value
adjustObjectPath path adjustValue value =
  case path of
    [] -> adjustValue value
    key : rest ->
      case value of
        Aeson.Object objectValue ->
          Aeson.Object (adjustKey (Key.fromText key) (adjustObjectPath rest adjustValue) objectValue)
        other -> other

lookupTaskConfigKey :: CircuitNodeRef -> Text -> CompiledCircuit -> Maybe Aeson.Value
lookupTaskConfigKey nodeRef key compiled = do
  CompiledCircuitTask taskNode <- Map.lookup nodeRef compiled.compiledCircuitNodes
  Aeson.Object metadata <- Just taskNode.circuitTaskNodeMetadata
  configValue <- KeyMap.lookup "config" metadata
  Aeson.Object config <- Just configValue
  KeyMap.lookup (Key.fromText key) config
