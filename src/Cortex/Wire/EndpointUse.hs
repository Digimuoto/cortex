{- |
Module      : Cortex.Wire.EndpointUse
Description : Per-endpoint use accounting projected over a Wire admission artifact.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Projects the endpoint-use vocabulary of ADR 0081 (Wire Endpoint Closure
Accounting) over an already-compiled 'WireAdmissionArtifact'. The projection is
derived, not re-decided: it reuses the artifact's primitive node rows (per-node
port shapes), connection edges, and carried boundary obligations rather than
re-walking the final 'CompiledCircuit' node relation, which has already
forgotten port-level detail.

The vocabulary mirrors the proven Lean closed-port model
(@theory/Cortex/Wire/PortLinearity.lean@, @OutputPortUse@/@ClosedPortLinear@):

> input_use  = produced_by_edge | host_input | imported_obligation
> output_use = consumed_by_edge | terminal_discharge

A terminating node is simply a node with no declared output ports; it is not a
separate endpoint-use constructor. The @terminal_discharge@ /kind/
(@exported_boundary@ | @host_return@ | @proof_boundary_sink@) is a
Haskell/CLI-side refinement carried here for inspection and closed-graph
checking; the Lean proof model keeps only the edge-versus-terminal partition.
-}
module Cortex.Wire.EndpointUse
  ( ClosureMode (..)
  , DischargeKind (..)
  , EndpointId (..)
  , InputUse (..)
  , OutputUse (..)
  , InputFrontier (..)
  , OutputFrontier (..)
  , NodeFrontier (..)
  , EndpointUseReport (..)
  , endpointUseReport
  , endpointUseReportFromArtifact
  , lookupNodeFrontier
  , reportUnaccounted
  , renderEndpointUseReportText
  , renderNodeFrontierText
  ) where

import Data.Aeson (ToJSON (toJSON), (.=))
import Data.Aeson qualified as Aeson
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

import Cortex.Wire.AdmissionArtifact
  ( AdmissionBoundaryPort (..)
  , AdmissionEndpointUseWitness (..)
  , AdmissionInputUseKind (..)
  , AdmissionInputUseWitness (..)
  , AdmissionOutputUseKind (..)
  , AdmissionOutputUseWitness (..)
  , AdmissionTerminalDischargeKind (..)
  , PrimitiveGraphStep (..)
  , WireAdmissionArtifact (..)
  , WireAdmissionClosureMode (..)
  , finalizeWireAdmissionArtifact
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..))

{- | Whether a derived report is for a closed executable graph or an open
fragment. Schema-v4 artifacts persist the corresponding closure mode; callers
that derive a report over hand-built artifacts still pass it explicitly.
-}
data ClosureMode
  = ClosedExecutable
  | OpenFragment
  deriving stock (Eq, Show, Generic)

instance ToJSON ClosureMode where
  toJSON = \case
    ClosedExecutable -> Aeson.String "closed_executable"
    OpenFragment -> Aeson.String "open_fragment"

{- | Operational kind of a non-edge output closure. Kept Haskell-side; the Lean
proof partition is edge-versus-terminal only.
-}
data DischargeKind
  = ExportedBoundary
  | HostReturn
  | ProofBoundarySink
  deriving stock (Eq, Show, Generic)

instance ToJSON DischargeKind where
  toJSON = \case
    ExportedBoundary -> Aeson.String "exported_boundary"
    HostReturn -> Aeson.String "host_return"
    ProofBoundarySink -> Aeson.String "proof_boundary_sink"

-- | A concrete endpoint, identified by its node and port name.
data EndpointId = EndpointId
  { endpointIdNode :: !CircuitNodeRef
  , endpointIdPort :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

instance ToJSON EndpointId where
  toJSON endpoint =
    Aeson.object
      [ "node" .= (endpoint.endpointIdNode.unCircuitNodeRef)
      , "port" .= endpoint.endpointIdPort
      ]

-- | How an input endpoint is satisfied.
data InputUse
  = -- | Satisfied by a concrete upstream output edge.
    ProducedByEdge !EndpointId
  | -- | Provided by the executable host at the top-level input boundary.
    HostInput
  | {- | Left open on the frontier; the obligation is imported from the caller.
    Used for open fragments and package interfaces.
    -}
    ImportedObligation
  | -- | No producer and not an open import: a missing upstream (diagnostic).
    InputUnaccounted
  deriving stock (Eq, Show, Generic)

instance ToJSON InputUse where
  toJSON = \case
    ProducedByEdge endpoint ->
      Aeson.object ["use" .= ("produced_by_edge" :: Text), "from" .= endpoint]
    HostInput ->
      Aeson.object ["use" .= ("host_input" :: Text)]
    ImportedObligation ->
      Aeson.object ["use" .= ("imported_obligation" :: Text)]
    InputUnaccounted ->
      Aeson.object ["use" .= ("unaccounted" :: Text)]

-- | How an output endpoint is accounted for.
data OutputUse
  = {- | Consumed by a concrete downstream input edge. Covers transforms and
    terminating nodes alike (a terminating node is reached by an ordinary
    edge).
    -}
    ConsumedByEdge !EndpointId
  | -- | A non-edge closure of the output, classified by kind.
    TerminalDischarge !DischargeKind
  | -- | Neither consumed nor a recognised discharge (diagnostic).
    OutputUnaccounted
  deriving stock (Eq, Show, Generic)

instance ToJSON OutputUse where
  toJSON = \case
    ConsumedByEdge endpoint ->
      Aeson.object ["use" .= ("consumed_by_edge" :: Text), "to" .= endpoint]
    TerminalDischarge kind ->
      Aeson.object ["use" .= ("terminal_discharge" :: Text), "kind" .= kind]
    OutputUnaccounted ->
      Aeson.object ["use" .= ("unaccounted" :: Text)]

-- | One input port of a node, with its accounting.
data InputFrontier = InputFrontier
  { inputFrontierPort :: !AdmissionBoundaryPort
  , inputFrontierUse :: !InputUse
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON InputFrontier where
  toJSON frontier =
    Aeson.object
      [ "port" .= frontier.inputFrontierPort.admissionBoundaryPort
      , "contract" .= frontier.inputFrontierPort.admissionBoundaryContract
      , "accounting" .= frontier.inputFrontierUse
      ]

-- | One output port of a node, with its accounting.
data OutputFrontier = OutputFrontier
  { outputFrontierPort :: !AdmissionBoundaryPort
  , outputFrontierUse :: !OutputUse
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON OutputFrontier where
  toJSON frontier =
    Aeson.object
      [ "port" .= frontier.outputFrontierPort.admissionBoundaryPort
      , "contract" .= frontier.outputFrontierPort.admissionBoundaryContract
      , "accounting" .= frontier.outputFrontierUse
      ]

-- | The endpoint accounting local to a single node.
data NodeFrontier = NodeFrontier
  { nodeFrontierRef :: !CircuitNodeRef
  , nodeFrontierInputs :: ![InputFrontier]
  , nodeFrontierOutputs :: ![OutputFrontier]
  , nodeFrontierTerminating :: !Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON NodeFrontier where
  toJSON frontier =
    Aeson.object
      [ "node" .= frontier.nodeFrontierRef.unCircuitNodeRef
      , "terminating" .= frontier.nodeFrontierTerminating
      , "inputs" .= frontier.nodeFrontierInputs
      , "outputs" .= frontier.nodeFrontierOutputs
      ]

-- | The whole-graph endpoint-use report.
data EndpointUseReport = EndpointUseReport
  { reportClosure :: !ClosureMode
  , reportNodes :: ![NodeFrontier]
  , reportHostInputs :: ![AdmissionBoundaryPort]
  , reportImportedObligations :: ![AdmissionBoundaryPort]
  , reportTerminalDischarges :: ![(AdmissionBoundaryPort, DischargeKind)]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON EndpointUseReport where
  toJSON report =
    Aeson.object
      [ "closure" .= report.reportClosure
      , "nodes" .= report.reportNodes
      , "hostInputs"
          .= fmap (.admissionBoundaryPort) report.reportHostInputs
      , "importedObligations"
          .= fmap (.admissionBoundaryPort) report.reportImportedObligations
      , "terminalDischarges"
          .= fmap
            ( \(boundary, kind) ->
                Aeson.object
                  [ "node" .= boundary.admissionBoundaryNode.unCircuitNodeRef
                  , "port" .= boundary.admissionBoundaryPort
                  , "kind" .= kind
                  ]
            )
            report.reportTerminalDischarges
      ]

{- | Project the ADR 0081 endpoint-use vocabulary over a compiled admission
artifact. Pure and total: every declared port is classified.
-}
endpointUseReport :: ClosureMode -> WireAdmissionArtifact -> EndpointUseReport
endpointUseReport closure artifact =
  endpointUseReportFromArtifact $
    finalizeWireAdmissionArtifact (closureModeToAdmission closure) artifact

closureModeToAdmission :: ClosureMode -> WireAdmissionClosureMode
closureModeToAdmission = \case
  ClosedExecutable -> AdmissionClosedExecutable
  OpenFragment -> AdmissionOpenFragment

-- | Render the endpoint-use witness persisted in a validator-ready admission artifact.
endpointUseReportFromArtifact :: WireAdmissionArtifact -> EndpointUseReport
endpointUseReportFromArtifact artifact =
  EndpointUseReport
    { reportClosure = closureModeFromAdmission artifact.wireAdmissionClosureMode
    , reportNodes = fmap nodeFrontierFor nodeRows
    , reportHostInputs =
        [ input.admissionInputUsePort
        | input <- artifact.wireAdmissionEndpointUses.admissionEndpointInputUses
        , AdmissionHostInput <- [input.admissionInputUseKind]
        ]
    , reportImportedObligations =
        [ input.admissionInputUsePort
        | input <- artifact.wireAdmissionEndpointUses.admissionEndpointInputUses
        , AdmissionImportedObligation <- [input.admissionInputUseKind]
        ]
    , reportTerminalDischarges =
        [ (output.admissionOutputUsePort, terminalKindFromAdmission kind)
        | output <- artifact.wireAdmissionEndpointUses.admissionEndpointOutputUses
        , AdmissionTerminalDischarge kind <- [output.admissionOutputUseKind]
        ]
    }
  where
    nodeRows =
      [ (node, inputs, outputs)
      | PrimitiveNode node inputs outputs <- artifact.wireAdmissionPrimitiveSteps
      ]

    inputUses =
      Map.fromList
        [ (boundaryKey input.admissionInputUsePort, inputUseFromAdmission input.admissionInputUseKind)
        | input <- artifact.wireAdmissionEndpointUses.admissionEndpointInputUses
        ]

    outputUses =
      Map.fromList
        [ (boundaryKey output.admissionOutputUsePort, outputUseFromAdmission output.admissionOutputUseKind)
        | output <- artifact.wireAdmissionEndpointUses.admissionEndpointOutputUses
        ]

    nodeFrontierFor (node, inputs, outputs) =
      NodeFrontier
        { nodeFrontierRef = node
        , nodeFrontierInputs =
            fmap
              ( \input ->
                  InputFrontier input $
                    fromMaybe InputUnaccounted (Map.lookup (boundaryKey input) inputUses)
              )
              inputs
        , nodeFrontierOutputs =
            fmap
              ( \output ->
                  OutputFrontier output $
                    fromMaybe OutputUnaccounted (Map.lookup (boundaryKey output) outputUses)
              )
              outputs
        , nodeFrontierTerminating = null outputs
        }

    boundaryKey boundary =
      (boundary.admissionBoundaryNode, boundary.admissionBoundaryPort)

    closureModeFromAdmission = \case
      AdmissionClosedExecutable -> ClosedExecutable
      AdmissionOpenFragment -> OpenFragment

    inputUseFromAdmission = \case
      AdmissionProducedByEdge fromPort ->
        ProducedByEdge (EndpointId fromPort.admissionBoundaryNode fromPort.admissionBoundaryPort)
      AdmissionHostInput -> HostInput
      AdmissionImportedObligation -> ImportedObligation

    outputUseFromAdmission = \case
      AdmissionConsumedByEdge toPort ->
        ConsumedByEdge (EndpointId toPort.admissionBoundaryNode toPort.admissionBoundaryPort)
      AdmissionTerminalDischarge kind ->
        TerminalDischarge (terminalKindFromAdmission kind)

    terminalKindFromAdmission = \case
      AdmissionExportedBoundary -> ExportedBoundary
      AdmissionHostReturn -> HostReturn
      AdmissionProofBoundarySink -> ProofBoundarySink

-- | The local frontier of one node, if present in the report.
lookupNodeFrontier :: CircuitNodeRef -> EndpointUseReport -> Maybe NodeFrontier
lookupNodeFrontier ref report =
  find ((== ref) . (.nodeFrontierRef)) report.reportNodes

{- | Endpoints with no admissible accounting: inputs with no producer, host
input, or imported obligation; and outputs neither consumed nor discharged.
Empty for a well-formed graph or open fragment.
-}
reportUnaccounted :: EndpointUseReport -> ([EndpointId], [EndpointId])
reportUnaccounted report =
  ( [ EndpointId node.nodeFrontierRef input.inputFrontierPort.admissionBoundaryPort
    | node <- report.reportNodes
    , input <- node.nodeFrontierInputs
    , InputUnaccounted <- [input.inputFrontierUse]
    ]
  , [ EndpointId node.nodeFrontierRef output.outputFrontierPort.admissionBoundaryPort
    | node <- report.reportNodes
    , output <- node.nodeFrontierOutputs
    , OutputUnaccounted <- [output.outputFrontierUse]
    ]
  )

-- | Human-readable single-node rendering.
renderNodeFrontierText :: NodeFrontier -> Text
renderNodeFrontierText frontier =
  T.unlines $
    ["node " <> frontier.nodeFrontierRef.unCircuitNodeRef <> terminatingTag]
      <> fmap renderInput frontier.nodeFrontierInputs
      <> fmap renderOutput frontier.nodeFrontierOutputs
  where
    terminatingTag = if frontier.nodeFrontierTerminating then "  (terminating)" else ""

    renderInput input =
      "  in  "
        <> input.inputFrontierPort.admissionBoundaryPort
        <> " : "
        <> input.inputFrontierPort.admissionBoundaryContract
        <> "  <- "
        <> renderInputUse input.inputFrontierUse

    renderOutput output =
      "  out "
        <> output.outputFrontierPort.admissionBoundaryPort
        <> " : "
        <> output.outputFrontierPort.admissionBoundaryContract
        <> "  -> "
        <> renderOutputUse output.outputFrontierUse

    renderInputUse = \case
      ProducedByEdge from -> "produced_by_edge " <> renderEndpoint from
      HostInput -> "host_input"
      ImportedObligation -> "imported_obligation (open)"
      InputUnaccounted -> "MISSING UPSTREAM"

    renderOutputUse = \case
      ConsumedByEdge to -> "consumed_by_edge " <> renderEndpoint to
      TerminalDischarge kind -> "terminal_discharge (" <> renderKind kind <> ")"
      OutputUnaccounted -> "UNACCOUNTED"

    renderKind = \case
      ExportedBoundary -> "exported_boundary"
      HostReturn -> "host_return"
      ProofBoundarySink -> "proof_boundary_sink"

    renderEndpoint endpoint =
      endpoint.endpointIdNode.unCircuitNodeRef <> "." <> endpoint.endpointIdPort

-- | Human-readable whole-graph rendering.
renderEndpointUseReportText :: EndpointUseReport -> Text
renderEndpointUseReportText report =
  T.intercalate "\n" $
    fmap renderNodeFrontierText report.reportNodes <> [summary]
  where
    (missingInputs, unaccountedOutputs) = reportUnaccounted report
    summary =
      T.unlines
        [ "frontier: "
            <> T.pack (show (length report.reportHostInputs))
            <> " host input(s), "
            <> T.pack (show (length report.reportImportedObligations))
            <> " imported obligation(s), "
            <> T.pack (show (length report.reportTerminalDischarges))
            <> " terminal discharge(s)"
        , "unaccounted: "
            <> T.pack (show (length missingInputs))
            <> " missing upstream, "
            <> T.pack (show (length unaccountedOutputs))
            <> " unaccounted output(s)"
        ]
