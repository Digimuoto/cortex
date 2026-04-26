{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.MemoryCompactionSpec (spec) where

import Cortex.Memory.Compact
  ( CheckpointSourceReference (..),
    CheckpointSummary (..),
    CompactionConfig (..),
    MessageForCompaction (..),
    buildCheckpointSummary,
    defaultCompactionConfig,
  )
import Data.Int (Int64)
import Data.List qualified as List
import Data.Text qualified as T
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Test.Hspec

spec :: Spec
spec = do
  describe "buildCheckpointSummary" $ do
    it "is deterministic and preserves replay references" $ do
      let input = sampleMessages 20
          resultA = buildCheckpointSummary defaultCompactionConfig input
          resultB = buildCheckpointSummary defaultCompactionConfig input
      resultA `shouldBe` resultB

      case resultA of
        Left err -> expectationFailure ("Expected Right but got Left: " <> T.unpack err)
        Right summary -> do
          summary.sourceMessageCount `shouldBe` 8
          summary.sourceStartSequence `shouldBe` 1
          summary.sourceEndSequence `shouldBe` 8
          length summary.sourceReferences `shouldBe` 8
          summary.summaryText `shouldSatisfy` T.isInfixOf "Compacted message range: #1 to #8"
          summary.estimatedTokensAfter `shouldSatisfy` (< summary.estimatedTokensBefore)

          case (List.uncons summary.sourceReferences, List.uncons input) of
            (Just (firstSource, _), Just (firstInput, _)) ->
              sourceMessageId firstSource `shouldBe` messageId firstInput
            _ ->
              expectationFailure "Expected non-empty source references and input messages"

    it "returns a deterministic validation error when there are too few messages to compact" $ do
      let config =
            defaultCompactionConfig
              { keepRecentMessageCount = 12,
                minMessagesToCompact = 8
              }
          input = sampleMessages 16
      buildCheckpointSummary config input
        `shouldBe` Left "Not enough older messages to compact for deterministic summary generation."

sampleMessages :: Int -> [MessageForCompaction]
sampleMessages count =
  fmap (mkMessage . fromIntegral) [1 .. count]
  where
    mkMessage :: Int64 -> MessageForCompaction
    mkMessage sequenceNo =
      MessageForCompaction
        { messageId = uuidFromSeq sequenceNo,
          messageSequence = sequenceNo,
          role = roleFor sequenceNo,
          content =
            "Message "
              <> T.pack (show sequenceNo)
              <> ": "
              <> T.replicate
                4
                "This message carries detailed portfolio diagnostics, allocation notes, and follow-up actions for deterministic compaction testing. ",
          toolName = toolNameFor sequenceNo,
          toolCallId = Nothing
        }

roleFor :: Int64 -> T.Text
roleFor seqNo
  | seqNo `mod` 5 == 0 = "tool"
  | even seqNo = "assistant"
  | otherwise = "user"

toolNameFor :: Int64 -> Maybe T.Text
toolNameFor seqNo
  | seqNo `mod` 5 == 0 = Just "getPortfolioSummary"
  | otherwise = Nothing

uuidFromSeq :: Int64 -> UUID
uuidFromSeq seqNo =
  case UUID.fromString ("00000000-0000-0000-0000-" <> padded seqNo) of
    Just uuidValue -> uuidValue
    Nothing -> error "invalid deterministic UUID"

padded :: Int64 -> String
padded sequenceNo =
  let base = show sequenceNo
   in replicate (12 - length base) '0' <> base
