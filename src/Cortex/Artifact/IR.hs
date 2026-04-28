{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Artifact.IR
  ( -- * IR types
    ReportIR (..),
    ValidatedReportIR (..),
    Block (..),
    Inline (..),
    Source (..),
    Provenance (..),
    TableDef (..),
    EmbedSpec (..),
    CurrencyCode (..),
    Alignment (..),

    -- * Validation
    ValidationError (..),
    validateIR,

    -- * Compilation
    CompileError (..),
    compileValidatedToAnnotatedHtml,
    compileValidatedToMarkdown,
    compileToMarkdown,
    compileToAnnotatedHtml,

    -- * Formatting helpers (exported for tests)
    formatCurrency,
    formatDecimal,
    formatPct,
    escapeTableCell,
    escapePlainText,

    -- * ISO 4217
    iso4217Codes,
  )
where

import Control.Lens ((&), (?~))
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.Char (isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, maybeToList)
import Data.OpenApi (NamedSchema (..), OpenApiType (..), ToSchema (..), description, type_)
import Data.Scientific (Scientific)
import Data.Scientific qualified as Sci
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Builder qualified as TB
import Data.Text.Lazy.Builder.Int qualified as TBI
import GHC.Generics (Generic)

-- | Top-level report IR.
data ReportIR = ReportIR
  { reportVersion :: Int,
    reportBlocks :: [Block],
    reportProvenance :: Maybe (Map Int Provenance)
  }
  deriving stock (Eq, Show, Generic)

newtype ValidatedReportIR = ValidatedReportIR
  { unValidatedReportIR :: ReportIR
  }
  deriving stock (Eq, Show, Generic)

-- | Block-level IR nodes.
data Block
  = HeadingBlock Int [Inline]
  | ParagraphBlock [Inline]
  | TableBlock TableDef
  | BulletListBlock [[Inline]]
  | OrderedListBlock [[Inline]]
  | CodeBlock Text Text
  | MathBlock Text
  | HorizontalRule
  deriving stock (Eq, Show, Generic)

-- | Inline-level IR nodes.
data Inline
  = PlainText Text
  | BoldText [Inline]
  | ItalicText [Inline]
  | InlineCode Text
  | InlineMath Text
  | Currency Scientific CurrencyCode
  | Pct Scientific
  | Ref Text Text
  | Link Text Text
  | Embed EmbedSpec
  | Sourced Int Inline
  deriving stock (Eq, Show, Generic)

-- | Provenance source reference.
data Source = Source
  { sourceToolCallId :: Text,
    sourceFieldPath :: Text
  }
  deriving stock (Eq, Show, Generic)

-- | Provenance for a sourced inline value.
data Provenance
  = Direct Source
  | Computed [Source] Text
  deriving stock (Eq, Show, Generic)

-- | Table definition.
data TableDef = TableDef
  { tableColumns :: [Text],
    tableAlignments :: Maybe [Alignment],
    tableRows :: [[[Inline]]]
  }
  deriving stock (Eq, Show, Generic)

-- | Embed widget spec.
data EmbedSpec
  = PriceEmbed Text
  | ChartEmbed Text Text (Maybe Text)
  deriving stock (Eq, Show, Generic)

-- | ISO 4217 currency code (validated).
newtype CurrencyCode = CurrencyCode {unCurrencyCode :: Text}
  deriving stock (Eq, Show, Generic)

-- | Column alignment.
data Alignment = AlignLeft | AlignCenter | AlignRight | AlignDefault
  deriving stock (Eq, Show, Generic)

--------------------------------------------------------------------------------
-- OpenAPI schema
--------------------------------------------------------------------------------

-- | Opaque schema: the IR uses custom tagged-union JSON encoding that cannot
-- be expressed via Generic-derived ToSchema.  We declare it as an opaque JSON
-- object so the OpenAPI docs don't mislead consumers.
instance ToSchema ReportIR where
  declareNamedSchema _ =
    pure . NamedSchema (Just "ReportIR") $
      mempty
        & type_ ?~ OpenApiObject
        & description ?~ "Report intermediate representation (v1). Uses custom tagged-union JSON encoding — see IR documentation for the full schema."

--------------------------------------------------------------------------------
-- FromJSON instances
--------------------------------------------------------------------------------

instance FromJSON ReportIR where
  parseJSON = Aeson.withObject "ReportIR" $ \o -> do
    v <- o .: "version"
    bs <- o .: "blocks"
    prov <- o .:? "provenance"
    pure (ReportIR v bs prov)

instance FromJSON Block where
  parseJSON = Aeson.withObject "Block" $ \o -> do
    tag <- o .: "type" :: Parser Text
    case tag of
      "heading" -> HeadingBlock <$> o .: "level" <*> o .: "content"
      "paragraph" -> ParagraphBlock <$> o .: "content"
      "table" -> do
        cols <- o .: "columns"
        aligns <- o .:? "alignments"
        rows <- o .: "rows"
        pure (TableBlock (TableDef cols aligns rows))
      "bullet_list" -> BulletListBlock <$> o .: "items"
      "ordered_list" -> OrderedListBlock <$> o .: "items"
      "code" -> CodeBlock <$> o .: "language" <*> o .: "content"
      "math_block" -> MathBlock <$> o .: "content"
      "horizontal_rule" -> pure HorizontalRule
      other -> fail ("Unknown block type: " <> T.unpack other)

instance FromJSON Inline where
  parseJSON = Aeson.withObject "Inline" $ \o -> do
    tag <- o .: "type" :: Parser Text
    case tag of
      "text" -> PlainText <$> o .: "value"
      "bold" -> BoldText <$> o .: "content"
      "italic" -> ItalicText <$> o .: "content"
      "code" -> InlineCode <$> o .: "value"
      "math" -> InlineMath <$> o .: "value"
      "currency" -> Currency <$> o .: "amount" <*> o .: "currencyCode"
      "pct" -> Pct <$> o .: "value"
      "ref" -> Ref <$> o .: "label" <*> o .: "value"
      "link" -> Link <$> o .: "text" <*> o .: "url"
      "embed" -> Embed <$> parseJSON (Aeson.Object o)
      "sourced" -> Sourced <$> o .: "provenanceId" <*> o .: "content"
      other -> fail ("Unknown inline type: " <> T.unpack other)

instance FromJSON EmbedSpec where
  parseJSON = Aeson.withObject "EmbedSpec" $ \o -> do
    tag <- o .: "embedType" :: Parser Text
    case tag of
      "price" -> PriceEmbed <$> o .: "symbol"
      "chart" -> ChartEmbed <$> o .: "symbol" <*> o .: "range" <*> o .:? "style"
      other -> fail ("Unknown embed type: " <> T.unpack other)

instance FromJSON CurrencyCode where
  parseJSON = Aeson.withText "CurrencyCode" $ \t ->
    pure (CurrencyCode t)

instance FromJSON Alignment where
  parseJSON = Aeson.withText "Alignment" $ \case
    "left" -> pure AlignLeft
    "center" -> pure AlignCenter
    "right" -> pure AlignRight
    "default" -> pure AlignDefault
    other -> fail ("Unknown alignment: " <> T.unpack other)

instance FromJSON TableDef where
  parseJSON = Aeson.withObject "TableDef" $ \o ->
    TableDef <$> o .: "columns" <*> o .:? "alignments" <*> o .: "rows"

instance FromJSON Source where
  parseJSON = Aeson.withObject "Source" $ \o ->
    Source <$> o .: "toolCallId" <*> o .: "fieldPath"

instance FromJSON Provenance where
  parseJSON = Aeson.withObject "Provenance" $ \o -> do
    tag <- o .: "kind" :: Parser Text
    case tag of
      "direct" -> Direct <$> o .: "source"
      "computed" -> Computed <$> o .: "sources" <*> o .: "operation"
      other -> fail ("Unknown provenance kind: " <> T.unpack other)

--------------------------------------------------------------------------------
-- ToJSON instances (symmetric, for round-trip tests)
--------------------------------------------------------------------------------

instance ToJSON ReportIR where
  toJSON ir =
    Aeson.object $
      [ "version" .= reportVersion ir,
        "blocks" .= reportBlocks ir
      ]
        <> foldMap (\prov -> ["provenance" .= prov]) (reportProvenance ir)

instance ToJSON Block where
  toJSON (HeadingBlock level content) =
    Aeson.object ["type" .= ("heading" :: Text), "level" .= level, "content" .= content]
  toJSON (ParagraphBlock content) =
    Aeson.object ["type" .= ("paragraph" :: Text), "content" .= content]
  toJSON (TableBlock td) =
    Aeson.object $
      ["type" .= ("table" :: Text), "columns" .= tableColumns td, "rows" .= tableRows td]
        <> foldMap (\a -> ["alignments" .= a]) (tableAlignments td)
  toJSON (BulletListBlock items) =
    Aeson.object ["type" .= ("bullet_list" :: Text), "items" .= items]
  toJSON (OrderedListBlock items) =
    Aeson.object ["type" .= ("ordered_list" :: Text), "items" .= items]
  toJSON (CodeBlock lang content) =
    Aeson.object ["type" .= ("code" :: Text), "language" .= lang, "content" .= content]
  toJSON (MathBlock content) =
    Aeson.object ["type" .= ("math_block" :: Text), "content" .= content]
  toJSON HorizontalRule =
    Aeson.object ["type" .= ("horizontal_rule" :: Text)]

instance ToJSON Inline where
  toJSON (PlainText v) = Aeson.object ["type" .= ("text" :: Text), "value" .= v]
  toJSON (BoldText content) = Aeson.object ["type" .= ("bold" :: Text), "content" .= content]
  toJSON (ItalicText content) = Aeson.object ["type" .= ("italic" :: Text), "content" .= content]
  toJSON (InlineCode v) = Aeson.object ["type" .= ("code" :: Text), "value" .= v]
  toJSON (InlineMath v) = Aeson.object ["type" .= ("math" :: Text), "value" .= v]
  toJSON (Currency amount cc) = Aeson.object ["type" .= ("currency" :: Text), "amount" .= amount, "currencyCode" .= cc]
  toJSON (Pct v) = Aeson.object ["type" .= ("pct" :: Text), "value" .= v]
  toJSON (Ref label value) = Aeson.object ["type" .= ("ref" :: Text), "label" .= label, "value" .= value]
  toJSON (Link text url) = Aeson.object ["type" .= ("link" :: Text), "text" .= text, "url" .= url]
  toJSON (Embed (PriceEmbed s)) =
    Aeson.object ["type" .= ("embed" :: Text), "embedType" .= ("price" :: Text), "symbol" .= s]
  toJSON (Embed (ChartEmbed s r st)) =
    Aeson.object $
      ["type" .= ("embed" :: Text), "embedType" .= ("chart" :: Text), "symbol" .= s, "range" .= r]
        <> foldMap (\v -> ["style" .= v]) st
  toJSON (Sourced provenanceId content) =
    Aeson.object ["type" .= ("sourced" :: Text), "provenanceId" .= provenanceId, "content" .= content]

instance ToJSON EmbedSpec where
  toJSON (PriceEmbed s) = Aeson.object ["embedType" .= ("price" :: Text), "symbol" .= s]
  toJSON (ChartEmbed s r st) =
    Aeson.object $
      ["embedType" .= ("chart" :: Text), "symbol" .= s, "range" .= r]
        <> foldMap (\v -> ["style" .= v]) st

instance ToJSON CurrencyCode where
  toJSON (CurrencyCode t) = Aeson.String t

instance ToJSON Alignment where
  toJSON AlignLeft = Aeson.String "left"
  toJSON AlignCenter = Aeson.String "center"
  toJSON AlignRight = Aeson.String "right"
  toJSON AlignDefault = Aeson.String "default"

instance ToJSON TableDef where
  toJSON td =
    Aeson.object $
      ["columns" .= tableColumns td, "rows" .= tableRows td]
        <> foldMap (\a -> ["alignments" .= a]) (tableAlignments td)

instance ToJSON Source where
  toJSON source =
    Aeson.object
      [ "toolCallId" .= sourceToolCallId source,
        "fieldPath" .= sourceFieldPath source
      ]

instance ToJSON Provenance where
  toJSON (Direct source) =
    Aeson.object ["kind" .= ("direct" :: Text), "source" .= source]
  toJSON (Computed sources operation) =
    Aeson.object
      [ "kind" .= ("computed" :: Text),
        "sources" .= sources,
        "operation" .= operation
      ]

--------------------------------------------------------------------------------
-- Validation
--------------------------------------------------------------------------------

data ValidationError
  = UnsupportedVersion Int
  | InvalidHeadingLevel Int
  | InvalidCurrencyCode Text
  | PctOutOfRange Scientific
  | TooManyBlocks Int
  | TooManyRows Int
  | TooManyColumns Int
  | StringTooLong Text Int
  | -- | row index, expected cols, actual cols
    RaggedTableRow Int Int Int
  | EmptyBlocks
  | NestedSourced
  | SourcedWrapsStructural
  | InvalidProvenanceId Int
  | ProvenanceIndexMissing
  | UnknownProvenanceId Int
  | EmptyToolCallId
  | InvalidLinkUrl Text
  | InvalidChartRange Text
  | InvalidChartStyle Text
  deriving stock (Eq, Show, Generic)

validateIR :: ReportIR -> Either [ValidationError] ValidatedReportIR
validateIR ir =
  if null errs then Right (ValidatedReportIR ir) else Left errs
  where
    provenanceIndex = reportProvenance ir
    errs = concat [versionErrors, blockCountErrors, provenanceErrors, blockErrors]

    versionErrors
      | reportVersion ir /= 1 = [UnsupportedVersion (reportVersion ir)]
      | otherwise = []

    blockCountErrors
      | length (reportBlocks ir) > 100 = [TooManyBlocks (length (reportBlocks ir))]
      | null (reportBlocks ir) = [EmptyBlocks]
      | otherwise = []

    provenanceErrors = concatMap validateProvenanceEntry (foldMap Map.toList provenanceIndex)

    blockErrors = concatMap (validateBlock provenanceIndex) (reportBlocks ir)

    validateProvenanceEntry :: (Int, Provenance) -> [ValidationError]
    validateProvenanceEntry (provenanceId, provenance) =
      [InvalidProvenanceId provenanceId | provenanceId <= 0]
        <> validateProvenance provenance

    validateProvenance :: Provenance -> [ValidationError]
    validateProvenance (Direct source) = validateSource source
    validateProvenance (Computed sources _) = concatMap validateSource sources

    validateSource :: Source -> [ValidationError]
    validateSource source =
      [EmptyToolCallId | T.null (T.strip (sourceToolCallId source))]

    validateBlock :: Maybe (Map Int Provenance) -> Block -> [ValidationError]
    validateBlock provenanceIndex' (HeadingBlock level inlines) =
      [InvalidHeadingLevel level | level < 2 || level > 6]
        <> concatMap (validateInline provenanceIndex') inlines
    validateBlock provenanceIndex' (ParagraphBlock inlines) = concatMap (validateInline provenanceIndex') inlines
    validateBlock provenanceIndex' (TableBlock td) = validateTable provenanceIndex' td
    validateBlock provenanceIndex' (BulletListBlock items) = concatMap (concatMap (validateInline provenanceIndex')) items
    validateBlock provenanceIndex' (OrderedListBlock items) = concatMap (concatMap (validateInline provenanceIndex')) items
    validateBlock _ (CodeBlock _ content) = validateStringLength "code content" content
    validateBlock _ (MathBlock content) = validateStringLength "math content" content
    validateBlock _ HorizontalRule = []

    validateTable :: Maybe (Map Int Provenance) -> TableDef -> [ValidationError]
    validateTable provenanceIndex' td =
      let colCount = length (tableColumns td)
          rowCount = length (tableRows td)
          colErrors = [TooManyColumns colCount | colCount > 20]
          rowErrors = [TooManyRows rowCount | rowCount > 500]
          cellErrors = concatMap (concatMap (concatMap (validateInline provenanceIndex'))) (tableRows td)
          rowWidthErrors =
            [ RaggedTableRow rowIdx colCount (length row)
            | (rowIdx, row) <- zip [0 :: Int ..] (tableRows td),
              length row /= colCount
            ]
       in colErrors <> rowErrors <> rowWidthErrors <> cellErrors

    validateInline :: Maybe (Map Int Provenance) -> Inline -> [ValidationError]
    validateInline _ (PlainText t) = validateStringLength "text" t
    validateInline provenanceIndex' (BoldText inlines) = concatMap (validateInline provenanceIndex') inlines
    validateInline provenanceIndex' (ItalicText inlines) = concatMap (validateInline provenanceIndex') inlines
    validateInline _ (InlineCode t) = validateStringLength "code" t
    validateInline _ (InlineMath t) = validateStringLength "math" t
    validateInline _ (Currency _ (CurrencyCode cc)) =
      [InvalidCurrencyCode cc | not (Set.member cc iso4217Codes)]
    validateInline _ (Pct fraction) = [PctOutOfRange fraction | abs fraction > 10]
    validateInline _ (Ref label value) = validateStringLength "ref label" label <> validateStringLength "ref value" value
    validateInline _ (Link t u) =
      validateStringLength "link text" t
        <> validateStringLength "link url" u
        <> [InvalidLinkUrl u | not (isValidLinkUrl u)]
    validateInline _ (Embed (PriceEmbed symbol)) = validateStringLength "embed symbol" symbol
    validateInline _ (Embed (ChartEmbed symbol range maybeStyle)) =
      validateStringLength "embed symbol" symbol
        <> [InvalidChartRange range | not (Set.member (T.toUpper range) allowedChartRanges)]
        <> [InvalidChartStyle style | style <- maybeToList maybeStyle, not (Set.member (T.toLower style) allowedChartStyles)]
    validateInline provenanceIndex' (Sourced provenanceId inner) =
      sourcedShapeErrors inner
        <> [InvalidProvenanceId provenanceId | provenanceId <= 0]
        <> provenanceErrorsFor provenanceIndex' provenanceId
        <> validateInline provenanceIndex' inner

    sourcedShapeErrors :: Inline -> [ValidationError]
    sourcedShapeErrors (PlainText _) = []
    sourcedShapeErrors (InlineCode _) = []
    sourcedShapeErrors (InlineMath _) = []
    sourcedShapeErrors (Currency _ _) = []
    sourcedShapeErrors (Pct _) = []
    sourcedShapeErrors (BoldText _) = [SourcedWrapsStructural]
    sourcedShapeErrors (ItalicText _) = [SourcedWrapsStructural]
    sourcedShapeErrors (Ref _ _) = [SourcedWrapsStructural]
    sourcedShapeErrors (Link _ _) = [SourcedWrapsStructural]
    sourcedShapeErrors (Embed _) = [SourcedWrapsStructural]
    sourcedShapeErrors (Sourced _ _) = [NestedSourced]

    provenanceErrorsFor :: Maybe (Map Int Provenance) -> Int -> [ValidationError]
    provenanceErrorsFor _ provenanceId | provenanceId <= 0 = []
    provenanceErrorsFor Nothing _ = [ProvenanceIndexMissing]
    provenanceErrorsFor (Just provenanceIndex') provenanceId =
      [UnknownProvenanceId provenanceId | Map.notMember provenanceId provenanceIndex']

    validateStringLength :: Text -> Text -> [ValidationError]
    validateStringLength label t =
      [StringTooLong label (T.length t) | T.length t > 10000]

--------------------------------------------------------------------------------
-- Compilation
--------------------------------------------------------------------------------

newtype CompileError = CompileError Text
  deriving stock (Eq, Show, Generic)

compileToMarkdown :: ReportIR -> Either CompileError Text
compileToMarkdown ir =
  case validateIR ir of
    Left errs -> Left (CompileError ("Validation failed: " <> T.pack (show errs)))
    Right validated -> Right (compileValidatedToMarkdown validated)

compileToAnnotatedHtml :: ReportIR -> Either CompileError Text
compileToAnnotatedHtml ir =
  case validateIR ir of
    Left errs -> Left (CompileError ("Validation failed: " <> T.pack (show errs)))
    Right validated -> Right (compileValidatedToAnnotatedHtml validated)

compileValidatedToMarkdown :: ValidatedReportIR -> Text
compileValidatedToMarkdown (ValidatedReportIR ir) =
  T.intercalate "\n\n" (fmap compileBlock (reportBlocks ir))

compileValidatedToAnnotatedHtml :: ValidatedReportIR -> Text
compileValidatedToAnnotatedHtml (ValidatedReportIR ir) =
  let provenanceIndex = fromMaybe Map.empty (reportProvenance ir)
   in T.intercalate "\n" (fmap (compileHtmlBlock provenanceIndex) (reportBlocks ir))

compileBlock :: Block -> Text
compileBlock (HeadingBlock level inlines) =
  T.replicate level "#" <> " " <> compileInlines inlines
compileBlock (ParagraphBlock inlines) =
  compileInlines inlines
compileBlock (TableBlock td) =
  compileTable td
compileBlock (BulletListBlock items) =
  T.intercalate "\n" (fmap (\item -> "- " <> compileInlines item) items)
compileBlock (OrderedListBlock items) =
  T.intercalate "\n" (zipWith (\i item -> T.pack (show i) <> ". " <> compileInlines item) [1 :: Int ..] items)
compileBlock (CodeBlock lang content) =
  "```" <> sanitizeLang lang <> "\n" <> content <> "\n```"
compileBlock (MathBlock content) =
  "$$\n" <> content <> "\n$$"
compileBlock HorizontalRule =
  "---"

compileHtmlBlock :: Map Int Provenance -> Block -> Text
compileHtmlBlock provenanceIndex (HeadingBlock level inlines) =
  let normalizedLevel = max 1 (min 6 level)
      tag = "h" <> T.pack (show normalizedLevel)
   in "<" <> tag <> ">" <> compileHtmlInlines provenanceIndex inlines <> "</" <> tag <> ">"
compileHtmlBlock provenanceIndex (ParagraphBlock inlines) =
  "<p>" <> compileHtmlInlines provenanceIndex inlines <> "</p>"
compileHtmlBlock provenanceIndex (TableBlock td) =
  compileHtmlTable provenanceIndex td
compileHtmlBlock provenanceIndex (BulletListBlock items) =
  "<ul>" <> T.concat (fmap (\item -> "<li>" <> compileHtmlInlines provenanceIndex item <> "</li>") items) <> "</ul>"
compileHtmlBlock provenanceIndex (OrderedListBlock items) =
  "<ol>" <> T.concat (fmap (\item -> "<li>" <> compileHtmlInlines provenanceIndex item <> "</li>") items) <> "</ol>"
compileHtmlBlock _ (CodeBlock lang content) =
  "<pre><code class=\"language-"
    <> escapeHtmlAttribute (sanitizeLang lang)
    <> "\">"
    <> escapeHtmlText content
    <> "</code></pre>"
compileHtmlBlock _ (MathBlock content) =
  "<div>$$\n" <> escapeHtmlText content <> "\n$$</div>"
compileHtmlBlock _ HorizontalRule =
  "<hr />"

compileTable :: TableDef -> Text
compileTable td =
  let headers = "| " <> T.intercalate " | " (tableColumns td) <> " |"
      alignRow = mkAlignmentRow (length (tableColumns td)) (tableAlignments td)
      dataRows = fmap compileTableRow (tableRows td)
   in T.intercalate "\n" (headers : alignRow : dataRows)

mkAlignmentRow :: Int -> Maybe [Alignment] -> Text
mkAlignmentRow colCount maybeAligns =
  let aligns = fromMaybe (replicate colCount AlignDefault) maybeAligns
      padded = take colCount (aligns <> repeat AlignDefault)
      cells = fmap alignCell padded
   in "| " <> T.intercalate " | " cells <> " |"
  where
    alignCell AlignLeft = ":---"
    alignCell AlignCenter = ":---:"
    alignCell AlignRight = "---:"
    alignCell AlignDefault = "---"

compileTableRow :: [[Inline]] -> Text
compileTableRow cells =
  "| " <> T.intercalate " | " (fmap (escapeTableCell . compileInlines) cells) <> " |"

compileHtmlTable :: Map Int Provenance -> TableDef -> Text
compileHtmlTable provenanceIndex td =
  let headerCells =
        zipWith
          (\label alignment -> compileHtmlTableCell "th" alignment (" scope=\"col\"") (escapeHtmlText label))
          (tableColumns td)
          (normalizedAlignments td)
      bodyRows =
        fmap
          ( \row ->
              "<tr>"
                <> T.concat
                  ( zipWith
                      (\cell alignment -> compileHtmlTableCell "td" alignment "" (compileHtmlInlines provenanceIndex cell))
                      row
                      (normalizedAlignments td)
                  )
                <> "</tr>"
          )
          (tableRows td)
   in "<table><thead><tr>"
        <> T.concat headerCells
        <> "</tr></thead><tbody>"
        <> T.concat bodyRows
        <> "</tbody></table>"

compileHtmlTableCell :: Text -> Alignment -> Text -> Text -> Text
compileHtmlTableCell tag alignment extraAttrs content =
  let styleAttr = alignmentStyle alignment
   in "<" <> tag <> styleAttr <> extraAttrs <> ">" <> content <> "</" <> tag <> ">"

normalizedAlignments :: TableDef -> [Alignment]
normalizedAlignments td =
  let colCount = length (tableColumns td)
      aligns = fromMaybe (replicate colCount AlignDefault) (tableAlignments td)
   in take colCount (aligns <> repeat AlignDefault)

alignmentStyle :: Alignment -> Text
alignmentStyle AlignLeft = " style=\"text-align: left;\""
alignmentStyle AlignCenter = " style=\"text-align: center;\""
alignmentStyle AlignRight = " style=\"text-align: right;\""
alignmentStyle AlignDefault = ""

compileInlines :: [Inline] -> Text
compileInlines = T.concat . fmap compileInline

compileHtmlInlines :: Map Int Provenance -> [Inline] -> Text
compileHtmlInlines provenanceIndex = T.concat . fmap (compileHtmlInline provenanceIndex)

compileInline :: Inline -> Text
compileInline (PlainText t) = escapePlainText t
compileInline (BoldText inlines) = "**" <> compileInlines inlines <> "**"
compileInline (ItalicText inlines) = "*" <> compileInlines inlines <> "*"
compileInline (InlineCode t) =
  if T.isInfixOf "`" t
    then "`` " <> t <> " ``"
    else "`" <> t <> "`"
compileInline (InlineMath t) = "$" <> t <> "$"
compileInline (Currency amount cc) = formatCurrency amount cc
compileInline (Pct fraction) = formatPct fraction
compileInline (Ref label value) = escapePlainText label <> ": " <> escapePlainText value
compileInline (Link text url) = "[" <> escapeLinkText text <> "](" <> escapeLinkUrl url <> ")"
compileInline (Embed spec) = compileEmbed spec
compileInline (Sourced _ inner) = compileInline inner

compileHtmlInline :: Map Int Provenance -> Inline -> Text
compileHtmlInline _ (PlainText t) = escapeHtmlText t
compileHtmlInline provenanceIndex (BoldText inlines) =
  "<strong>" <> compileHtmlInlines provenanceIndex inlines <> "</strong>"
compileHtmlInline provenanceIndex (ItalicText inlines) =
  "<em>" <> compileHtmlInlines provenanceIndex inlines <> "</em>"
compileHtmlInline _ (InlineCode t) = "<code>" <> escapeHtmlText t <> "</code>"
compileHtmlInline _ (InlineMath t) = "$" <> escapeHtmlText t <> "$"
compileHtmlInline _ (Currency amount cc) = escapeHtmlText (formatCurrency amount cc)
compileHtmlInline _ (Pct fraction) = escapeHtmlText (formatPct fraction)
compileHtmlInline _ (Ref label value) =
  escapeHtmlText label <> ": " <> escapeHtmlText value
compileHtmlInline _ (Link text url) =
  "<a href=\"" <> escapeHtmlAttribute url <> "\">" <> escapeHtmlText text <> "</a>"
compileHtmlInline _ (Embed spec) = escapeHtmlText (compileEmbed spec)
compileHtmlInline provenanceIndex (Sourced provenanceId inner) =
  let kind = provenanceKindText provenanceIndex provenanceId
   in "<span data-prov-id=\""
        <> T.pack (show provenanceId)
        <> "\" data-prov-kind=\""
        <> kind
        <> "\" tabindex=\"0\" role=\"button"
        <> "\">"
        <> compileHtmlInline provenanceIndex inner
        <> "</span>"

provenanceKindText :: Map Int Provenance -> Int -> Text
provenanceKindText provenanceIndex provenanceId =
  case Map.lookup provenanceId provenanceIndex of
    Just (Direct _) -> "direct"
    Just (Computed _ _) -> "computed"
    Nothing -> "unknown"

compileEmbed :: EmbedSpec -> Text
compileEmbed (PriceEmbed s) = "[price:" <> s <> "]"
compileEmbed (ChartEmbed s r Nothing) = "[chart:" <> s <> ":" <> r <> "]"
compileEmbed (ChartEmbed s r (Just st)) = "[chart:" <> s <> ":" <> r <> ":" <> st <> "]"

--------------------------------------------------------------------------------
-- Formatting helpers
--------------------------------------------------------------------------------

-- | Format a currency value with proper symbol, decimals, and thousand separators.
formatCurrency :: Scientific -> CurrencyCode -> Text
formatCurrency amount (CurrencyCode cc) =
  let isNeg = amount < 0
      absAmount = abs amount
      decimals = currencyDecimals cc
      (symbol, prefix) = currencySymbol cc
      formatted = formatDecimal decimals absAmount
      withSymbol =
        if prefix
          then symbol <> formatted
          else formatted <> " " <> symbol
   in if isNeg then "-" <> withSymbol else withSymbol

currencyDecimals :: Text -> Int
currencyDecimals cc
  | Set.member cc zeroDecimalCurrencyCodes = 0
  | Set.member cc threeDecimalCurrencyCodes = 3
  | otherwise = 2

-- | Returns (symbol, isPrefix).
currencySymbol :: Text -> (Text, Bool)
currencySymbol "USD" = ("$", True)
currencySymbol "EUR" = ("\x20AC", True)
currencySymbol "GBP" = ("\x00A3", True)
currencySymbol "JPY" = ("\x00A5", True)
currencySymbol cc = (cc <> " ", True)

-- | Format a decimal with thousand separators.
-- Uses integer arithmetic on Scientific to avoid Double precision loss.
formatDecimal :: Int -> Scientific -> Text
formatDecimal decimals sci =
  let -- Scale by 10^decimals and round half up using Scientific arithmetic.
      scaled = Sci.scientific 1 decimals -- 10^decimals as Scientific
      scaledAmount = sci * scaled
      absScaledAmount = abs scaledAmount
      wholeUnits = floor absScaledAmount :: Integer
      fractionalPart = absScaledAmount - fromInteger wholeUnits
      roundedMagnitude =
        if fractionalPart >= (0.5 :: Scientific)
          then wholeUnits + 1
          else wholeUnits
      rounded =
        if scaledAmount < 0
          then negate roundedMagnitude
          else roundedMagnitude
      factor = 10 ^ decimals :: Integer
      (wholePart, fracPart) = abs rounded `divMod` factor
      isNeg = rounded < 0
      wholeText = addThousandSeps (TL.toStrict (TB.toLazyText (TBI.decimal wholePart)))
      prefix = if isNeg then "-" else ""
   in if decimals == 0
        then prefix <> wholeText
        else
          let fracText = T.justifyRight decimals '0' (TL.toStrict (TB.toLazyText (TBI.decimal fracPart)))
           in prefix <> wholeText <> "." <> fracText

addThousandSeps :: Text -> Text
addThousandSeps t =
  let (digits, rest) = T.span isDigit t
      grouped = T.reverse (T.intercalate "," (T.chunksOf 3 (T.reverse digits)))
   in grouped <> rest

-- | Format a fraction as a percentage with 2dp.
formatPct :: Scientific -> Text
formatPct fraction =
  let pct = fraction * 100
      isNeg = pct < 0
      formatted = formatDecimal 2 (abs pct) <> "%"
   in if isNeg then "-" <> formatted else formatted

-- | Escape pipe and newline chars in table cells.
escapeTableCell :: Text -> Text
escapeTableCell = T.replace "\n" "<br>" . T.replace "|" "\\|"

-- | Escape markdown special chars in plain text.
escapePlainText :: Text -> Text
escapePlainText =
  T.replace "]" "\\]"
    . T.replace "[" "\\["
    . T.replace "`" "\\`"
    . T.replace "_" "\\_"
    . T.replace "*" "\\*"
    . T.replace "\\" "\\\\"

escapeHtmlText :: Text -> Text
escapeHtmlText =
  T.replace ">" "&gt;"
    . T.replace "<" "&lt;"
    . T.replace "&" "&amp;"

escapeHtmlAttribute :: Text -> Text
escapeHtmlAttribute =
  T.replace "\"" "&quot;"
    . T.replace ">" "&gt;"
    . T.replace "<" "&lt;"
    . T.replace "&" "&amp;"

-- | Escape characters that would break markdown link text.
escapeLinkText :: Text -> Text
escapeLinkText = T.replace "]" "\\]"

-- | Escape characters that would break markdown link URLs.
escapeLinkUrl :: Text -> Text
escapeLinkUrl = T.replace ")" "\\)"

isValidLinkUrl :: Text -> Bool
isValidLinkUrl rawUrl =
  let url = T.strip rawUrl
   in url == rawUrl
        && not (T.null url)
        && any (`T.isPrefixOf` url) ["http://", "https://"]

-- | Sanitize code-fence language tag (strip unsafe chars).
sanitizeLang :: Text -> Text
sanitizeLang = T.filter (\c -> c /= '`' && c /= '\n' && c /= '\r')

--------------------------------------------------------------------------------
-- ISO 4217 currency codes
--------------------------------------------------------------------------------

iso4217Codes :: Set Text
iso4217Codes =
  Set.fromList
    [ "AED",
      "AFN",
      "ALL",
      "AMD",
      "ANG",
      "AOA",
      "ARS",
      "AUD",
      "AWG",
      "AZN",
      "BAM",
      "BBD",
      "BDT",
      "BGN",
      "BHD",
      "BIF",
      "BMD",
      "BND",
      "BOB",
      "BRL",
      "BSD",
      "BTN",
      "BWP",
      "BYN",
      "BZD",
      "CAD",
      "CDF",
      "CHF",
      "CLP",
      "CNY",
      "COP",
      "CRC",
      "CUP",
      "CVE",
      "CZK",
      "DJF",
      "DKK",
      "DOP",
      "DZD",
      "EGP",
      "ERN",
      "ETB",
      "EUR",
      "FJD",
      "FKP",
      "GBP",
      "GEL",
      "GHS",
      "GIP",
      "GMD",
      "GNF",
      "GTQ",
      "GYD",
      "HKD",
      "HNL",
      "HRK",
      "HTG",
      "HUF",
      "IDR",
      "ILS",
      "INR",
      "IQD",
      "IRR",
      "ISK",
      "JMD",
      "JOD",
      "JPY",
      "KES",
      "KGS",
      "KHR",
      "KMF",
      "KPW",
      "KRW",
      "KWD",
      "KYD",
      "KZT",
      "LAK",
      "LBP",
      "LKR",
      "LRD",
      "LSL",
      "LYD",
      "MAD",
      "MDL",
      "MGA",
      "MKD",
      "MMK",
      "MNT",
      "MOP",
      "MRU",
      "MUR",
      "MVR",
      "MWK",
      "MXN",
      "MYR",
      "MZN",
      "NAD",
      "NGN",
      "NIO",
      "NOK",
      "NPR",
      "NZD",
      "OMR",
      "PAB",
      "PEN",
      "PGK",
      "PHP",
      "PKR",
      "PLN",
      "PYG",
      "QAR",
      "RON",
      "RSD",
      "RUB",
      "RWF",
      "SAR",
      "SBD",
      "SCR",
      "SDG",
      "SEK",
      "SGD",
      "SHP",
      "SLE",
      "SLL",
      "SOS",
      "SRD",
      "SSP",
      "STN",
      "SVC",
      "SYP",
      "SZL",
      "THB",
      "TJS",
      "TMT",
      "TND",
      "TOP",
      "TRY",
      "TTD",
      "TWD",
      "TZS",
      "UAH",
      "UGX",
      "USD",
      "UYU",
      "UZS",
      "VED",
      "VES",
      "VND",
      "VUV",
      "WST",
      "XAF",
      "XCD",
      "XDR",
      "XOF",
      "XPF",
      "YER",
      "ZAR",
      "ZMW",
      "ZWL"
    ]

zeroDecimalCurrencyCodes :: Set Text
zeroDecimalCurrencyCodes =
  Set.fromList
    [ "BIF",
      "CLP",
      "DJF",
      "GNF",
      "ISK",
      "JPY",
      "KMF",
      "KRW",
      "PYG",
      "RWF",
      "UGX",
      "VND",
      "VUV",
      "XAF",
      "XOF",
      "XPF"
    ]

threeDecimalCurrencyCodes :: Set Text
threeDecimalCurrencyCodes =
  Set.fromList
    [ "BHD",
      "IQD",
      "JOD",
      "KWD",
      "LYD",
      "OMR",
      "TND"
    ]

allowedChartRanges :: Set Text
allowedChartRanges = Set.fromList ["1D", "1W", "1M", "3M", "6M", "1Y", "YTD"]

allowedChartStyles :: Set Text
allowedChartStyles = Set.fromList ["area", "line"]
