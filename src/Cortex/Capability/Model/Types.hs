{-# LANGUAGE DerivingStrategies #-}

module Cortex.Capability.Model.Types
  ( CortexChoice (..)
  , CortexChoiceRequest (..)
  , CortexChoiceTimeoutClass (..)
  , CortexGroundingMode (..)
  , CortexResponseFormat (..)
  , CortexToolCall (..)
  , CortexUsage (..)
  )
where

import Data.Aeson qualified as Aeson
import Data.Scientific (Scientific)
import Data.Text (Text)
import GHC.Generics (Generic)

data CortexChoiceTimeoutClass
  = CortexChoiceTimeoutStandard
  | CortexChoiceTimeoutHeavy
  deriving stock (Eq, Show)

data CortexResponseFormat
  = CortexResponseText
  | CortexResponseJsonObject
  | CortexResponseJsonSchema Text Aeson.Value
  deriving stock (Eq, Show)

data CortexGroundingMode
  = GroundingDisabled
  | GroundingEnabled
  deriving stock (Eq, Show)

data CortexChoiceRequest = CortexChoiceRequest
  { cortexChoiceModelId :: Text
  , cortexChoiceGroundingMode :: CortexGroundingMode
  , cortexChoiceMessages :: [Aeson.Value]
  , cortexChoiceTools :: [Aeson.Value]
  , cortexChoiceResponseFormat :: CortexResponseFormat
  , cortexChoiceMaxOutputTokens :: Maybe Int
  , cortexChoiceStageName :: Text
  , cortexChoiceAgentName :: Maybe Text
  , cortexChoiceStepIndex :: Maybe Int
  , cortexChoiceSectionId :: Maybe Text
  , cortexChoiceAttempt :: Maybe Int
  , cortexChoiceTimeoutClass :: CortexChoiceTimeoutClass
  , cortexChoiceReasoningEnabled :: Bool
  }
  deriving stock (Eq, Show)

data CortexChoice = CortexChoice
  { cortexChoiceContent :: Text
  , cortexChoiceSourceLinks :: [(Text, Text)]
  , cortexChoiceToolCalls :: [CortexToolCall]
  , cortexChoiceFinishReason :: Maybe Text
  , cortexChoiceUsage :: Maybe CortexUsage
  , cortexChoiceReasoning :: Maybe Text
  , cortexChoiceReasoningDetails :: Maybe Aeson.Value
  }
  deriving stock (Eq, Show)

data CortexToolCall = CortexToolCall
  { cortexToolCallId :: Text
  , cortexToolCallName :: Text
  , cortexToolCallArguments :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

data CortexUsage = CortexUsage
  { cortexInputTokens :: Maybe Int
  , cortexOutputTokens :: Maybe Int
  , cortexTotalTokens :: Maybe Int
  , cortexCostUsd :: Maybe Scientific
  }
  deriving stock (Eq, Show)
