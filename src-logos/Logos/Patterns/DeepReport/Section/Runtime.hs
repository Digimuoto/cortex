{- |
Module      : Logos.Patterns.DeepReport.Section.Runtime
Description : Logos reasoning-library support for runtime.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Patterns.DeepReport.Section.Runtime
  ( ResearchChunkCompileSuccess (..)
  , chunkCompileFailureFromErrorText
  , classifyResearchChunkFailure
  , classifyResearchChunkFailureFromErrorText
  , parseResearchChunkChoice
  , parseResearchSectionPlanChoice
  , renderSectionValidationErrors
  , researchChunkCompileSuccessSummary
  )
where

import Control.Applicative ((<|>))
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.List (nub)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Logos.Patterns.DeepReport.Section
  ( ChunkCompileFailure (..)
  , ChunkFailureType (..)
  , ExternalRef (..)
  , ResearchChunk (..)
  , ResearchChunkLimits
  , ResearchFinding (..)
  , ResearchSectionPlan
  , ResearchSectionSpec (..)
  , SectionValidationError (..)
  , normalizeResearchChunkToLimits
  , parseResearchChunkLlmOutput
  , researchChunkHasVisibleBody
  , researchChunkHasVisibleContent
  , validateResearchChunk
  , validateResearchSectionPlan
  )

import Cortex.Capability.Model.Types (CortexChoice (..))
import Cortex.Capability.StructuredOutput
  ( decodeStructuredChoice
  , structuredOutputSchemaRejected
  )

data ResearchChunkCompileSuccess = ResearchChunkCompileSuccess
  { researchChunkCompileChunk :: ResearchChunk
  , researchChunkCompileRepairSummary :: Maybe Text
  , researchChunkCompileRepairPayload :: Maybe Aeson.Value
  }
  deriving stock (Eq, Show)

parseResearchSectionPlanChoice :: CortexChoice -> Either Text ResearchSectionPlan
parseResearchSectionPlanChoice choice = do
  plan <- decodeStructuredChoice choice
  first renderSectionValidationErrors (validateResearchSectionPlan plan)

parseResearchChunkChoice
  :: (ResearchSectionSpec -> ResearchChunk -> ResearchChunk)
  -> ResearchSectionSpec
  -> Int
  -> ResearchChunkLimits
  -> [ExternalRef]
  {- ^ External ref candidates offered to the LLM, in the same order as
   the 'externalRefs' integer indices it emits.
  -}
  -> CortexChoice
  -> Either ChunkCompileFailure ResearchChunkCompileSuccess
parseResearchChunkChoice shapeChunk spec attemptNumber limits candidates choice =
  case decodeChunkWithCandidates candidates choice of
    Left errText ->
      Left
        ( mkChunkFailure
            spec
            attemptNumber
            (classifyResearchChunkFailure choice errText)
            ("Section output was invalid. " <> errText)
            Nothing
        )
    Right chunk ->
      let normalizedChunk = normalizeResearchChunkToLimits limits chunk
          maybeNormalizationRepair = chunkRepairSummary chunk normalizedChunk
       in case validateResearchChunk limits normalizedChunk of
            Left validationErrors ->
              Left
                ( mkChunkFailure
                    spec
                    attemptNumber
                    (classifyResearchChunkFailure choice (renderSectionValidationErrors validationErrors))
                    ( "Section output did not satisfy the bounded chunk contract. "
                        <> renderSectionValidationErrors validationErrors
                    )
                    (Just normalizedChunk)
                )
            Right validChunk
              | validChunk.researchChunkSectionId /= spec.researchSectionId ->
                  Left
                    ( mkChunkFailure
                        spec
                        attemptNumber
                        ChunkFailureStructuredOutput
                        ( "Section output used the wrong section id. Expected "
                            <> spec.researchSectionId
                            <> " but received "
                            <> validChunk.researchChunkSectionId
                            <> "."
                        )
                        (Just validChunk)
                    )
              | otherwise ->
                  let layoutNormalizedChunk = shapeChunk spec validChunk
                      maybeLayoutRepair = chunkRepairSummary validChunk layoutNormalizedChunk
                      referenceNormalizedChunk = repairChunkReferenceCoverage layoutNormalizedChunk
                      maybeReferenceRepair = chunkRepairSummary layoutNormalizedChunk referenceNormalizedChunk
                      referenceCoverageErrors = validateChunkReferenceCoverage referenceNormalizedChunk
                   in case validateResearchChunk limits referenceNormalizedChunk of
                        Left validationErrors ->
                          Left
                            ( mkChunkFailure
                                spec
                                attemptNumber
                                ChunkFailureStructuredOutput
                                ( "Section output could not be normalized into the backend layout contract. "
                                    <> renderSectionValidationErrors validationErrors
                                )
                                (Just referenceNormalizedChunk)
                            )
                        Right finalChunk
                          | not (researchChunkHasVisibleContent finalChunk) ->
                              Left
                                ( mkChunkFailure
                                    spec
                                    attemptNumber
                                    ChunkFailureStructuredOutput
                                    "Section output did not produce any renderable content after workflow shaping."
                                    (Just finalChunk)
                                )
                        Right finalChunk
                          | not (null referenceCoverageErrors) ->
                              Left
                                ( mkChunkFailure
                                    spec
                                    attemptNumber
                                    ChunkFailureStructuredOutput
                                    ( "Section output did not satisfy reference coverage requirements. "
                                        <> renderSectionValidationErrors referenceCoverageErrors
                                    )
                                    (Just finalChunk)
                                )
                          | otherwise ->
                              let (repairSummary, repairPayload) =
                                    mergeRepairSummaries [maybeNormalizationRepair, maybeLayoutRepair, maybeReferenceRepair]
                               in Right
                                    ResearchChunkCompileSuccess
                                      { researchChunkCompileChunk = finalChunk
                                      , researchChunkCompileRepairSummary = repairSummary
                                      , researchChunkCompileRepairPayload = repairPayload
                                      }

{- | Decode the section compiler LLM's structured output. The 'ResearchChunk'
expects external refs as full 'ExternalRef' records, while the LLM emits
integer indices into the candidate list (see 'parseResearchChunkLlmOutput').
This helper parses the raw JSON as 'Aeson.Value' and resolves indices
against 'candidates' in one step.
-}
decodeChunkWithCandidates :: [ExternalRef] -> CortexChoice -> Either Text ResearchChunk
decodeChunkWithCandidates candidates choice
  | T.null stripped = Left "Structured output was empty."
  | otherwise = do
      value <-
        first T.pack $
          Aeson.eitherDecodeStrict' (TE.encodeUtf8 stripped)
      first T.pack (parseResearchChunkLlmOutput candidates value)
  where
    stripped = T.strip choice.cortexChoiceContent

chunkCompileFailureFromErrorText :: ResearchSectionSpec -> Int -> Text -> ChunkCompileFailure
chunkCompileFailureFromErrorText spec attemptNumber errText =
  mkChunkFailure
    spec
    attemptNumber
    (classifyResearchChunkFailureFromErrorText errText)
    errText
    Nothing

classifyResearchChunkFailure :: CortexChoice -> Text -> ChunkFailureType
classifyResearchChunkFailure choice errText
  | choice.cortexChoiceFinishReason == Just "length" = ChunkFailureTruncation
  | "end-of-input" `T.isInfixOf` normalizedErr = ChunkFailureTruncation
  | T.null (T.strip choice.cortexChoiceContent) = ChunkFailureNoContent
  | otherwise = ChunkFailureStructuredOutput
  where
    normalizedErr = T.toLower errText

classifyResearchChunkFailureFromErrorText :: Text -> ChunkFailureType
classifyResearchChunkFailureFromErrorText errText
  | "timeout" `T.isInfixOf` normalizedErr = ChunkFailureExternalError
  | structuredOutputSchemaRejected normalizedErr = ChunkFailureExternalError
  | "provider rejected the request" `T.isInfixOf` normalizedErr = ChunkFailureExternalError
  | "failed after network retries" `T.isInfixOf` normalizedErr = ChunkFailureExternalError
  | "unreadable completion response" `T.isInfixOf` normalizedErr = ChunkFailureExternalError
  | "returned no completion choices" `T.isInfixOf` normalizedErr = ChunkFailureExternalError
  | otherwise = ChunkFailureStructuredOutput
  where
    normalizedErr = T.toLower errText

researchChunkCompileSuccessSummary :: ResearchChunk -> Text
researchChunkCompileSuccessSummary chunk =
  T.intercalate
    " "
    [ chunk.researchChunkSectionId <> "."
    , "Paragraphs:"
    , tShow (length chunk.researchChunkParagraphs) <> ","
    , "findings:"
    , tShow (length chunk.researchChunkFindings) <> ","
    , "tables:"
    , tShow (length chunk.researchChunkTables) <> "."
    ]

renderSectionValidationErrors :: [SectionValidationError] -> Text
renderSectionValidationErrors errors =
  T.intercalate "; " (fmap (.sectionValidationMessage) errors)

mergeRepairSummaries :: [Maybe (Text, Aeson.Value)] -> (Maybe Text, Maybe Aeson.Value)
mergeRepairSummaries summaries =
  case catMaybes summaries of
    [] -> (Nothing, Nothing)
    present ->
      ( Just (T.intercalate " " (fmap fst present))
      , Just (Aeson.object ["repairs" Aeson..= fmap snd present])
      )

chunkRepairSummary :: ResearchChunk -> ResearchChunk -> Maybe (Text, Aeson.Value)
chunkRepairSummary original normalized
  | original == normalized = Nothing
  | otherwise =
      Just
        ( "Applied local chunk repair to fit bounded section limits: "
            <> T.intercalate "; " changeMessages
            <> "."
        , Aeson.object
            [ "section_id" Aeson..= normalized.researchChunkSectionId
            , "changes" Aeson..= changeMessages
            ]
        )
  where
    changeMessages =
      catMaybes
        [ titleChange
        , summaryChange
        , paragraphChange
        , findingChange
        , tableChange
        , evidenceRefChange
        , externalRefChange
        , openGapChange
        ]

    titleChange =
      boolChange "clipped title" (original.researchChunkTitle /= normalized.researchChunkTitle)

    summaryChange =
      boolChange "clipped summary" (original.researchChunkSummary /= normalized.researchChunkSummary)

    paragraphChange =
      lengthChange
        "paragraph"
        (length original.researchChunkParagraphs)
        (length normalized.researchChunkParagraphs)
        <|> boolChange
          "clipped paragraph text"
          (original.researchChunkParagraphs /= normalized.researchChunkParagraphs)

    findingChange =
      lengthChange
        "finding"
        (length original.researchChunkFindings)
        (length normalized.researchChunkFindings)
        <|> boolChange
          "clipped finding content"
          (original.researchChunkFindings /= normalized.researchChunkFindings)

    tableChange =
      lengthChange "table" (length original.researchChunkTables) (length normalized.researchChunkTables)
        <|> boolChange "trimmed table layout" (original.researchChunkTables /= normalized.researchChunkTables)

    evidenceRefChange =
      lengthChange
        "evidence ref"
        (length original.researchChunkEvidenceRefs)
        (length normalized.researchChunkEvidenceRefs)

    externalRefChange =
      lengthChange
        "external ref"
        (length original.researchChunkExternalRefs)
        (length normalized.researchChunkExternalRefs)

    openGapChange =
      lengthChange
        "open gap"
        (length original.researchChunkOpenGaps)
        (length normalized.researchChunkOpenGaps)
        <|> boolChange
          "clipped open-gap text"
          (original.researchChunkOpenGaps /= normalized.researchChunkOpenGaps)

    boolChange label changed
      | changed = Just label
      | otherwise = Nothing

    lengthChange label originalCount normalizedCount
      | originalCount > normalizedCount =
          Just
            ( "removed "
                <> tShow (originalCount - normalizedCount)
                <> " "
                <> pluralize label (originalCount - normalizedCount)
            )
      | otherwise = Nothing

pluralize :: Text -> Int -> Text
pluralize singular count
  | count == 1 = singular
  | otherwise = singular <> "s"

tShow :: Show a => a -> Text
tShow = T.pack . show

repairChunkReferenceCoverage :: ResearchChunk -> ResearchChunk
repairChunkReferenceCoverage =
  inheritChunkRefsIntoFindings
    . promoteFindingRefsIntoChunk

promoteFindingRefsIntoChunk :: ResearchChunk -> ResearchChunk
promoteFindingRefsIntoChunk chunk
  | chunkHasRefs chunk = chunk
  | otherwise =
      chunk
        { researchChunkEvidenceRefs =
            nub
              ( chunk.researchChunkEvidenceRefs
                  <> concatMap (.researchFindingEvidenceRefs) chunk.researchChunkFindings
              )
        , researchChunkExternalRefs =
            nub
              ( chunk.researchChunkExternalRefs
                  <> concatMap (.researchFindingExternalRefs) chunk.researchChunkFindings
              )
        }

inheritChunkRefsIntoFindings :: ResearchChunk -> ResearchChunk
inheritChunkRefsIntoFindings chunk
  | not (chunkHasRefs chunk) = chunk
  | otherwise =
      chunk
        { researchChunkFindings =
            fmap inheritRefs chunk.researchChunkFindings
        }
  where
    inheritRefs finding
      | findingHasRefs finding = finding
      | otherwise =
          finding
            { researchFindingEvidenceRefs = chunk.researchChunkEvidenceRefs
            , researchFindingExternalRefs = chunk.researchChunkExternalRefs
            }

validateChunkReferenceCoverage :: ResearchChunk -> [SectionValidationError]
validateChunkReferenceCoverage chunk =
  chunkBodyErrors <> findingErrors
  where
    chunkBodyErrors
      | not (researchChunkHasVisibleBody chunk) = []
      | chunkHasRefs chunk = []
      | otherwise =
          [SectionValidationError "Rendered section body must carry at least one evidenceRef or externalRef."]
    findingErrors =
      [ SectionValidationError "Every rendered finding must carry at least one evidenceRef or externalRef."
      | finding <- chunk.researchChunkFindings
      , not (findingHasRefs finding)
      ]

chunkHasRefs :: ResearchChunk -> Bool
chunkHasRefs chunk =
  hasNonEmptyTextList chunk.researchChunkEvidenceRefs
    || not (null chunk.researchChunkExternalRefs)

findingHasRefs :: ResearchFinding -> Bool
findingHasRefs finding =
  hasNonEmptyTextList finding.researchFindingEvidenceRefs
    || not (null finding.researchFindingExternalRefs)

hasNonEmptyTextList :: [Text] -> Bool
hasNonEmptyTextList = not . all (T.null . T.strip)

mkChunkFailure
  :: ResearchSectionSpec
  -> Int
  -> ChunkFailureType
  -> Text
  -> Maybe ResearchChunk
  -> ChunkCompileFailure
mkChunkFailure spec attemptNumber failureType message maybeChunk =
  ChunkCompileFailure
    { chunkFailureSectionId = spec.researchSectionId
    , chunkFailureSectionTitle = Just spec.researchSectionTitle
    , chunkFailureAttempt = attemptNumber
    , chunkFailureType = failureType
    , chunkFailureMessage = message
    , chunkFailureCandidateEvidenceRefs = []
    , chunkFailureCandidateExternalRefs = []
    , chunkFailureOpenGaps = foldMap (.researchChunkOpenGaps) maybeChunk
    }
