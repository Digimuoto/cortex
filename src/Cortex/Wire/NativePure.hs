{- |
Module      : Cortex.Wire.NativePure
Description : Canonical NativePure v1 realization plans.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

NativePure is additive: it derives a strict-registry-only, per-source-node
certification input from the admitted 'CompiledCircuit'.  The compiled circuit
remains the referent; this module neither rewrites nor replaces its topology.

The v1 realization deliberately maps one PureWire source node to one kernel.
CorePure values remain immutable SSA values.  Read/write storage regions are
introduced only after semantic lowering, so no ownership or borrowing algebra
leaks into the source semantics.
-}
module Cortex.Wire.NativePure
  ( module Cortex.Wire.NativePure.Shape
  , NativePurePlan (..)
  , NativePureKernel (..)
  , NativePureVariant (..)
  , NativePureBoundary (..)
  , NativePureOutputBoundary (..)
  , NativePureBounds (..)
  , NativePureRegion (..)
  , NativePureAccess (..)
  , RealizationArtifact (..)
  , NativePureError (..)
  , nativePurePlanSchema
  , realizationArtifactSchema
  , nativePureRealizerFamily
  , staticProgramV2Schema
  , lowerCompiledCircuitToNativePurePlan
  , renderNativePureError
  )
where

import Control.Monad (foldM, unless, when)
import Data.Aeson (ToJSON (..), Value, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.Foldable (traverse_)
import Data.Functor (($>))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isJust, mapMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

import Cortex.Wire.AdmissionArtifact
  ( WireAdmissionArtifact
  , wireAdmissionMetadataKey
  )
import Cortex.Wire.AdmissionBundle (admitWireAdmissionBundle)
import Cortex.Wire.Circuit.Compiled
  ( CircuitCompatibilityWitness (..)
  , CompiledCircuit (..)
  , CompiledCircuitNode (..)
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..), CircuitTaskNode (..))
import Cortex.Wire.Contracts
  ( WireContractRegistry (..)
  , WireContractSpec (..)
  , wirePortsFromMetadataValue
  )
import Cortex.Wire.NativePure.Shape
import Cortex.Wire.Pure
  ( PureEvalError
  , renderPureEvalError
  , validatePureTaskConfig
  , validatePureVariantTaskConfig
  )
import Cortex.Wire.Syntax
  ( CorePureBinOp (..)
  , CorePureBinding (..)
  , CorePureExpr (..)
  , CorePureField (..)
  , CorePureLiteral (..)
  , CorePureUnaryOp (..)
  , WireInputCardinality (..)
  , WireInputPort (..)
  , WireOutputPort (..)
  , WirePorts (..)
  )

nativePurePlanSchema :: Text
nativePurePlanSchema = "cortex.wire.native-pure-plan/v1"

realizationArtifactSchema :: Text
realizationArtifactSchema = "cortex.wire.realization-artifact/v1"

nativePureRealizerFamily :: Text
nativePureRealizerFamily = "cortex.wire.native-pure/v1"

-- | Additive deployment profile; @static-program/v1@ remains unchanged.
staticProgramV2Schema :: Text
staticProgramV2Schema = "cortex.wire.static-program/v2"

data NativePurePlan = NativePurePlan
  { nativePurePlanProgramId :: !Text
  , nativePurePlanProgramIdentity :: !Text
  , nativePurePlanRealization :: !RealizationArtifact
  , nativePurePlanKernels :: ![NativePureKernel]
  }
  deriving stock (Eq, Show, Generic)

data RealizationArtifact = RealizationArtifact
  { realizationReferentIdentity :: !Text
  , realizationSourceMembers :: !(Map CircuitNodeRef CircuitNodeRef)
  , realizationRuntimeMembers :: !(Map CircuitNodeRef [CircuitNodeRef])
  }
  deriving stock (Eq, Show, Generic)

data NativePureKernel = NativePureKernel
  { nativePureKernelRef :: !CircuitNodeRef
  , nativePureKernelInputs :: ![NativePureBoundary]
  , nativePureKernelOutput :: !NativePureOutputBoundary
  , nativePureKernelBindings :: ![CorePureBinding]
  , nativePureKernelWhere :: !(Maybe CorePureExpr)
  , nativePureKernelOutputs :: !(Map Text CorePureExpr)
  , nativePureKernelVariant :: !(Maybe NativePureVariant)
  , nativePureKernelBounds :: !NativePureBounds
  , nativePureKernelRegions :: ![NativePureRegion]
  }
  deriving stock (Eq, Show, Generic)

data NativePureVariant = NativePureVariant
  { nativePureVariantLabels :: ![Text]
  , nativePureVariantExpression :: !CorePureExpr
  }
  deriving stock (Eq, Show, Generic)

data NativePureBoundary = NativePureBoundary
  { nativePureBoundaryLabel :: !Text
  , nativePureBoundaryContract :: !Text
  , nativePureBoundaryShape :: !NativeShape
  , nativePureBoundaryLayout :: !NativeLayout
  }
  deriving stock (Eq, Show, Generic)

data NativePureOutputBoundary
  = NativePureProduct ![NativePureBoundary]
  | NativePureSum !Natural ![NativePureBoundary]
  deriving stock (Eq, Show, Generic)

data NativePureBounds = NativePureBounds
  { nativePureBoundStackBytes :: !Word64
  , nativePureBoundStaticBytes :: !Word64
  , nativePureBoundOutputBytes :: !Word64
  , nativePureBoundCheckpointBytes :: !Word64
  , nativePureBoundSteps :: !Word64
  }
  deriving stock (Eq, Show, Generic)

data NativePureAccess = NativePureRead | NativePureWrite
  deriving stock (Eq, Show, Generic)

data NativePureRegion = NativePureRegion
  { nativePureRegionName :: !Text
  , nativePureRegionAccess :: !NativePureAccess
  , nativePureRegionCapacity :: !Word64
  , nativePureRegionAlignment :: !Word64
  }
  deriving stock (Eq, Show, Generic)

data NativePureError
  = NativePureMissingAdmissionArtifact
  | NativePureMalformedAdmissionArtifact
  | NativePureAdmissionRejected !Text
  | NativePureMalformedMetadata !CircuitNodeRef !Text
  | NativePureMissingContract !CircuitNodeRef !Text
  | NativePureMissingShape !CircuitNodeRef !Text
  | NativePureInvalidShape !CircuitNodeRef !Text !NativeShapeError
  | NativePureInputNotExact !CircuitNodeRef !Text
  | NativePureMixedOutputBoundary !CircuitNodeRef
  | NativePureSumRequiresVariant !CircuitNodeRef
  | NativePureVariantRequiresSum !CircuitNodeRef
  | NativePureOutputEquationMismatch !CircuitNodeRef
  | NativePureUnsupportedExpression !CircuitNodeRef !Text
  | NativePureInvalidOutputBoundary !CircuitNodeRef !NativeShapeError
  | NativePureResourceOverflow !CircuitNodeRef
  | NativePureCheckpointTooLarge !CircuitNodeRef !Word64
  deriving stock (Eq, Show)

renderNativePureError :: NativePureError -> Text
renderNativePureError = \case
  NativePureMissingAdmissionArtifact -> "compiled circuit has no Wire admission artifact"
  NativePureMalformedAdmissionArtifact -> "compiled circuit carries malformed Wire admission metadata"
  NativePureAdmissionRejected rejection -> "compiled circuit failed unified Wire admission: " <> rejection
  NativePureMalformedMetadata nodeRef reason -> at nodeRef ("malformed pure metadata: " <> reason)
  NativePureMissingContract nodeRef contractId -> at nodeRef ("unknown contract " <> contractId)
  NativePureMissingShape nodeRef contractId ->
    at nodeRef ("contract " <> contractId <> " has no native_shape projection")
  NativePureInvalidShape nodeRef contractId shapeError ->
    at
      nodeRef
      ("contract " <> contractId <> " has invalid native_shape: " <> renderNativeShapeError shapeError)
  NativePureInputNotExact nodeRef portName ->
    at nodeRef ("input " <> portName <> " must accept exactly one contract with cardinality one")
  NativePureMixedOutputBoundary nodeRef ->
    at nodeRef "outputs must be either one product or one declared exclusive group"
  NativePureSumRequiresVariant nodeRef ->
    at nodeRef "an exclusive output group requires a pure sum variant body, not output equations"
  NativePureVariantRequiresSum nodeRef ->
    at nodeRef "a pure sum variant body requires one declared exclusive output group"
  NativePureOutputEquationMismatch nodeRef ->
    at nodeRef "pure output equations do not exactly match the declared output boundary"
  NativePureUnsupportedExpression nodeRef reason -> at nodeRef ("unsupported CorePure expression: " <> reason)
  NativePureInvalidOutputBoundary nodeRef shapeError ->
    at nodeRef ("output boundary has an invalid native layout: " <> renderNativeShapeError shapeError)
  NativePureResourceOverflow nodeRef -> at nodeRef "resource bound exceeds uint64_t"
  NativePureCheckpointTooLarge nodeRef bytes ->
    at nodeRef ("worst-case checkpoint " <> T.pack (show bytes) <> " bytes exceeds 2 MiB")
  where
    at nodeRef message = "NativePure node " <> nodeRef.unCircuitNodeRef <> ": " <> message

instance ToJSON NativeLayout where
  toJSON layout =
    Aeson.object
      [ "size" .= layout.nativeLayoutSize
      , "alignment" .= layout.nativeLayoutAlignment
      ]

instance ToJSON NativePureBoundary where
  toJSON boundary =
    Aeson.object
      [ "label" .= boundary.nativePureBoundaryLabel
      , "contract" .= boundary.nativePureBoundaryContract
      , "shape" .= boundary.nativePureBoundaryShape
      , "layout" .= boundary.nativePureBoundaryLayout
      ]

instance ToJSON NativePureOutputBoundary where
  toJSON = \case
    NativePureProduct fields ->
      Aeson.object ["kind" .= ("product" :: Text), "fields" .= fields]
    NativePureSum group variants ->
      Aeson.object
        [ "kind" .= ("sum" :: Text)
        , "group" .= group
        , "variants" .= variants
        ]

instance ToJSON NativePureAccess where
  toJSON =
    Aeson.String . \case
      NativePureRead -> "read"
      NativePureWrite -> "write"

instance ToJSON NativePureRegion where
  toJSON region =
    Aeson.object
      [ "name" .= region.nativePureRegionName
      , "access" .= region.nativePureRegionAccess
      , "capacity" .= region.nativePureRegionCapacity
      , "alignment" .= region.nativePureRegionAlignment
      ]

instance ToJSON NativePureBounds where
  toJSON bounds =
    Aeson.object
      [ "stack_bytes" .= bounds.nativePureBoundStackBytes
      , "static_bytes" .= bounds.nativePureBoundStaticBytes
      , "output_bytes" .= bounds.nativePureBoundOutputBytes
      , "checkpoint_bytes" .= bounds.nativePureBoundCheckpointBytes
      , "steps" .= bounds.nativePureBoundSteps
      ]

instance ToJSON NativePureKernel where
  toJSON kernel =
    Aeson.object
      ( [ "ref" .= kernel.nativePureKernelRef.unCircuitNodeRef
        , "inputs" .= kernel.nativePureKernelInputs
        , "output" .= kernel.nativePureKernelOutput
        , "bindings" .= kernel.nativePureKernelBindings
        , "where" .= kernel.nativePureKernelWhere
        , "bounds" .= kernel.nativePureKernelBounds
        , "regions" .= kernel.nativePureKernelRegions
        ]
          <> case kernel.nativePureKernelVariant of
            Nothing -> ["outputs" .= kernel.nativePureKernelOutputs]
            Just variant -> ["variant" .= variant]
      )

instance ToJSON NativePureVariant where
  toJSON variant =
    Aeson.object
      [ "labels" .= variant.nativePureVariantLabels
      , "expression" .= variant.nativePureVariantExpression
      ]

instance ToJSON RealizationArtifact where
  toJSON realization =
    Aeson.object
      [ "schema" .= realizationArtifactSchema
      , "family" .= nativePureRealizerFamily
      , "referent_identity" .= realization.realizationReferentIdentity
      , "source_members"
          .= [ Aeson.object
                 [ "source" .= source.unCircuitNodeRef
                 , "runtime" .= kernel.unCircuitNodeRef
                 ]
             | (source, kernel) <- Map.toAscList realization.realizationSourceMembers
             ]
      , "runtime_members"
          .= [ Aeson.object
                 [ "runtime" .= runtime.unCircuitNodeRef
                 , "sources" .= fmap (.unCircuitNodeRef) sources
                 ]
             | (runtime, sources) <- Map.toAscList realization.realizationRuntimeMembers
             ]
      ]

instance ToJSON NativePurePlan where
  toJSON plan =
    Aeson.object
      [ "schema" .= nativePurePlanSchema
      , "program_id" .= plan.nativePurePlanProgramId
      , "program_identity" .= plan.nativePurePlanProgramIdentity
      , "realization" .= plan.nativePurePlanRealization
      , "kernels" .= plan.nativePurePlanKernels
      ]

-- | Derive one certified-kernel candidate for every source-authored pure task.
lowerCompiledCircuitToNativePurePlan
  :: WireContractRegistry
  -> CompiledCircuit
  -> Either NativePureError NativePurePlan
lowerCompiledCircuitToNativePurePlan registry compiled = do
  admission <- extractAdmission compiled
  case admitWireAdmissionBundle admission compiled of
    Left rejection -> Left (NativePureAdmissionRejected (T.pack (show rejection)))
    Right _bundle -> pure ()
  kernels <- catMaybes <$> traverse lowerNode (Map.toAscList compiled.compiledCircuitNodes)
  -- The realization witness binds realized units only: effectful nodes stay
  -- host-scheduled and must not appear as NativePure runtime members.
  let identity = compiled.compiledCircuitCompatibility.circuitCompatibilityDigest
      kernelRefs = fmap (.nativePureKernelRef) kernels
      sourceMembers = Map.fromList [(nodeRef, nodeRef) | nodeRef <- kernelRefs]
      runtimeMembers = Map.fromList [(nodeRef, [nodeRef]) | nodeRef <- kernelRefs]
  pure
    NativePurePlan
      { nativePurePlanProgramId = compiled.compiledCircuitId
      , nativePurePlanProgramIdentity = identity
      , nativePurePlanRealization =
          RealizationArtifact
            { realizationReferentIdentity = identity
            , realizationSourceMembers = sourceMembers
            , realizationRuntimeMembers = runtimeMembers
            }
      , nativePurePlanKernels = kernels
      }
  where
    lowerNode (nodeRef, CompiledCircuitTask taskNode)
      | taskExecutor taskNode == Just "pure" = Just <$> lowerPureNode registry nodeRef taskNode
      | otherwise = pure Nothing
    lowerNode _ = pure Nothing

lowerPureNode
  :: WireContractRegistry
  -> CircuitNodeRef
  -> CircuitTaskNode
  -> Either NativePureError NativePureKernel
lowerPureNode registry nodeRef taskNode = do
  metadata <- requireObject nodeRef "task" taskNode.circuitTaskNodeMetadata
  portsValue <- requireKey nodeRef "ports" metadata
  ports <- firstMetadata nodeRef (wirePortsFromMetadataValue portsValue)
  config <- requireKey nodeRef "config" metadata >>= requireObject nodeRef "config"
  requireExactKeys nodeRef "config" ["bindings", "where", "outputs", "variant"] config
  bindings <- parseOptional nodeRef "bindings" [] config
  whereExpr <- parseOptional nodeRef "where" Nothing config
  outputs <-
    maybe
      (Right Map.empty)
      (parseValue nodeRef "outputs")
      (KeyMap.lookup "outputs" config)
  variant <- parseVariant nodeRef config
  let outputPortsExclusive =
        any (isJust . (.wireOutputPortExclusiveGroup)) (Map.elems ports.wirePortsOutputs)
  case (KeyMap.member "outputs" config, variant) of
    (True, Nothing) -> do
      -- An exclusive group is a sum boundary; product equations over it would
      -- compute every variant of a boundary that must commit exactly one.
      when outputPortsExclusive $
        Left (NativePureSumRequiresVariant nodeRef)
      unless (Map.keysSet outputs == Map.keysSet ports.wirePortsOutputs) $
        Left (NativePureOutputEquationMismatch nodeRef)
      firstPureMetadata nodeRef (validatePureTaskConfig ports bindings whereExpr outputs)
    (False, Just variantConfig) -> do
      unless outputPortsExclusive $
        Left (NativePureVariantRequiresSum nodeRef)
      unless (Set.fromList variantConfig.nativePureVariantLabels == Map.keysSet ports.wirePortsOutputs) $
        Left (NativePureOutputEquationMismatch nodeRef)
      firstPureMetadata
        nodeRef
        ( validatePureVariantTaskConfig
            ports
            bindings
            whereExpr
            variantConfig.nativePureVariantLabels
            variantConfig.nativePureVariantExpression
        )
    _ -> Left (NativePureMalformedMetadata nodeRef "config requires exactly one of outputs or variant")
  inputs <- traverse (lowerInput registry nodeRef) (Map.toAscList ports.wirePortsInputs)
  outputFields <- traverse (lowerOutput registry nodeRef) (Map.toAscList ports.wirePortsOutputs)
  outputBoundary <- classifyOutputs nodeRef ports outputFields
  -- Type-directed admission: every body expression is checked against the
  -- crossing native shapes, so the plan cannot carry a body the intrinsically
  -- typed kernel has no representation for.
  let inputScope =
        Map.fromList
          [ (boundary.nativePureBoundaryLabel, boundary.nativePureBoundaryShape)
          | boundary <- inputs
          ]
  bindingScope <- foldM (synthNativeBinding nodeRef) inputScope bindings
  bodyScope <- bindNativeWhere nodeRef bindingScope whereExpr
  let outputShapes =
        Map.fromList
          [ (boundary.nativePureBoundaryLabel, boundary.nativePureBoundaryShape)
          | boundary <- outputFields
          ]
  traverse_
    ( \(label, outputExpr) ->
        case Map.lookup label outputShapes of
          Just shape -> checkNativeExpr nodeRef bodyScope outputExpr shape
          Nothing -> Left (NativePureOutputEquationMismatch nodeRef)
    )
    (Map.toAscList outputs)
  traverse_
    ( \variantConfig ->
        checkNativeVariantExpr
          nodeRef
          bodyScope
          outputShapes
          variantConfig.nativePureVariantExpression
    )
    variant
  bounds <- calculateBounds nodeRef inputs outputBoundary bindings whereExpr outputs variant
  let inputRegions = fmap (boundaryRegion NativePureRead "input.") inputs
  outputRegions <- outputBoundaryRegions nodeRef outputBoundary
  pure
    NativePureKernel
      { nativePureKernelRef = nodeRef
      , nativePureKernelInputs = inputs
      , nativePureKernelOutput = outputBoundary
      , nativePureKernelBindings = bindings
      , nativePureKernelWhere = whereExpr
      , nativePureKernelOutputs = outputs
      , nativePureKernelVariant = variant
      , nativePureKernelBounds = bounds
      , nativePureKernelRegions = inputRegions <> outputRegions
      }

lowerInput
  :: WireContractRegistry
  -> CircuitNodeRef
  -> (Text, WireInputPort)
  -> Either NativePureError NativePureBoundary
lowerInput registry nodeRef (label, port)
  | [contractId] <- port.wireInputPortAccepts
  , port.wireInputPortCardinality == WireInputCardinalityOne =
      lowerBoundary registry nodeRef label contractId
  | otherwise = Left (NativePureInputNotExact nodeRef label)

lowerOutput
  :: WireContractRegistry
  -> CircuitNodeRef
  -> (Text, WireOutputPort)
  -> Either NativePureError NativePureBoundary
lowerOutput registry nodeRef (label, port) =
  lowerBoundary registry nodeRef label port.wireOutputPortContract

lowerBoundary
  :: WireContractRegistry
  -> CircuitNodeRef
  -> Text
  -> Text
  -> Either NativePureError NativePureBoundary
lowerBoundary registry nodeRef label contractId = do
  contract <-
    maybe
      (Left (NativePureMissingContract nodeRef contractId))
      Right
      (Map.lookup contractId registry.wireContractRegistryContracts)
  shape <-
    maybe
      (Left (NativePureMissingShape nodeRef contractId))
      Right
      contract.wireContractSpecNativeShape
  let nativeShape = shape.nativeShapeProjectionShape
  layout <-
    case nativeShapeLayout nativeShape of
      Left shapeError -> Left (NativePureInvalidShape nodeRef contractId shapeError)
      Right validLayout -> Right validLayout
  pure
    NativePureBoundary
      { nativePureBoundaryLabel = label
      , nativePureBoundaryContract = contractId
      , nativePureBoundaryShape = nativeShape
      , nativePureBoundaryLayout = layout
      }

classifyOutputs
  :: CircuitNodeRef
  -> WirePorts
  -> [NativePureBoundary]
  -> Either NativePureError NativePureOutputBoundary
classifyOutputs nodeRef ports boundaries =
  case Set.toList groups of
    []
      | not (any hasGroup outputPorts) -> Right (NativePureProduct boundaries)
    [group]
      | all ((== Just group) . (.wireOutputPortExclusiveGroup)) outputPorts ->
          Right (NativePureSum group boundaries)
    _ -> Left (NativePureMixedOutputBoundary nodeRef)
  where
    outputPorts = Map.elems ports.wirePortsOutputs
    groups = Set.fromList (mapMaybe (.wireOutputPortExclusiveGroup) outputPorts)
    hasGroup = isJust . (.wireOutputPortExclusiveGroup)

calculateBounds
  :: CircuitNodeRef
  -> [NativePureBoundary]
  -> NativePureOutputBoundary
  -> [CorePureBinding]
  -> Maybe CorePureExpr
  -> Map Text CorePureExpr
  -> Maybe NativePureVariant
  -> Either NativePureError NativePureBounds
calculateBounds nodeRef inputs outputBoundary bindings whereExpr outputExprs variant = do
  inputBytes <- sumBounded nodeRef (fmap (layoutSize . (.nativePureBoundaryLayout)) inputs)
  outputLayout <- outputBoundaryLayout nodeRef outputBoundary
  let outputBytes = outputLayout.nativeLayoutSize
  stackBytes <- sumBounded nodeRef [inputBytes, outputBytes, outputBytes]
  -- Sum output layouts already include their uint32 variant tag.
  checkpointBytes <- sumBounded nodeRef [inputBytes, outputBytes]
  when (checkpointBytes > 2 * 1024 * 1024) $
    Left (NativePureCheckpointTooLarge nodeRef checkpointBytes)
  expressionSteps <-
    sumBounded nodeRef $
      fmap (exprCost . (.corePureBindingExpr)) bindings
        <> foldMap (pure . exprCost) whereExpr
        <> fmap exprCost (Map.elems outputExprs)
        <> foldMap (pure . exprCost . (.nativePureVariantExpression)) variant
  staticBytes <-
    sumBounded nodeRef $
      fmap (exprStaticBytes . (.corePureBindingExpr)) bindings
        <> foldMap (pure . exprStaticBytes) whereExpr
        <> fmap exprStaticBytes (Map.elems outputExprs)
        <> foldMap (pure . exprStaticBytes . (.nativePureVariantExpression)) variant
  pure
    NativePureBounds
      { nativePureBoundStackBytes = stackBytes
      , nativePureBoundStaticBytes = staticBytes
      , nativePureBoundOutputBytes = outputBytes
      , nativePureBoundCheckpointBytes = checkpointBytes
      , nativePureBoundSteps = expressionSteps
      }
  where
    layoutSize layout = layout.nativeLayoutSize

outputBoundaryLayout
  :: CircuitNodeRef
  -> NativePureOutputBoundary
  -> Either NativePureError NativeLayout
outputBoundaryLayout nodeRef = \case
  -- Product outputs are stored as one aligned record so the byte accounting
  -- includes inter-field padding rather than under-counting concatenated,
  -- separately-aligned regions.
  NativePureProduct fields ->
    case fields of
      [] -> pure (NativeLayout 0 1)
      _ -> boundaryLayout (NativeRecord (Map.fromList (fmap variantShape fields)))
  NativePureSum _ variants ->
    boundaryLayout (NativeSum (Map.fromList (fmap variantShape variants)))
  where
    boundaryLayout shape =
      case nativeShapeLayout shape of
        Left shapeError -> Left (NativePureInvalidOutputBoundary nodeRef shapeError)
        Right layout -> Right layout

    variantShape boundary =
      (boundary.nativePureBoundaryLabel, boundary.nativePureBoundaryShape)

outputBoundaryRegions
  :: CircuitNodeRef
  -> NativePureOutputBoundary
  -> Either NativePureError [NativePureRegion]
outputBoundaryRegions nodeRef = \case
  NativePureProduct fields ->
    pure (fmap (boundaryRegion NativePureWrite "output.") fields)
  sumBoundary@NativePureSum {} -> do
    layout <- outputBoundaryLayout nodeRef sumBoundary
    pure
      [ NativePureRegion
          { nativePureRegionName = "output.variant"
          , nativePureRegionAccess = NativePureWrite
          , nativePureRegionCapacity = layout.nativeLayoutSize
          , nativePureRegionAlignment = layout.nativeLayoutAlignment
          }
      ]

boundaryRegion :: NativePureAccess -> Text -> NativePureBoundary -> NativePureRegion
boundaryRegion access prefix boundary =
  NativePureRegion
    { nativePureRegionName = prefix <> boundary.nativePureBoundaryLabel
    , nativePureRegionAccess = access
    , nativePureRegionCapacity = boundary.nativePureBoundaryLayout.nativeLayoutSize
    , nativePureRegionAlignment = boundary.nativePureBoundaryLayout.nativeLayoutAlignment
    }

sumBounded :: CircuitNodeRef -> [Word64] -> Either NativePureError Word64
sumBounded nodeRef = foldM add 0
  where
    add total value
      | maxBound - total < value = Left (NativePureResourceOverflow nodeRef)
      | otherwise = Right (total + value)

{- | Exact worst-case step count for the admitted basis: every admitted form
costs one step plus its children, branches take the more expensive arm. Calls,
lambdas, lists, and indexing carry only structural cost here because
'validateNativeExpr' rejects them before bounds are computed; the sole admitted
call form is the variant constructor injection, which is one step around its
payload.
-}
exprCost :: CorePureExpr -> Word64
exprCost = \case
  CorePureLit {} -> 1
  CorePureIdent {} -> 1
  CorePureList values -> 1 + sum (fmap exprCost values)
  CorePureRecord fields -> 1 + sum (fmap (exprCost . (.corePureFieldValue)) fields)
  CorePureFieldAccess value _ -> 1 + exprCost value
  CorePureIndex value index -> 1 + exprCost value + exprCost index
  CorePureLambda _ body -> 1 + exprCost body
  CorePureCall function arguments ->
    1 + exprCost function + sum (fmap exprCost arguments)
  CorePureUnary _ value -> 1 + exprCost value
  CorePureBinary _ left right -> 1 + exprCost left + exprCost right
  CorePureLet bindings body ->
    1 + sum (fmap (exprCost . (.corePureBindingExpr)) (NE.toList bindings)) + exprCost body
  CorePureIf condition thenExpr elseExpr ->
    1 + exprCost condition + max (exprCost thenExpr) (exprCost elseExpr)

{- | Bytes of static storage an expression pins into the generated object:
UTF-8 text literals become read-only static data.
-}
exprStaticBytes :: CorePureExpr -> Word64
exprStaticBytes = \case
  CorePureLit literal ->
    case literal of
      CorePureString text -> fromIntegral (BS.length (TE.encodeUtf8 text))
      CorePureNumber {} -> 0
      CorePureBool {} -> 0
      CorePureNull -> 0
  CorePureIdent {} -> 0
  CorePureList values -> sum (fmap exprStaticBytes values)
  CorePureRecord fields -> sum (fmap (exprStaticBytes . (.corePureFieldValue)) fields)
  CorePureFieldAccess value _ -> exprStaticBytes value
  CorePureIndex value index -> exprStaticBytes value + exprStaticBytes index
  CorePureLambda _ body -> exprStaticBytes body
  CorePureCall function arguments ->
    exprStaticBytes function + sum (fmap exprStaticBytes arguments)
  CorePureUnary _ value -> exprStaticBytes value
  CorePureBinary _ left right -> exprStaticBytes left + exprStaticBytes right
  CorePureLet bindings body ->
    sum (fmap (exprStaticBytes . (.corePureBindingExpr)) (NE.toList bindings)) + exprStaticBytes body
  CorePureIf condition thenExpr elseExpr ->
    exprStaticBytes condition + exprStaticBytes thenExpr + exprStaticBytes elseExpr

-- | Names in scope for kernel bodies, each with its crossing native shape.
type NativeScope = Map Text NativeShape

{- | Type-directed admission for the certified kernel basis. An expression is
checked against the native shape it must produce, so a fractional literal
cannot cross an i64 boundary and an operation without a kernel representation
— negate, merge, division, derived comparisons, builtin calls, lambdas,
vectors — is a rejection, never a silent pass-through (ADR 0096: the profile
over-rejects; it must not emit uncertifiable kernel bodies).
-}
checkNativeExpr
  :: CircuitNodeRef -> NativeScope -> CorePureExpr -> NativeShape -> Either NativePureError ()
checkNativeExpr nodeRef = check
  where
    check scope expr expected =
      case expr of
        CorePureLit literal -> checkNativeLiteral nodeRef literal expected
        CorePureIdent name -> do
          shape <- lookupNativeScope nodeRef scope name
          requireShapeFits nodeRef shape expected
        CorePureRecord fields ->
          case expected of
            NativeRecord expectedFields -> do
              flatFields <- traverse (singleSegmentField nodeRef) fields
              unless (Set.fromList (fmap fst flatFields) == Map.keysSet expectedFields) $
                unsupported ("record literal fields do not match the expected native record shape")
              traverse_
                ( \(name, value) ->
                    -- The key-set equality above makes this lookup total.
                    traverse_ (check scope value) (Map.lookup name expectedFields)
                )
                flatFields
            _ -> unsupported "record literal used where a non-record native shape is expected"
        CorePureFieldAccess {} -> do
          shape <- synthNativeShape nodeRef scope expr
          requireShapeFits nodeRef shape expected
        CorePureIf condition thenExpr elseExpr -> do
          check scope condition NativeBool
          check scope thenExpr expected
          check scope elseExpr expected
        CorePureLet bindings body -> do
          innerScope <- foldM (synthNativeLetBinding nodeRef) scope (NE.toList bindings)
          check innerScope body expected
        CorePureUnary unaryOp value ->
          case unaryOp of
            CorePureNot -> do
              requireExpected NativeBool "boolean not produces bool" expected
              check scope value NativeBool
            CorePureNegate ->
              unsupported "negate has no certified kernel representation; write 0 - value"
        CorePureBinary binOp left right ->
          case binOp of
            CorePureAdd -> checkedArithmetic scope left right expected
            CorePureSubtract -> checkedArithmetic scope left right expected
            CorePureMultiply -> checkedArithmetic scope left right expected
            CorePureDivide ->
              unsupported "division is not in the certified kernel basis yet"
            CorePureMerge ->
              unsupported "record merge has no certified kernel representation"
            CorePureEqual -> i64Comparison scope left right expected
            CorePureLessThan -> i64Comparison scope left right expected
            CorePureNotEqual ->
              unsupported "derived comparison != is outside the kernel basis; only == and < are represented"
            CorePureLessThanOrEqual ->
              unsupported "derived comparison <= is outside the kernel basis; only == and < are represented"
            CorePureGreaterThan ->
              unsupported "derived comparison > is outside the kernel basis; only == and < are represented"
            CorePureGreaterThanOrEqual ->
              unsupported "derived comparison >= is outside the kernel basis; only == and < are represented"
            CorePureAnd -> boolConnective scope left right expected
            CorePureOr -> boolConnective scope left right expected
        CorePureList _ ->
          unsupported "vector literals are not in the certified kernel basis yet"
        CorePureIndex _ _ ->
          unsupported "vector indexing is not in the certified kernel basis yet"
        CorePureLambda _ _ ->
          unsupported "lambdas are not in the certified kernel basis yet"
        CorePureCall _ _ ->
          unsupported "builtin calls are not in the certified kernel basis yet"

    checkedArithmetic scope left right expected = do
      requireExpected NativeI64 "checked arithmetic produces i64" expected
      check scope left NativeI64
      check scope right NativeI64

    i64Comparison scope left right expected = do
      requireExpected NativeBool "an i64 comparison produces bool" expected
      check scope left NativeI64
      check scope right NativeI64

    boolConnective scope left right expected = do
      requireExpected NativeBool "a boolean connective produces bool" expected
      check scope left NativeBool
      check scope right NativeBool

    requireExpected shape reason expected =
      unless (expected == shape) $
        unsupported (reason <> ", but the crossing shape here is different")

    unsupported = Left . NativePureUnsupportedExpression nodeRef

{- | Synthesize the native shape of an expression in binding position. String
literals synthesize their exact byte capacity; text capacities widen through
'requireShapeFits' when checked against a larger declared capacity.
-}
synthNativeShape
  :: CircuitNodeRef -> NativeScope -> CorePureExpr -> Either NativePureError NativeShape
synthNativeShape nodeRef = synth
  where
    synth scope = \case
      CorePureLit literal -> synthNativeLiteral nodeRef literal
      CorePureIdent name -> lookupNativeScope nodeRef scope name
      CorePureRecord fields -> do
        flatFields <- traverse (singleSegmentField nodeRef) fields
        when (null flatFields) $
          unsupported "an empty record literal has no native shape"
        NativeRecord . Map.fromList
          <$> traverse (\(name, value) -> (,) name <$> synth scope value) flatFields
      CorePureFieldAccess baseExpr fieldName -> do
        baseShape <- synth scope baseExpr
        case baseShape of
          NativeRecord fields ->
            case Map.lookup fieldName fields of
              Just shape -> Right shape
              Nothing ->
                unsupported ("record projection names unknown native field " <> fieldName)
          _ -> unsupported "record projection applied to a non-record native shape"
      CorePureIf condition thenExpr elseExpr -> do
        checkNativeExpr nodeRef scope condition NativeBool
        thenShape <- synth scope thenExpr
        checkNativeExpr nodeRef scope elseExpr thenShape
        Right thenShape
      CorePureLet bindings body -> do
        innerScope <- foldM (synthNativeLetBinding nodeRef) scope (NE.toList bindings)
        synth innerScope body
      expr@(CorePureUnary unaryOp value) ->
        case unaryOp of
          CorePureNot -> do
            checkNativeExpr nodeRef scope value NativeBool
            Right NativeBool
          CorePureNegate -> checkOnly scope expr NativeBool
      expr@(CorePureBinary binOp _ _) ->
        case binOp of
          CorePureAdd -> checkOnly scope expr NativeI64
          CorePureSubtract -> checkOnly scope expr NativeI64
          CorePureMultiply -> checkOnly scope expr NativeI64
          CorePureDivide -> checkOnly scope expr NativeI64
          CorePureMerge -> checkOnly scope expr NativeBool
          CorePureEqual -> checkOnly scope expr NativeBool
          CorePureNotEqual -> checkOnly scope expr NativeBool
          CorePureLessThan -> checkOnly scope expr NativeBool
          CorePureLessThanOrEqual -> checkOnly scope expr NativeBool
          CorePureGreaterThan -> checkOnly scope expr NativeBool
          CorePureGreaterThanOrEqual -> checkOnly scope expr NativeBool
          CorePureAnd -> checkOnly scope expr NativeBool
          CorePureOr -> checkOnly scope expr NativeBool
      expr@(CorePureList _) -> checkOnly scope expr NativeBool
      expr@(CorePureIndex _ _) -> checkOnly scope expr NativeBool
      expr@(CorePureCall _ _) -> checkOnly scope expr NativeBool
      expr@(CorePureLambda _ _) -> checkOnly scope expr NativeBool

    -- Operator and rejected forms have one possible (or no) result shape;
    -- checking against it reuses the admission rules and their diagnostics.
    checkOnly scope expr shape =
      checkNativeExpr nodeRef scope expr shape $> shape

    unsupported :: Text -> Either NativePureError a
    unsupported = Left . NativePureUnsupportedExpression nodeRef

synthNativeBinding
  :: CircuitNodeRef -> NativeScope -> CorePureBinding -> Either NativePureError NativeScope
synthNativeBinding nodeRef scope binding = do
  shape <- synthNativeShape nodeRef scope binding.corePureBindingExpr
  Right (Map.insert binding.corePureBindingName shape scope)

synthNativeLetBinding
  :: CircuitNodeRef -> NativeScope -> CorePureBinding -> Either NativePureError NativeScope
synthNativeLetBinding = synthNativeBinding

{- | Bind the node @where@ record into the body scope. The native profile
requires the clause to synthesize a record shape; each field becomes a scoped
name, mirroring 'Cortex.Wire.Pure.bindCorePureWhere'.
-}
bindNativeWhere
  :: CircuitNodeRef -> NativeScope -> Maybe CorePureExpr -> Either NativePureError NativeScope
bindNativeWhere nodeRef scope = \case
  Nothing -> Right scope
  Just whereExpr -> do
    whereShape <- synthNativeShape nodeRef scope whereExpr
    case whereShape of
      NativeRecord fields -> Right (Map.union fields scope)
      _ ->
        Left
          ( NativePureUnsupportedExpression
              nodeRef
              "a where clause must synthesize a native record shape"
          )

{- | Variant bodies mirror 'Cortex.Wire.Pure.evaluateVariantResult': control
flow may branch through if/let, and every path must end in a declared
constructor injection whose payload checks against that variant's shape.
-}
checkNativeVariantExpr
  :: CircuitNodeRef -> NativeScope -> Map Text NativeShape -> CorePureExpr -> Either NativePureError ()
checkNativeVariantExpr nodeRef outerScope variantShapes = goVariant outerScope
  where
    goVariant scope = \case
      CorePureIf condition thenExpr elseExpr -> do
        checkNativeExpr nodeRef scope condition NativeBool
        goVariant scope thenExpr
        goVariant scope elseExpr
      CorePureLet bindings body -> do
        innerScope <- foldM (synthNativeLetBinding nodeRef) scope (NE.toList bindings)
        goVariant innerScope body
      CorePureCall (CorePureIdent label) [payload]
        | Just shape <- Map.lookup label variantShapes ->
            checkNativeExpr nodeRef scope payload shape
      other ->
        Left
          ( NativePureUnsupportedExpression
              nodeRef
              ("pure sum path must end in a declared constructor, got " <> T.pack (show other))
          )

checkNativeLiteral
  :: CircuitNodeRef -> CorePureLiteral -> NativeShape -> Either NativePureError ()
checkNativeLiteral nodeRef literal expected =
  case (literal, expected) of
    (CorePureBool _, NativeBool) -> Right ()
    (CorePureNull, NativeUnit) -> Right ()
    (CorePureString text, NativeText capacity)
      | utf8Length text <= fromIntegral capacity -> Right ()
      | otherwise ->
          unsupported ("string literal exceeds the crossing text capacity " <> T.pack (show capacity))
    (CorePureNumber number, NativeI64) ->
      case floatingOrInteger number :: Either Double Integer of
        Right integer
          | integer >= -(2 ^ (63 :: Integer)) && integer < 2 ^ (63 :: Integer) -> Right ()
          | otherwise -> unsupported "integer literal exceeds the checked i64 range"
        Left _ -> unsupported "fractional literal cannot cross an i64 native shape"
    (CorePureNumber number, NativeU64) ->
      case floatingOrInteger number :: Either Double Integer of
        Right integer
          | integer >= 0 && integer < 2 ^ (64 :: Integer) -> Right ()
          | otherwise -> unsupported "integer literal exceeds the u64 range"
        Left _ -> unsupported "fractional literal cannot cross a u64 native shape"
    (CorePureNumber _, NativeF64) -> Right ()
    (_, _) ->
      unsupported
        ("literal " <> T.pack (show literal) <> " does not fit the crossing native shape")
  where
    unsupported = Left . NativePureUnsupportedExpression nodeRef

synthNativeLiteral
  :: CircuitNodeRef -> CorePureLiteral -> Either NativePureError NativeShape
synthNativeLiteral nodeRef = \case
  CorePureBool _ -> Right NativeBool
  CorePureNull -> Right NativeUnit
  CorePureString text -> Right (NativeText (max 1 (fromIntegral (utf8Length text))))
  CorePureNumber number ->
    case floatingOrInteger number :: Either Double Integer of
      Right integer
        | integer >= -(2 ^ (63 :: Integer)) && integer < 2 ^ (63 :: Integer) -> Right NativeI64
        | otherwise ->
            Left
              ( NativePureUnsupportedExpression
                  nodeRef
                  "integer literal exceeds the checked i64 range"
              )
      Left _ -> Right NativeF64

utf8Length :: Text -> Int
utf8Length = BS.length . TE.encodeUtf8

lookupNativeScope
  :: CircuitNodeRef -> NativeScope -> Text -> Either NativePureError NativeShape
lookupNativeScope nodeRef scope name =
  case Map.lookup name scope of
    Just shape -> Right shape
    Nothing ->
      Left
        ( NativePureUnsupportedExpression
            nodeRef
            ("identifier " <> name <> " has no native shape in scope")
        )

singleSegmentField
  :: CircuitNodeRef -> CorePureField -> Either NativePureError (Text, CorePureExpr)
singleSegmentField nodeRef field =
  case field.corePureFieldPath of
    name NE.:| [] -> Right (name, field.corePureFieldValue)
    path ->
      Left
        ( NativePureUnsupportedExpression
            nodeRef
            ("dotted record field path " <> T.intercalate "." (NE.toList path) <> " is not in the kernel basis")
        )

{- | A synthesized shape fits a declared crossing shape when they agree up to
text-capacity widening: a literal-synthesized @text n@ fits any declared
@text m@ with @n <= m@ because the value's bytes fit the larger buffer.
-}
requireShapeFits
  :: CircuitNodeRef -> NativeShape -> NativeShape -> Either NativePureError ()
requireShapeFits nodeRef actual expected =
  if fits actual expected
    then Right ()
    else
      Left
        ( NativePureUnsupportedExpression
            nodeRef
            "expression shape does not fit the crossing native shape"
        )
  where
    fits (NativeText actualCapacity) (NativeText expectedCapacity) =
      actualCapacity <= expectedCapacity
    fits (NativeRecord actualFields) (NativeRecord expectedFields) =
      Map.keysSet actualFields == Map.keysSet expectedFields
        && and (Map.intersectionWith fits actualFields expectedFields)
    fits (NativeSum actualVariants) (NativeSum expectedVariants) =
      Map.keysSet actualVariants == Map.keysSet expectedVariants
        && and (Map.intersectionWith fits actualVariants expectedVariants)
    fits (NativeVector actualCapacity actualElement) (NativeVector expectedCapacity expectedElement) =
      actualCapacity == expectedCapacity && fits actualElement expectedElement
    fits actual' expected' = actual' == expected'

taskExecutor :: CircuitTaskNode -> Maybe Text
taskExecutor taskNode = do
  metadata <- asObject taskNode.circuitTaskNodeMetadata
  executorValue <- KeyMap.lookup "executor" metadata
  executor <- asObject executorValue
  Aeson.String "native" <- KeyMap.lookup "kind" executor
  Aeson.String target <- KeyMap.lookup "target" executor
  pure target

extractAdmission :: CompiledCircuit -> Either NativePureError WireAdmissionArtifact
extractAdmission compiled = do
  metadata <-
    maybe
      (Left NativePureMissingAdmissionArtifact)
      Right
      (asObject compiled.compiledCircuitMetadata)
  encoded <-
    maybe
      (Left NativePureMissingAdmissionArtifact)
      Right
      (KeyMap.lookup (Key.fromText wireAdmissionMetadataKey) metadata)
  case Aeson.fromJSON encoded of
    Aeson.Error _ -> Left NativePureMalformedAdmissionArtifact
    Aeson.Success admission -> Right admission

requireObject
  :: CircuitNodeRef
  -> Text
  -> Value
  -> Either NativePureError (KeyMap.KeyMap Value)
requireObject nodeRef label value =
  maybe
    (Left (NativePureMalformedMetadata nodeRef (label <> " must be an object")))
    Right
    (asObject value)

asObject :: Value -> Maybe (KeyMap.KeyMap Value)
asObject = \case
  Aeson.Object objectValue -> Just objectValue
  _ -> Nothing

requireKey
  :: CircuitNodeRef
  -> Text
  -> KeyMap.KeyMap Value
  -> Either NativePureError Value
requireKey nodeRef key objectValue =
  maybe
    (Left (NativePureMalformedMetadata nodeRef ("missing " <> key)))
    Right
    (KeyMap.lookup (Key.fromText key) objectValue)

parseRequired
  :: Aeson.FromJSON value
  => CircuitNodeRef
  -> Text
  -> KeyMap.KeyMap Value
  -> Either NativePureError value
parseRequired nodeRef key objectValue =
  requireKey nodeRef key objectValue >>= parseValue nodeRef key

parseOptional
  :: Aeson.FromJSON value
  => CircuitNodeRef
  -> Text
  -> value
  -> KeyMap.KeyMap Value
  -> Either NativePureError value
parseOptional nodeRef key defaultValue objectValue =
  case KeyMap.lookup (Key.fromText key) objectValue of
    Nothing -> Right defaultValue
    Just value -> parseValue nodeRef key value

parseVariant
  :: CircuitNodeRef
  -> KeyMap.KeyMap Value
  -> Either NativePureError (Maybe NativePureVariant)
parseVariant nodeRef config =
  case KeyMap.lookup "variant" config of
    Nothing -> Right Nothing
    Just value -> do
      objectValue <- requireObject nodeRef "variant" value
      let actualKeys = Set.fromList (fmap Key.toText (KeyMap.keys objectValue))
          expectedKeys = Set.fromList ["labels", "expression"]
      unless (actualKeys == expectedKeys) $
        Left (NativePureMalformedMetadata nodeRef "variant fields must be exactly labels and expression")
      labels <- parseRequired nodeRef "labels" objectValue
      expression <- parseRequired nodeRef "expression" objectValue
      when (length labels < 2) $
        Left (NativePureMalformedMetadata nodeRef "variant requires at least two labels")
      when (any (T.null . T.strip) labels) $
        Left (NativePureMalformedMetadata nodeRef "variant labels must not be blank")
      when (Set.size (Set.fromList labels) /= length labels) $
        Left (NativePureMalformedMetadata nodeRef "variant labels must be unique")
      pure (Just (NativePureVariant labels expression))

requireExactKeys
  :: CircuitNodeRef
  -> Text
  -> [Text]
  -> KeyMap.KeyMap Value
  -> Either NativePureError ()
requireExactKeys nodeRef label allowed objectValue =
  case Set.toAscList (actual Set.\\ expected) of
    [] -> Right ()
    unknown : _ ->
      Left (NativePureMalformedMetadata nodeRef (label <> " has unknown field " <> unknown))
  where
    actual = Set.fromList (fmap Key.toText (KeyMap.keys objectValue))
    expected = Set.fromList allowed

parseValue
  :: Aeson.FromJSON value => CircuitNodeRef -> Text -> Value -> Either NativePureError value
parseValue nodeRef key value =
  case Aeson.fromJSON value of
    Aeson.Error message -> Left (NativePureMalformedMetadata nodeRef (key <> ": " <> T.pack message))
    Aeson.Success decoded -> Right decoded

firstMetadata :: CircuitNodeRef -> Either Text value -> Either NativePureError value
firstMetadata nodeRef = \case
  Left message -> Left (NativePureMalformedMetadata nodeRef message)
  Right value -> Right value

firstPureMetadata
  :: CircuitNodeRef
  -> Either PureEvalError value
  -> Either NativePureError value
firstPureMetadata nodeRef = \case
  Left pureError ->
    Left (NativePureMalformedMetadata nodeRef (renderPureEvalError pureError))
  Right value -> Right value
