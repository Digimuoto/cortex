module Cortex.Capability.Provider.OpenRouter.Wire
  ( OpenRouterCompletion (..)
  , OpenRouterUsage (..)
  , OpenRouterChoice (..)
  , OpenRouterToolCall (..)
  , parseCostValue
  , parseFunctionPayload
  , parseOpenRouterContent
  , parseOpenRouterMessage
  , parseSourceLinkAnnotation
  , sourceLinksFromAnnotations
  )
where

import Control.Applicative ((<|>))
import Control.Monad (join, unless, (>=>))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Foldable (asum)
import Data.Maybe (fromMaybe, isJust, isNothing, mapMaybe)
import Data.Scientific (Scientific)
import Data.Scientific qualified as Scientific
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Text.Read (readMaybe)

import Platform.Serde.Json.Text
  ( jsonValueText
  )

data OpenRouterCompletion = OpenRouterCompletion
  { openRouterChoices :: [OpenRouterChoice]
  , openRouterUsage :: Maybe OpenRouterUsage
  }
  deriving stock (Eq, Show)

data OpenRouterUsage = OpenRouterUsage
  { openRouterInputTokens :: Maybe Int
  , openRouterOutputTokens :: Maybe Int
  , openRouterTotalTokens :: Maybe Int
  , openRouterCostUsd :: Maybe Scientific
  }
  deriving stock (Eq, Show)

data OpenRouterChoice = OpenRouterChoice
  { openRouterContent :: Text
  , openRouterSourceLinks :: [(Text, Text)]
  , openRouterToolCalls :: [OpenRouterToolCall]
  , openRouterFinishReason :: Maybe Text
  , openRouterUsage :: Maybe OpenRouterUsage
  , openRouterReasoning :: Maybe Text
  , openRouterReasoningDetails :: Maybe Aeson.Value
  }
  deriving stock (Eq, Show)

data OpenRouterToolCall = OpenRouterToolCall
  { openRouterToolCallId :: Text
  , openRouterToolCallName :: Text
  , openRouterToolCallArguments :: Text
  }
  deriving stock (Eq, Show)

instance Aeson.FromJSON OpenRouterCompletion where
  parseJSON = Aeson.withObject "OpenRouterCompletion" $ \o -> do
    maybeChoicesValue <- o Aeson..:? "choices"
    maybeUsageValue <- o Aeson..:? "usage"
    let rawChoices =
          case maybeChoicesValue of
            Just (Aeson.Array arr) -> V.toList arr
            Just (Aeson.Object obj) -> [Aeson.Object obj]
            _ -> []
    pure
      OpenRouterCompletion
        { openRouterChoices =
            filter isMeaningfulOpenRouterChoice $
              mapMaybe (parseMaybe Aeson.parseJSON) rawChoices
        , openRouterUsage = maybeUsageValue >>= parseMaybe Aeson.parseJSON >>= meaningfulOpenRouterUsage
        }

instance Aeson.FromJSON OpenRouterUsage where
  parseJSON = Aeson.withObject "OpenRouterUsage" $ \o ->
    OpenRouterUsage
      <$> parseOptionalIntField o ["prompt_tokens", "input_tokens"]
      <*> parseOptionalIntField o ["completion_tokens", "output_tokens"]
      <*> parseOptionalIntField o ["total_tokens"]
      <*> pure (lookupOptionalValue o "cost" >>= parseMaybe parseCostValue)

instance Aeson.FromJSON OpenRouterChoice where
  parseJSON = Aeson.withObject "OpenRouterChoice" $ \o -> do
    let messageValue =
          case lookupOptionalValue o "message" of
            Just Aeson.Null -> Aeson.Object o
            Just value -> value
            Nothing -> Aeson.Object o
        finishReason =
          case lookupOptionalValue o "finish_reason" of
            Just Aeson.Null -> Nothing
            Just (Aeson.String txt) -> Just txt
            Just other -> Just (jsonValueText other)
            Nothing -> Nothing
    (content, sourceLinks, toolCalls) <- parseOpenRouterMessage messageValue
    let reasoning = case messageValue of
          Aeson.Object msgObj ->
            case KeyMap.lookup "reasoning" msgObj of
              Just (Aeson.String r) | not (T.null (T.strip r)) -> Just r
              _ -> Nothing
          _ -> Nothing
        reasoningDetails = case messageValue of
          Aeson.Object msgObj -> KeyMap.lookup "reasoning_details" msgObj
          _ -> Nothing
    pure
      OpenRouterChoice
        { openRouterContent = content
        , openRouterSourceLinks = sourceLinks
        , openRouterToolCalls = toolCalls
        , openRouterFinishReason = finishReason
        , openRouterUsage =
            lookupOptionalValue o "usage" >>= parseMaybe Aeson.parseJSON >>= meaningfulOpenRouterUsage
        , openRouterReasoning = reasoning
        , openRouterReasoningDetails = reasoningDetails
        }

instance Aeson.FromJSON OpenRouterToolCall where
  parseJSON = Aeson.withObject "OpenRouterToolCall" $ \o -> do
    callId <- o Aeson..: "id"
    functionValue <- o Aeson..: "function"
    (name, argumentsText) <- parseFunctionPayload functionValue
    pure
      OpenRouterToolCall
        { openRouterToolCallId = callId
        , openRouterToolCallName = name
        , openRouterToolCallArguments = argumentsText
        }

parseCostValue :: Aeson.Value -> Parser Scientific
parseCostValue = \case
  Aeson.Number value -> pure value
  Aeson.String rawValue ->
    case readMaybe (T.unpack rawValue) of
      Just value -> pure value
      Nothing -> fail ("Invalid OpenRouter cost value: " <> T.unpack rawValue)
  other -> fail ("Invalid OpenRouter cost JSON type: " <> show other)

parseOpenRouterMessage :: Aeson.Value -> Parser (Text, [(Text, Text)], [OpenRouterToolCall])
parseOpenRouterMessage = Aeson.withObject "OpenRouterMessage" $ \o -> do
  contentValue <- o Aeson..:? "content"
  annotations <- o Aeson..:? "annotations" Aeson..!= []
  toolCalls <- o Aeson..:? "tool_calls" Aeson..!= []
  (content, contentSourceLinks) <- maybe (pure ("", [])) parseOpenRouterContent contentValue
  let annotationSourceLinks = sourceLinksFromAnnotations annotations
  pure (content, dedupeSourceLinks (annotationSourceLinks <> contentSourceLinks), toolCalls)

parseOpenRouterContent :: Aeson.Value -> Parser (Text, [(Text, Text)])
parseOpenRouterContent Aeson.Null = pure ("", [])
parseOpenRouterContent (Aeson.String txt) = pure (txt, [])
parseOpenRouterContent (Aeson.Array arr) =
  pure . foldl combineParts ("", []) . fmap extractPart $ V.toList arr
  where
    combineParts (textAcc, sourceLinksAcc) (partText, partSourceLinks) =
      (textAcc <> partText, sourceLinksAcc <> partSourceLinks)
    extractPart (Aeson.String txt) = (txt, [])
    extractPart (Aeson.Object obj) =
      let partText =
            fromMaybe
              ""
              ( parseMaybe (Aeson..: "text") obj
                  <|> parseMaybe (Aeson..: "content") obj
              )
          partSourceLinks =
            fromMaybe
              []
              (parseMaybe (\value -> value Aeson..:? "annotations" Aeson..!= []) obj)
       in (partText, sourceLinksFromAnnotations partSourceLinks)
    extractPart _ = ("", [])
parseOpenRouterContent other = pure (jsonValueText other, [])

parseFunctionPayload :: Aeson.Value -> Parser (Text, Text)
parseFunctionPayload = Aeson.withObject "OpenRouterFunctionPayload" $ \o -> do
  name <- o Aeson..: "name"
  argsValue <- o Aeson..:? "arguments" Aeson..!= Aeson.String "{}"
  let argsText =
        case argsValue of
          Aeson.String txt -> txt
          _ -> jsonValueText argsValue
  pure (name, argsText)

parseSourceLinkAnnotation :: Aeson.Value -> Parser (Text, Text)
parseSourceLinkAnnotation =
  Aeson.withObject "OpenRouterAnnotation" $ \o -> do
    nestedCitation <- o Aeson..:? "url_citation"
    let nestedUrl = nestedCitation >>= parseMaybe (Aeson..: "url")
    let nestedTitle = nestedCitation >>= join . parseMaybe (Aeson..:? "title")
    let directUrl = parseMaybe (Aeson..: "url") o
    let directTitle = join (parseMaybe (Aeson..:? "title") o)
    let annotationType = fromMaybe "" (join (parseMaybe (Aeson..:? "type") o) :: Maybe Text)
    let maybeUrl = nestedUrl <|> directUrl
    let maybeTitle = nestedTitle <|> directTitle
    url <- maybe (fail "missing url citation") pure maybeUrl
    let normalizedTitle =
          case maybeTitle of
            Just title | not (T.null (T.strip title)) -> T.strip title
            _ -> url
    unless
      ( annotationType `elem` ["", "url_citation"]
          || isJust nestedCitation
      )
      (fail "unsupported annotation type")
    pure (normalizedTitle, url)

sourceLinksFromAnnotations :: [Aeson.Value] -> [(Text, Text)]
sourceLinksFromAnnotations =
  dedupeSourceLinks . mapMaybe (parseMaybe parseSourceLinkAnnotation)

dedupeSourceLinks :: [(Text, Text)] -> [(Text, Text)]
dedupeSourceLinks = go []
  where
    go _ [] = []
    go seen (link@(_, url) : rest)
      | url `elem` seen = go seen rest
      | otherwise = link : go (url : seen) rest

lookupOptionalValue :: Aeson.Object -> Text -> Maybe Aeson.Value
lookupOptionalValue obj key = KeyMap.lookup (Key.fromText key) obj

parseOptionalIntField :: Aeson.Object -> [Text] -> Parser (Maybe Int)
parseOptionalIntField obj keys =
  pure . asum $
    fmap
      (lookupOptionalValue obj >=> parseMaybe parseOpenRouterIntValue)
      keys

parseOpenRouterIntValue :: Aeson.Value -> Parser Int
parseOpenRouterIntValue = \case
  Aeson.Number value ->
    maybe
      (fail ("Invalid OpenRouter integer value: " <> show value))
      pure
      (Scientific.toBoundedInteger value)
  Aeson.String rawValue ->
    case readMaybe (T.unpack (T.strip rawValue)) of
      Just value -> pure value
      Nothing -> fail ("Invalid OpenRouter integer value: " <> T.unpack rawValue)
  other -> fail ("Invalid OpenRouter integer JSON type: " <> show other)

isMeaningfulOpenRouterChoice :: OpenRouterChoice -> Bool
isMeaningfulOpenRouterChoice choice =
  not (T.null (T.strip (openRouterContent choice)))
    || not (null (openRouterToolCalls choice))
    || not (null (openRouterSourceLinks choice))

meaningfulOpenRouterUsage :: OpenRouterUsage -> Maybe OpenRouterUsage
meaningfulOpenRouterUsage usage
  | all
      isNothing
      [openRouterInputTokens usage, openRouterOutputTokens usage, openRouterTotalTokens usage]
      && isNothing (openRouterCostUsd usage) =
      Nothing
  | otherwise =
      Just usage
