{- |
Module      : Cortex.Capability.Provider.OpenRouterSpec
Description : Tests for Cortex.Capability.Provider.OpenRouter.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Capability.Provider.OpenRouterSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Cortex.Capability.Model.Output
  ( appendSourcesSection
  , shouldAppendExternalSourceFooter
  )
import Cortex.Capability.Model.Types
  ( CortexChoiceRequest (..)
  , CortexChoiceTimeoutClass (..)
  , CortexGroundingMode (..)
  , CortexResponseFormat (..)
  )
import Cortex.Capability.Provider.OpenRouter
  ( buildOpenRouterRequestPayload
  , defaultMaxOutputTokens
  , sourceLinksFromAnnotations
  )
import Cortex.Capability.Provider.OpenRouter.Client
  ( openRouterRequestPayload
  , openRouterResolvedMaxOutputTokens
  )
import Cortex.Capability.Provider.OpenRouter.Wire
  ( OpenRouterChoice (..)
  , OpenRouterCompletion (..)
  , OpenRouterUsage (..)
  )

spec :: Spec
spec = do
  describe "appendSourcesSection" $ do
    it "returns content unchanged when no sources are present" $ do
      appendSourcesSection "" [] `shouldBe` ""

    it "appends a sources section with markdown links" $ do
      appendSourcesSection
        "Semiconductor equities sold off after weaker macro data."
        [ ("Reuters on jobs data", "https://www.reuters.com/example")
        , ("Fed remarks", "https://www.federalreserve.gov/example")
        ]
        `shouldBe` T.intercalate
          "\n"
          [ "Semiconductor equities sold off after weaker macro data."
          , ""
          , "Sources:"
          , "- [Reuters on jobs data](<https://www.reuters.com/example>)"
          , "- [Fed remarks](<https://www.federalreserve.gov/example>)"
          ]

    it "deduplicates repeated source URLs" $ do
      appendSourcesSection
        "Answer"
        [ ("First title", "https://example.com/a")
        , ("Second title ignored", "https://example.com/a")
        ]
        `shouldBe` T.intercalate
          "\n"
          [ "Answer"
          , ""
          , "Sources:"
          , "- [First title](<https://example.com/a>)"
          ]

    it "adds one extra newline when content already ends with a newline" $ do
      appendSourcesSection
        "Answer\n"
        [("Source", "https://example.com/a")]
        `shouldBe` T.intercalate
          "\n"
          [ "Answer"
          , ""
          , "Sources:"
          , "- [Source](<https://example.com/a>)"
          ]

    it "escapes markdown-sensitive title and URL characters" $ do
      appendSourcesSection
        "Answer"
        [("Source [1]", "https://example.com/a>(b)")]
        `shouldBe` T.intercalate
          "\n"
          [ "Answer"
          , ""
          , "Sources:"
          , "- [Source \\[1\\]](<https://example.com/a\\>(b)>)"
          ]

  describe "shouldAppendExternalSourceFooter" $ do
    it "suppresses external web footers when grounding is disabled" $ do
      shouldAppendExternalSourceFooter GroundingDisabled [("Macroption", "https://example.com")]
        `shouldBe` False

    it "keeps external web footers when grounding is enabled and sources are present" $ do
      shouldAppendExternalSourceFooter GroundingEnabled [("Reuters", "https://example.com")]
        `shouldBe` True

    it "does not append an external footer without sources even when grounding is enabled" $ do
      shouldAppendExternalSourceFooter GroundingEnabled []
        `shouldBe` False

  describe "sourceLinksFromAnnotations" $ do
    it "extracts nested url_citation annotations" $ do
      sourceLinksFromAnnotations
        [ Aeson.object
            [ "type" Aeson..= ("url_citation" :: Text)
            , "url_citation"
                Aeson..= Aeson.object
                  [ "url" Aeson..= ("https://www.reuters.com/example" :: Text)
                  , "title" Aeson..= ("Reuters" :: Text)
                  ]
            ]
        ]
        `shouldBe` [("Reuters", "https://www.reuters.com/example")]

    it "extracts direct url annotations and deduplicates repeated URLs" $ do
      sourceLinksFromAnnotations
        [ Aeson.object
            [ "type" Aeson..= ("url_citation" :: Text)
            , "url" Aeson..= ("https://www.federalreserve.gov/example" :: Text)
            ]
        , Aeson.object
            [ "type" Aeson..= ("url_citation" :: Text)
            , "url" Aeson..= ("https://www.federalreserve.gov/example" :: Text)
            , "title" Aeson..= ("Ignored duplicate label" :: Text)
            ]
        ]
        `shouldBe` [("https://www.federalreserve.gov/example", "https://www.federalreserve.gov/example")]

    it "falls back to the URL when the annotation title is blank" $ do
      sourceLinksFromAnnotations
        [ Aeson.object
            [ "type" Aeson..= ("url_citation" :: Text)
            , "url_citation"
                Aeson..= Aeson.object
                  [ "url" Aeson..= ("https://example.com/fallback" :: Text)
                  , "title" Aeson..= ("   " :: Text)
                  ]
            ]
        ]
        `shouldBe` [("https://example.com/fallback", "https://example.com/fallback")]

  describe "buildOpenRouterRequestPayload" $ do
    it "includes the built-in web plugin when grounding is enabled" $ do
      let payload =
            buildOpenRouterRequestPayload
              "openai/gpt-4o"
              GroundingEnabled
              [ Aeson.object
                  ["role" Aeson..= ("user" :: Text), "content" Aeson..= ("What moved markets today?" :: Text)]
              ]
              []
              CortexResponseText
              defaultMaxOutputTokens
              False
          maybePlugins =
            AesonTypes.parseMaybe
              (Aeson.withObject "payload" (AesonTypes..:? "plugins"))
              payload
              :: Maybe (Maybe [Aeson.Value])
      maybePlugins
        `shouldBe` Just
          ( Just
              [ Aeson.object
                  [ "id" Aeson..= ("web" :: Text)
                  , "max_results" Aeson..= (5 :: Int)
                  ]
              ]
          )

    it "omits the built-in web plugin when grounding is disabled" $ do
      let payload =
            buildOpenRouterRequestPayload
              "openai/gpt-4o"
              GroundingDisabled
              [ Aeson.object
                  ["role" Aeson..= ("user" :: Text), "content" Aeson..= ("Summarize my portfolio." :: Text)]
              ]
              []
              CortexResponseText
              defaultMaxOutputTokens
              False
          maybeModel =
            AesonTypes.parseMaybe
              (Aeson.withObject "payload" (AesonTypes..: "model"))
              payload
              :: Maybe Text
          maybeToolChoice =
            AesonTypes.parseMaybe
              (Aeson.withObject "payload" (AesonTypes..: "tool_choice"))
              payload
              :: Maybe Text
          maybeMaxTokens =
            AesonTypes.parseMaybe
              (Aeson.withObject "payload" (AesonTypes..: "max_tokens"))
              payload
              :: Maybe Int
          maybePlugins =
            AesonTypes.parseMaybe
              (Aeson.withObject "payload" (AesonTypes..:? "plugins"))
              payload
              :: Maybe (Maybe [Aeson.Value])
      maybeModel `shouldBe` Just "openai/gpt-4o"
      maybeToolChoice `shouldBe` Just "auto"
      maybeMaxTokens `shouldBe` Just defaultMaxOutputTokens
      maybePlugins `shouldBe` Just Nothing

    it "includes a json_schema response format and custom max tokens when requested" $ do
      let payload =
            buildOpenRouterRequestPayload
              "openai/gpt-4o"
              GroundingDisabled
              [Aeson.object ["role" Aeson..= ("user" :: Text), "content" Aeson..= ("Return JSON." :: Text)]]
              []
              (CortexResponseJsonSchema "sample" (Aeson.object ["type" Aeson..= ("object" :: Text)]))
              4096
              False
          maybeResponseFormat =
            AesonTypes.parseMaybe
              (Aeson.withObject "payload" (AesonTypes..: "response_format"))
              payload
              :: Maybe Aeson.Value
          maybeMaxTokens =
            AesonTypes.parseMaybe
              (Aeson.withObject "payload" (AesonTypes..: "max_tokens"))
              payload
              :: Maybe Int
      maybeResponseFormat
        `shouldBe` Just
          ( Aeson.object
              [ "type" Aeson..= ("json_schema" :: Text)
              , "json_schema"
                  Aeson..= Aeson.object
                    [ "name" Aeson..= ("sample" :: Text)
                    , "strict" Aeson..= True
                    , "schema" Aeson..= Aeson.object ["type" Aeson..= ("object" :: Text)]
                    ]
              ]
          )
      maybeMaxTokens `shouldBe` Just 4096

  describe "OpenRouter completion decoding" $ do
    it "accepts usage token counts encoded as strings" $ do
      let payload =
            Aeson.object
              [ "choices"
                  Aeson..= [ Aeson.object
                               [ "message"
                                   Aeson..= Aeson.object
                                     [ "content" Aeson..= ("Portfolio risk stayed concentrated in semis." :: Text)
                                     ]
                               ]
                           ]
              , "usage"
                  Aeson..= Aeson.object
                    [ "prompt_tokens" Aeson..= ("157374" :: Text)
                    , "completion_tokens" Aeson..= ("900" :: Text)
                    , "total_tokens" Aeson..= ("158274" :: Text)
                    , "cost" Aeson..= ("0.0495" :: Text)
                    ]
              ]
      case Aeson.fromJSON payload of
        Aeson.Error err ->
          expectationFailure err
        Aeson.Success OpenRouterCompletion {openRouterUsage = usage} -> do
          fmap openRouterInputTokens usage `shouldBe` Just (Just 157374)
          fmap openRouterOutputTokens usage `shouldBe` Just (Just 900)
          fmap openRouterTotalTokens usage `shouldBe` Just (Just 158274)

    it "falls back to choice-root content when message is absent" $ do
      let payload =
            Aeson.object
              [ "choices"
                  Aeson..= [ Aeson.object
                               [ "content" Aeson..= ("Recovered from choice root" :: Text)
                               , "finish_reason" Aeson..= ("stop" :: Text)
                               ]
                           ]
              ]
      case Aeson.fromJSON payload of
        Aeson.Error err ->
          expectationFailure err
        Aeson.Success OpenRouterCompletion {openRouterChoices = choices} ->
          choices
            `shouldBe` [ OpenRouterChoice
                           { openRouterContent = "Recovered from choice root"
                           , openRouterSourceLinks = []
                           , openRouterToolCalls = []
                           , openRouterFinishReason = Just "stop"
                           , openRouterUsage = Nothing
                           , openRouterReasoning = Nothing
                           , openRouterReasoningDetails = Nothing
                           }
                       ]

    it "keeps readable choices when siblings are malformed or empty" $ do
      let payload =
            Aeson.object
              [ "choices"
                  Aeson..= [ Aeson.object ["unexpected" Aeson..= True]
                           , Aeson.object
                               [ "message"
                                   Aeson..= Aeson.object
                                     [ "content" Aeson..= ("Recovered choice" :: Text)
                                     ]
                               ]
                           ]
              , "usage"
                  Aeson..= Aeson.object
                    [ "prompt_tokens" Aeson..= ("broken" :: Text)
                    ]
              ]
      case Aeson.fromJSON payload of
        Aeson.Error err ->
          expectationFailure err
        Aeson.Success OpenRouterCompletion {openRouterChoices = choices, openRouterUsage = usage} -> do
          fmap openRouterContent choices `shouldBe` ["Recovered choice"]
          usage `shouldBe` Nothing

  describe "openRouterRequestPayload" $ do
    it "builds an OpenRouter payload directly from a Cortex choice request" $ do
      let request =
            CortexChoiceRequest
              { cortexChoiceModelId = "openai/gpt-4o"
              , cortexChoiceGroundingMode = GroundingDisabled
              , cortexChoiceMessages =
                  [ Aeson.object
                      [ "role" Aeson..= ("user" :: Text)
                      , "content" Aeson..= ("Summarize this portfolio." :: Text)
                      ]
                  ]
              , cortexChoiceTools = []
              , cortexChoiceResponseFormat = CortexResponseText
              , cortexChoiceMaxOutputTokens = Nothing
              , cortexChoiceStageName = "chat"
              , cortexChoiceAgentName = Nothing
              , cortexChoiceStepIndex = Nothing
              , cortexChoiceSectionId = Nothing
              , cortexChoiceAttempt = Nothing
              , cortexChoiceTimeoutClass = CortexChoiceTimeoutStandard
              , cortexChoiceReasoningEnabled = False
              }
          payload = openRouterRequestPayload request
          maybeMaxTokens =
            AesonTypes.parseMaybe
              (Aeson.withObject "payload" (AesonTypes..: "max_tokens"))
              payload
              :: Maybe Int
          maybeModel =
            AesonTypes.parseMaybe
              (Aeson.withObject "payload" (AesonTypes..: "model"))
              payload
              :: Maybe Text
      maybeModel `shouldBe` Just "openai/gpt-4o"
      openRouterResolvedMaxOutputTokens request `shouldBe` defaultMaxOutputTokens
      maybeMaxTokens `shouldBe` Just defaultMaxOutputTokens

    it "uses the explicit max token override consistently across typed and payload views" $ do
      let request =
            CortexChoiceRequest
              { cortexChoiceModelId = "openai/gpt-4o"
              , cortexChoiceGroundingMode = GroundingDisabled
              , cortexChoiceMessages =
                  [ Aeson.object
                      [ "role" Aeson..= ("user" :: Text)
                      , "content" Aeson..= ("Return JSON." :: Text)
                      ]
                  ]
              , cortexChoiceTools = []
              , cortexChoiceResponseFormat = CortexResponseText
              , cortexChoiceMaxOutputTokens = Just 4096
              , cortexChoiceStageName = "chat"
              , cortexChoiceAgentName = Nothing
              , cortexChoiceStepIndex = Nothing
              , cortexChoiceSectionId = Nothing
              , cortexChoiceAttempt = Nothing
              , cortexChoiceTimeoutClass = CortexChoiceTimeoutStandard
              , cortexChoiceReasoningEnabled = False
              }
          payload = openRouterRequestPayload request
          maybeMaxTokens =
            AesonTypes.parseMaybe
              (Aeson.withObject "payload" (AesonTypes..: "max_tokens"))
              payload
              :: Maybe Int
      openRouterResolvedMaxOutputTokens request `shouldBe` 4096
      maybeMaxTokens `shouldBe` Just 4096
