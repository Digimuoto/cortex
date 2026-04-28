{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Nous.Patterns.DeepReport.Section
  ( ChunkCompileFailure (..)
  , ChunkFailureType (..)
  , ExternalRef (..)
  , ResearchChunk (..)
  , ResearchChunkLimits (..)
  , ResearchFinding (..)
  , ResearchSectionPlan (..)
  , ResearchSectionSpec (..)
  , ResearchTable (..)
  , ResearchTableAlignment (..)
  , SectionExecutionResult (..)
  , SectionValidationError (..)
  , compressedResearchChunkLimits
  , defaultResearchChunkLimits
  , executeSectionPlan
  , executeSectionPlanParallelIO
  , externalRefDisplayLabel
  , normalizeResearchChunkToLimits
  , parseResearchChunkLlmOutput
  , researchChunkHasVisibleBody
  , researchChunkHasVisibleContent
  , researchChunkLlmSchema
  , researchChunkSchema
  , researchSectionPlanSchema
  , validateResearchChunk
  , validateResearchSectionPlan
  )
where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.QSem (newQSem, signalQSem, waitQSem)
import Control.Exception (bracket_)
import Control.Monad (foldM)
import Data.Aeson (FromJSON (..), ToJSON (..), (.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.Char (isAsciiLower, isDigit)
import Data.Either (partitionEithers)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T

data ResearchSectionPlan = ResearchSectionPlan
  { researchSectionPlanTitle :: Text
  , researchSectionPlanSections :: [ResearchSectionSpec]
  }
  deriving stock (Eq, Show)

data ResearchSectionSpec = ResearchSectionSpec
  { researchSectionId :: Text
  , researchSectionTitle :: Text
  , researchSectionBrief :: Text
  }
  deriving stock (Eq, Show)

{- | Structured external reference. The host constructs these from tool
call results (webSearch, getWebContent, getAssetNews) before the
section compiler runs. The section compiler never sees or emits the
URL or title as prose — it picks refs by integer index into the
candidate list and the host resolves the index back to this record.
That keeps byte-exact URL copying off the LLM's critical path.
-}
data ExternalRef = ExternalRef
  { externalRefUrl :: Text
  , externalRefTitle :: Maybe Text
  , externalRefPublishedDate :: Maybe Text
  , externalRefSourceToolCallId :: Maybe Text
  }
  deriving stock (Eq, Show)

{- | Human-readable label for an 'ExternalRef'. Falls back to the URL
when no title is available.
-}
externalRefDisplayLabel :: ExternalRef -> Text
externalRefDisplayLabel ref =
  case externalRefTitle ref of
    Just title | not (T.null (T.strip title)) -> T.strip title
    _ -> externalRefUrl ref

data ResearchChunk = ResearchChunk
  { researchChunkSectionId :: Text
  , researchChunkTitle :: Text
  , researchChunkSummary :: Maybe Text
  , researchChunkParagraphs :: [Text]
  , researchChunkFindings :: [ResearchFinding]
  , researchChunkTables :: [ResearchTable]
  , researchChunkEvidenceRefs :: [Text]
  , researchChunkExternalRefs :: [ExternalRef]
  , researchChunkOpenGaps :: [Text]
  }
  deriving stock (Eq, Show)

data ResearchFinding = ResearchFinding
  { researchFindingText :: Text
  , researchFindingEvidenceRefs :: [Text]
  , researchFindingExternalRefs :: [ExternalRef]
  }
  deriving stock (Eq, Show)

data ResearchTable = ResearchTable
  { researchTableColumns :: [Text]
  , researchTableAlignments :: Maybe [ResearchTableAlignment]
  , researchTableRows :: [[Text]]
  }
  deriving stock (Eq, Show)

data ResearchTableAlignment
  = ResearchAlignLeft
  | ResearchAlignCenter
  | ResearchAlignRight
  | ResearchAlignDefault
  deriving stock (Eq, Show)

{- | Bounds the section compiler enforces on each research chunk. Only
*count* caps survive — the per-content character caps were dropped
(see DIG-507 dogfood 2026-04-22): they duplicated the JSON schema's
own 'maxLength' hint with a post-hoc @T.take N@ that truncated mid-
word when an LLM produced slightly longer output than expected. The
schema's 'maxLength' is retained as a courtesy hint to the provider,
but is no longer enforced by a normalizing cut on our side. If the
model ever produces genuinely runaway lengths we'll add a bound back
empirically, scoped to the specific overflow.
-}
data ResearchChunkLimits = ResearchChunkLimits
  { chunkParagraphMaxCount :: Int
  , chunkFindingMaxCount :: Int
  , chunkAllowTables :: Bool
  , chunkTableMaxCount :: Int
  , chunkTableMaxColumns :: Int
  , chunkTableMaxRows :: Int
  , chunkEvidenceRefMaxCount :: Int
  , chunkExternalRefMaxCount :: Int
  , chunkOpenGapMaxCount :: Int
  }
  deriving stock (Eq, Show)

data SectionValidationError = SectionValidationError
  { sectionValidationMessage :: Text
  }
  deriving stock (Eq, Show)

data ChunkFailureType
  = ChunkFailureTruncation
  | ChunkFailureStructuredOutput
  | ChunkFailureExternalError
  | ChunkFailureNoContent
  deriving stock (Eq, Show)

data ChunkCompileFailure = ChunkCompileFailure
  { chunkFailureSectionId :: Text
  , chunkFailureSectionTitle :: Maybe Text
  , chunkFailureAttempt :: Int
  , chunkFailureType :: ChunkFailureType
  , chunkFailureMessage :: Text
  , chunkFailureCandidateEvidenceRefs :: [Text]
  , chunkFailureCandidateExternalRefs :: [Text]
  , chunkFailureOpenGaps :: [Text]
  }
  deriving stock (Eq, Show)

data SectionExecutionResult = SectionExecutionResult
  { sectionExecutionChunks :: [ResearchChunk]
  , sectionExecutionFailures :: [ChunkCompileFailure]
  }
  deriving stock (Eq, Show)

defaultResearchChunkLimits :: ResearchChunkLimits
defaultResearchChunkLimits =
  ResearchChunkLimits
    { chunkParagraphMaxCount = 4
    , chunkFindingMaxCount = 8
    , chunkAllowTables = True
    , chunkTableMaxCount = 2
    , chunkTableMaxColumns = 6
    , chunkTableMaxRows = 12
    , chunkEvidenceRefMaxCount = 16
    , chunkExternalRefMaxCount = 8
    , chunkOpenGapMaxCount = 5
    }

compressedResearchChunkLimits :: ResearchChunkLimits
compressedResearchChunkLimits =
  defaultResearchChunkLimits
    { chunkParagraphMaxCount = 3
    , chunkFindingMaxCount = 5
    , chunkAllowTables = False
    , chunkTableMaxCount = 0
    }

executeSectionPlan
  :: Monad m
  => [ResearchSectionSpec]
  -> (Int -> ResearchSectionSpec -> m (Either ChunkCompileFailure ResearchChunk))
  -> m SectionExecutionResult
executeSectionPlan specs runOne = do
  (chunks, failures) <-
    foldM
      step
      ([], [])
      (zip [1 ..] specs)
  pure
    SectionExecutionResult
      { sectionExecutionChunks = reverse chunks
      , sectionExecutionFailures = reverse failures
      }
  where
    step (chunks, failures) (sectionIndex, spec) = do
      outcome <- runOne sectionIndex spec
      pure $
        case outcome of
          Left failure -> (chunks, failure : failures)
          Right chunk -> (chunk : chunks, failures)

{- | Parallel-IO variant of 'executeSectionPlan'. Section compilation has no
data dependency between sections — each call reads the same reviewed draft
plus its own per-section spec and produces an independent `ResearchChunk`.
Sequential execution via `foldM` turned a 7-section report into 7× the
per-call latency. Concurrent execution with a bounded semaphore collapses
that to roughly `max(per-call) + overhead` while respecting provider rate
limits.

Used by the deep-report workflow path. The generic `executeSectionPlan`
stays available for callers whose compile action isn't in IO (e.g. the
Clerk runtime path runs in Servant's `Handler`, which lacks a robust
`MonadUnliftIO` instance).

Sections are scheduled in input order; `mapConcurrently` preserves order,
and `partitionEithers` preserves order within each partition, so chunks
come back in plan order.
-}
executeSectionPlanParallelIO
  :: [ResearchSectionSpec]
  -> (Int -> ResearchSectionSpec -> IO (Either ChunkCompileFailure ResearchChunk))
  -> IO SectionExecutionResult
executeSectionPlanParallelIO specs runOne = do
  sem <- newQSem sectionCompilerMaxConcurrency
  outcomes <-
    mapConcurrently
      (\(sectionIndex, spec) -> bracket_ (waitQSem sem) (signalQSem sem) (runOne sectionIndex spec))
      (zip [1 ..] specs)
  let (failures, chunks) = partitionEithers outcomes
  pure
    SectionExecutionResult
      { sectionExecutionChunks = chunks
      , sectionExecutionFailures = failures
      }

{- | Matches the upper bound on section plans (see
'validateResearchSectionPlan'); with this cap no run serializes a tail
behind the semaphore regardless of how many sections the planner chose.
-}
sectionCompilerMaxConcurrency :: Int
sectionCompilerMaxConcurrency = 8

validateResearchSectionPlan
  :: ResearchSectionPlan -> Either [SectionValidationError] ResearchSectionPlan
validateResearchSectionPlan plan =
  if null errors then Right plan else Left errors
  where
    errors =
      concat
        [ validateNonEmptyText "Report title must not be empty." plan.researchSectionPlanTitle
        , validateMaxChars "Report title exceeds 120 characters." 120 plan.researchSectionPlanTitle
        , [ SectionValidationError "Section plan must include at least one section."
          | null plan.researchSectionPlanSections
          ]
        , [ SectionValidationError "Section plan may include at most 8 sections."
          | length plan.researchSectionPlanSections > 8
          ]
        , case plan.researchSectionPlanSections of
            [] -> []
            (firstSection : _) ->
              [ SectionValidationError "The first section must be executive_summary."
              | firstSection.researchSectionId /= "executive_summary"
              ]
        , [ SectionValidationError ("Duplicate section id: " <> duplicateId)
          | duplicateId <- duplicateSectionIds plan.researchSectionPlanSections
          ]
        , concatMap validateSectionSpec plan.researchSectionPlanSections
        ]

normalizeResearchChunkToLimits :: ResearchChunkLimits -> ResearchChunk -> ResearchChunk
normalizeResearchChunkToLimits limits chunk =
  ResearchChunk
    { researchChunkSectionId = normalizeSectionId chunk.researchChunkSectionId
    , researchChunkTitle = T.strip chunk.researchChunkTitle
    , researchChunkSummary = normalizeOptionalText chunk.researchChunkSummary
    , researchChunkParagraphs =
        normalizeTextList limits.chunkParagraphMaxCount chunk.researchChunkParagraphs
    , researchChunkFindings =
        take limits.chunkFindingMaxCount
          . filter (not . T.null . researchFindingText)
          $ fmap normalizeFinding chunk.researchChunkFindings
    , researchChunkTables =
        if limits.chunkAllowTables
          then take limits.chunkTableMaxCount (fmap normalizeTable chunk.researchChunkTables)
          else []
    , researchChunkEvidenceRefs =
        normalizeRefList limits.chunkEvidenceRefMaxCount chunk.researchChunkEvidenceRefs
    , researchChunkExternalRefs =
        take limits.chunkExternalRefMaxCount chunk.researchChunkExternalRefs
    , researchChunkOpenGaps =
        normalizeTextList limits.chunkOpenGapMaxCount chunk.researchChunkOpenGaps
    }
  where
    -- SectionId is a snake_case key used for routing and persistence, so
    -- it stays hard-capped — unlike prose content, its length is part of
    -- its shape, and a multi-line section id is never the right answer.
    normalizeSectionId = T.take 64 . T.strip

    normalizeFinding finding =
      ResearchFinding
        { researchFindingText = T.strip finding.researchFindingText
        , researchFindingEvidenceRefs =
            normalizeRefList limits.chunkEvidenceRefMaxCount finding.researchFindingEvidenceRefs
        , researchFindingExternalRefs =
            take limits.chunkExternalRefMaxCount finding.researchFindingExternalRefs
        }

    normalizeTable table =
      let columns =
            (take limits.chunkTableMaxColumns . filter (not . T.null))
              (fmap T.strip table.researchTableColumns)
          width = length columns
          alignments =
            case table.researchTableAlignments of
              Nothing -> Nothing
              Just values
                | width <= 0 -> Nothing
                | otherwise ->
                    Just (take width values <> replicate (width - min width (length values)) ResearchAlignDefault)
          rows =
            take limits.chunkTableMaxRows $
              fmap (normalizeTableRow width) table.researchTableRows
       in ResearchTable
            { researchTableColumns = columns
            , researchTableAlignments = alignments
            , researchTableRows = rows
            }

    normalizeTableRow width row =
      let trimmed = take width (fmap T.strip row)
       in trimmed <> replicate (max 0 (width - length trimmed)) ""

normalizeOptionalText :: Maybe Text -> Maybe Text
normalizeOptionalText = \case
  Nothing -> Nothing
  Just value ->
    let stripped = T.strip value
     in if T.null stripped then Nothing else Just stripped

normalizeTextList :: Int -> [Text] -> [Text]
normalizeTextList maxItems =
  take maxItems
    . filter (not . T.null)
    . fmap T.strip

{- | Reference lists (evidenceRefs) are short deterministic identifiers
— tool-call ids like @call_5V4uLw…@. A 120-char ceiling on each ref
is still sensible because anything longer has to be junk. Unlike
prose content, truncation here can't corrupt a reader: a truncated
id simply won't resolve, so we'll see a lookup miss, not a mid-word
surprise in the user-facing report.
-}
normalizeRefList :: Int -> [Text] -> [Text]
normalizeRefList maxItems =
  take maxItems
    . filter (not . T.null)
    . fmap (T.take normalizedRefMaxChars . T.strip)

normalizedRefMaxChars :: Int
normalizedRefMaxChars = 120

{- | Structural validator for a normalized chunk. Only *shape* checks
survive — list-length caps, section-id format, non-empty required
text, table rectangularity. Per-char-length checks were dropped with
the normalizer's post-hoc truncation (see 'ResearchChunkLimits').
-}
validateResearchChunk
  :: ResearchChunkLimits -> ResearchChunk -> Either [SectionValidationError] ResearchChunk
validateResearchChunk limits chunk =
  if null errors then Right chunk else Left errors
  where
    errors =
      concat
        [ validateSectionId chunk.researchChunkSectionId
        , validateNonEmptyText "Chunk title must not be empty." chunk.researchChunkTitle
        , [ SectionValidationError "Chunk exceeds maximum paragraph count."
          | length chunk.researchChunkParagraphs > limits.chunkParagraphMaxCount
          ]
        , [ SectionValidationError "Chunk exceeds maximum finding count."
          | length chunk.researchChunkFindings > limits.chunkFindingMaxCount
          ]
        , concatMap validateFinding chunk.researchChunkFindings
        , validateChunkTables chunk.researchChunkTables
        , validateRefList "evidenceRefs" limits.chunkEvidenceRefMaxCount chunk.researchChunkEvidenceRefs
        , [ SectionValidationError "Chunk exceeds maximum external ref count."
          | length chunk.researchChunkExternalRefs > limits.chunkExternalRefMaxCount
          ]
        , [ SectionValidationError "Chunk exceeds maximum open gap count."
          | length chunk.researchChunkOpenGaps > limits.chunkOpenGapMaxCount
          ]
        , [ SectionValidationError
              "Chunk must include at least one summary, paragraph, finding, table, or open gap."
          | chunkHasNoRenderableContent chunk
          ]
        ]

    validateFinding finding =
      validateNonEmptyText "Finding text must not be empty." finding.researchFindingText
        <> validateRefList
          "finding evidenceRefs"
          limits.chunkEvidenceRefMaxCount
          finding.researchFindingEvidenceRefs
        <> [ SectionValidationError "Finding exceeds maximum external ref count."
           | length finding.researchFindingExternalRefs > limits.chunkExternalRefMaxCount
           ]

    validateTable table =
      let columns = table.researchTableColumns
          rowWidth = length columns
          alignmentErrors =
            case table.researchTableAlignments of
              Nothing -> []
              Just alignments
                | length alignments /= rowWidth ->
                    [SectionValidationError "Table alignments must match the column count."]
                | otherwise -> []
          rowErrors =
            concatMap
              ( \row ->
                  [SectionValidationError "Table row width must match the column count." | length row /= rowWidth]
              )
              table.researchTableRows
       in validateNonEmptyText "Table must include at least one column." (T.intercalate "|" columns)
            <> if length columns > limits.chunkTableMaxColumns
              then [SectionValidationError "Table exceeds maximum column count."]
              else
                []
                  <> if length table.researchTableRows > limits.chunkTableMaxRows
                    then [SectionValidationError "Table exceeds maximum row count."]
                    else
                      []
                        <> alignmentErrors
                        <> rowErrors

    validateChunkTables tables
      | not limits.chunkAllowTables =
          [SectionValidationError "Chunk tables are disabled for this retry profile." | not (null tables)]
      | otherwise =
          [ SectionValidationError "Chunk exceeds maximum table count."
          | length tables > limits.chunkTableMaxCount
          ]
            <> concatMap validateTable tables

researchSectionPlanSchema :: Aeson.Value
researchSectionPlanSchema =
  Aeson.object
    [ "type" .= ("object" :: Text)
    , "additionalProperties" .= False
    , "required" .= ["title" :: Text, "sections"]
    , "properties"
        .= Aeson.object
          [ "title"
              .= boundedStringSchema "Short report title." 120
          , "sections"
              .= arraySchema
                "Ordered section plan. Runtime hard cap: 1-8 sections. The first section must be executive_summary."
                sectionSpecSchema
          ]
    ]

{- | JSON Schema the section compiler LLM is asked to produce. External
refs are an array of integer indices into the candidate list supplied
alongside the prompt — not strings — so the model cannot truncate URLs
or titles. 'researchChunkLlmSchema' is the alias used for this schema
at the LLM interaction boundary; 'researchChunkSchema' is retained as a
back-compat name.
-}
researchChunkSchema :: ResearchChunkLimits -> Aeson.Value
researchChunkSchema = researchChunkLlmSchema

researchChunkLlmSchema :: ResearchChunkLimits -> Aeson.Value
researchChunkLlmSchema limits =
  Aeson.object
    [ "type" .= ("object" :: Text)
    , "additionalProperties" .= False
    , "required"
        .= [ "sectionId" :: Text
           , "title"
           , "summary"
           , "paragraphs"
           , "findings"
           , "tables"
           , "evidenceRefs"
           , "externalRefs"
           , "openGaps"
           ]
    , "properties"
        .= Aeson.object
          [ "sectionId" .= sectionIdSchema
          , "title" .= plainStringSchema "Section title."
          , "summary" .= nullableSchema (plainStringSchema "Optional section summary.")
          , "paragraphs" .= plainStringArraySchema "Section paragraphs." limits.chunkParagraphMaxCount
          , "findings"
              .= arraySchemaWithLimit "Section findings." limits.chunkFindingMaxCount (findingLlmSchema limits)
          , "tables" .= arraySchemaWithLimit "Section tables." limits.chunkTableMaxCount (tableSchema limits)
          , "evidenceRefs"
              .= refArraySchema "Deterministic tool-call ids used for this section." limits.chunkEvidenceRefMaxCount
          , "externalRefs" .= externalRefIndexArraySchema limits.chunkExternalRefMaxCount
          , "openGaps" .= plainStringArraySchema "Remaining gaps or follow-ups." limits.chunkOpenGapMaxCount
          ]
    ]

instance FromJSON ResearchSectionPlan where
  parseJSON = Aeson.withObject "ResearchSectionPlan" $ \o ->
    ResearchSectionPlan
      <$> o .: "title"
      <*> o .: "sections"

instance ToJSON ResearchSectionPlan where
  toJSON plan =
    Aeson.object
      [ "title" .= plan.researchSectionPlanTitle
      , "sections" .= plan.researchSectionPlanSections
      ]

instance FromJSON ResearchSectionSpec where
  parseJSON = Aeson.withObject "ResearchSectionSpec" $ \o ->
    ResearchSectionSpec
      <$> o .: "sectionId"
      <*> o .: "title"
      <*> o .: "brief"

instance ToJSON ResearchSectionSpec where
  toJSON sectionSpec =
    Aeson.object
      [ "sectionId" .= sectionSpec.researchSectionId
      , "title" .= sectionSpec.researchSectionTitle
      , "brief" .= sectionSpec.researchSectionBrief
      ]

-- FromJSON\/ToJSON for 'ResearchChunk' and 'ResearchFinding' are the

-- * persistence* shape: @externalRefs@ serializes as an array of full

-- 'ExternalRef' records (@{url, title, publishedDate, ...}@). The LLM
-- output shape — integer indices — is parsed via
-- 'parseResearchChunkLlmOutput', which takes the candidate list and
-- resolves each index into a full 'ExternalRef'.
instance FromJSON ResearchChunk where
  parseJSON = Aeson.withObject "ResearchChunk" $ \o ->
    ResearchChunk
      <$> o .: "sectionId"
      <*> o .: "title"
      <*> o .:? "summary"
      <*> o .:? "paragraphs" .!= []
      <*> o .:? "findings" .!= []
      <*> o .:? "tables" .!= []
      <*> o .:? "evidenceRefs" .!= []
      <*> o .:? "externalRefs" .!= []
      <*> o .:? "openGaps" .!= []

instance ToJSON ResearchChunk where
  toJSON chunk =
    Aeson.object
      [ "sectionId" .= chunk.researchChunkSectionId
      , "title" .= chunk.researchChunkTitle
      , "summary" .= chunk.researchChunkSummary
      , "paragraphs" .= chunk.researchChunkParagraphs
      , "findings" .= chunk.researchChunkFindings
      , "tables" .= chunk.researchChunkTables
      , "evidenceRefs" .= chunk.researchChunkEvidenceRefs
      , "externalRefs" .= chunk.researchChunkExternalRefs
      , "openGaps" .= chunk.researchChunkOpenGaps
      ]

instance FromJSON ResearchFinding where
  parseJSON = Aeson.withObject "ResearchFinding" $ \o ->
    ResearchFinding
      <$> o .: "text"
      <*> o .:? "evidenceRefs" .!= []
      <*> o .:? "externalRefs" .!= []

instance ToJSON ResearchFinding where
  toJSON finding =
    Aeson.object
      [ "text" .= finding.researchFindingText
      , "evidenceRefs" .= finding.researchFindingEvidenceRefs
      , "externalRefs" .= finding.researchFindingExternalRefs
      ]

instance FromJSON ExternalRef where
  parseJSON = Aeson.withObject "ExternalRef" $ \o ->
    ExternalRef
      <$> o .: "url"
      <*> o .:? "title"
      <*> o .:? "publishedDate"
      <*> o .:? "sourceToolCallId"

instance ToJSON ExternalRef where
  toJSON ref =
    Aeson.object
      [ "url" .= externalRefUrl ref
      , "title" .= externalRefTitle ref
      , "publishedDate" .= externalRefPublishedDate ref
      , "sourceToolCallId" .= externalRefSourceToolCallId ref
      ]

{- | Parse the section compiler LLM's JSON output into a 'ResearchChunk'.
The LLM's schema declares @externalRefs@ as an array of integer
indices into the candidate list passed alongside the prompt; this
parser resolves each index back to a full 'ExternalRef' and drops any
out-of-range or duplicate entries silently so a wayward index can't
sink an otherwise-valid chunk. Evidence refs stay stringly typed —
short deterministic tool-call ids the LLM copies reliably.
-}
parseResearchChunkLlmOutput :: [ExternalRef] -> Aeson.Value -> Either String ResearchChunk
parseResearchChunkLlmOutput candidates =
  AesonTypes.parseEither (parseLlmChunk candidates)

parseLlmChunk :: [ExternalRef] -> Aeson.Value -> AesonTypes.Parser ResearchChunk
parseLlmChunk candidates = Aeson.withObject "ResearchChunk" $ \o -> do
  sectionId <- o .: "sectionId"
  title <- o .: "title"
  summary <- o .:? "summary"
  paragraphs <- o .:? "paragraphs" .!= []
  rawFindings <- o .:? "findings" .!= []
  findings <- traverse (parseLlmFinding candidates) rawFindings
  tables <- o .:? "tables" .!= []
  evidenceRefs <- o .:? "evidenceRefs" .!= []
  externalRefIndices <- o .:? "externalRefs" .!= []
  openGaps <- o .:? "openGaps" .!= []
  pure
    ResearchChunk
      { researchChunkSectionId = sectionId
      , researchChunkTitle = title
      , researchChunkSummary = summary
      , researchChunkParagraphs = paragraphs
      , researchChunkFindings = findings
      , researchChunkTables = tables
      , researchChunkEvidenceRefs = evidenceRefs
      , researchChunkExternalRefs = resolveExternalRefIndices candidates externalRefIndices
      , researchChunkOpenGaps = openGaps
      }

parseLlmFinding :: [ExternalRef] -> Aeson.Value -> AesonTypes.Parser ResearchFinding
parseLlmFinding candidates = Aeson.withObject "ResearchFinding" $ \o -> do
  text <- o .: "text"
  evidenceRefs <- o .:? "evidenceRefs" .!= []
  externalRefIndices <- o .:? "externalRefs" .!= []
  pure
    ResearchFinding
      { researchFindingText = text
      , researchFindingEvidenceRefs = evidenceRefs
      , researchFindingExternalRefs = resolveExternalRefIndices candidates externalRefIndices
      }

resolveExternalRefIndices :: [ExternalRef] -> [Int] -> [ExternalRef]
resolveExternalRefIndices candidates = dedupeByUrl . mapMaybe lookupIndex
  where
    total = length candidates
    lookupIndex i
      | i < 0 || i >= total = Nothing
      | otherwise = Just (candidates !! i)
    dedupeByUrl = go []
      where
        go seen [] = reverse seen
        go seen (ref : rest)
          | any ((== externalRefUrl ref) . externalRefUrl) seen = go seen rest
          | otherwise = go (ref : seen) rest

instance FromJSON ResearchTable where
  parseJSON = Aeson.withObject "ResearchTable" $ \o ->
    ResearchTable
      <$> o .: "columns"
      <*> o .:? "alignments"
      <*> o .:? "rows" .!= []

instance ToJSON ResearchTable where
  toJSON table =
    Aeson.object
      [ "columns" .= table.researchTableColumns
      , "alignments" .= table.researchTableAlignments
      , "rows" .= table.researchTableRows
      ]

instance FromJSON ResearchTableAlignment where
  parseJSON = Aeson.withText "ResearchTableAlignment" $ \case
    "left" -> pure ResearchAlignLeft
    "center" -> pure ResearchAlignCenter
    "right" -> pure ResearchAlignRight
    "default" -> pure ResearchAlignDefault
    other -> fail ("Unknown table alignment: " <> T.unpack other)

instance ToJSON ResearchTableAlignment where
  toJSON = \case
    ResearchAlignLeft -> Aeson.String "left"
    ResearchAlignCenter -> Aeson.String "center"
    ResearchAlignRight -> Aeson.String "right"
    ResearchAlignDefault -> Aeson.String "default"

sectionSpecSchema :: Aeson.Value
sectionSpecSchema =
  Aeson.object
    [ "type" .= ("object" :: Text)
    , "additionalProperties" .= False
    , "required" .= ["sectionId" :: Text, "title", "brief"]
    , "properties"
        .= Aeson.object
          [ "sectionId" .= sectionIdSchema
          , "title" .= boundedStringSchema "Short section title." 120
          , "brief" .= boundedStringSchema "One concise sentence describing the section focus." 600
          ]
    ]

findingLlmSchema :: ResearchChunkLimits -> Aeson.Value
findingLlmSchema limits =
  Aeson.object
    [ "type" .= ("object" :: Text)
    , "additionalProperties" .= False
    , "required" .= ["text" :: Text, "evidenceRefs", "externalRefs"]
    , "properties"
        .= Aeson.object
          [ "text"
              .= plainStringSchema
                "Short finding text (one concise sentence; prefer splitting ideas across multiple findings over one long finding)."
          , "evidenceRefs"
              .= refArraySchema
                "Deterministic tool-call ids supporting this finding."
                limits.chunkEvidenceRefMaxCount
          , "externalRefs" .= externalRefIndexArraySchema limits.chunkExternalRefMaxCount
          ]
    ]

externalRefIndexArraySchema :: Int -> Aeson.Value
externalRefIndexArraySchema maxItems =
  Aeson.object
    [ "type" .= ("array" :: Text)
    , "description"
        .= ( "Integer indices into the Available external refs JSON list. "
               <> "Each index is the `idx` value of the entry being cited. "
               <> "Do not emit URLs, titles, or any other string form. "
               <> "Runtime hard cap: up to "
               <> T.pack (show maxItems)
               <> " items."
               :: Text
           )
    , "items" .= Aeson.object ["type" .= ("integer" :: Text)]
    ]

tableSchema :: ResearchChunkLimits -> Aeson.Value
tableSchema limits =
  Aeson.object
    [ "type" .= ("object" :: Text)
    , "additionalProperties" .= False
    , "required" .= ["columns" :: Text, "alignments", "rows"]
    , "properties"
        .= Aeson.object
          [ "columns" .= plainStringArraySchema "Table columns." limits.chunkTableMaxColumns
          , "alignments"
              .= nullableSchema
                ( arraySchemaWithLimit
                    "Optional table alignments."
                    limits.chunkTableMaxColumns
                    ( Aeson.object
                        [ "type" .= ("string" :: Text)
                        , "enum" .= ["left" :: Text, "center", "right", "default"]
                        ]
                    )
                )
          , "rows"
              .= arraySchemaWithLimit
                "Table rows."
                limits.chunkTableMaxRows
                ( arraySchemaWithLimit
                    "Table row cells."
                    limits.chunkTableMaxColumns
                    (plainStringSchema "Table cell text.")
                )
          ]
    ]

sectionIdSchema :: Aeson.Value
sectionIdSchema =
  Aeson.object
    [ "type" .= ("string" :: Text)
    , "description"
        .= ("Stable lowercase snake_case section id. The first section must be executive_summary." :: Text)
    , "pattern" .= ("^[a-z0-9_]+$" :: Text)
    , "maxLength" .= (64 :: Int)
    ]

refArraySchema :: Text -> Int -> Aeson.Value
refArraySchema description maxItems =
  arraySchemaWithLimit description maxItems (boundedStringSchema "Reference id." 120)

{- | Plain string schema with no 'maxLength'. See the comment on
'ResearchChunkLimits' for why character caps are no longer enforced
at this boundary.
-}
plainStringSchema :: Text -> Aeson.Value
plainStringSchema description =
  Aeson.object
    [ "type" .= ("string" :: Text)
    , "description" .= description
    ]

plainStringArraySchema :: Text -> Int -> Aeson.Value
plainStringArraySchema description maxItems =
  arraySchemaWithLimit description maxItems (plainStringSchema "String value.")

arraySchemaWithLimit :: Text -> Int -> Aeson.Value -> Aeson.Value
arraySchemaWithLimit description maxItems =
  arraySchema (description <> " Runtime hard cap: up to " <> T.pack (show maxItems) <> " items.")

arraySchema :: Text -> Aeson.Value -> Aeson.Value
arraySchema description itemSchema =
  Aeson.object
    [ "type" .= ("array" :: Text)
    , "description" .= description
    , "items" .= itemSchema
    ]

boundedStringSchema :: Text -> Int -> Aeson.Value
boundedStringSchema description maxChars =
  Aeson.object
    [ "type" .= ("string" :: Text)
    , "description" .= description
    , "maxLength" .= maxChars
    ]

nullableSchema :: Aeson.Value -> Aeson.Value
nullableSchema schema =
  Aeson.object
    [ "anyOf"
        .= [ schema
           , Aeson.object ["type" .= ("null" :: Text)]
           ]
    ]

validateSectionSpec :: ResearchSectionSpec -> [SectionValidationError]
validateSectionSpec spec =
  validateSectionId spec.researchSectionId
    <> validateNonEmptyText "Section title must not be empty." spec.researchSectionTitle
    <> validateMaxChars "Section title exceeds 120 characters." 120 spec.researchSectionTitle
    <> validateNonEmptyText "Section brief must not be empty." spec.researchSectionBrief
    <> validateMaxChars "Section brief exceeds 600 characters." 600 spec.researchSectionBrief

validateSectionId :: Text -> [SectionValidationError]
validateSectionId sectionId =
  validateNonEmptyText "Section id must not be empty." sectionId
    <> validateMaxChars "Section id exceeds 64 characters." 64 sectionId
    <> [ SectionValidationError "Section id must be lowercase snake_case." | not (isValidSectionId sectionId)
       ]

validateRefList :: Text -> Int -> [Text] -> [SectionValidationError]
validateRefList fieldName maxItems refs =
  [ SectionValidationError (fieldName <> " exceeds the maximum item count.")
  | length refs > maxItems
  ]
    <> concatMap (validateMaxChars (fieldName <> " entry exceeds the maximum length.") 120) refs

validateNonEmptyText :: Text -> Text -> [SectionValidationError]
validateNonEmptyText errMessage value =
  [SectionValidationError errMessage | T.null (T.strip value)]

validateMaxChars :: Text -> Int -> Text -> [SectionValidationError]
validateMaxChars errMessage maxChars value =
  [SectionValidationError errMessage | T.length value > maxChars]

duplicateSectionIds :: [ResearchSectionSpec] -> [Text]
duplicateSectionIds specs =
  fmap firstDuplicate . filter ((> 1) . length) . groupStable $ fmap (.researchSectionId) specs
  where
    firstDuplicate (x : _) = x
    firstDuplicate [] = ""

    groupStable [] = []
    groupStable (x : xs) =
      let matches = x : filter (== x) xs
          rest = filter (/= x) xs
       in matches : groupStable rest

chunkHasNoRenderableContent :: ResearchChunk -> Bool
chunkHasNoRenderableContent chunk =
  maybe True (T.null . T.strip) chunk.researchChunkSummary
    && all (T.null . T.strip) chunk.researchChunkParagraphs
    && null chunk.researchChunkFindings
    && null chunk.researchChunkTables
    && null chunk.researchChunkOpenGaps

researchChunkHasVisibleBody :: ResearchChunk -> Bool
researchChunkHasVisibleBody chunk =
  maybe False hasNonEmptyText chunk.researchChunkSummary
    || any hasNonEmptyText chunk.researchChunkParagraphs
    || not (null chunk.researchChunkTables)

researchChunkHasVisibleContent :: ResearchChunk -> Bool
researchChunkHasVisibleContent chunk =
  researchChunkHasVisibleBody chunk
    || any (hasNonEmptyText . (.researchFindingText)) chunk.researchChunkFindings

hasNonEmptyText :: Text -> Bool
hasNonEmptyText = not . T.null . T.strip

isValidSectionId :: Text -> Bool
isValidSectionId sectionId =
  not (T.null sectionId)
    && T.all (\c -> c == '_' || isAsciiLower c || isDigit c) sectionId
