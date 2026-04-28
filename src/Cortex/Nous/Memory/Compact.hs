{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Nous.Memory.Compact
  ( CompactionConfig (..),
    defaultCompactionConfig,
    MessageForCompaction (..),
    CheckpointSourceReference (..),
    CheckpointSummary (..),
    buildCheckpointSummary,
    estimateTextTokens,
    estimateMessageTokens,
  )
where

import Control.Monad (when)
import Data.Aeson (FromJSON, ToJSON)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID (UUID)
import GHC.Generics (Generic)
import Platform.Text (truncateText)

-- | Deterministic compaction controls.
data CompactionConfig = CompactionConfig
  { keepRecentMessageCount :: Int,
    minMessagesToCompact :: Int,
    maxExcerptCount :: Int
  }
  deriving stock (Eq, Show, Generic)

defaultCompactionConfig :: CompactionConfig
defaultCompactionConfig =
  CompactionConfig
    { keepRecentMessageCount = 12,
      minMessagesToCompact = 8,
      maxExcerptCount = 6
    }

data MessageForCompaction = MessageForCompaction
  { messageId :: UUID,
    messageSequence :: Int64,
    role :: Text,
    content :: Text,
    toolName :: Maybe Text,
    toolCallId :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

-- | Source mapping retained for replayability from compacted summary back to raw messages.
data CheckpointSourceReference = CheckpointSourceReference
  { sourceMessageId :: UUID,
    sourceMessageSequence :: Int64,
    sourceRole :: Text,
    sourceToolName :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data CheckpointSummary = CheckpointSummary
  { summaryText :: Text,
    sourceMessageCount :: Int64,
    sourceStartSequence :: Int64,
    sourceEndSequence :: Int64,
    sourceReferences :: [CheckpointSourceReference],
    estimatedTokensBefore :: Int64,
    estimatedTokensAfter :: Int64
  }
  deriving stock (Eq, Show, Generic)

buildCheckpointSummary ::
  CompactionConfig -> [MessageForCompaction] -> Either Text CheckpointSummary
buildCheckpointSummary rawConfig rawMessages = do
  let messages = sortOn messageSequence rawMessages
      keepCount = clampInt 1 200 rawConfig.keepRecentMessageCount
      minCompactCount = clampInt 1 2000 rawConfig.minMessagesToCompact

  when (null messages) $
    Left "Cannot create checkpoint from an empty message list."

  when (length messages <= keepCount) $
    Left "Not enough messages to compact. Conversation must exceed keepRecentMessageCount."

  let compactCount = length messages - keepCount
  when (compactCount < minCompactCount) $
    Left "Not enough older messages to compact for deterministic summary generation."

  let (compacted, _) = splitAt compactCount messages
      (startSeq, endSeq) = sequenceBounds compacted
      sourceRefs = fmap toSourceReference compacted
      beforeTokens = sum (fmap estimateMessageTokens compacted)
      summary = renderSummary rawConfig compacted beforeTokens
      afterTokens = estimateTextTokens summary

  if afterTokens >= beforeTokens
    then Left "Compaction did not reduce the estimated token footprint for the selected range."
    else
      Right
        CheckpointSummary
          { summaryText = summary,
            sourceMessageCount = fromIntegral (length compacted),
            sourceStartSequence = startSeq,
            sourceEndSequence = endSeq,
            sourceReferences = sourceRefs,
            estimatedTokensBefore = beforeTokens,
            estimatedTokensAfter = afterTokens
          }

toSourceReference :: MessageForCompaction -> CheckpointSourceReference
toSourceReference msg =
  CheckpointSourceReference
    { sourceMessageId = msg.messageId,
      sourceMessageSequence = msg.messageSequence,
      sourceRole = normalizeRole msg.role,
      sourceToolName = msg.toolName >>= nonEmptyText . T.strip
    }

renderSummary :: CompactionConfig -> [MessageForCompaction] -> Int64 -> Text
renderSummary config compacted beforeTokens =
  T.unlines $
    [ "Deterministic checkpoint summary.",
      "Compacted message range: #"
        <> tShow startSeq
        <> " to #"
        <> tShow endSeq
        <> " ("
        <> tShow (length compacted)
        <> " messages).",
      "Role counts: "
        <> "user="
        <> countOf "user"
        <> ", assistant="
        <> countOf "assistant"
        <> ", tool="
        <> countOf "tool"
        <> ", system="
        <> countOf "system"
        <> ".",
      "Estimated tokens (before -> summary): "
        <> tShow beforeTokens
        <> " -> "
        <> tShow (estimateTextTokens draftWithoutTokenLine)
        <> "."
    ]
      <> compactedOldestBlock
      <> compactedNewestBlock
      <> toolBlock
      <> userIntentBlock
  where
    (startSeq, endSeq) = sequenceBounds compacted
    maxExcerpts = clampInt 2 20 config.maxExcerptCount
    oldestCount = maxExcerpts `div` 2
    newestCount = maxExcerpts - oldestCount
    oldest = take oldestCount compacted
    newest = drop (max 0 (length compacted - newestCount)) compacted
    roleCounts = foldr (\msg -> Map.insertWith (+) (normalizeRole msg.role) (1 :: Int)) Map.empty compacted
    countOf roleName = tShow (Map.findWithDefault 0 roleName roleCounts)
    compactedOldestBlock =
      if null oldest
        then []
        else "Oldest excerpts:" : fmap formatExcerpt oldest
    compactedNewestBlock =
      if null newest
        then []
        else "Newest excerpts:" : fmap formatExcerpt newest
    toolNames = take 8 (orderedUnique (mapMaybeToolName compacted))
    toolBlock =
      [ "Tools used in compacted range: " <> T.intercalate ", " toolNames <> "."
      | not (null toolNames)
      ]
    firstUserIntents = take 2 (mapMaybeUserIntent compacted)
    lastUserIntents = take 2 (reverse (mapMaybeUserIntent compacted))
    userIntentBlock =
      if null firstUserIntents && null lastUserIntents
        then []
        else
          [ "User intent snapshots:",
            "First intents: " <> intentLine firstUserIntents,
            "Latest intents: " <> intentLine (reverse lastUserIntents)
          ]
    draftWithoutTokenLine =
      T.unlines
        [ "Deterministic checkpoint summary.",
          "Compacted message range: #"
            <> tShow startSeq
            <> " to #"
            <> tShow endSeq
            <> " ("
            <> tShow (length compacted)
            <> " messages).",
          "Role counts: "
            <> "user="
            <> countOf "user"
            <> ", assistant="
            <> countOf "assistant"
            <> ", tool="
            <> countOf "tool"
            <> ", system="
            <> countOf "system"
            <> "."
        ]
        <> T.unlines compactedOldestBlock
        <> T.unlines compactedNewestBlock
        <> T.unlines toolBlock
        <> T.unlines userIntentBlock

formatExcerpt :: MessageForCompaction -> Text
formatExcerpt msg =
  "- #"
    <> tShow msg.messageSequence
    <> " ["
    <> normalizeRole msg.role
    <> "] "
    <> snippet msg.content

mapMaybeToolName :: [MessageForCompaction] -> [Text]
mapMaybeToolName =
  foldr
    ( \msg acc ->
        case msg.toolName >>= (nonEmptyText . T.strip) of
          Nothing -> acc
          Just name -> name : acc
    )
    []

mapMaybeUserIntent :: [MessageForCompaction] -> [Text]
mapMaybeUserIntent =
  foldr
    ( \msg acc ->
        if normalizeRole msg.role == "user"
          then case nonEmptyText (snippet msg.content) of
            Nothing -> acc
            Just s -> s : acc
          else acc
    )
    []

intentLine :: [Text] -> Text
intentLine intents =
  if null intents
    then "(none)"
    else T.intercalate " | " intents

orderedUnique :: [Text] -> [Text]
orderedUnique = go Map.empty
  where
    go :: Map Text () -> [Text] -> [Text]
    go _ [] = []
    go seen (x : xs)
      | Map.member x seen = go seen xs
      | otherwise = x : go (Map.insert x () seen) xs

normalizeRole :: Text -> Text
normalizeRole roleName =
  case T.toLower (T.strip roleName) of
    "assistant" -> "assistant"
    "tool" -> "tool"
    "system" -> "system"
    _ -> "user"

snippet :: Text -> Text
snippet txt = truncateText 160 (normalizeWhitespace txt)

normalizeWhitespace :: Text -> Text
normalizeWhitespace = T.unwords . T.words

nonEmptyText :: Text -> Maybe Text
nonEmptyText txt
  | T.null txt = Nothing
  | otherwise = Just txt

estimateMessageTokens :: MessageForCompaction -> Int64
estimateMessageTokens msg =
  estimateTextTokens roleText
    + estimateTextTokens msg.content
    + maybe 0 estimateTextTokens msg.toolName
    + maybe 0 estimateTextTokens msg.toolCallId
  where
    roleText = normalizeRole msg.role

estimateTextTokens :: Text -> Int64
estimateTextTokens txt =
  let normalizedLen = T.length (normalizeWhitespace txt)
      estimate = (normalizedLen + 3) `div` 4
   in fromIntegral (max 1 estimate)

clampInt :: Int -> Int -> Int -> Int
clampInt minValue maxValue value =
  max minValue (min maxValue value)

tShow :: (Show a) => a -> Text
tShow = T.pack . show

sequenceBounds :: [MessageForCompaction] -> (Int64, Int64)
sequenceBounds messages =
  case messages of
    [] -> (0, 0)
    (firstMsg : rest) -> (firstMsg.messageSequence, lastSequence firstMsg.messageSequence rest)
  where
    lastSequence :: Int64 -> [MessageForCompaction] -> Int64
    lastSequence latest [] = latest
    lastSequence _ (msg : remaining) = lastSequence msg.messageSequence remaining
