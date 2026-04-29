{- |
Module      : Logos.Types
Description : Canonical epistemological archetypes for Logos.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

These values define semantic expectations for modes of cognition. They do
not register executors, grant tool authority, or define runtime contracts.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Types
  ( LogosArchetype (..)
  , LogosArchetypeDefinition (..)
  , LogosCapabilityBundle (..)
  , LogosCapabilityBundleStatus (..)
  , LogosCapabilityComponent (..)
  , LogosCapabilityComponentKind (..)
  , allLogosArchetypeDefinitions
  , allLogosArchetypes
  , logosArchetypeDefinition
  , logosCapabilityBundleFor
  )
where

import Data.Text (Text)
import Data.Text qualified as T

data LogosArchetype
  = Logos
  | Sophia
  | Techne
  | Episteme
  | Kritikos
  | Themis
  | Poiesis
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data LogosArchetypeDefinition = LogosArchetypeDefinition
  { logosArchetypeDefinitionArchetype :: LogosArchetype
  , logosArchetypeDefinitionPath :: Text
  , logosArchetypeDefinitionRole :: Text
  , logosArchetypeDefinitionFrameworks :: [Text]
  , logosArchetypeDefinitionSummary :: Text
  , logosArchetypeDefinitionUseWhen :: Text
  }
  deriving stock (Eq, Show)

data LogosCapabilityComponentKind
  = LogosPromptDiscipline
  | LogosRetrievalCorpus
  | LogosEmbeddingSpace
  | LogosToolSurface
  | LogosEvaluationCriteria
  | LogosMemoryPolicy
  | LogosRuntimeContract
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data LogosCapabilityComponent = LogosCapabilityComponent
  { logosCapabilityComponentKind :: LogosCapabilityComponentKind
  , logosCapabilityComponentDescription :: Text
  }
  deriving stock (Eq, Show)

data LogosCapabilityBundle = LogosCapabilityBundle
  { logosCapabilityBundleArchetype :: LogosArchetype
  , logosCapabilityBundlePath :: Text
  , logosCapabilityBundleStatus :: LogosCapabilityBundleStatus
  , logosCapabilityBundleDefinition :: LogosArchetypeDefinition
  , logosCapabilityBundleComponents :: [LogosCapabilityComponent]
  }
  deriving stock (Eq, Show)

data LogosCapabilityBundleStatus
  = LogosCapabilityBundleStub
  deriving stock (Eq, Show)

allLogosArchetypes :: [LogosArchetype]
allLogosArchetypes = [minBound .. maxBound]

allLogosArchetypeDefinitions :: [LogosArchetypeDefinition]
allLogosArchetypeDefinitions = fmap logosArchetypeDefinition allLogosArchetypes

logosCapabilityBundleFor :: LogosArchetype -> LogosCapabilityBundle
logosCapabilityBundleFor archetype =
  let definition = logosArchetypeDefinition archetype
   in LogosCapabilityBundle
        { logosCapabilityBundleArchetype = archetype
        , logosCapabilityBundlePath = logosArchetypeDefinitionPath definition <> ".Activation"
        , logosCapabilityBundleStatus = LogosCapabilityBundleStub
        , logosCapabilityBundleDefinition = definition
        , logosCapabilityBundleComponents = defaultLogosCapabilityBundleComponents
        }

defaultLogosCapabilityBundleComponents :: [LogosCapabilityComponent]
defaultLogosCapabilityBundleComponents =
  fmap logosCapabilityComponent [minBound .. maxBound]

logosCapabilityComponent :: LogosCapabilityComponentKind -> LogosCapabilityComponent
logosCapabilityComponent kind =
  LogosCapabilityComponent
    { logosCapabilityComponentKind = kind
    , logosCapabilityComponentDescription = logosCapabilityComponentDescriptionFor kind
    }

logosCapabilityComponentDescriptionFor :: LogosCapabilityComponentKind -> Text
logosCapabilityComponentDescriptionFor LogosPromptDiscipline =
  "Prompt discipline and instruction shape for the epistemic mode."
logosCapabilityComponentDescriptionFor LogosRetrievalCorpus =
  "Curated source corpus and corpus weighting policy for retrieval."
logosCapabilityComponentDescriptionFor LogosEmbeddingSpace =
  "Embedding spaces and indexes specialized for the epistemic mode."
logosCapabilityComponentDescriptionFor LogosToolSurface =
  "Tool permissions and tool descriptions available under the capability."
logosCapabilityComponentDescriptionFor LogosEvaluationCriteria =
  "Evaluation checks used to judge outputs produced under the capability."
logosCapabilityComponentDescriptionFor LogosMemoryPolicy =
  "Memory selection, retention, decay, and provenance policy."
logosCapabilityComponentDescriptionFor LogosRuntimeContract =
  "Runtime contract that states structural obligations for the mode."

logosArchetypeDefinition :: LogosArchetype -> LogosArchetypeDefinition
logosArchetypeDefinition Logos =
  LogosArchetypeDefinition
    { logosArchetypeDefinitionArchetype = Logos
    , logosArchetypeDefinitionPath = logosArchetypePath Logos
    , logosArchetypeDefinitionRole = "Discursive reason, argument, symbolic reasoning"
    , logosArchetypeDefinitionFrameworks =
        [ "Self-consistency"
        , "Tree of Thoughts"
        ]
    , logosArchetypeDefinitionSummary =
        "Makes reasoning explicit as structured claims, premises, inference, and explanation."
    , logosArchetypeDefinitionUseWhen =
        "Use for argumentation, derivation, conceptual analysis, formalization, or disciplined reasoning."
    }
logosArchetypeDefinition Sophia =
  LogosArchetypeDefinition
    { logosArchetypeDefinitionArchetype = Sophia
    , logosArchetypeDefinitionPath = logosArchetypePath Sophia
    , logosArchetypeDefinitionRole = "Wisdom, judgment, synthesis"
    , logosArchetypeDefinitionFrameworks =
        [ "LLM-as-a-judge"
        , "Multi-agent debate"
        ]
    , logosArchetypeDefinitionSummary =
        "Weighs competing goods, recognizes context, identifies salience, and synthesizes under uncertainty."
    , logosArchetypeDefinitionUseWhen =
        "Use for prioritization, strategic judgment, synthesis, trade-off analysis, or conclusion selection."
    }
logosArchetypeDefinition Techne =
  LogosArchetypeDefinition
    { logosArchetypeDefinitionArchetype = Techne
    , logosArchetypeDefinitionPath = logosArchetypePath Techne
    , logosArchetypeDefinitionRole = "Craft, engineering, implementation"
    , logosArchetypeDefinitionFrameworks =
        [ "SWE-agent"
        , "CodeAct"
        , "Tool-use frameworks"
        ]
    , logosArchetypeDefinitionSummary =
        "Turns understanding into working artifacts, executable plans, interfaces, tests, and systems."
    , logosArchetypeDefinitionUseWhen =
        "Use for engineering execution, code generation, system design, refactoring, or implementation."
    }
logosArchetypeDefinition Episteme =
  LogosArchetypeDefinition
    { logosArchetypeDefinitionArchetype = Episteme
    , logosArchetypeDefinitionPath = logosArchetypePath Episteme
    , logosArchetypeDefinitionRole = "Knowledge, evidence, research"
    , logosArchetypeDefinitionFrameworks =
        [ "ReAct"
        , "Tool-use agents"
        , "Information retrieval"
        ]
    , logosArchetypeDefinitionSummary =
        "Grounds cognition in what is known, observed, measured, cited, or otherwise supported."
    , logosArchetypeDefinitionUseWhen =
        "Use for research, evidence gathering, factual validation, source comparison, or knowledge-base construction."
    }
logosArchetypeDefinition Kritikos =
  LogosArchetypeDefinition
    { logosArchetypeDefinitionArchetype = Kritikos
    , logosArchetypeDefinitionPath = logosArchetypePath Kritikos
    , logosArchetypeDefinitionRole = "Criticism, adversarial review"
    , logosArchetypeDefinitionFrameworks =
        [ "Constitutional AI"
        , "Red-teaming"
        ]
    , logosArchetypeDefinitionSummary =
        "Applies constructive severity to expose weak claims, hidden assumptions, contradictions, and failure modes."
    , logosArchetypeDefinitionUseWhen =
        "Use for opposition, falsification, stress testing, risk discovery, adversarial review, or critique."
    }
logosArchetypeDefinition Themis =
  LogosArchetypeDefinition
    { logosArchetypeDefinitionArchetype = Themis
    , logosArchetypeDefinitionPath = logosArchetypePath Themis
    , logosArchetypeDefinitionRole = "Audit, law, correctness, constraints"
    , logosArchetypeDefinitionFrameworks =
        [ "AI safety"
        , "Constitutional AI"
        , "Alignment"
        ]
    , logosArchetypeDefinitionSummary =
        "Ensures reasoning and action remain within defined bounds, contracts, policies, and invariants."
    , logosArchetypeDefinitionUseWhen =
        "Use for validation, auditability, compliance, correctness checking, permissioning, or constraints."
    }
logosArchetypeDefinition Poiesis =
  LogosArchetypeDefinition
    { logosArchetypeDefinitionArchetype = Poiesis
    , logosArchetypeDefinitionPath = logosArchetypePath Poiesis
    , logosArchetypeDefinitionRole = "Creative generation, composition"
    , logosArchetypeDefinitionFrameworks =
        [ "Creative generation"
        , "Story-telling agents"
        ]
    , logosArchetypeDefinitionSummary =
        "Brings forth new forms, alternatives, narratives, designs, and generative possibilities."
    , logosArchetypeDefinitionUseWhen =
        "Use for invention, naming, storytelling, design exploration, creative synthesis, or generative expansion."
    }

logosArchetypePath :: LogosArchetype -> Text
logosArchetypePath archetype = "Logos.Archetypes." <> T.pack (show archetype)
