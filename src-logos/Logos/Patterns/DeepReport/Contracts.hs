{- |
Module      : Logos.Patterns.DeepReport.Contracts
Description : Generic DeepReport contract catalog.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

These contract specs describe reusable reasoning payload boundaries. They do
not register executors, grant tool authority, or define downstream artifact
persistence behavior.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Patterns.DeepReport.Contracts
  ( deepReportWireContractRegistry
  , deepReportWireContractSpecs
  , deepReportPlannerOutputContract
  , deepReportPlannerRewriteNeededContract
  , deepReportEvidenceBundleContract
  , deepReportEvidenceReadyContract
  , deepReportEvidenceRepairNeededContract
  , deepReportConditionPassthroughContract
  , deepReportAnalysisFragmentContract
  , deepReportReportFragmentContract
  , deepReportReviewBundleContract
  , deepReportReviewConcernsContract
  , deepReportReportArtifactRefContract
  , deepReportWorkflowAuditContract
  , deepReportAwaitSignalContract
  )
where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Text (Text)

import Cortex.Wire
  ( WireContractRegistry
  , WireContractSpec (..)
  , WirePayloadKind (..)
  , wireContractRegistryFromList
  )

deepReportWireContractRegistry :: WireContractRegistry
deepReportWireContractRegistry =
  wireContractRegistryFromList deepReportWireContractSpecs

deepReportWireContractSpecs :: [WireContractSpec]
deepReportWireContractSpecs =
  [ deepReportPlannerOutputContract
  , deepReportPlannerRewriteNeededContract
  , deepReportEvidenceBundleContract
  , deepReportEvidenceReadyContract
  , deepReportEvidenceRepairNeededContract
  , deepReportConditionPassthroughContract
  , deepReportAnalysisFragmentContract
  , deepReportReportFragmentContract
  , deepReportReviewBundleContract
  , deepReportReviewConcernsContract
  , deepReportReportArtifactRefContract
  , deepReportWorkflowAuditContract
  , deepReportAwaitSignalContract
  ]

deepReportPlannerOutputContract :: WireContractSpec
deepReportPlannerOutputContract =
  contractSpec
    "PlannerOutput"
    WirePayloadJson
    "Planner decomposition, launch inputs, workflow request, universe hints, and stage setup context."
    (objectPayloadSchema "Planner output payload.")
    [Aeson.object ["request" .= ("Analyze the selected universe." :: Text)]]

deepReportPlannerRewriteNeededContract :: WireContractSpec
deepReportPlannerRewriteNeededContract =
  contractSpec
    "PlannerRewriteNeeded"
    WirePayloadJson
    "Planner output payload that should be routed through the adjust branch before synthesis."
    (objectPayloadSchema "Planner output payload that requests rewrite-driven expansion.")
    []

deepReportEvidenceBundleContract :: WireContractSpec
deepReportEvidenceBundleContract =
  contractSpec
    "EvidenceBundle"
    WirePayloadJson
    "Gathered evidence, source references, required-evidence status, and market/context data."
    (objectPayloadSchema "Gatherer output payload.")
    []

deepReportEvidenceReadyContract :: WireContractSpec
deepReportEvidenceReadyContract =
  contractSpec
    "EvidenceReady"
    WirePayloadJson
    "Evidence bundle that has already passed the required-evidence gate and is safe to feed into downstream analysis."
    (objectPayloadSchema "Required-evidence-gated gatherer payload.")
    []

deepReportEvidenceRepairNeededContract :: WireContractSpec
deepReportEvidenceRepairNeededContract =
  contractSpec
    "EvidenceRepairNeeded"
    WirePayloadJson
    "Evidence bundle that failed the required-evidence gate and must be repaired before downstream analysis."
    (objectPayloadSchema "Gatherer payload that still needs required-evidence repair.")
    []

deepReportConditionPassthroughContract :: WireContractSpec
deepReportConditionPassthroughContract =
  contractSpec
    "ConditionPassthrough"
    WirePayloadJson
    "Condition boundary pass-through payload used after a conditional repair branch."
    (objectPayloadSchema "Condition pass-through payload.")
    []

deepReportAnalysisFragmentContract :: WireContractSpec
deepReportAnalysisFragmentContract =
  contractSpec
    "AnalysisFragment"
    WirePayloadJson
    "Analysis payload emitted by analyst-like nodes, including thesis assessment, evidence references, and open gaps."
    (objectPayloadSchema "Analyst output payload.")
    []

deepReportReportFragmentContract :: WireContractSpec
deepReportReportFragmentContract =
  contractSpec
    "ReportFragment"
    WirePayloadJson
    "Compiled report section draft with section identity, prose, findings, tables, references, and open gaps."
    (objectPayloadSchema "Section output payload.")
    []

deepReportReviewBundleContract :: WireContractSpec
deepReportReviewBundleContract =
  contractSpec
    "ReviewBundle"
    WirePayloadJson
    "Reviewed report bundle or publish-gate output ready for report artifact emission."
    (objectPayloadSchema "Reviewer output payload.")
    []

deepReportReviewConcernsContract :: WireContractSpec
deepReportReviewConcernsContract =
  contractSpec
    "ReviewConcerns"
    WirePayloadJson
    "Structured critique emitted by the review node: slot, status (clean|has_concerns), and a list of concerns. No text field - the review node cannot rewrite."
    (objectPayloadSchema "Review concerns payload.")
    []

deepReportReportArtifactRefContract :: WireContractSpec
deepReportReportArtifactRefContract =
  contractSpec
    "ReportArtifactRef"
    WirePayloadArtifactRef
    "Persisted artifact reference produced by an emit node."
    (objectPayloadSchema "Artifact output payload.")
    []

deepReportWorkflowAuditContract :: WireContractSpec
deepReportWorkflowAuditContract =
  contractSpec
    "WorkflowAudit"
    WirePayloadJson
    "Workflow audit result payload for run-quality and evidence-quality assessment."
    (objectPayloadSchema "Audit output payload.")
    []

deepReportAwaitSignalContract :: WireContractSpec
deepReportAwaitSignalContract =
  contractSpec
    "AwaitSignal"
    WirePayloadJson
    "Signal payload emitted by await boundaries."
    (objectPayloadSchema "Await signal payload.")
    []

contractSpec :: Text -> WirePayloadKind -> Text -> Aeson.Value -> [Aeson.Value] -> WireContractSpec
contractSpec contractId payloadKind description schema examples =
  WireContractSpec
    { wireContractSpecId = contractId
    , wireContractSpecPayloadKind = payloadKind
    , wireContractSpecDescription = description
    , wireContractSpecSchema = Just schema
    , wireContractSpecExamples = examples
    }

objectPayloadSchema :: Text -> Aeson.Value
objectPayloadSchema description =
  Aeson.object
    [ "type" .= ("object" :: Text)
    , "description" .= description
    , "additionalProperties" .= True
    ]
