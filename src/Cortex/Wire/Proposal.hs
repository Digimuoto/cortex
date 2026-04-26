{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Wire.Proposal
  ( WireAppendHole (..),
    WireProposalError (..),
    wireProposalErrorCategory,
    renderWireProposalError,
    normalizeWireProposalResponse,
    wireProposalGrammarReference,
    wireProposalSingleNodeExample,
    wireProposalSingleNodeShorthandExample,
    wireProposalInvalidMissingGraphExample,
    wireProposalInvalidOuterReferenceExample,
    compileWireAppendProposalWithEnv,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (when)
import Cortex.Circuit.Artifact (CircuitConditionNode (..), CompiledCircuit (..), CompiledCircuitNode (..))
import Cortex.Circuit.IR
  ( CircuitArtifactBoundary (..),
    CircuitNodeRef (..),
    CircuitRewriteBoundary (..),
    CircuitSignalBoundary (..),
    CircuitTaskNode (..),
  )
import Cortex.Wire.Contract (WireCompileEnv, wirePortsFromMetadataValue)
import Cortex.Wire.Syntax
import Cortex.Wire.V1 qualified as WireV1
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (traverse_)
import Data.List (dropWhileEnd)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

data WireAppendHole = WireAppendHole
  { wireAppendHoleAnchor :: !CircuitNodeRef,
    wireAppendHoleAnchorPorts :: !WirePorts,
    wireAppendHoleSuccessors :: !(Map CircuitNodeRef WirePorts)
  }
  deriving stock (Eq, Show)

data WireProposalError
  = WireProposalParseError !Text
  | WireProposalScopeError !Text
  | WireProposalShapeError !Text
  | WireProposalCompileError !WireError
  | WireProposalHoleFitError !Text
  deriving stock (Eq, Show)

wireProposalErrorCategory :: WireProposalError -> Text
wireProposalErrorCategory = \case
  WireProposalParseError _ -> "wire_parse_rejected"
  WireProposalScopeError _ -> "wire_scope_rejected"
  WireProposalShapeError _ -> "wire_shape_rejected"
  WireProposalCompileError err -> wireCompileErrorCategory err
  WireProposalHoleFitError _ -> "wire_hole_fit_rejected"

wireCompileErrorCategory :: WireError -> Text
wireCompileErrorCategory = \case
  WireParseError {} -> "wire_parse_rejected"
  WireNoCompatiblePorts {} -> "wire_type_rejected"
  WirePortContractMismatch {} -> "wire_type_rejected"
  WireAmbiguousCompatiblePorts {} -> "wire_type_rejected"
  WireMissingDefaultInputPort {} -> "wire_type_rejected"
  WireMissingDefaultOutputPort {} -> "wire_type_rejected"
  WireUnknownPort {} -> "wire_type_rejected"
  WireUnknownContract {} -> "wire_type_rejected"
  _ -> "wire_lowering_rejected"

renderWireProposalError :: WireProposalError -> Text
renderWireProposalError = \case
  WireProposalParseError errText -> "Wire proposal parse error: " <> errText
  WireProposalScopeError errText -> "Wire proposal scope error: " <> errText
  WireProposalShapeError errText -> "Wire proposal shape error: " <> errText
  WireProposalCompileError err -> renderWireError err
  WireProposalHoleFitError errText -> "Wire proposal hole-fit error: " <> errText

normalizeWireProposalResponse :: Text -> Text
normalizeWireProposalResponse =
  stabilize . T.strip
  where
    stabilize sourceText =
      let normalized = T.strip (normalizeOnce sourceText)
       in if normalized == sourceText
            then normalized
            else stabilize normalized

normalizeOnce :: Text -> Text
normalizeOnce sourceText =
  fromMaybeText sourceText $
    unwrapFence sourceText <|> unwrapJsonWrapper sourceText

fromMaybeText :: Text -> Maybe Text -> Text
fromMaybeText = fromMaybe

unwrapFence :: Text -> Maybe Text
unwrapFence sourceText = do
  firstLine : remainingLines <- pure (T.lines sourceText)
  guardText ("```" `T.isPrefixOf` T.stripStart firstLine)
  let trimmedLines = dropWhileEnd isFenceLine remainingLines
  pure (T.unlines trimmedLines)
  where
    isFenceLine lineText = "```" `T.isPrefixOf` T.strip lineText

unwrapJsonWrapper :: Text -> Maybe Text
unwrapJsonWrapper sourceText = do
  Aeson.Object payload <- Aeson.decodeStrict' (TE.encodeUtf8 sourceText)
  listToMaybe
    ( mapMaybe
        ( \fieldName ->
            case KeyMap.lookup (Key.fromText fieldName) payload of
              Just (Aeson.String innerText) -> Just innerText
              _ -> Nothing
        )
        ["source", "circuitSource", "proposal", "wire", "rawResponse"]
    )

guardText :: Bool -> Maybe ()
guardText True = Just ()
guardText False = Nothing

compileWireAppendProposalWithEnv ::
  WireCompileEnv ->
  WireAppendHole ->
  Text ->
  Either WireProposalError CompiledCircuit
compileWireAppendProposalWithEnv compileEnv appendHole rawSource = do
  compiled <-
    mapLeft
      WireProposalCompileError
      (WireV1.compileWireFragmentTextWithEnv compileEnv rawSource)
  nodePorts <- proposalPortsCatalogFromCompiled compiled
  validateAppendHole appendHole nodePorts compiled
  Right compiled

proposalPortsCatalogFromCompiled :: CompiledCircuit -> Either WireProposalError (Map CircuitNodeRef WirePorts)
proposalPortsCatalogFromCompiled compiled =
  traverse extractNodePorts compiled.compiledCircuitNodes
  where
    extractNodePorts = \case
      CompiledCircuitTask taskNode ->
        extractPortsFromMetadata taskNode.circuitTaskNodeRef taskNode.circuitTaskNodeMetadata
      CompiledCircuitSignal signalBoundary ->
        extractPortsFromMetadata signalBoundary.circuitSignalBoundaryRef signalBoundary.circuitSignalMetadata
      CompiledCircuitArtifact artifactBoundary ->
        extractPortsFromMetadata artifactBoundary.circuitArtifactBoundaryRef artifactBoundary.circuitArtifactMetadata
      CompiledCircuitRewriteBoundary rewriteBoundary ->
        extractPortsFromMetadata rewriteBoundary.circuitRewriteBoundaryRef rewriteBoundary.circuitRewriteMetadata
      CompiledCircuitCondition conditionNode ->
        extractPortsFromMetadata conditionNode.circuitConditionNodeRef conditionNode.circuitConditionNodeMetadata
    extractPortsFromMetadata nodeRef metadataValue = do
      metadataObj <-
        case metadataValue of
          Aeson.Object obj -> Right obj
          _ ->
            Left
              ( WireProposalHoleFitError
                  ( "proposal node "
                      <> unCircuitNodeRef nodeRef
                      <> " did not lower to object metadata with ports"
                  )
              )
      portsValue <-
        maybe
          (Left (WireProposalHoleFitError ("proposal node " <> unCircuitNodeRef nodeRef <> " has no lowered ports metadata")))
          Right
          (KeyMap.lookup (Key.fromText "ports") metadataObj)
      case wirePortsFromMetadataValue portsValue of
        Left errText ->
          Left
            ( WireProposalHoleFitError
                ( "proposal node "
                    <> unCircuitNodeRef nodeRef
                    <> " has invalid lowered ports metadata: "
                    <> errText
                )
            )
        Right ports -> Right ports

validateAppendHole ::
  WireAppendHole ->
  Map CircuitNodeRef WirePorts ->
  CompiledCircuit ->
  Either WireProposalError ()
validateAppendHole appendHole proposalPorts compiled = do
  when (null compiled.compiledCircuitEntryNodes) $
    Left (WireProposalHoleFitError "proposal has no entry nodes")
  when (null compiled.compiledCircuitExitNodes) $
    Left (WireProposalHoleFitError "proposal has no exit nodes")
  traverse_ validateEntry compiled.compiledCircuitEntryNodes
  traverse_ validateExit compiled.compiledCircuitExitNodes
  where
    validateEntry entryRef = do
      entryPorts <- lookupProposalPorts entryRef
      let compatibleContracts = portContractOverlap appendHole.wireAppendHoleAnchorPorts entryPorts
      when (null compatibleContracts) $
        Left
          ( WireProposalHoleFitError
              ( renderEntryHoleFitFailure
                  appendHole
                  entryRef
                  entryPorts
                  compatibleContracts
              )
          )
    validateExit exitRef = do
      exitPorts <- lookupProposalPorts exitRef
      traverse_
        (validateExitSuccessor exitRef exitPorts)
        (Map.toAscList appendHole.wireAppendHoleSuccessors)
    validateExitSuccessor exitRef exitPorts (successorRef, successorPorts) =
      let compatibleContracts = portContractOverlap exitPorts successorPorts
       in when (null compatibleContracts) $
            Left
              ( WireProposalHoleFitError
                  ( renderExitHoleFitFailure
                      exitRef
                      exitPorts
                      successorRef
                      successorPorts
                      compatibleContracts
                  )
              )
    lookupProposalPorts nodeRef =
      case Map.lookup nodeRef proposalPorts of
        Just ports -> Right ports
        Nothing ->
          Left
            ( WireProposalHoleFitError
                ( "proposal node "
                    <> unCircuitNodeRef nodeRef
                    <> " has no resolved ports"
                )
            )

portContractOverlap :: WirePorts -> WirePorts -> [Text]
portContractOverlap sourcePorts sinkPorts =
  Set.toAscList . Set.fromList $
    [ outputPort.wireOutputPortContract
    | outputPort <- Map.elems sourcePorts.wirePortsOutputs,
      inputPort <- Map.elems sinkPorts.wirePortsInputs,
      outputPort.wireOutputPortContract `elem` inputPort.wireInputPortAccepts
    ]

renderEntryHoleFitFailure ::
  WireAppendHole ->
  CircuitNodeRef ->
  WirePorts ->
  [Text] ->
  Text
renderEntryHoleFitFailure appendHole entryRef entryPorts compatibleContracts =
  T.intercalate
    "\n"
    [ "Entry hole-fit failed: anchor "
        <> unCircuitNodeRef appendHole.wireAppendHoleAnchor
        <> " cannot feed proposal entry "
        <> unCircuitNodeRef entryRef
        <> ".",
      "Hole-fit rule: the first inserted node must accept at least one contract emitted by the anchor.",
      "Anchor outputs: " <> renderOutputPorts appendHole.wireAppendHoleAnchorPorts,
      "Entry inputs: " <> renderInputPorts entryPorts,
      "Shared contracts: " <> renderContractList compatibleContracts,
      "Proposal-local config overrides do not change ports or contracts."
    ]

renderExitHoleFitFailure ::
  CircuitNodeRef ->
  WirePorts ->
  CircuitNodeRef ->
  WirePorts ->
  [Text] ->
  Text
renderExitHoleFitFailure exitRef exitPorts successorRef successorPorts compatibleContracts =
  T.intercalate
    "\n"
    [ "Exit hole-fit failed: proposal exit "
        <> unCircuitNodeRef exitRef
        <> " cannot feed original successor "
        <> unCircuitNodeRef successorRef
        <> ".",
      "Hole-fit rule: every proposal exit must emit at least one contract accepted by every original successor.",
      "Exit outputs: " <> renderOutputPorts exitPorts,
      "Successor inputs: " <> renderInputPorts successorPorts,
      "Shared contracts: " <> renderContractList compatibleContracts,
      "Proposal-local config overrides do not change ports or contracts."
    ]

renderInputPorts :: WirePorts -> Text
renderInputPorts ports =
  if Map.null ports.wirePortsInputs
    then "none"
    else
      T.intercalate
        "; "
        [ portName
            <> " accepts "
            <> renderContractBracketList inputPort.wireInputPortAccepts
            <> " ("
            <> renderInputCardinality inputPort.wireInputPortCardinality
            <> ", "
            <> (if inputPort.wireInputPortRequired then "required" else "optional")
            <> ")"
        | (portName, inputPort) <- Map.toAscList ports.wirePortsInputs
        ]

renderOutputPorts :: WirePorts -> Text
renderOutputPorts ports =
  if Map.null ports.wirePortsOutputs
    then "none"
    else
      T.intercalate
        "; "
        [ portName <> " -> " <> outputPort.wireOutputPortContract
        | (portName, outputPort) <- Map.toAscList ports.wirePortsOutputs
        ]

renderInputCardinality :: WireInputCardinality -> Text
renderInputCardinality = \case
  WireInputCardinalityOne -> "one"
  WireInputCardinalityMany -> "many"

renderContractList :: [Text] -> Text
renderContractList [] = "none"
renderContractList contracts = T.intercalate ", " contracts

renderContractBracketList :: [Text] -> Text
renderContractBracketList contracts = "[" <> renderContractList contracts <> "]"

wireProposalGrammarReference :: Text
wireProposalGrammarReference =
  T.unlines
    [ "proposal ::= (node_decl | let_decl)* final_graph_expr",
      "node_decl ::= node IDENT : port_decl* = @executor { config_fields };",
      "let_decl ::= let IDENT = expr;",
      "final_graph_expr ::= graph_expr   # v1 file-return syntax: no trailing ';' on the final expression",
      "graph_expr ::= node | (graph_expr) | () | graph_expr => graph_expr | graph_expr <> graph_expr | graph_expr, graph_expr",
      "hard constraints: every referenced node must be declared locally in this proposal; graph must be a DAG; proposal entries must fit the anchor outputs; proposal exits must fit every original successor; outer workflow nodes are not in proposal scope."
    ]

wireProposalSingleNodeExample :: Text
wireProposalSingleNodeExample =
  T.unlines
    [ "node audit_pass :",
      "  <- AnalysisFragment",
      "  -> AnalysisFragment",
      "= @auditor {",
      "  prompt = \"Audit the current draft for stale dates and unsupported current-claims.\";",
      "};",
      "audit_pass"
    ]

wireProposalSingleNodeShorthandExample :: Text
wireProposalSingleNodeShorthandExample =
  "node audit_pass : <- AnalysisFragment -> AnalysisFragment = @auditor { prompt = \"Audit the current draft for stale dates and unsupported current-claims.\"; }; audit_pass"

wireProposalInvalidMissingGraphExample :: Text
wireProposalInvalidMissingGraphExample =
  T.unlines
    [ "node probe_a :",
      "  <- PlannerOutput",
      "  -> EvidenceBundle",
      "= @gatherer {",
      "  prompt = \"Fetch the freshest company evidence needed to resolve the key open claim.\";",
      "};",
      "",
      "node audit_pass :",
      "  <- EvidenceBundle",
      "  -> AnalysisFragment",
      "= @auditor {",
      "  prompt = \"Audit the resulting draft for stale dates and unsupported current-claims.\";",
      "};"
    ]

wireProposalInvalidOuterReferenceExample :: Text
wireProposalInvalidOuterReferenceExample =
  T.unlines
    [ "node probe_a :",
      "  <- PlannerOutput",
      "  -> EvidenceBundle",
      "= @gatherer {",
      "  prompt = \"Fetch the freshest dated evidence needed to resolve the key open claim.\";",
      "};",
      "",
      "node audit_pass :",
      "  <- EvidenceBundle",
      "  -> AnalysisFragment",
      "= @auditor {",
      "  prompt = \"Audit the resulting draft for stale dates and unsupported current-claims.\";",
      "};",
      "current_evidence => audit_pass"
    ]

mapLeft :: (err -> err') -> Either err a -> Either err' a
mapLeft f = \case
  Left err -> Left (f err)
  Right value -> Right value
