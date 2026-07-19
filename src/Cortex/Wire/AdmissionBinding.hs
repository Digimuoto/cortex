{- |
Module      : Cortex.Wire.AdmissionBinding
Description : Binding checker between admission artifacts and compiled circuits.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

'Cortex.Wire.AdmissionArtifact' validates that a 'WireAdmissionArtifact' is
internally consistent: summary rows replay from the primitive trace, component
rows close over the summary domain, and frontiers are backed by primitive rows.
None of those checks mention the 'CompiledCircuit' the artifact travels with.
Today the two agree only because 'Cortex.Wire.Compile' derives both from the
same lowering fragment; that agreement is a construction property of one code
path, not a checked invariant, and it does not hold for circuits built through
other paths (for example "Cortex.Wire.Circuit.Compiler", which passes metadata
through verbatim).

This module makes the agreement checkable. 'admissionArtifactBindsCompiledCircuit'
decides whether an artifact describes a specific compiled circuit:

* __schema__: the artifact carries the current schema version;
* __node set__: artifact summary nodes equal the circuit's node-map domain;
* __topology__: the node-level projection of the artifact's raw connections,
  together with its node rows, rebuilds exactly the circuit topology. The
  port-to-node projection is lossy (several port connections may induce the
  same node edge), so the claim is equality of the projected relation, mirroring
  how the compiler builds the topology from the same connection rows;
* __derived boundary__: the circuit's entry and exit node lists are exactly the
  sources and sinks of its topology. Artifact entries and exits are open
  boundary /ports/ and live at a different abstraction level than entry and
  exit /nodes/; they are bound to the primitive trace by the artifact-internal
  validator, while the node-level boundary is bound here through the topology;
* __metadata attachment__: the circuit metadata embeds exactly this artifact
  under the admission metadata key;
* __select bodies__: every select admission row resolves to a condition node in
  the circuit, and the row's arms reconstruct that node's nested then/else
  fragment tree, including the binary nesting and identity-branch swaps the
  compiler performs. Select arm bodies are not part of the circuit's top-level
  node map, so no other clause reaches them.

Passing this checker does not prove the compiler emitted the artifact, and it
does not validate artifact-internal consistency (use
'Cortex.Wire.AdmissionArtifact.wireAdmissionArtifactValidatorReady' or the Lean
checker for that). It proves that /this/ artifact and /this/ circuit describe
the same graph surface, which turns silent drift between the two into a
detectable failure.
-}
module Cortex.Wire.AdmissionBinding
  ( AdmissionBindingError (..)
  , admissionArtifactBindsCompiledCircuit
  , admissionArtifactProjectedTopology
  , renderAdmissionBindingError
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (traverse_)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Numeric.Natural (Natural)

import Cortex.Algebra.Graph (Relation (..), edges, sinks, sources, toRelation, vertices)
import Cortex.Wire.AST (Connection (..), EndpointRef (..))
import Cortex.Wire.AdmissionArtifact
  ( SelectAdmissionArtifact (..)
  , SelectArmAdmissionArtifact (..)
  , SelectVariantArtifact (..)
  , WireAdmissionArtifact (..)
  , wireAdmissionCurrentSchemaVersion
  , wireAdmissionMetadataKey
  , wireAdmissionMetadataValue
  )
import Cortex.Wire.Circuit.Compiled
  ( CircuitConditionNode (..)
  , CompiledCircuit (..)
  , CompiledCircuitFragment (..)
  , CompiledCircuitNode (..)
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..))

{- | Why an artifact does not bind to a compiled circuit. Constructors carry
the disagreeing values so failures are diagnosable without re-deriving them.
-}
data AdmissionBindingError
  = -- | Artifact schema version, then the expected current version.
    BindingSchemaVersionMismatch !Natural !Natural
  | -- | Nodes only in the artifact summary, then nodes only in the circuit map.
    BindingNodeSetMismatch !(Set CircuitNodeRef) !(Set CircuitNodeRef)
  | {- | Node-level projection of artifact connections, then the circuit topology
    it failed to rebuild.
    -}
    BindingTopologyMismatch !(Relation CircuitNodeRef) !(Relation CircuitNodeRef)
  | -- | Circuit entry-node list, then the topology sources it should equal.
    BindingEntryNodesNotTopologySources ![CircuitNodeRef] ![CircuitNodeRef]
  | -- | Circuit exit-node list, then the topology sinks it should equal.
    BindingExitNodesNotTopologySinks ![CircuitNodeRef] ![CircuitNodeRef]
  | -- | Circuit metadata is not a JSON object, so it cannot embed an artifact.
    BindingMetadataNotObject
  | -- | Circuit metadata has no admission artifact entry.
    BindingMetadataMissingAdmissionKey
  | -- | Circuit metadata embeds a different admission artifact value.
    BindingMetadataArtifactMismatch
  | -- | A select row's condition node is absent from the circuit node map.
    BindingSelectConditionNodeMissing !CircuitNodeRef
  | -- | A select row's condition node resolves to a non-condition circuit node.
    BindingSelectConditionNodeNotCondition !CircuitNodeRef
  | -- | A select condition tree level was reached with fewer than two arms.
    BindingSelectArmGroupTooSmall !CircuitNodeRef
  | {- | Owning condition node, the arm body node set the row claims, then the
    node set the nested fragment actually holds.
    -}
    BindingSelectBranchBodyMismatch !CircuitNodeRef !(Set CircuitNodeRef) !(Set CircuitNodeRef)
  | {- | A branch expected to be pruned (identity arms) carries a fragment, or
    a concrete branch is missing its fragment.
    -}
    BindingSelectBranchShapeMismatch !CircuitNodeRef
  | {- | A branch expected to hold exactly one nested condition node holds
    something else.
    -}
    BindingSelectNestedFragmentShapeMismatch !CircuitNodeRef
  deriving stock (Eq, Show)

-- | Actionable prose for every binding failure, without derived 'Show' dumps.
renderAdmissionBindingError :: AdmissionBindingError -> Text
renderAdmissionBindingError = \case
  BindingSchemaVersionMismatch artifactVersion expectedVersion ->
    "artifact schema version "
      <> showText artifactVersion
      <> " does not match the current version "
      <> showText expectedVersion
  BindingNodeSetMismatch artifactOnly circuitOnly ->
    "artifact and circuit node sets disagree; artifact-only: ["
      <> refSet artifactOnly
      <> "], circuit-only: ["
      <> refSet circuitOnly
      <> "]"
  BindingTopologyMismatch projected actual ->
    "artifact connections do not rebuild the circuit topology; artifact-only edges: ["
      <> edgeSet (Set.difference projected.relEdges actual.relEdges)
      <> "], circuit-only edges: ["
      <> edgeSet (Set.difference actual.relEdges projected.relEdges)
      <> "]"
  BindingEntryNodesNotTopologySources entryNodes topologySources ->
    "circuit entry nodes ["
      <> refList entryNodes
      <> "] do not equal the topology sources ["
      <> refList topologySources
      <> "]"
  BindingExitNodesNotTopologySinks exitNodes topologySinks ->
    "circuit exit nodes ["
      <> refList exitNodes
      <> "] do not equal the topology sinks ["
      <> refList topologySinks
      <> "]"
  BindingMetadataNotObject ->
    "circuit metadata is not a JSON object, so it cannot embed an admission artifact"
  BindingMetadataMissingAdmissionKey ->
    "circuit metadata has no admission artifact entry"
  BindingMetadataArtifactMismatch ->
    "circuit metadata embeds a different admission artifact value"
  BindingSelectConditionNodeMissing nodeRef ->
    atSelect nodeRef "is absent from the circuit node map"
  BindingSelectConditionNodeNotCondition nodeRef ->
    atSelect nodeRef "resolves to a non-condition circuit node"
  BindingSelectArmGroupTooSmall nodeRef ->
    atSelect nodeRef "groups fewer than two arms"
  BindingSelectBranchBodyMismatch nodeRef claimed actual ->
    atSelect nodeRef $
      "claims arm body nodes ["
        <> refSet claimed
        <> "] but the nested fragment holds ["
        <> refSet actual
        <> "]"
  BindingSelectBranchShapeMismatch nodeRef ->
    atSelect nodeRef "has a pruned branch with a fragment or a concrete branch without one"
  BindingSelectNestedFragmentShapeMismatch nodeRef ->
    atSelect nodeRef "has a branch that must hold exactly one nested condition node"
  where
    showText :: Show a => a -> Text
    showText = T.pack . show
    refSet = refList . Set.toAscList
    refList = T.intercalate ", " . fmap (.unCircuitNodeRef)
    edgeSet =
      T.intercalate ", "
        . fmap (\(from, to) -> from.unCircuitNodeRef <> "->" <> to.unCircuitNodeRef)
        . Set.toAscList
    atSelect nodeRef message =
      "select condition node " <> nodeRef.unCircuitNodeRef <> " " <> message

{- | Decide whether @artifact@ describes @circuit@. 'Right' means every binding
clause holds; 'Left' names the first clause that fails. Clauses are ordered
from cheap structural checks to the recursive select-tree walk so that a
coarse disagreement (wrong node set) is reported before a fine one.
-}
admissionArtifactBindsCompiledCircuit
  :: WireAdmissionArtifact -> CompiledCircuit -> Either AdmissionBindingError ()
admissionArtifactBindsCompiledCircuit artifact circuit = do
  bindsSchema artifact
  bindsNodeSet artifact circuit
  bindsTopology artifact circuit
  bindsDerivedBoundary circuit
  bindsMetadataAttachment artifact circuit
  bindsSelectBodies artifact circuit

{- | The node-level topology the artifact claims: its node rows as vertices and
the endpoint-node projection of its raw connections as edges. This mirrors
how the compiler derives 'compiledCircuitTopology' from the lowering
fragment, so for honestly emitted artifacts the projection rebuilds the
circuit topology exactly.
-}
admissionArtifactProjectedTopology :: WireAdmissionArtifact -> Relation CircuitNodeRef
admissionArtifactProjectedTopology artifact =
  toRelation $
    vertices artifact.wireAdmissionNodes
      <> edges
        [ (connection.connectionFrom.endpointNodeRef, connection.connectionTo.endpointNodeRef)
        | connection <- artifact.wireAdmissionConnections
        ]

bindsSchema :: WireAdmissionArtifact -> Either AdmissionBindingError ()
bindsSchema artifact
  | artifact.wireAdmissionSchemaVersion == wireAdmissionCurrentSchemaVersion = Right ()
  | otherwise =
      Left
        ( BindingSchemaVersionMismatch
            artifact.wireAdmissionSchemaVersion
            wireAdmissionCurrentSchemaVersion
        )

bindsNodeSet :: WireAdmissionArtifact -> CompiledCircuit -> Either AdmissionBindingError ()
bindsNodeSet artifact circuit
  | artifactNodes == circuitNodes = Right ()
  | otherwise =
      Left
        ( BindingNodeSetMismatch
            (artifactNodes `Set.difference` circuitNodes)
            (circuitNodes `Set.difference` artifactNodes)
        )
  where
    artifactNodes = Set.fromList artifact.wireAdmissionNodes
    circuitNodes = Map.keysSet circuit.compiledCircuitNodes

bindsTopology :: WireAdmissionArtifact -> CompiledCircuit -> Either AdmissionBindingError ()
bindsTopology artifact circuit
  | projected == circuit.compiledCircuitTopology = Right ()
  | otherwise =
      Left (BindingTopologyMismatch projected circuit.compiledCircuitTopology)
  where
    projected = admissionArtifactProjectedTopology artifact

{- | Entry and exit node lists are derived data: the compiler computes them as
the sources and sinks of the topology. Recomputing them here extends the
topology binding to the boundary fields without equating node-level sources
with the artifact's port-level entry rows, which are a different notion (a
node with no input ports is a source without entry ports; a partially
connected node has an entry port without being a source).
-}
bindsDerivedBoundary :: CompiledCircuit -> Either AdmissionBindingError ()
bindsDerivedBoundary circuit = do
  let derivedEntries = Set.toAscList (sources circuit.compiledCircuitTopology)
      derivedExits = Set.toAscList (sinks circuit.compiledCircuitTopology)
  if circuit.compiledCircuitEntryNodes == derivedEntries
    then Right ()
    else
      Left
        ( BindingEntryNodesNotTopologySources
            circuit.compiledCircuitEntryNodes
            derivedEntries
        )
  if circuit.compiledCircuitExitNodes == derivedExits
    then Right ()
    else
      Left
        ( BindingExitNodesNotTopologySinks
            circuit.compiledCircuitExitNodes
            derivedExits
        )

bindsMetadataAttachment
  :: WireAdmissionArtifact -> CompiledCircuit -> Either AdmissionBindingError ()
bindsMetadataAttachment artifact circuit =
  case circuit.compiledCircuitMetadata of
    Aeson.Object metadataObject ->
      case KeyMap.lookup (Key.fromText wireAdmissionMetadataKey) metadataObject of
        Nothing -> Left BindingMetadataMissingAdmissionKey
        Just storedValue
          | storedValue == wireAdmissionMetadataValue artifact -> Right ()
          | otherwise -> Left BindingMetadataArtifactMismatch
    _nonObjectMetadata -> Left BindingMetadataNotObject

{- | What a group of select arms must compile to on one side of a binary
condition node: nothing (all arms are identity and the branch is pruned), a
concrete arm body, or a nested condition node owning the remaining arms.
-}
data SelectGroupShape
  = SelectGroupIdentity
  | SelectGroupBody !(Set CircuitNodeRef)
  | SelectGroupNested ![SelectArmAdmissionArtifact]

{- | Select arm bodies live inside the condition node's then/else fragments,
not in the circuit's top-level node map, so the node-set and topology
clauses never see them. This clause replays the compiler's binary tree
construction over the row's arms and checks each level against the nested
compiled fragments.
-}
bindsSelectBodies
  :: WireAdmissionArtifact -> CompiledCircuit -> Either AdmissionBindingError ()
bindsSelectBodies artifact circuit =
  traverse_ checkSelectRow artifact.wireAdmissionSelects
  where
    checkSelectRow selectRow = do
      let conditionRef = selectRow.selectAdmissionConditionNode
      conditionNode <-
        case Map.lookup conditionRef circuit.compiledCircuitNodes of
          Nothing -> Left (BindingSelectConditionNodeMissing conditionRef)
          Just (CompiledCircuitCondition conditionNode) -> Right conditionNode
          Just _otherNode -> Left (BindingSelectConditionNodeNotCondition conditionRef)
      let orderedArms = selectArmsInVariantOrder selectRow
      checkConditionTree conditionRef orderedArms conditionNode

    selectArmsInVariantOrder selectRow =
      sortOn armOrder selectRow.selectAdmissionArms
      where
        variantOrder =
          Map.fromList
            (zip (fmap (.selectVariantKey) selectRow.selectAdmissionVariants) [0 :: Int ..])
        armOrder arm =
          ( Map.findWithDefault maxBound arm.selectArmCanonicalKey variantOrder
          , arm.selectArmSourceIndex
          )

    -- Mirrors buildSelectConditionTree: the first arm forms the then group,
    -- the remaining arms the else group, recursing for nested groups.
    checkConditionTree
      :: CircuitNodeRef
      -> [SelectArmAdmissionArtifact]
      -> CircuitConditionNode
      -> Either AdmissionBindingError ()
    checkConditionTree ownerRef arms conditionNode =
      case arms of
        firstArm : restArms@(_ : _) -> do
          let thenShape = groupShape [firstArm]
              elseShape = groupShape restArms
          -- Mirrors buildBinarySelectConditionNode: a pruned then branch
          -- swaps with a concrete else branch. Both branches pruned is
          -- rejected at compile time, so it cannot bind.
          (chosenThen, chosenElse) <-
            case (thenShape, elseShape) of
              (SelectGroupIdentity, SelectGroupIdentity) ->
                Left (BindingSelectBranchShapeMismatch ownerRef)
              (SelectGroupIdentity, concreteElse) ->
                Right (concreteElse, SelectGroupIdentity)
              shapes ->
                Right shapes
          matchThenBranch ownerRef chosenThen conditionNode.circuitConditionNodeThenFragment
          matchElseBranch ownerRef chosenElse conditionNode.circuitConditionNodeElseFragment
        _tooFewArms ->
          Left (BindingSelectArmGroupTooSmall ownerRef)

    groupShape arms =
      case arms of
        [arm]
          | identityArm arm -> SelectGroupIdentity
          | otherwise -> SelectGroupBody (Set.fromList arm.selectArmBodyNodes)
        _groupArms
          | all identityArm arms -> SelectGroupIdentity
          | otherwise -> SelectGroupNested arms

    -- Mirrors isIdentityFragment over the persisted row: an identity arm body
    -- has no nodes and exposes no boundary.
    identityArm arm =
      null arm.selectArmBodyNodes
        && null arm.selectArmBodyEntries
        && null arm.selectArmBodyExits

    matchThenBranch ownerRef shape fragment =
      case shape of
        SelectGroupIdentity ->
          -- The compiler rejects condition nodes whose then branch is not
          -- concrete, so an identity shape can only mean the row and the
          -- circuit disagree.
          Left (BindingSelectBranchShapeMismatch ownerRef)
        SelectGroupBody expectedBody ->
          matchBodyFragment ownerRef expectedBody fragment
        SelectGroupNested nestedArms ->
          matchNestedFragment ownerRef nestedArms fragment

    matchElseBranch ownerRef shape maybeFragment =
      case (shape, maybeFragment) of
        (SelectGroupIdentity, Nothing) -> Right ()
        (SelectGroupIdentity, Just _fragment) ->
          Left (BindingSelectBranchShapeMismatch ownerRef)
        (_concreteShape, Nothing) ->
          Left (BindingSelectBranchShapeMismatch ownerRef)
        (SelectGroupBody expectedBody, Just fragment) ->
          matchBodyFragment ownerRef expectedBody fragment
        (SelectGroupNested nestedArms, Just fragment) ->
          matchNestedFragment ownerRef nestedArms fragment

    matchBodyFragment ownerRef expectedBody fragment
      | fragmentNodes == expectedBody = Right ()
      | otherwise =
          Left (BindingSelectBranchBodyMismatch ownerRef expectedBody fragmentNodes)
      where
        fragmentNodes = Map.keysSet fragment.compiledCircuitFragmentNodes

    matchNestedFragment ownerRef nestedArms fragment =
      case Map.toList fragment.compiledCircuitFragmentNodes of
        [(_nestedRef, CompiledCircuitCondition nestedCondition)] ->
          checkConditionTree ownerRef nestedArms nestedCondition
        _otherNodes ->
          Left (BindingSelectNestedFragmentShapeMismatch ownerRef)
