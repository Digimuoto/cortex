{- |
Module      : Logos.Memory.Query
Description : Logos reasoning-library support for query.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Memory.Query
  ( LogosMemoryQuery (..)
  , parseMemoryQuery
  , logosMemoryQueryFuzzyText
  , logosMemoryQueryPositiveTerms
  , logosMemoryQueryIsBlank
  , hasAnyKeyword
  )
where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import Logos.Memory.Types (LogosMemoryEntityConfig (..))

data LogosMemoryQuery = LogosMemoryQuery
  { logosMemoryQueryRawText :: Text
  , logosMemoryQueryNormalizedText :: Text
  , logosMemoryQueryWebsearchText :: Text
  , logosMemoryQuerySemanticText :: Text
  , logosMemoryQueryTerms :: [Text]
  , logosMemoryQueryPhrases :: [Text]
  , logosMemoryQueryNegativeTerms :: [Text]
  , logosMemoryQueryEntities :: [Text]
  , logosMemoryQueryReportTypeHint :: Maybe Text
  , logosMemoryQueryContinuationIntent :: Bool
  , logosMemoryQueryRecencyHint :: Maybe Text
  , logosMemoryQueryAnchoredItemIds :: [UUID]
  , logosMemoryQueryExplicitTargetItemId :: Maybe UUID
  }
  deriving stock (Eq, Show)

parseMemoryQuery :: LogosMemoryEntityConfig -> Text -> [UUID] -> Maybe UUID -> LogosMemoryQuery
parseMemoryQuery entityConfig rawText anchoredItemIds explicitTargetItemId =
  LogosMemoryQuery
    { logosMemoryQueryRawText = stripped
    , logosMemoryQueryNormalizedText = normalizeQueryText stripped
    , logosMemoryQueryWebsearchText = stripped
    , logosMemoryQuerySemanticText = stripped
    , logosMemoryQueryTerms = positiveTerms
    , logosMemoryQueryPhrases = phrases
    , logosMemoryQueryNegativeTerms = negativeTerms
    , logosMemoryQueryEntities = logosMemoryExtractEntities entityConfig stripped
    , logosMemoryQueryReportTypeHint = detectReportType stripped
    , logosMemoryQueryContinuationIntent = hasContinuationCue normalized
    , logosMemoryQueryRecencyHint = detectRecencyHint normalized
    , logosMemoryQueryAnchoredItemIds = dedupeUuids anchoredItemIds
    , logosMemoryQueryExplicitTargetItemId = explicitTargetItemId
    }
  where
    stripped = T.strip rawText
    normalized = normalizeQueryText stripped
    phrases = extractQuotedPhrases stripped
    (negativeTerms, positiveTerms) = partitionSignedTerms stripped

logosMemoryQueryPositiveTerms :: LogosMemoryQuery -> [Text]
logosMemoryQueryPositiveTerms query =
  Set.toList . Set.fromList . filter (not . T.null) $
    query.logosMemoryQueryTerms
      <> concatMap tokenizePlainText query.logosMemoryQueryPhrases
      <> fmap normalizeToken query.logosMemoryQueryEntities

logosMemoryQueryFuzzyText :: LogosMemoryQuery -> Text
logosMemoryQueryFuzzyText query =
  case dedupePreservingOrder tokens of
    [] -> query.logosMemoryQueryNormalizedText
    deduped -> T.unwords deduped
  where
    tokens =
      filter (not . T.null) $
        query.logosMemoryQueryTerms
          <> concatMap tokenizePlainText query.logosMemoryQueryPhrases
          <> fmap normalizeToken query.logosMemoryQueryEntities

logosMemoryQueryIsBlank :: LogosMemoryQuery -> Bool
logosMemoryQueryIsBlank query =
  T.null query.logosMemoryQueryNormalizedText

extractQuotedPhrases :: Text -> [Text]
extractQuotedPhrases text =
  reverse (go text [])
  where
    go remaining acc =
      case T.breakOn "\"" remaining of
        (_prefix, quoted)
          | T.null quoted ->
              acc
          | otherwise ->
              let rest = T.drop 1 quoted
               in case T.breakOn "\"" rest of
                    (phrase, closing)
                      | T.null closing ->
                          acc
                      | otherwise ->
                          let acc' =
                                case normalizePhrase phrase of
                                  normalized
                                    | T.null normalized -> acc
                                    | otherwise -> normalized : acc
                           in go (T.drop 1 closing) acc'

    normalizePhrase = T.unwords . T.words . T.toLower

partitionSignedTerms :: Text -> ([Text], [Text])
partitionSignedTerms text =
  foldr step ([], []) (tokenizeRaw text)
  where
    step token (negatives, positives) =
      case T.uncons token of
        Just ('-', rest) ->
          case normalizeSignedToken rest of
            Nothing -> (negatives, positives)
            Just normalized -> (normalized : negatives, positives)
        _ ->
          case normalizeSignedToken token of
            Nothing -> (negatives, positives)
            Just normalized -> (negatives, normalized : positives)

tokenizeRaw :: Text -> [Text]
tokenizeRaw =
  filter (not . T.null)
    . fmap T.strip
    . T.split (not . isQueryTokenChar)

tokenizePlainText :: Text -> [Text]
tokenizePlainText =
  mapMaybe normalizeSignedToken . tokenizeRaw

normalizeSignedToken :: Text -> Maybe Text
normalizeSignedToken rawToken =
  let normalized = normalizeToken rawToken
   in if isMeaningfulToken normalized then Just normalized else Nothing

normalizeToken :: Text -> Text
normalizeToken =
  T.toLower . T.dropAround (\char -> char == '"' || char == '\'' || char == '.' || char == ',')

normalizeQueryText :: Text -> Text
normalizeQueryText =
  T.unwords . T.words . T.toLower

isMeaningfulToken :: Text -> Bool
isMeaningfulToken token =
  let len = T.length token
      hasAlphaNum = T.any (\char -> isAsciiLower char || isAsciiUpper char || isDigit char) token
   in not (T.null token)
        && hasAlphaNum
        && len >= 2
        && token `notElem` queryNoiseWords

isQueryTokenChar :: Char -> Bool
isQueryTokenChar char =
  isAsciiUpper char
    || isAsciiLower char
    || isDigit char
    || char == '.'
    || char == '-'
    || char == '"'
    || char == '\''

detectReportType :: Text -> Maybe Text
detectReportType rawText
  | hasAnyKeyword haystack ["deep report", "deep-report"] = Just "deep-report"
  | hasAnyKeyword haystack ["plan", "execution plan"] = Just "plan"
  | hasAnyKeyword haystack ["report", "analysis", "memo", "note"] = Just "report"
  | otherwise = Nothing
  where
    haystack = normalizeQueryText rawText

hasContinuationCue :: Text -> Bool
hasContinuationCue =
  hasAnyKeyword
    <*> pure
      [ "continue"
      , "continuation"
      , "revise"
      , "revision"
      , "update"
      , "refresh"
      , "follow up"
      , "follow-up"
      , "extend"
      , "what did we say"
      , "prior report"
      , "this report"
      ]

detectRecencyHint :: Text -> Maybe Text
detectRecencyHint haystack
  | hasAnyKeyword haystack ["latest", "newest", "today"] = Just "latest"
  | hasAnyKeyword haystack ["recent", "recently", "current"] = Just "recent"
  | hasAnyKeyword haystack ["last quarter", "quarter"] = Just "last-quarter"
  | hasAnyKeyword haystack ["yesterday", "last week"] = Just "short-window"
  | otherwise = Nothing

hasAnyKeyword :: Text -> [Text] -> Bool
hasAnyKeyword haystack =
  any (`T.isInfixOf` haystack)

dedupeUuids :: [UUID] -> [UUID]
dedupeUuids = Set.toList . Set.fromList

dedupePreservingOrder :: [Text] -> [Text]
dedupePreservingOrder = go Set.empty
  where
    go _ [] = []
    go seen (token : rest)
      | Set.member token seen = go seen rest
      | otherwise = token : go (Set.insert token seen) rest

queryNoiseWords :: [Text]
queryNoiseWords =
  [ "a"
  , "about"
  , "again"
  , "and"
  , "around"
  , "explain"
  , "for"
  , "from"
  , "give"
  , "me"
  , "my"
  , "our"
  , "show"
  , "tell"
  , "that"
  , "the"
  , "their"
  , "them"
  , "there"
  , "these"
  , "they"
  , "what"
  , "which"
  , "with"
  , "your"
  ]
