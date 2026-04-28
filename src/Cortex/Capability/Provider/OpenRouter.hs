{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Capability.Provider.OpenRouter
  ( buildOpenRouterRequestPayload,
    defaultMaxOutputTokens,
    openRouterChoiceToCortex,
    openRouterUsageToCortex,
    sourceLinksFromAnnotations,
    parseCostValue,
    parseOpenRouterContent,
    parseOpenRouterMessage,
    parseFunctionPayload,
    parseSourceLinkAnnotation,
  )
where

import Cortex.Capability.Model.Types
  ( CortexChoice (..),
    CortexGroundingMode (..),
    CortexResponseFormat (..),
    CortexToolCall (..),
    CortexUsage (..),
  )
import Cortex.Capability.Provider.OpenRouter.Wire
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Pair)
import Data.Text (Text)

defaultMaxOutputTokens :: Int
defaultMaxOutputTokens = 8192

-- | Convert an OpenRouter wire choice to a provider-neutral CortexChoice.
openRouterChoiceToCortex :: OpenRouterChoice -> CortexChoice
openRouterChoiceToCortex choice =
  CortexChoice
    { cortexChoiceContent = choice.openRouterContent,
      cortexChoiceSourceLinks = choice.openRouterSourceLinks,
      cortexChoiceToolCalls = fmap openRouterToolCallToCortex choice.openRouterToolCalls,
      cortexChoiceFinishReason = choice.openRouterFinishReason,
      cortexChoiceUsage = fmap openRouterUsageToCortex choice.openRouterUsage,
      cortexChoiceReasoning = choice.openRouterReasoning,
      cortexChoiceReasoningDetails = choice.openRouterReasoningDetails
    }

openRouterToolCallToCortex :: OpenRouterToolCall -> CortexToolCall
openRouterToolCallToCortex call =
  CortexToolCall
    { cortexToolCallId = call.openRouterToolCallId,
      cortexToolCallName = call.openRouterToolCallName,
      cortexToolCallArguments = call.openRouterToolCallArguments
    }

-- | Convert OpenRouter wire usage to provider-neutral CortexUsage.
openRouterUsageToCortex :: OpenRouterUsage -> CortexUsage
openRouterUsageToCortex usage =
  CortexUsage
    { cortexInputTokens = usage.openRouterInputTokens,
      cortexOutputTokens = usage.openRouterOutputTokens,
      cortexTotalTokens = usage.openRouterTotalTokens,
      cortexCostUsd = usage.openRouterCostUsd
    }

buildOpenRouterRequestPayload :: Text -> CortexGroundingMode -> [Aeson.Value] -> [Aeson.Value] -> CortexResponseFormat -> Int -> Bool -> Aeson.Value
buildOpenRouterRequestPayload modelId groundingMode messages tools responseFormat maxTokens reasoningEnabled =
  Aeson.object
    ( [ "model" .= modelId,
        "messages" .= messages,
        "tools" .= tools,
        "tool_choice" .= ("auto" :: Text),
        "max_tokens" .= maxTokens
      ]
        <> responseFormatFields responseFormat
        <> groundingPluginFields groundingMode
        <> reasoningFields reasoningEnabled
    )

reasoningFields :: Bool -> [Pair]
reasoningFields False = []
reasoningFields True =
  [ "reasoning"
      .= Aeson.object
        [ "effort" .= ("high" :: Text)
        ]
  ]

groundingPluginFields :: CortexGroundingMode -> [Pair]
groundingPluginFields GroundingDisabled = []
groundingPluginFields GroundingEnabled =
  [ "plugins"
      .= [ Aeson.object
             [ "id" .= ("web" :: Text),
               "max_results" .= (5 :: Int)
             ]
         ]
  ]

responseFormatFields :: CortexResponseFormat -> [Pair]
responseFormatFields CortexResponseText = []
responseFormatFields CortexResponseJsonObject =
  [ "response_format"
      .= Aeson.object
        [ "type" .= ("json_object" :: Text)
        ]
  ]
responseFormatFields (CortexResponseJsonSchema schemaName schemaValue) =
  [ "response_format"
      .= Aeson.object
        [ "type" .= ("json_schema" :: Text),
          "json_schema"
            .= Aeson.object
              [ "name" .= schemaName,
                "strict" .= True,
                "schema" .= schemaValue
              ]
        ]
  ]
