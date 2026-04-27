{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Canonical epistemological archetypes for Cortex.Nous.
--
-- These values define semantic expectations for modes of cognition. They do
-- not register executors, grant tool authority, or define runtime contracts.
module Cortex.Nous.Types
  ( NousArchetype (..),
    NousArchetypeDefinition (..),
    NousCapabilityBundle (..),
    NousCapabilityBundleStatus (..),
    NousCapabilityComponent (..),
    NousCapabilityComponentKind (..),
    allNousArchetypeDefinitions,
    allNousArchetypes,
    nousArchetypeDefinition,
    nousCapabilityBundle,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

data NousArchetype
  = Logos
  | Sophia
  | Techne
  | Episteme
  | Kritikos
  | Themis
  | Poiesis
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data NousArchetypeDefinition = NousArchetypeDefinition
  { nousArchetypeDefinitionArchetype :: NousArchetype,
    nousArchetypeDefinitionPath :: Text,
    nousArchetypeDefinitionRole :: Text,
    nousArchetypeDefinitionFrameworks :: [Text],
    nousArchetypeDefinitionSummary :: Text,
    nousArchetypeDefinitionUseWhen :: Text
  }
  deriving stock (Eq, Show)

data NousCapabilityComponentKind
  = NousPromptDiscipline
  | NousRetrievalCorpus
  | NousEmbeddingSpace
  | NousToolSurface
  | NousEvaluationCriteria
  | NousMemoryPolicy
  | NousRuntimeContract
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data NousCapabilityComponent = NousCapabilityComponent
  { nousCapabilityComponentKind :: NousCapabilityComponentKind,
    nousCapabilityComponentDescription :: Text
  }
  deriving stock (Eq, Show)

data NousCapabilityBundle = NousCapabilityBundle
  { nousCapabilityBundleArchetype :: NousArchetype,
    nousCapabilityBundlePath :: Text,
    nousCapabilityBundleStatus :: NousCapabilityBundleStatus,
    nousCapabilityBundleDefinition :: NousArchetypeDefinition,
    nousCapabilityBundleComponents :: [NousCapabilityComponent]
  }
  deriving stock (Eq, Show)

data NousCapabilityBundleStatus
  = NousCapabilityBundleStub
  deriving stock (Eq, Show)

allNousArchetypes :: [NousArchetype]
allNousArchetypes = [minBound .. maxBound]

allNousArchetypeDefinitions :: [NousArchetypeDefinition]
allNousArchetypeDefinitions = fmap nousArchetypeDefinition allNousArchetypes

nousCapabilityBundle :: NousArchetype -> NousCapabilityBundle
nousCapabilityBundle archetype =
  let definition = nousArchetypeDefinition archetype
   in NousCapabilityBundle
        { nousCapabilityBundleArchetype = archetype,
          nousCapabilityBundlePath = nousArchetypeDefinitionPath definition <> ".Capability",
          nousCapabilityBundleStatus = NousCapabilityBundleStub,
          nousCapabilityBundleDefinition = definition,
          nousCapabilityBundleComponents = defaultNousCapabilityBundleComponents
        }

defaultNousCapabilityBundleComponents :: [NousCapabilityComponent]
defaultNousCapabilityBundleComponents =
  fmap nousCapabilityComponent [minBound .. maxBound]

nousCapabilityComponent :: NousCapabilityComponentKind -> NousCapabilityComponent
nousCapabilityComponent kind =
  NousCapabilityComponent
    { nousCapabilityComponentKind = kind,
      nousCapabilityComponentDescription = nousCapabilityComponentDescriptionFor kind
    }

nousCapabilityComponentDescriptionFor :: NousCapabilityComponentKind -> Text
nousCapabilityComponentDescriptionFor NousPromptDiscipline =
  "Prompt discipline and instruction shape for the epistemic mode."
nousCapabilityComponentDescriptionFor NousRetrievalCorpus =
  "Curated source corpus and corpus weighting policy for retrieval."
nousCapabilityComponentDescriptionFor NousEmbeddingSpace =
  "Embedding spaces and indexes specialized for the epistemic mode."
nousCapabilityComponentDescriptionFor NousToolSurface =
  "Tool permissions and tool descriptions available under the capability."
nousCapabilityComponentDescriptionFor NousEvaluationCriteria =
  "Evaluation checks used to judge outputs produced under the capability."
nousCapabilityComponentDescriptionFor NousMemoryPolicy =
  "Memory selection, retention, decay, and provenance policy."
nousCapabilityComponentDescriptionFor NousRuntimeContract =
  "Runtime contract that states structural obligations for the mode."

nousArchetypeDefinition :: NousArchetype -> NousArchetypeDefinition
nousArchetypeDefinition Logos =
  NousArchetypeDefinition
    { nousArchetypeDefinitionArchetype = Logos,
      nousArchetypeDefinitionPath = nousArchetypePath Logos,
      nousArchetypeDefinitionRole = "Discursive reason, argument, symbolic reasoning",
      nousArchetypeDefinitionFrameworks =
        [ "Self-consistency",
          "Tree of Thoughts"
        ],
      nousArchetypeDefinitionSummary =
        "Makes reasoning explicit as structured claims, premises, inference, and explanation.",
      nousArchetypeDefinitionUseWhen =
        "Use for argumentation, derivation, conceptual analysis, formalization, or disciplined reasoning."
    }
nousArchetypeDefinition Sophia =
  NousArchetypeDefinition
    { nousArchetypeDefinitionArchetype = Sophia,
      nousArchetypeDefinitionPath = nousArchetypePath Sophia,
      nousArchetypeDefinitionRole = "Wisdom, judgment, synthesis",
      nousArchetypeDefinitionFrameworks =
        [ "LLM-as-a-judge",
          "Multi-agent debate"
        ],
      nousArchetypeDefinitionSummary =
        "Weighs competing goods, recognizes context, identifies salience, and synthesizes under uncertainty.",
      nousArchetypeDefinitionUseWhen =
        "Use for prioritization, strategic judgment, synthesis, trade-off analysis, or conclusion selection."
    }
nousArchetypeDefinition Techne =
  NousArchetypeDefinition
    { nousArchetypeDefinitionArchetype = Techne,
      nousArchetypeDefinitionPath = nousArchetypePath Techne,
      nousArchetypeDefinitionRole = "Craft, engineering, implementation",
      nousArchetypeDefinitionFrameworks =
        [ "SWE-agent",
          "CodeAct",
          "Tool-use frameworks"
        ],
      nousArchetypeDefinitionSummary =
        "Turns understanding into working artifacts, executable plans, interfaces, tests, and systems.",
      nousArchetypeDefinitionUseWhen =
        "Use for engineering execution, code generation, system design, refactoring, or implementation."
    }
nousArchetypeDefinition Episteme =
  NousArchetypeDefinition
    { nousArchetypeDefinitionArchetype = Episteme,
      nousArchetypeDefinitionPath = nousArchetypePath Episteme,
      nousArchetypeDefinitionRole = "Knowledge, evidence, research",
      nousArchetypeDefinitionFrameworks =
        [ "ReAct",
          "Tool-use agents",
          "Information retrieval"
        ],
      nousArchetypeDefinitionSummary =
        "Grounds cognition in what is known, observed, measured, cited, or otherwise supported.",
      nousArchetypeDefinitionUseWhen =
        "Use for research, evidence gathering, factual validation, source comparison, or knowledge-base construction."
    }
nousArchetypeDefinition Kritikos =
  NousArchetypeDefinition
    { nousArchetypeDefinitionArchetype = Kritikos,
      nousArchetypeDefinitionPath = nousArchetypePath Kritikos,
      nousArchetypeDefinitionRole = "Criticism, adversarial review",
      nousArchetypeDefinitionFrameworks =
        [ "Constitutional AI",
          "Red-teaming"
        ],
      nousArchetypeDefinitionSummary =
        "Applies constructive severity to expose weak claims, hidden assumptions, contradictions, and failure modes.",
      nousArchetypeDefinitionUseWhen =
        "Use for opposition, falsification, stress testing, risk discovery, adversarial review, or critique."
    }
nousArchetypeDefinition Themis =
  NousArchetypeDefinition
    { nousArchetypeDefinitionArchetype = Themis,
      nousArchetypeDefinitionPath = nousArchetypePath Themis,
      nousArchetypeDefinitionRole = "Audit, law, correctness, constraints",
      nousArchetypeDefinitionFrameworks =
        [ "AI safety",
          "Constitutional AI",
          "Alignment"
        ],
      nousArchetypeDefinitionSummary =
        "Ensures reasoning and action remain within defined bounds, contracts, policies, and invariants.",
      nousArchetypeDefinitionUseWhen =
        "Use for validation, auditability, compliance, correctness checking, permissioning, or constraints."
    }
nousArchetypeDefinition Poiesis =
  NousArchetypeDefinition
    { nousArchetypeDefinitionArchetype = Poiesis,
      nousArchetypeDefinitionPath = nousArchetypePath Poiesis,
      nousArchetypeDefinitionRole = "Creative generation, composition",
      nousArchetypeDefinitionFrameworks =
        [ "Creative generation",
          "Story-telling agents"
        ],
      nousArchetypeDefinitionSummary =
        "Brings forth new forms, alternatives, narratives, designs, and generative possibilities.",
      nousArchetypeDefinitionUseWhen =
        "Use for invention, naming, storytelling, design exploration, creative synthesis, or generative expansion."
    }

nousArchetypePath :: NousArchetype -> Text
nousArchetypePath archetype = "Cortex.Nous." <> T.pack (show archetype)
