{- |
Module      : Cortex.Wire.NativePure.Artifact
Description : Normalized NativePure realization artifacts and maximal fusion.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

This module turns the ephemeral, referent-bound admission candidates into a
versioned normalized input, a witnessed quotient of the complete source
topology, and a validated region plan. Maximal fusion is the production mode;
an explicit one-source-per-region mode provides traceable differential and
diagnostic artifacts without weakening boundary or provenance validation.
-}
module Cortex.Wire.NativePure.Artifact
  ( NativePureNormalizedInput (..)
  , RealizationArtifact (..)
  , RealizationRuntimeUnit (..)
  , RealizationRuntimeKind (..)
  , NativePureFusionMode (..)
  , NativePurePlan (..)
  , NativePureFusedRegion (..)
  , NativePureRegionBoundary (..)
  , NativePureRegionOutput (..)
  , NativePureRegionSumBoundary (..)
  , NativePureRegionEdge (..)
  , NativePureSsaStep (..)
  , NativePureSsaInput (..)
  , NativePureSsaEquation (..)
  , NativePureSsaValueRef (..)
  , NativePureAnfBlock (..)
  , NativePureAnfBinding (..)
  , NativePureAnfOp (..)
  , NativePureArtifactError (..)
  , nativePureNormalizedInputSchema
  , realizationArtifactSchema
  , nativePurePlanSchema
  , normalizeNativePureInput
  , realizeNativePurePlan
  , realizeNativePurePlanWithMode
  , validateRealizationArtifact
  , validateNativePurePlan
  , renderNativePureArtifactError
  )
where

import Control.Monad (foldM, foldM_, unless, when)
import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.Foldable (traverse_)
import Data.Functor (($>))
import Data.List qualified as List
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Scientific (floatingOrInteger)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

import Cortex.Algebra.Graph
  ( Relation (..)
  , edges
  , inducedSubgraph
  , predecessors
  , successors
  , toRelation
  , topSort
  , vertices
  )
import Cortex.Wire.Circuit.Compiled
  ( CircuitCompatibilityWitness (..)
  , CompiledCircuit (..)
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..))
import Cortex.Wire.Contract (WireContractRegistry)
import Cortex.Wire.NativePure.Admission
  ( NativePureAdmissionError
  , NativePureBoundary (..)
  , NativePureBounds (..)
  , NativePureCandidates (..)
  , NativePureKernelCandidate (..)
  , NativePureOutputBoundary (..)
  , NativePureVariantCandidate (..)
  , admitNativePureCandidates
  , renderNativePureAdmissionError
  )
import Cortex.Wire.NativePure.Shape
  ( NativeLayout (..)
  , NativeShape (..)
  , nativeShapeLayout
  , renderNativeShapeError
  )
import Cortex.Wire.Syntax
  ( Connection (..)
  , CorePureBinOp (..)
  , CorePureBinding (..)
  , CorePureExpr (..)
  , CorePureField (..)
  , CorePureLiteral (..)
  , CorePureUnaryOp (..)
  , EndpointRef (..)
  )

nativePureNormalizedInputSchema :: Text
nativePureNormalizedInputSchema = "cortex.wire.native-pure-input/v1"

realizationArtifactSchema :: Text
realizationArtifactSchema = "cortex.wire.realization-artifact/v1"

nativePurePlanSchema :: Text
nativePurePlanSchema = "cortex.wire.native-pure-plan/v1"

data NativePureNormalizedInput = NativePureNormalizedInput
  { nativePureNormalizedProgramId :: !Text
  , nativePureNormalizedReferentIdentity :: !Text
  , nativePureNormalizedSourceNodes :: ![CircuitNodeRef]
  , nativePureNormalizedSourceEdges :: ![(CircuitNodeRef, CircuitNodeRef)]
  , nativePureNormalizedCandidates :: ![NativePureKernelCandidate]
  , nativePureNormalizedConnections :: ![Connection]
  , nativePureNormalizedDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)

newtype NativePureSsaValueRef = NativePureSsaValueRef
  { unNativePureSsaValueRef :: Text
  }
  deriving stock (Eq, Ord, Show, Generic)

data NativePureSsaInput = NativePureSsaInput
  { nativePureSsaInputLabel :: !Text
  , nativePureSsaInputValue :: !NativePureSsaValueRef
  , nativePureSsaInputContract :: !Text
  , nativePureSsaInputShape :: !NativeShape
  }
  deriving stock (Eq, Show, Generic)

data NativePureAnfBlock = NativePureAnfBlock
  { nativePureAnfBlockBindings :: ![NativePureAnfBinding]
  , nativePureAnfBlockResult :: !NativePureSsaValueRef
  }
  deriving stock (Eq, Show, Generic)

data NativePureAnfBinding = NativePureAnfBinding
  { nativePureAnfBindingValue :: !NativePureSsaValueRef
  , nativePureAnfBindingShape :: !NativeShape
  , nativePureAnfBindingOp :: !NativePureAnfOp
  }
  deriving stock (Eq, Show, Generic)

data NativePureAnfOp
  = NativePureAnfLiteral !CorePureLiteral
  | NativePureAnfAlias !NativePureSsaValueRef
  | NativePureAnfRecord !(Map Text NativePureSsaValueRef)
  | NativePureAnfProject !NativePureSsaValueRef !Text
  | NativePureAnfNot !NativePureSsaValueRef
  | NativePureAnfBinary !CorePureBinOp !NativePureSsaValueRef !NativePureSsaValueRef
  | NativePureAnfIf !NativePureSsaValueRef !NativePureAnfBlock !NativePureAnfBlock
  | NativePureAnfInject !Text !NativePureSsaValueRef
  deriving stock (Eq, Show, Generic)

data NativePureSsaEquation = NativePureSsaEquation
  { nativePureSsaEquationValue :: !NativePureSsaValueRef
  , nativePureSsaEquationLabel :: !Text
  , nativePureSsaEquationContract :: !Text
  , nativePureSsaEquationShape :: !NativeShape
  , nativePureSsaEquationExpr :: !CorePureExpr
  , nativePureSsaEquationAnf :: !NativePureAnfBlock
  }
  deriving stock (Eq, Show, Generic)

{- | One topologically sequenced source node. Every result value is assigned
exactly once; internal inputs point at an earlier result in the same region.
-}
data NativePureSsaStep = NativePureSsaStep
  { nativePureSsaStepSource :: !CircuitNodeRef
  , nativePureSsaStepInputs :: ![NativePureSsaInput]
  , nativePureSsaStepPrelude :: ![NativePureAnfBinding]
  , nativePureSsaStepEquations :: ![NativePureSsaEquation]
  , nativePureSsaStepVariant :: !(Maybe NativePureVariantCandidate)
  }
  deriving stock (Eq, Show, Generic)

data NativePureRegionBoundary = NativePureRegionBoundary
  { nativePureRegionBoundaryEndpoint :: !EndpointRef
  , nativePureRegionBoundaryContract :: !Text
  , nativePureRegionBoundaryShape :: !NativeShape
  , nativePureRegionBoundaryLayout :: !NativeLayout
  }
  deriving stock (Eq, Show, Generic)

data NativePureRegionEdge = NativePureRegionEdge
  { nativePureRegionEdgeFrom :: !EndpointRef
  , nativePureRegionEdgeTo :: !EndpointRef
  }
  deriving stock (Eq, Ord, Show, Generic)

{- | A product field crosses independently. An exclusive sum crosses as one
tagged aggregate so its variant storage cannot be mistaken for simultaneous
product outputs.
-}
data NativePureRegionSumBoundary = NativePureRegionSumBoundary
  { nativePureRegionSumSource :: !CircuitNodeRef
  , nativePureRegionSumGroup :: !Natural
  , nativePureRegionSumVariants :: ![NativePureRegionBoundary]
  , nativePureRegionSumShape :: !NativeShape
  , nativePureRegionSumLayout :: !NativeLayout
  }
  deriving stock (Eq, Show, Generic)

data NativePureRegionOutput
  = NativePureRegionProductField !NativePureRegionBoundary
  | NativePureRegionExclusiveSum !NativePureRegionSumBoundary
  deriving stock (Eq, Show, Generic)

data NativePureFusedRegion = NativePureFusedRegion
  { nativePureFusedRegionRef :: !Text
  , nativePureFusedRegionSources :: ![CircuitNodeRef]
  , nativePureFusedRegionInputs :: ![NativePureRegionBoundary]
  , nativePureFusedRegionOutputs :: ![NativePureRegionOutput]
  , nativePureFusedRegionInternalEdges :: ![NativePureRegionEdge]
  , nativePureFusedRegionSsa :: ![NativePureSsaStep]
  , nativePureFusedRegionBounds :: !NativePureBounds
  }
  deriving stock (Eq, Show, Generic)

data RealizationRuntimeKind
  = RealizationPureRegion
  | RealizationPreservedNode
  deriving stock (Eq, Ord, Show, Generic)

data RealizationRuntimeUnit = RealizationRuntimeUnit
  { realizationRuntimeUnitRef :: !Text
  , realizationRuntimeUnitKind :: !RealizationRuntimeKind
  , realizationRuntimeUnitSources :: ![CircuitNodeRef]
  }
  deriving stock (Eq, Ord, Show, Generic)

{- | Region-selection policy. Maximal fusion is the production profile;
unfused realization is a diagnostic profile that preserves one eligible
source node per region while retaining the same boundary and provenance
validation.
-}
data NativePureFusionMode
  = NativePureMaximalFusion
  | NativePureUnfused
  deriving stock (Eq, Ord, Show, Generic)

data RealizationArtifact = RealizationArtifact
  { realizationArtifactReferentIdentity :: !Text
  , realizationArtifactInputDigest :: !Text
  , realizationArtifactSourceToRuntime :: !(Map CircuitNodeRef Text)
  , realizationArtifactRuntimeUnits :: !(Map Text RealizationRuntimeUnit)
  , realizationArtifactRuntimeEdges :: !(Set (Text, Text))
  , realizationArtifactDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)

data NativePurePlan = NativePurePlan
  { nativePurePlanProgramId :: !Text
  , nativePurePlanProgramIdentity :: !Text
  , nativePurePlanInputDigest :: !Text
  , nativePurePlanFusionMode :: !NativePureFusionMode
  , nativePurePlanRealization :: !RealizationArtifact
  , nativePurePlanRegions :: ![NativePureFusedRegion]
  , nativePurePlanDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)

data NativePureArtifactError
  = NativePureArtifactAdmission !NativePureAdmissionError
  | NativePureArtifactSourceCycle
  | NativePureArtifactEmptyRegion !Text
  | NativePureArtifactDuplicateSource !CircuitNodeRef
  | NativePureArtifactMissingSourceProvenance !CircuitNodeRef
  | NativePureArtifactUnknownSourceProvenance !CircuitNodeRef
  | NativePureArtifactMissingRuntimeUnit !Text
  | NativePureArtifactRuntimeInverseMismatch !Text
  | NativePureArtifactRuntimeCycle
  | NativePureArtifactCrossRegionPureEdge !Connection
  | NativePureArtifactRegionMismatch !Text
  | NativePureArtifactRealizationMismatch
  | NativePureArtifactMissingPort !EndpointRef
  | NativePureArtifactMissingBoundary !EndpointRef
  | NativePureArtifactInvalidBoundary !Text
  | NativePureArtifactSsaUseBeforeDefinition !NativePureSsaValueRef
  | NativePureArtifactSsaDuplicateDefinition !NativePureSsaValueRef
  | NativePureArtifactBoundsOverflow !Text
  | NativePureArtifactCheckpointTooLarge !Text !Word64
  | NativePureArtifactDigestMismatch !Text
  deriving stock (Eq, Show)

renderNativePureArtifactError :: NativePureArtifactError -> Text
renderNativePureArtifactError = \case
  NativePureArtifactAdmission err -> renderNativePureAdmissionError err
  NativePureArtifactSourceCycle -> "normalized NativePure source topology is cyclic"
  NativePureArtifactEmptyRegion regionRef -> "NativePure region " <> regionRef <> " has no source members"
  NativePureArtifactDuplicateSource source -> "source " <> refText source <> " belongs to more than one runtime unit"
  NativePureArtifactMissingSourceProvenance source -> "source " <> refText source <> " has no runtime provenance"
  NativePureArtifactUnknownSourceProvenance source -> "realization refers to unknown source " <> refText source
  NativePureArtifactMissingRuntimeUnit runtimeRef -> "source provenance refers to missing runtime unit " <> runtimeRef
  NativePureArtifactRuntimeInverseMismatch runtimeRef -> "runtime unit " <> runtimeRef <> " disagrees with source-to-runtime provenance"
  NativePureArtifactRuntimeCycle -> "realized quotient topology is cyclic"
  NativePureArtifactCrossRegionPureEdge connection -> "eligible pure edge crosses maximal regions: " <> T.pack (show connection)
  NativePureArtifactRegionMismatch regionRef -> "NativePure region " <> regionRef <> " does not match the normalized maximal component"
  NativePureArtifactRealizationMismatch -> "realization artifact does not match the normalized witnessed quotient"
  NativePureArtifactMissingPort endpoint -> "normalized connection has no exact port at " <> T.pack (show endpoint)
  NativePureArtifactMissingBoundary endpoint -> "no typed NativePure boundary for " <> T.pack (show endpoint)
  NativePureArtifactInvalidBoundary reason -> "invalid NativePure region boundary: " <> reason
  NativePureArtifactSsaUseBeforeDefinition valueRef -> "SSA value is used before definition: " <> valueRef.unNativePureSsaValueRef
  NativePureArtifactSsaDuplicateDefinition valueRef -> "SSA value is defined more than once: " <> valueRef.unNativePureSsaValueRef
  NativePureArtifactBoundsOverflow regionRef -> "NativePure region " <> regionRef <> " resource bounds overflow uint64"
  NativePureArtifactCheckpointTooLarge regionRef bytes ->
    "NativePure region " <> regionRef <> " checkpoint " <> T.pack (show bytes) <> " bytes exceeds 2 MiB"
  NativePureArtifactDigestMismatch artifactName -> artifactName <> " digest does not match canonical content"
  where
    refText = (.unCircuitNodeRef)

normalizeNativePureInput
  :: WireContractRegistry
  -> CompiledCircuit
  -> Either NativePureArtifactError NativePureNormalizedInput
normalizeNativePureInput registry compiled = do
  candidates <- firstAdmission (admitNativePureCandidates registry compiled)
  sourceOrder <-
    maybe (Left NativePureArtifactSourceCycle) Right (topSort compiled.compiledCircuitTopology)
  let sourceEdges = Set.toAscList compiled.compiledCircuitTopology.relEdges
      normalizedWithoutDigest =
        NativePureNormalizedInput
          { nativePureNormalizedProgramId = compiled.compiledCircuitId
          , nativePureNormalizedReferentIdentity =
              compiled.compiledCircuitCompatibility.circuitCompatibilityDigest
          , nativePureNormalizedSourceNodes = sourceOrder
          , nativePureNormalizedSourceEdges = sourceEdges
          , nativePureNormalizedCandidates = candidates.nativePureCandidatesKernels
          , nativePureNormalizedConnections = List.sort candidates.nativePureCandidatesConnections
          , nativePureNormalizedDigest = ""
          }
      digest = canonicalDigest (normalizedInputValue normalizedWithoutDigest)
  pure normalizedWithoutDigest {nativePureNormalizedDigest = digest}

realizeNativePurePlan
  :: NativePureNormalizedInput
  -> Either NativePureArtifactError NativePurePlan
realizeNativePurePlan = realizeNativePurePlanWithMode NativePureMaximalFusion

realizeNativePurePlanWithMode
  :: NativePureFusionMode
  -> NativePureNormalizedInput
  -> Either NativePureArtifactError NativePurePlan
realizeNativePurePlanWithMode fusionMode normalized = do
  unless (canonicalDigest (normalizedInputValue normalized) == normalized.nativePureNormalizedDigest) $
    Left (NativePureArtifactDigestMismatch "normalized input")
  let candidateMap =
        Map.fromList
          [ (candidate.nativePureKernelCandidateRef, candidate)
          | candidate <- normalized.nativePureNormalizedCandidates
          ]
      sourceRelation =
        toRelation $
          vertices normalized.nativePureNormalizedSourceNodes
            <> edges normalized.nativePureNormalizedSourceEdges
      components = realizationComponents fusionMode normalized candidateMap
  regions <-
    traverse
      (uncurry (buildRegion sourceRelation candidateMap normalized.nativePureNormalizedConnections))
      (zip [0 :: Int ..] components)
  artifact <- buildRealizationArtifact normalized sourceRelation regions
  validateRealizationArtifact normalized artifact
  let planWithoutDigest =
        NativePurePlan
          { nativePurePlanProgramId = normalized.nativePureNormalizedProgramId
          , nativePurePlanProgramIdentity = normalized.nativePureNormalizedReferentIdentity
          , nativePurePlanInputDigest = normalized.nativePureNormalizedDigest
          , nativePurePlanFusionMode = fusionMode
          , nativePurePlanRealization = artifact
          , nativePurePlanRegions = regions
          , nativePurePlanDigest = ""
          }
      plan =
        planWithoutDigest {nativePurePlanDigest = canonicalDigest (nativePurePlanValue planWithoutDigest)}
  validateNativePurePlan normalized plan
  pure plan

validateRealizationArtifact
  :: NativePureNormalizedInput -> RealizationArtifact -> Either NativePureArtifactError ()
validateRealizationArtifact normalized artifact = do
  when
    (artifact.realizationArtifactReferentIdentity /= normalized.nativePureNormalizedReferentIdentity)
    (Left (NativePureArtifactDigestMismatch "realization referent"))
  unless (artifact.realizationArtifactInputDigest == normalized.nativePureNormalizedDigest) $
    Left (NativePureArtifactDigestMismatch "realization input")
  unless (canonicalDigest (realizationArtifactValue artifact) == artifact.realizationArtifactDigest) $
    Left (NativePureArtifactDigestMismatch "realization artifact")
  let sourceSet = Set.fromList normalized.nativePureNormalizedSourceNodes
      mappedSet = Map.keysSet artifact.realizationArtifactSourceToRuntime
  traverse_ (ensureMember mappedSet NativePureArtifactMissingSourceProvenance) sourceSet
  traverse_ (ensureMember sourceSet NativePureArtifactUnknownSourceProvenance) mappedSet
  traverse_
    ( \runtimeRef ->
        unless
          (Map.member runtimeRef artifact.realizationArtifactRuntimeUnits)
          (Left (NativePureArtifactMissingRuntimeUnit runtimeRef))
    )
    artifact.realizationArtifactSourceToRuntime
  foldM_ checkUnit Set.empty (Map.toAscList artifact.realizationArtifactRuntimeUnits)
  let runtimeRelation =
        toRelation $
          vertices (Map.keys artifact.realizationArtifactRuntimeUnits)
            <> edges (Set.toAscList artifact.realizationArtifactRuntimeEdges)
  when (isNothing (topSort runtimeRelation)) (Left NativePureArtifactRuntimeCycle)
  where
    ensureMember setValue mkError value = unless (Set.member value setValue) (Left (mkError value))
    checkUnit seen (runtimeRef, unit) = do
      when (null unit.realizationRuntimeUnitSources) (Left (NativePureArtifactEmptyRegion runtimeRef))
      unless
        ( all
            (\source -> Map.lookup source artifact.realizationArtifactSourceToRuntime == Just runtimeRef)
            unit.realizationRuntimeUnitSources
        )
        (Left (NativePureArtifactRuntimeInverseMismatch runtimeRef))
      case List.find (`Set.member` seen) unit.realizationRuntimeUnitSources of
        Just duplicate -> Left (NativePureArtifactDuplicateSource duplicate)
        Nothing -> pure (seen <> Set.fromList unit.realizationRuntimeUnitSources)

validateNativePurePlan
  :: NativePureNormalizedInput -> NativePurePlan -> Either NativePureArtifactError ()
validateNativePurePlan normalized plan = do
  unless (plan.nativePurePlanInputDigest == normalized.nativePureNormalizedDigest) $
    Left (NativePureArtifactDigestMismatch "plan input")
  validateRealizationArtifact normalized plan.nativePurePlanRealization
  unless (canonicalDigest (nativePurePlanValue plan) == plan.nativePurePlanDigest) $
    Left (NativePureArtifactDigestMismatch "NativePure plan")
  let sourceRelation =
        toRelation $
          vertices normalized.nativePureNormalizedSourceNodes
            <> edges normalized.nativePureNormalizedSourceEdges
      candidateMap =
        Map.fromList
          [ (candidate.nativePureKernelCandidateRef, candidate)
          | candidate <- normalized.nativePureNormalizedCandidates
          ]
      expectedComponents = realizationComponents plan.nativePurePlanFusionMode normalized candidateMap
  expectedRegions <-
    traverse
      (uncurry (buildRegion sourceRelation candidateMap normalized.nativePureNormalizedConnections))
      (zip [0 :: Int ..] expectedComponents)
  case List.find (uncurry (/=)) (zip plan.nativePurePlanRegions expectedRegions) of
    Just (actual, _) -> Left (NativePureArtifactRegionMismatch actual.nativePureFusedRegionRef)
    Nothing
      | length plan.nativePurePlanRegions /= length expectedRegions ->
          Left (NativePureArtifactRegionMismatch "<region-count>")
      | otherwise -> pure ()
  expectedRealization <- buildRealizationArtifact normalized sourceRelation expectedRegions
  unless (plan.nativePurePlanRealization == expectedRealization) $
    Left NativePureArtifactRealizationMismatch
  let expectedPureSources =
        Set.fromList (fmap (.nativePureKernelCandidateRef) normalized.nativePureNormalizedCandidates)
      actualPureSources = Set.fromList (concatMap (.nativePureFusedRegionSources) plan.nativePurePlanRegions)
  case Set.lookupMin (expectedPureSources Set.\\ actualPureSources) of
    Just missing -> Left (NativePureArtifactMissingSourceProvenance missing)
    Nothing -> pure ()
  case Set.lookupMin (actualPureSources Set.\\ expectedPureSources) of
    Just unknown -> Left (NativePureArtifactUnknownSourceProvenance unknown)
    Nothing -> pure ()
  foldM_ validateRegion Set.empty plan.nativePurePlanRegions
  pure ()
  where
    validateRegion seen region = do
      when (null region.nativePureFusedRegionSources) $
        Left (NativePureArtifactEmptyRegion region.nativePureFusedRegionRef)
      case List.find (`Set.member` seen) region.nativePureFusedRegionSources of
        Just duplicate -> Left (NativePureArtifactDuplicateSource duplicate)
        Nothing -> pure ()
      validateSsa region
      when (region.nativePureFusedRegionBounds.nativePureBoundCheckpointBytes > hostedCheckpointCeiling) $
        Left
          ( NativePureArtifactCheckpointTooLarge
              region.nativePureFusedRegionRef
              region.nativePureFusedRegionBounds.nativePureBoundCheckpointBytes
          )
      pure (seen <> Set.fromList region.nativePureFusedRegionSources)

validateSsa :: NativePureFusedRegion -> Either NativePureArtifactError ()
validateSsa region = do
  let boundaryDefinitions =
        Map.fromList
          [ ( boundaryValueRef region.nativePureFusedRegionRef boundary.nativePureRegionBoundaryEndpoint
            , boundary.nativePureRegionBoundaryShape
            )
          | boundary <- region.nativePureFusedRegionInputs
          ]
  _ <- foldM validateStep boundaryDefinitions region.nativePureFusedRegionSsa
  pure ()
  where
    validateStep defined step = do
      traverse_
        ( \input ->
            requireDefinedShape defined input.nativePureSsaInputValue input.nativePureSsaInputShape
        )
        step.nativePureSsaStepInputs
      preludeDefinitions <- validateAnfBindings defined step.nativePureSsaStepPrelude
      foldM validateEquation preludeDefinitions step.nativePureSsaStepEquations
    validateEquation defined equation = do
      resultShape <- validateAnfBlock defined equation.nativePureSsaEquationAnf
      requireAnfShape resultShape equation.nativePureSsaEquationShape
      addDefinition defined equation.nativePureSsaEquationValue equation.nativePureSsaEquationShape

validateAnfBlock
  :: Map NativePureSsaValueRef NativeShape
  -> NativePureAnfBlock
  -> Either NativePureArtifactError NativeShape
validateAnfBlock defined block = do
  blockDefinitions <- validateAnfBindings defined block.nativePureAnfBlockBindings
  maybe
    (Left (NativePureArtifactSsaUseBeforeDefinition block.nativePureAnfBlockResult))
    pure
    (Map.lookup block.nativePureAnfBlockResult blockDefinitions)

validateAnfBindings
  :: Map NativePureSsaValueRef NativeShape
  -> [NativePureAnfBinding]
  -> Either NativePureArtifactError (Map NativePureSsaValueRef NativeShape)
validateAnfBindings = foldM validateBinding
  where
    validateBinding defined binding = do
      validateOperation defined binding.nativePureAnfBindingShape binding.nativePureAnfBindingOp
      addDefinition defined binding.nativePureAnfBindingValue binding.nativePureAnfBindingShape

validateOperation
  :: Map NativePureSsaValueRef NativeShape
  -> NativeShape
  -> NativePureAnfOp
  -> Either NativePureArtifactError ()
validateOperation defined resultShape = \case
  NativePureAnfLiteral _ -> pure ()
  NativePureAnfAlias valueRef -> requireDefinedShape defined valueRef resultShape
  NativePureAnfRecord fields ->
    case resultShape of
      NativeRecord expectedFields -> do
        unless (Map.keysSet fields == Map.keysSet expectedFields) $
          Left
            (NativePureArtifactInvalidBoundary "NativePure ANF record fields do not match its result shape")
        traverse_
          ( \(fieldName, valueRef) -> traverse_ (requireDefinedShape defined valueRef) (Map.lookup fieldName expectedFields)
          )
          (Map.toAscList fields)
      _ -> Left (NativePureArtifactInvalidBoundary "NativePure ANF record has a non-record result shape")
  NativePureAnfProject valueRef fieldName -> do
    baseShape <- requireDefined defined valueRef
    case baseShape of
      NativeRecord fields ->
        maybe
          (Left (NativePureArtifactInvalidBoundary ("NativePure ANF projects unknown field " <> fieldName)))
          (`requireAnfShape` resultShape)
          (Map.lookup fieldName fields)
      _ -> Left (NativePureArtifactInvalidBoundary "NativePure ANF projects a non-record value")
  NativePureAnfNot valueRef -> do
    requireAnfShape resultShape NativeBool
    requireDefinedShape defined valueRef NativeBool
  NativePureAnfBinary binaryOp left right -> do
    (operandShape, expectedResult) <- binaryShapes binaryOp
    requireAnfShape resultShape expectedResult
    requireDefinedShape defined left operandShape
    requireDefinedShape defined right operandShape
  NativePureAnfIf condition thenBlock elseBlock -> do
    requireDefinedShape defined condition NativeBool
    thenShape <- validateAnfBlock defined thenBlock
    elseShape <- validateAnfBlock defined elseBlock
    requireAnfShape thenShape resultShape
    requireAnfShape elseShape resultShape
  NativePureAnfInject label payload ->
    case resultShape of
      NativeSum variants ->
        maybe
          (Left (NativePureArtifactInvalidBoundary ("NativePure ANF injects unknown label " <> label)))
          (requireDefinedShape defined payload)
          (Map.lookup label variants)
      _ -> Left (NativePureArtifactInvalidBoundary "NativePure ANF injection has a non-sum result shape")

requireDefined
  :: Map NativePureSsaValueRef NativeShape
  -> NativePureSsaValueRef
  -> Either NativePureArtifactError NativeShape
requireDefined defined valueRef =
  maybe
    (Left (NativePureArtifactSsaUseBeforeDefinition valueRef))
    pure
    (Map.lookup valueRef defined)

requireDefinedShape
  :: Map NativePureSsaValueRef NativeShape
  -> NativePureSsaValueRef
  -> NativeShape
  -> Either NativePureArtifactError ()
requireDefinedShape defined valueRef expected = do
  actual <- requireDefined defined valueRef
  requireAnfShape actual expected

addDefinition
  :: Map NativePureSsaValueRef NativeShape
  -> NativePureSsaValueRef
  -> NativeShape
  -> Either NativePureArtifactError (Map NativePureSsaValueRef NativeShape)
addDefinition defined valueRef shape
  | Map.member valueRef defined =
      Left (NativePureArtifactSsaDuplicateDefinition valueRef)
  | otherwise = pure (Map.insert valueRef shape defined)

nativePureFusionRelation
  :: Map CircuitNodeRef NativePureKernelCandidate
  -> [Connection]
  -> Relation CircuitNodeRef
nativePureFusionRelation candidates connections =
  toRelation $
    vertices (Map.keys candidates)
      <> edges
        [ (fromSource, toSource)
        | connection <- connections
        , let fromSource = connection.connectionFrom.endpointNodeRef
        , let toSource = connection.connectionTo.endpointNodeRef
        , Map.member toSource candidates
        , Just fromCandidate <- [Map.lookup fromSource candidates]
        , isNothing fromCandidate.nativePureKernelCandidateVariant
        ]

maximalEligibleComponents :: Relation CircuitNodeRef -> Set CircuitNodeRef -> [[CircuitNodeRef]]
maximalEligibleComponents relation eligible = go Set.empty (Set.toAscList eligible)
  where
    go _ [] = []
    go visited (source : rest)
      | Set.member source visited = go visited rest
      | otherwise =
          let componentSet = flood Set.empty [source]
              ordered =
                filter (`Set.member` componentSet) $
                  fromMaybe (Set.toAscList componentSet) (topSort (inducedSubgraph componentSet relation))
           in ordered : go (visited <> componentSet) rest
    flood seen [] = seen
    flood seen (node : pending)
      | Set.member node seen = flood seen pending
      | otherwise =
          let adjacent =
                Set.toAscList $
                  Set.intersection eligible (predecessors relation node <> successors relation node)
           in flood (Set.insert node seen) (adjacent <> pending)

realizationComponents
  :: NativePureFusionMode
  -> NativePureNormalizedInput
  -> Map CircuitNodeRef NativePureKernelCandidate
  -> [[CircuitNodeRef]]
realizationComponents fusionMode normalized candidates =
  case fusionMode of
    NativePureMaximalFusion ->
      maximalEligibleComponents
        (nativePureFusionRelation candidates normalized.nativePureNormalizedConnections)
        (Map.keysSet candidates)
    NativePureUnfused ->
      [ [source]
      | source <- normalized.nativePureNormalizedSourceNodes
      , Map.member source candidates
      ]

buildRegion
  :: Relation CircuitNodeRef
  -> Map CircuitNodeRef NativePureKernelCandidate
  -> [Connection]
  -> Int
  -> [CircuitNodeRef]
  -> Either NativePureArtifactError NativePureFusedRegion
buildRegion sourceRelation candidateMap connections index members = do
  when (null members) (Left (NativePureArtifactEmptyRegion regionRef))
  candidates <- traverse requireCandidate members
  bounds <- sumBounds regionRef (fmap (.nativePureKernelCandidateBounds) candidates)
  let memberSet = Set.fromList members
      internalConnections =
        [ connection
        | connection <- connections
        , Set.member connection.connectionFrom.endpointNodeRef memberSet
        , Set.member connection.connectionTo.endpointNodeRef memberSet
        ]
      crossingInputs =
        [ connection.connectionTo
        | connection <- connections
        , not (Set.member connection.connectionFrom.endpointNodeRef memberSet)
        , Set.member connection.connectionTo.endpointNodeRef memberSet
        ]
      crossingOutputs =
        [ connection.connectionFrom
        | connection <- connections
        , Set.member connection.connectionFrom.endpointNodeRef memberSet
        , not (Set.member connection.connectionTo.endpointNodeRef memberSet)
        ]
      entryInputs =
        [ endpoint
        | candidate <- candidates
        , boundary <- candidate.nativePureKernelCandidateInputs
        , let endpoint = EndpointRef candidate.nativePureKernelCandidateRef (Just boundary.nativePureBoundaryLabel)
        , not (any ((== endpoint) . (.connectionTo)) internalConnections)
        ]
      exitOutputs =
        [ endpoint
        | candidate <- candidates
        , boundary <- outputBoundaries candidate.nativePureKernelCandidateOutput
        , let endpoint = EndpointRef candidate.nativePureKernelCandidateRef (Just boundary.nativePureBoundaryLabel)
        , not (any ((== endpoint) . (.connectionFrom)) internalConnections)
        ]
      inputEndpoints = List.sort (Set.toList (Set.fromList (crossingInputs <> entryInputs)))
      outputEndpoints = List.sort (Set.toList (Set.fromList (crossingOutputs <> exitOutputs)))
  inputBoundaries <- traverse (typedBoundary candidateMap) inputEndpoints
  regionOutputs <-
    concat
      <$> traverse
        (candidateRegionOutputs candidateMap (Set.fromList outputEndpoints))
        candidates
  ssa <- traverse (buildSsaStep regionRef candidateMap internalConnections inputEndpoints) members
  targetSteps <- nativePureRegionTargetSteps regionRef ssa regionOutputs
  (realizedOutputBytes, realizedCheckpointBytes) <-
    nativePureRegionFrameBounds regionRef inputBoundaries regionOutputs
  let realizedBounds =
        bounds
          { nativePureBoundOutputBytes =
              max bounds.nativePureBoundOutputBytes realizedOutputBytes
          , nativePureBoundCheckpointBytes =
              max bounds.nativePureBoundCheckpointBytes realizedCheckpointBytes
          , nativePureBoundSteps = max bounds.nativePureBoundSteps targetSteps
          }
  when (realizedBounds.nativePureBoundCheckpointBytes > hostedCheckpointCeiling) $
    Left
      ( NativePureArtifactCheckpointTooLarge
          regionRef
          realizedBounds.nativePureBoundCheckpointBytes
      )
  let region =
        NativePureFusedRegion
          { nativePureFusedRegionRef = regionRef
          , nativePureFusedRegionSources = members
          , nativePureFusedRegionInputs = inputBoundaries
          , nativePureFusedRegionOutputs = regionOutputs
          , nativePureFusedRegionInternalEdges =
              [ NativePureRegionEdge connection.connectionFrom connection.connectionTo
              | connection <- List.sort internalConnections
              ]
          , nativePureFusedRegionSsa = ssa
          , nativePureFusedRegionBounds = realizedBounds
          }
  validateSsa region
  let induced = inducedSubgraph memberSet sourceRelation
  when (isNothing (topSort induced)) (Left NativePureArtifactSourceCycle)
  pure region
  where
    regionRef = "native-pure/" <> T.justifyRight 4 '0' (T.pack (show index))
    requireCandidate source =
      maybe
        (Left (NativePureArtifactMissingSourceProvenance source))
        Right
        (Map.lookup source candidateMap)

{- | Exact worst-case cost of the intrinsically typed target term constructed
from a fused region's ANF. Fusion introduces explicit lets and output-record
construction that do not exist in the authored CorePure expression, so the
realization artifact owns this post-elaboration bound rather than allowing
the downstream Lean renderer to silently raise it.
-}
nativePureRegionTargetSteps
  :: Text
  -> [NativePureSsaStep]
  -> [NativePureRegionOutput]
  -> Either NativePureArtifactError Word64
nativePureRegionTargetSteps regionRef ssa outputs = do
  perBinding <- traverse bindingTargetSteps (concatMap stepBindings ssa)
  bindingSteps <- sumChecked perBinding
  addChecked bindingSteps outputSteps
  where
    outputSteps
      | length outputs <= 1 = 1
      | otherwise = 1 + fromIntegral (length outputs)

    stepBindings step =
      step.nativePureSsaStepPrelude
        <> concatMap equationBindings step.nativePureSsaStepEquations

    equationBindings equation =
      equation.nativePureSsaEquationAnf.nativePureAnfBlockBindings
        <> [ NativePureAnfBinding
               equation.nativePureSsaEquationValue
               equation.nativePureSsaEquationShape
               (NativePureAnfAlias equation.nativePureSsaEquationAnf.nativePureAnfBlockResult)
           | equation.nativePureSsaEquationAnf.nativePureAnfBlockResult
               /= equation.nativePureSsaEquationValue
           ]

    bindingTargetSteps binding = do
      operation <- operationTargetSteps binding.nativePureAnfBindingOp
      addChecked 1 operation

    operationTargetSteps = \case
      NativePureAnfLiteral {} -> pure 1
      NativePureAnfAlias {} -> pure 1
      NativePureAnfRecord fields -> addChecked 1 (fromIntegral (Map.size fields))
      NativePureAnfProject {} -> pure 2
      NativePureAnfNot {} -> pure 2
      NativePureAnfBinary {} -> pure 3
      NativePureAnfIf _ thenBlock elseBlock -> do
        thenSteps <- blockTargetSteps thenBlock
        elseSteps <- blockTargetSteps elseBlock
        addChecked 2 (max thenSteps elseSteps)
      NativePureAnfInject {} -> pure 2

    blockTargetSteps block = do
      perBinding <- traverse bindingTargetSteps block.nativePureAnfBlockBindings
      bindings <- sumChecked perBinding
      addChecked bindings 1

    sumChecked = foldM addChecked 0
    addChecked left right =
      maybe
        (Left (NativePureArtifactBoundsOverflow regionRef))
        Right
        (checkedAdd left right)

nativePureRegionFrameBounds
  :: Text
  -> [NativePureRegionBoundary]
  -> [NativePureRegionOutput]
  -> Either NativePureArtifactError (Word64, Word64)
nativePureRegionFrameBounds regionRef inputs outputs = do
  outputLayout <- layoutFor (outputShape outputs)
  if null inputs
    then pure (outputLayout.nativeLayoutSize, outputLayout.nativeLayoutSize)
    else do
      inputLayout <-
        layoutFor (NativeRecord (indexedShapes (fmap (.nativePureRegionBoundaryShape) inputs)))
      outputOffset <- alignChecked inputLayout.nativeLayoutSize outputLayout.nativeLayoutAlignment
      unaligned <-
        maybe
          (Left (NativePureArtifactBoundsOverflow regionRef))
          Right
          (checkedAdd outputOffset outputLayout.nativeLayoutSize)
      checkpoint <-
        alignChecked unaligned (max inputLayout.nativeLayoutAlignment outputLayout.nativeLayoutAlignment)
      pure (outputLayout.nativeLayoutSize, checkpoint)
  where
    layoutFor shape =
      either
        (Left . NativePureArtifactInvalidBoundary . renderNativeShapeError)
        Right
        (nativeShapeLayout shape)

    outputShape = \case
      [] -> NativeUnit
      [output] -> outputRegionShape output
      regionOutputs -> NativeRecord (indexedShapes (fmap outputRegionShape regionOutputs))

    outputRegionShape = \case
      NativePureRegionProductField boundary -> boundary.nativePureRegionBoundaryShape
      NativePureRegionExclusiveSum boundary -> boundary.nativePureRegionSumShape

    indexedShapes shapes =
      Map.fromList
        [ ("field_" <> T.justifyRight 4 '0' (T.pack (show fieldIndex)), shape)
        | (fieldIndex, shape) <- zip [0 :: Int ..] shapes
        ]

    alignChecked value alignment = do
      let remainder = value `mod` alignment
          padding = if remainder == 0 then 0 else alignment - remainder
      maybe
        (Left (NativePureArtifactBoundsOverflow regionRef))
        Right
        (checkedAdd value padding)

candidateRegionOutputs
  :: Map CircuitNodeRef NativePureKernelCandidate
  -> Set EndpointRef
  -> NativePureKernelCandidate
  -> Either NativePureArtifactError [NativePureRegionOutput]
candidateRegionOutputs candidateMap exits candidate =
  case candidate.nativePureKernelCandidateOutput of
    NativePureProduct fields ->
      traverse
        (fmap NativePureRegionProductField . typedBoundary candidateMap)
        [ endpoint
        | field <- fields
        , let endpoint = fieldEndpoint field
        , Set.member endpoint exits
        ]
    NativePureSum group variants -> do
      let variantEndpoints = fmap fieldEndpoint variants
          exitingVariants = filter (`Set.member` exits) variantEndpoints
      if null exitingVariants
        then pure []
        else do
          unless (length exitingVariants == length variantEndpoints) $
            Left (NativePureArtifactInvalidBoundary "exclusive sum variants must cross a region together")
          boundaries <- traverse (typedBoundary candidateMap) variantEndpoints
          let shape =
                NativeSum
                  ( Map.fromList
                      [ (boundary.nativePureBoundaryLabel, boundary.nativePureBoundaryShape)
                      | boundary <- variants
                      ]
                  )
          layout <-
            case nativeShapeLayout shape of
              Left shapeError -> Left (NativePureArtifactInvalidBoundary (renderNativeShapeError shapeError))
              Right nativeLayout -> pure nativeLayout
          pure
            [ NativePureRegionExclusiveSum
                NativePureRegionSumBoundary
                  { nativePureRegionSumSource = candidate.nativePureKernelCandidateRef
                  , nativePureRegionSumGroup = group
                  , nativePureRegionSumVariants = boundaries
                  , nativePureRegionSumShape = shape
                  , nativePureRegionSumLayout = layout
                  }
            ]
  where
    fieldEndpoint boundary =
      EndpointRef candidate.nativePureKernelCandidateRef (Just boundary.nativePureBoundaryLabel)

buildSsaStep
  :: Text
  -> Map CircuitNodeRef NativePureKernelCandidate
  -> [Connection]
  -> [EndpointRef]
  -> CircuitNodeRef
  -> Either NativePureArtifactError NativePureSsaStep
buildSsaStep regionRef candidateMap internalConnections regionInputEndpoints source = do
  candidate <-
    maybe
      (Left (NativePureArtifactMissingSourceProvenance source))
      Right
      (Map.lookup source candidateMap)
  inputs <- traverse inputValue candidate.nativePureKernelCandidateInputs
  (prelude, bodyScope, firstCounter) <- lowerCandidatePrelude source inputs candidate
  (equations, _nextCounter) <-
    case candidate.nativePureKernelCandidateVariant of
      Nothing ->
        foldM
          ( \(built, counter) (label, expr) -> do
              boundary <- typedBoundary candidateMap (EndpointRef source (Just label))
              (anfBlock, nextCounter) <-
                lowerNativePureAnf
                  source
                  bodyScope
                  counter
                  expr
                  boundary.nativePureRegionBoundaryShape
              pure
                ( built
                    <> [ NativePureSsaEquation
                           { nativePureSsaEquationValue = outputValueRef source label
                           , nativePureSsaEquationLabel = label
                           , nativePureSsaEquationContract = boundary.nativePureRegionBoundaryContract
                           , nativePureSsaEquationShape = boundary.nativePureRegionBoundaryShape
                           , nativePureSsaEquationExpr = expr
                           , nativePureSsaEquationAnf = anfBlock
                           }
                       ]
                , nextCounter
                )
          )
          ([], firstCounter)
          (Map.toAscList candidate.nativePureKernelCandidateOutputs)
      Just variant -> do
        let variants = outputBoundaries candidate.nativePureKernelCandidateOutput
            variantShape =
              NativeSum
                ( Map.fromList
                    [(boundary.nativePureBoundaryLabel, boundary.nativePureBoundaryShape) | boundary <- variants]
                )
        (anfBlock, nextCounter) <-
          lowerNativePureAnf
            source
            bodyScope
            firstCounter
            variant.nativePureVariantCandidateExpression
            variantShape
        pure
          (
            [ NativePureSsaEquation
                { nativePureSsaEquationValue = outputValueRef source "__variant"
                , nativePureSsaEquationLabel = "__variant"
                , nativePureSsaEquationContract = "cortex.wire.exclusive-sum"
                , nativePureSsaEquationShape = variantShape
                , nativePureSsaEquationExpr = variant.nativePureVariantCandidateExpression
                , nativePureSsaEquationAnf = anfBlock
                }
            ]
          , nextCounter
          )
  pure
    NativePureSsaStep
      { nativePureSsaStepSource = source
      , nativePureSsaStepInputs = inputs
      , nativePureSsaStepPrelude = prelude
      , nativePureSsaStepEquations = equations
      , nativePureSsaStepVariant = candidate.nativePureKernelCandidateVariant
      }
  where
    inputValue boundary = do
      let endpoint = EndpointRef source (Just boundary.nativePureBoundaryLabel)
          internalSource =
            List.find ((== endpoint) . (.connectionTo)) internalConnections
      valueRef <-
        case internalSource of
          Just connection -> do
            sourcePort <- requirePort connection.connectionFrom
            sourceCandidate <-
              maybe
                (Left (NativePureArtifactMissingBoundary connection.connectionFrom))
                Right
                (Map.lookup connection.connectionFrom.endpointNodeRef candidateMap)
            pure $
              case sourceCandidate.nativePureKernelCandidateVariant of
                Nothing -> outputValueRef connection.connectionFrom.endpointNodeRef sourcePort
                Just _ -> outputValueRef connection.connectionFrom.endpointNodeRef "__variant"
          Nothing ->
            if endpoint `elem` regionInputEndpoints
              then pure (boundaryValueRef regionRef endpoint)
              else Left (NativePureArtifactMissingBoundary endpoint)
      pure
        NativePureSsaInput
          { nativePureSsaInputLabel = boundary.nativePureBoundaryLabel
          , nativePureSsaInputValue = valueRef
          , nativePureSsaInputContract = boundary.nativePureBoundaryContract
          , nativePureSsaInputShape = boundary.nativePureBoundaryShape
          }

type NativePureAnfScope = Map Text (NativePureSsaValueRef, NativeShape)

lowerCandidatePrelude
  :: CircuitNodeRef
  -> [NativePureSsaInput]
  -> NativePureKernelCandidate
  -> Either NativePureArtifactError ([NativePureAnfBinding], NativePureAnfScope, Int)
lowerCandidatePrelude source inputs candidate = do
  (bindingPrelude, bindingScope, nextCounter) <-
    foldM lowerBinding ([], inputScope, 0) candidate.nativePureKernelCandidateBindings
  case candidate.nativePureKernelCandidateWhere of
    Nothing -> pure (bindingPrelude, bindingScope, nextCounter)
    Just whereExpr -> do
      whereShape <- inferNativePureAnfShape source bindingScope whereExpr
      fields <-
        case whereShape of
          NativeRecord recordFields -> pure recordFields
          _ -> Left (NativePureArtifactInvalidBoundary "NativePure where expression must be a record")
      (whereBlock, afterWhere) <-
        lowerNativePureAnf source bindingScope nextCounter whereExpr whereShape
      (projectionBindings, bodyScope, finalCounter) <-
        foldM
          (lowerWhereField whereBlock.nativePureAnfBlockResult)
          ([], bindingScope, afterWhere)
          (Map.toAscList fields)
      pure
        ( bindingPrelude <> whereBlock.nativePureAnfBlockBindings <> projectionBindings
        , bodyScope
        , finalCounter
        )
  where
    inputScope =
      Map.fromList
        [ (input.nativePureSsaInputLabel, (input.nativePureSsaInputValue, input.nativePureSsaInputShape))
        | input <- inputs
        ]
    lowerBinding (built, scope, counter) binding = do
      shape <- inferNativePureAnfShape source scope binding.corePureBindingExpr
      (block, nextCounter) <-
        lowerNativePureAnf source scope counter binding.corePureBindingExpr shape
      pure
        ( built <> block.nativePureAnfBlockBindings
        , Map.insert binding.corePureBindingName (block.nativePureAnfBlockResult, shape) scope
        , nextCounter
        )
    lowerWhereField recordValue (built, scope, counter) (fieldName, fieldShape) = do
      let (fieldValue, nextCounter) = freshAnfValue source counter
          fieldBinding =
            NativePureAnfBinding
              { nativePureAnfBindingValue = fieldValue
              , nativePureAnfBindingShape = fieldShape
              , nativePureAnfBindingOp = NativePureAnfProject recordValue fieldName
              }
      pure
        ( built <> [fieldBinding]
        , Map.insert fieldName (fieldValue, fieldShape) scope
        , nextCounter
        )

lowerNativePureAnf
  :: CircuitNodeRef
  -> NativePureAnfScope
  -> Int
  -> CorePureExpr
  -> NativeShape
  -> Either NativePureArtifactError (NativePureAnfBlock, Int)
lowerNativePureAnf source = lower
  where
    lower currentScope counter expr expected =
      case expr of
        CorePureLit literal -> bind counter expected (NativePureAnfLiteral literal) []
        CorePureIdent name -> do
          (valueRef, actualShape) <- requireScope currentScope name
          requireAnfShape actualShape expected
          pure (NativePureAnfBlock [] valueRef, counter)
        CorePureRecord fields -> do
          expectedFields <-
            case expected of
              NativeRecord recordFields -> pure recordFields
              _ -> invalid "record expression has a non-record expected shape"
          flatFields <- traverse flatField fields
          unless (Set.fromList (fmap fst flatFields) == Map.keysSet expectedFields) $
            invalid "record expression fields do not match its native shape"
          (built, values, nextCounter) <-
            foldM
              (lowerRecordField currentScope expectedFields)
              ([], Map.empty, counter)
              flatFields
          bind nextCounter expected (NativePureAnfRecord values) built
        CorePureFieldAccess baseExpr fieldName -> do
          baseShape <- inferNativePureAnfShape source currentScope baseExpr
          fieldShape <-
            case baseShape of
              NativeRecord fields ->
                maybe (invalid ("unknown record field " <> fieldName)) pure (Map.lookup fieldName fields)
              _ -> invalid "record projection applied to a non-record value"
          requireAnfShape fieldShape expected
          (baseBlock, nextCounter) <- lower currentScope counter baseExpr baseShape
          bind
            nextCounter
            expected
            (NativePureAnfProject baseBlock.nativePureAnfBlockResult fieldName)
            baseBlock.nativePureAnfBlockBindings
        CorePureIf condition thenExpr elseExpr -> do
          (conditionBlock, afterCondition) <- lower currentScope counter condition NativeBool
          (thenBlock, afterThen) <- lower currentScope afterCondition thenExpr expected
          (elseBlock, afterElse) <- lower currentScope afterThen elseExpr expected
          bind
            afterElse
            expected
            (NativePureAnfIf conditionBlock.nativePureAnfBlockResult thenBlock elseBlock)
            conditionBlock.nativePureAnfBlockBindings
        CorePureLet bindings body -> do
          (letBindings, letScope, afterBindings) <-
            foldM
              lowerLetBinding
              ([], currentScope, counter)
              (NE.toList bindings)
          (bodyBlock, afterBody) <- lower letScope afterBindings body expected
          pure
            ( bodyBlock {nativePureAnfBlockBindings = letBindings <> bodyBlock.nativePureAnfBlockBindings}
            , afterBody
            )
        CorePureUnary CorePureNot value -> do
          requireAnfShape NativeBool expected
          (valueBlock, nextCounter) <- lower currentScope counter value NativeBool
          bind
            nextCounter
            NativeBool
            (NativePureAnfNot valueBlock.nativePureAnfBlockResult)
            valueBlock.nativePureAnfBlockBindings
        CorePureUnary CorePureNegate _ -> invalid "negate is outside the NativePure ANF basis"
        CorePureBinary binaryOp left right -> do
          (operandShape, resultShape) <- binaryShapes binaryOp
          requireAnfShape resultShape expected
          (leftBlock, afterLeft) <- lower currentScope counter left operandShape
          (rightBlock, afterRight) <- lower currentScope afterLeft right operandShape
          bind
            afterRight
            resultShape
            (NativePureAnfBinary binaryOp leftBlock.nativePureAnfBlockResult rightBlock.nativePureAnfBlockResult)
            (leftBlock.nativePureAnfBlockBindings <> rightBlock.nativePureAnfBlockBindings)
        CorePureCall (CorePureIdent label) [payload] ->
          case expected of
            NativeSum variants -> do
              payloadShape <-
                maybe (invalid ("unknown NativePure sum constructor " <> label)) pure (Map.lookup label variants)
              (payloadBlock, nextCounter) <- lower currentScope counter payload payloadShape
              bind
                nextCounter
                expected
                (NativePureAnfInject label payloadBlock.nativePureAnfBlockResult)
                payloadBlock.nativePureAnfBlockBindings
            _ -> invalid "constructor expression has a non-sum expected shape"
        CorePureList _ -> invalid "list expression is outside the NativePure ANF basis"
        CorePureIndex _ _ -> invalid "index expression is outside the NativePure ANF basis"
        CorePureLambda _ _ -> invalid "lambda expression is outside the NativePure ANF basis"
        CorePureCall _ _ -> invalid "call expression is outside the NativePure ANF basis"
      where
        lowerLetBinding (built, letScope, nextCounter) binding = do
          shape <- inferNativePureAnfShape source letScope binding.corePureBindingExpr
          (block, afterBinding) <-
            lower letScope nextCounter binding.corePureBindingExpr shape
          pure
            ( built <> block.nativePureAnfBlockBindings
            , Map.insert binding.corePureBindingName (block.nativePureAnfBlockResult, shape) letScope
            , afterBinding
            )

    lowerRecordField currentScope expectedFields (built, values, counter) (fieldName, fieldExpr) = do
      fieldShape <-
        maybe (invalid ("unknown record field " <> fieldName)) pure (Map.lookup fieldName expectedFields)
      (fieldBlock, nextCounter) <- lower currentScope counter fieldExpr fieldShape
      pure
        ( built <> fieldBlock.nativePureAnfBlockBindings
        , Map.insert fieldName fieldBlock.nativePureAnfBlockResult values
        , nextCounter
        )

    bind counter shape operation preceding =
      let (valueRef, nextCounter) = freshAnfValue source counter
       in pure
            ( NativePureAnfBlock
                ( preceding
                    <> [ NativePureAnfBinding
                           { nativePureAnfBindingValue = valueRef
                           , nativePureAnfBindingShape = shape
                           , nativePureAnfBindingOp = operation
                           }
                       ]
                )
                valueRef
            , nextCounter
            )

    requireScope currentScope name =
      maybe
        (invalid ("identifier " <> name <> " is absent from NativePure ANF scope"))
        pure
        (Map.lookup name currentScope)
    invalid = Left . NativePureArtifactInvalidBoundary

inferNativePureAnfShape
  :: CircuitNodeRef
  -> NativePureAnfScope
  -> CorePureExpr
  -> Either NativePureArtifactError NativeShape
inferNativePureAnfShape source = infer
  where
    infer scope = \case
      CorePureLit literal -> inferLiteral literal
      CorePureIdent name ->
        maybe
          (invalid ("identifier " <> name <> " is absent from NativePure ANF scope"))
          (pure . snd)
          (Map.lookup name scope)
      CorePureRecord fields -> do
        flatFields <- traverse flatField fields
        when (null flatFields) (invalid "empty records are outside the NativePure ANF basis")
        NativeRecord . Map.fromList
          <$> traverse (\(fieldName, fieldExpr) -> (fieldName,) <$> infer scope fieldExpr) flatFields
      CorePureFieldAccess baseExpr fieldName -> do
        baseShape <- infer scope baseExpr
        case baseShape of
          NativeRecord fields ->
            maybe (invalid ("unknown record field " <> fieldName)) pure (Map.lookup fieldName fields)
          _ -> invalid "record projection applied to a non-record value"
      CorePureIf condition thenExpr elseExpr -> do
        conditionShape <- infer scope condition
        requireAnfShape conditionShape NativeBool
        thenShape <- infer scope thenExpr
        elseShape <- infer scope elseExpr
        requireAnfShape elseShape thenShape
        pure thenShape
      CorePureLet bindings body -> do
        innerScope <-
          foldM
            ( \built binding -> do
                shape <- infer built binding.corePureBindingExpr
                let placeholder = NativePureSsaValueRef (source.unCircuitNodeRef <> ".scope." <> binding.corePureBindingName)
                pure (Map.insert binding.corePureBindingName (placeholder, shape) built)
            )
            scope
            (NE.toList bindings)
        infer innerScope body
      CorePureUnary CorePureNot value -> inferOperand scope value NativeBool $> NativeBool
      CorePureUnary CorePureNegate _ -> invalid "negate is outside the NativePure ANF basis"
      CorePureBinary binaryOp left right -> do
        (operandShape, resultShape) <- binaryShapes binaryOp
        _ <- inferOperand scope left operandShape
        _ <- inferOperand scope right operandShape
        pure resultShape
      CorePureList _ -> invalid "list expression is outside the NativePure ANF basis"
      CorePureIndex _ _ -> invalid "index expression is outside the NativePure ANF basis"
      CorePureLambda _ _ -> invalid "lambda expression is outside the NativePure ANF basis"
      CorePureCall _ _ -> invalid "call expression cannot synthesize a NativePure ANF shape"
    inferOperand scope expr expected = do
      actual <- infer scope expr
      requireAnfShape actual expected
      pure actual
    inferLiteral = \case
      CorePureBool _ -> pure NativeBool
      CorePureNull -> pure NativeUnit
      CorePureString text -> pure (NativeText (max 1 (fromIntegral (BS.length (TE.encodeUtf8 text)))))
      CorePureNumber number ->
        case floatingOrInteger number :: Either Double Integer of
          Right integer
            | integer >= -(2 ^ (63 :: Integer)) && integer < 2 ^ (63 :: Integer) -> pure NativeI64
            | otherwise -> invalid "integer literal exceeds the NativePure i64 range"
          Left _ -> pure NativeF64
    invalid = Left . NativePureArtifactInvalidBoundary

flatField :: CorePureField -> Either NativePureArtifactError (Text, CorePureExpr)
flatField field =
  case field.corePureFieldPath of
    fieldName NE.:| [] -> pure (fieldName, field.corePureFieldValue)
    fieldPath ->
      Left
        ( NativePureArtifactInvalidBoundary
            ("dotted record field " <> T.intercalate "." (NE.toList fieldPath) <> " is outside NativePure ANF")
        )

binaryShapes :: CorePureBinOp -> Either NativePureArtifactError (NativeShape, NativeShape)
binaryShapes = \case
  CorePureAdd -> pure (NativeI64, NativeI64)
  CorePureSubtract -> pure (NativeI64, NativeI64)
  CorePureMultiply -> pure (NativeI64, NativeI64)
  CorePureEqual -> pure (NativeI64, NativeBool)
  CorePureLessThan -> pure (NativeI64, NativeBool)
  CorePureAnd -> pure (NativeBool, NativeBool)
  CorePureOr -> pure (NativeBool, NativeBool)
  unsupported ->
    Left
      ( NativePureArtifactInvalidBoundary
          ("operator " <> T.pack (show unsupported) <> " is outside NativePure ANF")
      )

requireAnfShape :: NativeShape -> NativeShape -> Either NativePureArtifactError ()
requireAnfShape actual expected =
  unless (shapeFits actual expected) $
    Left (NativePureArtifactInvalidBoundary "NativePure ANF operand shape does not fit its typed use")
  where
    shapeFits (NativeText actualCapacity) (NativeText expectedCapacity) = actualCapacity <= expectedCapacity
    shapeFits (NativeRecord actualFields) (NativeRecord expectedFields) =
      Map.keysSet actualFields == Map.keysSet expectedFields
        && and (Map.intersectionWith shapeFits actualFields expectedFields)
    shapeFits (NativeSum actualVariants) (NativeSum expectedVariants) =
      Map.keysSet actualVariants == Map.keysSet expectedVariants
        && and (Map.intersectionWith shapeFits actualVariants expectedVariants)
    shapeFits (NativeVector actualCapacity actualElement) (NativeVector expectedCapacity expectedElement) =
      actualCapacity == expectedCapacity && shapeFits actualElement expectedElement
    shapeFits actualShape expectedShape = actualShape == expectedShape

freshAnfValue :: CircuitNodeRef -> Int -> (NativePureSsaValueRef, Int)
freshAnfValue source counter =
  ( NativePureSsaValueRef
      (source.unCircuitNodeRef <> ".anf." <> T.justifyRight 6 '0' (T.pack (show counter)))
  , counter + 1
  )

buildRealizationArtifact
  :: NativePureNormalizedInput
  -> Relation CircuitNodeRef
  -> [NativePureFusedRegion]
  -> Either NativePureArtifactError RealizationArtifact
buildRealizationArtifact normalized sourceRelation regions = do
  let pureMappings =
        [ (source, region.nativePureFusedRegionRef)
        | region <- regions
        , source <- region.nativePureFusedRegionSources
        ]
      pureSources = Set.fromList (fmap fst pureMappings)
      preservedMappings =
        [ (source, "source/" <> source.unCircuitNodeRef)
        | source <- normalized.nativePureNormalizedSourceNodes
        , not (Set.member source pureSources)
        ]
      sourceToRuntime = Map.fromList (pureMappings <> preservedMappings)
      pureUnits =
        [ ( region.nativePureFusedRegionRef
          , RealizationRuntimeUnit
              region.nativePureFusedRegionRef
              RealizationPureRegion
              region.nativePureFusedRegionSources
          )
        | region <- regions
        ]
      preservedUnits =
        [ (runtimeRef, RealizationRuntimeUnit runtimeRef RealizationPreservedNode [source])
        | (source, runtimeRef) <- preservedMappings
        ]
      runtimeUnits = Map.fromList (pureUnits <> preservedUnits)
      runtimeEdges =
        Set.fromList
          [ (fromRuntime, toRuntime)
          | (fromSource, toSource) <- Set.toAscList sourceRelation.relEdges
          , let fromRuntime = sourceToRuntime Map.! fromSource
          , let toRuntime = sourceToRuntime Map.! toSource
          , fromRuntime /= toRuntime
          ]
      artifactWithoutDigest =
        RealizationArtifact
          { realizationArtifactReferentIdentity = normalized.nativePureNormalizedReferentIdentity
          , realizationArtifactInputDigest = normalized.nativePureNormalizedDigest
          , realizationArtifactSourceToRuntime = sourceToRuntime
          , realizationArtifactRuntimeUnits = runtimeUnits
          , realizationArtifactRuntimeEdges = runtimeEdges
          , realizationArtifactDigest = ""
          }
      artifact =
        artifactWithoutDigest
          { realizationArtifactDigest = canonicalDigest (realizationArtifactValue artifactWithoutDigest)
          }
  validateRealizationArtifact normalized artifact
  pure artifact

typedBoundary
  :: Map CircuitNodeRef NativePureKernelCandidate
  -> EndpointRef
  -> Either NativePureArtifactError NativePureRegionBoundary
typedBoundary candidates endpoint = do
  portName <- requirePort endpoint
  candidate <-
    maybe
      (Left (NativePureArtifactMissingBoundary endpoint))
      Right
      (Map.lookup endpoint.endpointNodeRef candidates)
  boundary <-
    maybe
      (Left (NativePureArtifactMissingBoundary endpoint))
      Right
      ( List.find ((== portName) . (.nativePureBoundaryLabel)) $
          candidate.nativePureKernelCandidateInputs
            <> outputBoundaries candidate.nativePureKernelCandidateOutput
      )
  pure
    NativePureRegionBoundary
      { nativePureRegionBoundaryEndpoint = endpoint
      , nativePureRegionBoundaryContract = boundary.nativePureBoundaryContract
      , nativePureRegionBoundaryShape = boundary.nativePureBoundaryShape
      , nativePureRegionBoundaryLayout = boundary.nativePureBoundaryLayout
      }

outputBoundaries :: NativePureOutputBoundary -> [NativePureBoundary]
outputBoundaries = \case
  NativePureProduct boundaries -> boundaries
  NativePureSum _ boundaries -> boundaries

requirePort :: EndpointRef -> Either NativePureArtifactError Text
requirePort endpoint = maybe (Left (NativePureArtifactMissingPort endpoint)) Right endpoint.endpointPortName

sumBounds :: Text -> [NativePureBounds] -> Either NativePureArtifactError NativePureBounds
sumBounds regionRef = foldM addBounds (NativePureBounds 0 0 0 0 0)
  where
    addBounds left right =
      NativePureBounds
        <$> add left.nativePureBoundStackBytes right.nativePureBoundStackBytes
        <*> add left.nativePureBoundStaticBytes right.nativePureBoundStaticBytes
        <*> add left.nativePureBoundOutputBytes right.nativePureBoundOutputBytes
        <*> add left.nativePureBoundCheckpointBytes right.nativePureBoundCheckpointBytes
        <*> add left.nativePureBoundSteps right.nativePureBoundSteps
    add left right = maybe (Left (NativePureArtifactBoundsOverflow regionRef)) Right (checkedAdd left right)

checkedAdd :: Word64 -> Word64 -> Maybe Word64
checkedAdd left right
  | maxBound - left < right = Nothing
  | otherwise = Just (left + right)

hostedCheckpointCeiling :: Word64
hostedCheckpointCeiling = 2 * 1024 * 1024

boundaryValueRef :: Text -> EndpointRef -> NativePureSsaValueRef
boundaryValueRef regionRef endpoint =
  NativePureSsaValueRef
    ( regionRef
        <> ".input."
        <> endpoint.endpointNodeRef.unCircuitNodeRef
        <> "."
        <> fromMaybe "_" endpoint.endpointPortName
    )

outputValueRef :: CircuitNodeRef -> Text -> NativePureSsaValueRef
outputValueRef source label = NativePureSsaValueRef (source.unCircuitNodeRef <> ".output." <> label)

firstAdmission
  :: Either NativePureAdmissionError value -> Either NativePureArtifactError value
firstAdmission = either (Left . NativePureArtifactAdmission) Right

canonicalDigest :: Value -> Text
canonicalDigest value = T.pack (show (hashlazy @SHA256 (Aeson.encode value) :: Digest SHA256))

normalizedInputValue :: NativePureNormalizedInput -> Value
normalizedInputValue normalized =
  object
    [ "schema" .= nativePureNormalizedInputSchema
    , "program_id" .= normalized.nativePureNormalizedProgramId
    , "referent_identity" .= normalized.nativePureNormalizedReferentIdentity
    , "source_nodes" .= fmap (.unCircuitNodeRef) normalized.nativePureNormalizedSourceNodes
    , "source_edges"
        .= [ object ["from" .= from.unCircuitNodeRef, "to" .= to.unCircuitNodeRef]
           | (from, to) <- normalized.nativePureNormalizedSourceEdges
           ]
    , "candidates" .= fmap candidateValue normalized.nativePureNormalizedCandidates
    , "connections" .= normalized.nativePureNormalizedConnections
    ]

realizationArtifactValue :: RealizationArtifact -> Value
realizationArtifactValue artifact =
  object
    [ "schema" .= realizationArtifactSchema
    , "referent_identity" .= artifact.realizationArtifactReferentIdentity
    , "input_digest" .= artifact.realizationArtifactInputDigest
    , "source_to_runtime"
        .= [ object ["source" .= source.unCircuitNodeRef, "runtime" .= runtimeRef]
           | (source, runtimeRef) <- Map.toAscList artifact.realizationArtifactSourceToRuntime
           ]
    , "runtime_units" .= Map.elems artifact.realizationArtifactRuntimeUnits
    , "runtime_edges"
        .= [ object ["from" .= from, "to" .= to]
           | (from, to) <- Set.toAscList artifact.realizationArtifactRuntimeEdges
           ]
    ]

nativePurePlanValue :: NativePurePlan -> Value
nativePurePlanValue plan =
  object
    [ "schema" .= nativePurePlanSchema
    , "program_id" .= plan.nativePurePlanProgramId
    , "program_identity" .= plan.nativePurePlanProgramIdentity
    , "input_digest" .= plan.nativePurePlanInputDigest
    , "fusion_mode" .= plan.nativePurePlanFusionMode
    , "realization" .= plan.nativePurePlanRealization
    , "regions" .= plan.nativePurePlanRegions
    ]

instance ToJSON NativePureNormalizedInput where
  toJSON normalized =
    case normalizedInputValue normalized of
      Aeson.Object fields ->
        Aeson.Object (KeyMap.insert "digest" (Aeson.String normalized.nativePureNormalizedDigest) fields)
      value -> value

instance ToJSON NativePureSsaValueRef where
  toJSON = Aeson.String . unNativePureSsaValueRef

instance ToJSON NativePureSsaInput where
  toJSON input =
    object
      [ "label" .= input.nativePureSsaInputLabel
      , "value" .= input.nativePureSsaInputValue
      , "contract" .= input.nativePureSsaInputContract
      , "shape" .= input.nativePureSsaInputShape
      ]

instance ToJSON NativePureAnfBlock where
  toJSON block =
    object
      [ "bindings" .= block.nativePureAnfBlockBindings
      , "result" .= block.nativePureAnfBlockResult
      ]

instance ToJSON NativePureAnfBinding where
  toJSON binding =
    object
      [ "value" .= binding.nativePureAnfBindingValue
      , "shape" .= binding.nativePureAnfBindingShape
      , "op" .= binding.nativePureAnfBindingOp
      ]

instance ToJSON NativePureAnfOp where
  toJSON = \case
    NativePureAnfLiteral literal -> object ["kind" .= ("literal" :: Text), "literal" .= literal]
    NativePureAnfAlias valueRef -> object ["kind" .= ("alias" :: Text), "value" .= valueRef]
    NativePureAnfRecord fields -> object ["kind" .= ("record" :: Text), "fields" .= fields]
    NativePureAnfProject valueRef fieldName ->
      object ["kind" .= ("project" :: Text), "value" .= valueRef, "field" .= fieldName]
    NativePureAnfNot valueRef -> object ["kind" .= ("not" :: Text), "value" .= valueRef]
    NativePureAnfBinary binaryOp left right ->
      object
        [ "kind" .= ("binary" :: Text)
        , "operator" .= binaryOp
        , "left" .= left
        , "right" .= right
        ]
    NativePureAnfIf condition thenBlock elseBlock ->
      object
        [ "kind" .= ("if" :: Text)
        , "condition" .= condition
        , "then" .= thenBlock
        , "else" .= elseBlock
        ]
    NativePureAnfInject label payload ->
      object ["kind" .= ("inject" :: Text), "label" .= label, "payload" .= payload]

instance ToJSON NativePureSsaEquation where
  toJSON equation =
    object
      [ "value" .= equation.nativePureSsaEquationValue
      , "label" .= equation.nativePureSsaEquationLabel
      , "contract" .= equation.nativePureSsaEquationContract
      , "shape" .= equation.nativePureSsaEquationShape
      , "expression" .= equation.nativePureSsaEquationExpr
      , "anf" .= equation.nativePureSsaEquationAnf
      ]

instance ToJSON NativePureSsaStep where
  toJSON step =
    object
      [ "source" .= step.nativePureSsaStepSource.unCircuitNodeRef
      , "inputs" .= step.nativePureSsaStepInputs
      , "prelude" .= step.nativePureSsaStepPrelude
      , "equations" .= step.nativePureSsaStepEquations
      , "variant" .= fmap variantValue step.nativePureSsaStepVariant
      ]

instance ToJSON NativePureRegionBoundary where
  toJSON boundary =
    object
      [ "endpoint" .= boundary.nativePureRegionBoundaryEndpoint
      , "contract" .= boundary.nativePureRegionBoundaryContract
      , "shape" .= boundary.nativePureRegionBoundaryShape
      , "layout" .= layoutValue boundary.nativePureRegionBoundaryLayout
      ]

instance ToJSON NativePureRegionEdge where
  toJSON edgeValue = object ["from" .= edgeValue.nativePureRegionEdgeFrom, "to" .= edgeValue.nativePureRegionEdgeTo]

instance ToJSON NativePureRegionOutput where
  toJSON = \case
    NativePureRegionProductField boundary ->
      object
        [ "kind" .= ("product_field" :: Text)
        , "boundary" .= boundary
        ]
    NativePureRegionExclusiveSum sumBoundary ->
      object
        [ "kind" .= ("exclusive_sum" :: Text)
        , "source" .= sumBoundary.nativePureRegionSumSource.unCircuitNodeRef
        , "group" .= sumBoundary.nativePureRegionSumGroup
        , "variants" .= sumBoundary.nativePureRegionSumVariants
        , "shape" .= sumBoundary.nativePureRegionSumShape
        , "layout" .= layoutValue sumBoundary.nativePureRegionSumLayout
        ]

instance ToJSON NativePureFusedRegion where
  toJSON region =
    object
      [ "ref" .= region.nativePureFusedRegionRef
      , "sources" .= fmap (.unCircuitNodeRef) region.nativePureFusedRegionSources
      , "inputs" .= region.nativePureFusedRegionInputs
      , "outputs" .= region.nativePureFusedRegionOutputs
      , "internal_edges" .= region.nativePureFusedRegionInternalEdges
      , "ssa" .= region.nativePureFusedRegionSsa
      , "bounds" .= boundsValue region.nativePureFusedRegionBounds
      ]

instance ToJSON RealizationRuntimeKind where
  toJSON =
    Aeson.String . \case
      RealizationPureRegion -> "pure_region"
      RealizationPreservedNode -> "preserved_node"

instance ToJSON RealizationRuntimeUnit where
  toJSON unit =
    object
      [ "runtime" .= unit.realizationRuntimeUnitRef
      , "kind" .= unit.realizationRuntimeUnitKind
      , "sources" .= fmap (.unCircuitNodeRef) unit.realizationRuntimeUnitSources
      ]

instance ToJSON NativePureFusionMode where
  toJSON =
    Aeson.String . \case
      NativePureMaximalFusion -> "maximal"
      NativePureUnfused -> "unfused"

instance ToJSON RealizationArtifact where
  toJSON artifact =
    case realizationArtifactValue artifact of
      Aeson.Object fields ->
        Aeson.Object (KeyMap.insert "digest" (Aeson.String artifact.realizationArtifactDigest) fields)
      value -> value

instance ToJSON NativePurePlan where
  toJSON plan =
    case nativePurePlanValue plan of
      Aeson.Object fields ->
        Aeson.Object (KeyMap.insert "digest" (Aeson.String plan.nativePurePlanDigest) fields)
      value -> value

layoutValue :: NativeLayout -> Value
layoutValue layout = object ["size" .= layout.nativeLayoutSize, "alignment" .= layout.nativeLayoutAlignment]

boundsValue :: NativePureBounds -> Value
boundsValue bounds =
  object
    [ "stack_bytes" .= bounds.nativePureBoundStackBytes
    , "static_bytes" .= bounds.nativePureBoundStaticBytes
    , "output_bytes" .= bounds.nativePureBoundOutputBytes
    , "checkpoint_bytes" .= bounds.nativePureBoundCheckpointBytes
    , "steps" .= bounds.nativePureBoundSteps
    ]

outputBoundaryValue :: NativePureOutputBoundary -> Value
outputBoundaryValue = \case
  NativePureProduct boundaries -> object ["kind" .= ("product" :: Text), "fields" .= fmap boundaryValue boundaries]
  NativePureSum group boundaries ->
    object ["kind" .= ("sum" :: Text), "group" .= group, "variants" .= fmap boundaryValue boundaries]

candidateValue :: NativePureKernelCandidate -> Value
candidateValue candidate =
  object
    [ "ref" .= candidate.nativePureKernelCandidateRef.unCircuitNodeRef
    , "inputs" .= fmap boundaryValue candidate.nativePureKernelCandidateInputs
    , "output" .= outputBoundaryValue candidate.nativePureKernelCandidateOutput
    , "bindings" .= candidate.nativePureKernelCandidateBindings
    , "where" .= candidate.nativePureKernelCandidateWhere
    , "outputs" .= candidate.nativePureKernelCandidateOutputs
    , "variant" .= fmap variantValue candidate.nativePureKernelCandidateVariant
    , "bounds" .= boundsValue candidate.nativePureKernelCandidateBounds
    ]

boundaryValue :: NativePureBoundary -> Value
boundaryValue boundary =
  object
    [ "label" .= boundary.nativePureBoundaryLabel
    , "contract" .= boundary.nativePureBoundaryContract
    , "shape" .= boundary.nativePureBoundaryShape
    , "layout" .= layoutValue boundary.nativePureBoundaryLayout
    ]

variantValue :: NativePureVariantCandidate -> Value
variantValue variant =
  object
    [ "labels" .= variant.nativePureVariantCandidateLabels
    , "expression" .= variant.nativePureVariantCandidateExpression
    ]
