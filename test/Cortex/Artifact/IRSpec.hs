module Cortex.Artifact.IRSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Scientific (Scientific)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Test.Hspec
import Test.QuickCheck qualified as QC

import Cortex.Artifact.IR

spec :: Spec
spec = do
  describe "formatCurrency" $ do
    it "formats USD with dollar sign and 2 decimals" $
      formatCurrency 185.00 (CurrencyCode "USD") `shouldBe` "$185.00"

    it "formats negative USD" $
      formatCurrency (-42.50) (CurrencyCode "USD") `shouldBe` "-$42.50"

    it "formats large USD with thousand separators" $
      formatCurrency 1234567.89 (CurrencyCode "USD") `shouldBe` "$1,234,567.89"

    it "formats JPY with 0 decimals" $
      formatCurrency 1000 (CurrencyCode "JPY") `shouldBe` "\x00A5" <> "1,000"

    it "formats EUR" $
      formatCurrency 42.50 (CurrencyCode "EUR") `shouldBe` "\x20AC" <> "42.50"

    it "formats GBP" $
      formatCurrency 99.99 (CurrencyCode "GBP") `shouldBe` "\x00A3" <> "99.99"

    it "formats unknown currency with code prefix" $
      formatCurrency 10.00 (CurrencyCode "SEK") `shouldBe` "SEK 10.00"

    it "formats 3-decimal currencies using ISO minor units" $
      formatCurrency 1.2345 (CurrencyCode "KWD") `shouldBe` "KWD 1.235"

  describe "formatPct" $ do
    it "formats fraction as percentage" $
      formatPct 0.4065 `shouldBe` "40.65%"

    it "formats zero" $
      formatPct 0.0 `shouldBe` "0.00%"

    it "formats small fraction" $
      formatPct 0.001 `shouldBe` "0.10%"

    it "formats 1.0 as 100%" $
      formatPct 1.0 `shouldBe` "100.00%"

  describe "escapeTableCell" $ do
    it "escapes pipe characters" $
      escapeTableCell "A|B" `shouldBe` "A\\|B"

    it "replaces newlines with br" $
      escapeTableCell "Line1\nLine2" `shouldBe` "Line1<br>Line2"

  describe "escapePlainText" $ do
    it "escapes markdown special chars" $
      escapePlainText "*bold* _italic_ `code`" `shouldBe` "\\*bold\\* \\_italic\\_ \\`code\\`"

    it "escapes brackets" $
      escapePlainText "[link](url)" `shouldBe` "\\[link\\](url)"

  describe "validateIR" $ do
    it "rejects unsupported version" $ do
      let ir = mkReportIR 2 [ParagraphBlock [PlainText "text"]]
      validateIR ir `shouldBe` Left [UnsupportedVersion 2]

    it "rejects empty blocks" $ do
      let ir = mkReportIR 1 []
      validateIR ir `shouldBe` Left [EmptyBlocks]

    it "rejects invalid currency code" $ do
      let ir = mkReportIR 1 [ParagraphBlock [Currency 10 (CurrencyCode "FAKE")]]
      case validateIR ir of
        Left errs -> errs `shouldContain` [InvalidCurrencyCode "FAKE"]
        Right _ -> expectationFailure "Should have rejected invalid currency"

    it "rejects heading level 1" $ do
      let ir = mkReportIR 1 [HeadingBlock 1 [PlainText "bad heading"]]
      case validateIR ir of
        Left errs -> errs `shouldContain` [InvalidHeadingLevel 1]
        Right _ -> expectationFailure "Should have rejected heading level 1"

    it "rejects too many blocks" $ do
      let ir = mkReportIR 1 (replicate 101 HorizontalRule)
      case validateIR ir of
        Left errs -> errs `shouldContain` [TooManyBlocks 101]
        Right _ -> expectationFailure "Should have rejected oversized payload"

    it "rejects too many columns" $ do
      let td = TableDef (replicate 21 "col") Nothing []
      let ir = mkReportIR 1 [TableBlock td]
      case validateIR ir of
        Left errs -> errs `shouldContain` [TooManyColumns 21]
        Right _ -> expectationFailure "Should have rejected too many columns"

    it "accepts valid IR" $ do
      let ir = mkReportIR 1 [ParagraphBlock [PlainText "hello"]]
      validateIR ir `shouldBe` Right (ValidatedReportIR ir)

    it "rejects sourced values with unknown provenance IDs" $ do
      let ir = mkReportIR 1 [ParagraphBlock [Sourced 1 (Currency 185.00 (CurrencyCode "USD"))]]
      case validateIR ir of
        Left errs -> errs `shouldContain` [ProvenanceIndexMissing]
        Right _ -> expectationFailure "Should have rejected unresolved provenance ID"

    it "rejects sourced wrappers around structural inline nodes" $ do
      let ir =
            mkReportIRWithProvenance
              [ParagraphBlock [Sourced 1 (BoldText [PlainText "hello"])]]
              [(1, Direct (Source "call_abc" "$.price"))]
      case validateIR ir of
        Left errs -> errs `shouldContain` [SourcedWrapsStructural]
        Right _ -> expectationFailure "Should have rejected structural sourced wrapper"

    it "rejects nested sourced wrappers" $ do
      let ir =
            mkReportIRWithProvenance
              [ParagraphBlock [Sourced 1 (Sourced 1 (Currency 185.00 (CurrencyCode "USD")))]]
              [(1, Direct (Source "call_abc" "$.price"))]
      case validateIR ir of
        Left errs -> errs `shouldContain` [NestedSourced]
        Right _ -> expectationFailure "Should have rejected nested sourced wrapper"

    it "rejects sourced wrappers around links" $ do
      let ir =
            mkReportIRWithProvenance
              [ParagraphBlock [Sourced 1 (Link "Reuters" "https://www.reuters.com/example")]]
              [(1, Direct (Source "call_news" "$.url"))]
      case validateIR ir of
        Left errs -> errs `shouldContain` [SourcedWrapsStructural]
        Right _ -> expectationFailure "Should have rejected sourced link wrapper"

    it "rejects provenance sources with empty tool call IDs" $ do
      let ir =
            mkReportIRWithProvenance
              [ParagraphBlock [Sourced 1 (Currency 185.00 (CurrencyCode "USD"))]]
              [(1, Direct (Source "   " "$.price"))]
      case validateIR ir of
        Left errs -> errs `shouldContain` [EmptyToolCallId]
        Right _ -> expectationFailure "Should have rejected empty tool call ID"

    it "rejects pct values outside the supported decimal-fraction range" $ do
      let ir = mkReportIR 1 [ParagraphBlock [Pct 40.65]]
      case validateIR ir of
        Left errs -> errs `shouldContain` [PctOutOfRange 40.65]
        Right _ -> expectationFailure "Should have rejected whole-number percent input"

    it "rejects invalid link URL schemes" $ do
      let ir = mkReportIR 1 [ParagraphBlock [Link "click" "javascript:alert(1)"]]
      case validateIR ir of
        Left errs -> errs `shouldContain` [InvalidLinkUrl "javascript:alert(1)"]
        Right _ -> expectationFailure "Should have rejected non-http link URL"

    it "rejects invalid chart ranges and styles" $ do
      let ir = mkReportIR 1 [ParagraphBlock [Embed (ChartEmbed "AAPL" "5Y" (Just "bars"))]]
      case validateIR ir of
        Left errs -> do
          errs `shouldContain` [InvalidChartRange "5Y"]
          errs `shouldContain` [InvalidChartStyle "bars"]
        Right _ -> expectationFailure "Should have rejected unsupported chart embed values"

  describe "compileToMarkdown" $ do
    it "compiles inline math with delimiters" $ do
      let ir = mkReportIR 1 [ParagraphBlock [PlainText "x equals ", InlineMath "x^2"]]
      compileToMarkdown ir `shouldBe` Right "x equals $x^2$"

    it "compiles display math" $ do
      let ir = mkReportIR 1 [MathBlock "E = mc^2"]
      compileToMarkdown ir `shouldBe` Right "$$\nE = mc^2\n$$"

    it "compiles code blocks with language tag" $ do
      let ir = mkReportIR 1 [CodeBlock "python" "print('hi')"]
      compileToMarkdown ir `shouldBe` Right "```python\nprint('hi')\n```"

    it "compiles bullet lists" $ do
      let ir = mkReportIR 1 [BulletListBlock [[PlainText "one"], [PlainText "two"]]]
      compileToMarkdown ir `shouldBe` Right "- one\n- two"

    it "compiles ordered lists" $ do
      let ir = mkReportIR 1 [OrderedListBlock [[PlainText "first"], [PlainText "second"]]]
      compileToMarkdown ir `shouldBe` Right "1. first\n2. second"

    it "compiles bold and italic" $ do
      let ir =
            mkReportIR
              1
              [ParagraphBlock [BoldText [PlainText "bold"], PlainText " and ", ItalicText [PlainText "italic"]]]
      compileToMarkdown ir `shouldBe` Right "**bold** and *italic*"

    it "compiles inline code with backticks" $ do
      let ir = mkReportIR 1 [ParagraphBlock [InlineCode "x = 1"]]
      compileToMarkdown ir `shouldBe` Right "`x = 1`"

    it "compiles inline code containing backticks" $ do
      let ir = mkReportIR 1 [ParagraphBlock [InlineCode "a`b"]]
      compileToMarkdown ir `shouldBe` Right "`` a`b ``"

    it "compiles links" $ do
      let ir = mkReportIR 1 [ParagraphBlock [Link "click" "https://example.com"]]
      compileToMarkdown ir `shouldBe` Right "[click](https://example.com)"

    it "compiles ref nodes" $ do
      let ir = mkReportIR 1 [ParagraphBlock [Ref "Price" "$185.00"]]
      compileToMarkdown ir `shouldBe` Right "Price: $185.00"

    it "compiles sourced inline values identically to unwrapped values" $ do
      let sourcedIr =
            mkReportIRWithProvenance
              [ParagraphBlock [PlainText "Price: ", Sourced 1 (Currency 185.00 (CurrencyCode "USD"))]]
              [(1, Direct (Source "call_abc123" "$.price"))]
          plainIr =
            mkReportIR
              1
              [ParagraphBlock [PlainText "Price: ", Currency 185.00 (CurrencyCode "USD")]]
      compileToMarkdown sourcedIr `shouldBe` compileToMarkdown plainIr

    it "matches the total validated compiler path for generated valid IR"
      . QC.property
      . QC.forAll genValidReportIR
      $ \ir ->
        case validateIR ir of
          Left errs ->
            QC.counterexample ("Unexpected validation failure: " <> show errs) False
          Right validated ->
            QC.counterexample "Validated and unvalidated compiler paths diverged" $
              compileToMarkdown ir == Right (compileValidatedToMarkdown validated)
                && compileToAnnotatedHtml ir == Right (compileValidatedToAnnotatedHtml validated)

  describe "compileToAnnotatedHtml" $ do
    it "wraps sourced values with provenance span attributes" $ do
      let ir =
            mkReportIRWithProvenance
              [ParagraphBlock [PlainText "Price: ", Sourced 1 (Currency 185.00 (CurrencyCode "USD"))]]
              [(1, Direct (Source "call_abc123" "$.price"))]
      compileToAnnotatedHtml ir
        `shouldBe` Right
          "<p>Price: <span data-prov-id=\"1\" data-prov-kind=\"direct\" tabindex=\"0\" role=\"button\">$185.00</span></p>"

    it "marks computed provenance distinctly" $ do
      let ir =
            mkReportIRWithProvenance
              [ParagraphBlock [Sourced 2 (Pct 0.1234)]]
              [(2, Computed [Source "call_bid" "$.bid", Source "call_ask" "$.ask"] "spread / ask")]
      compileToAnnotatedHtml ir
        `shouldBe` Right
          "<p><span data-prov-id=\"2\" data-prov-kind=\"computed\" tabindex=\"0\" role=\"button\">12.34%</span></p>"

    it "renders unsourced values without provenance wrappers" $ do
      let ir = mkReportIR 1 [ParagraphBlock [PlainText "Spread: ", Pct 0.1234]]
      compileToAnnotatedHtml ir `shouldBe` Right "<p>Spread: 12.34%</p>"

    it "renders links as anchors in annotated html" $ do
      let ir = mkReportIR 1 [ParagraphBlock [Link "Reuters" "https://www.reuters.com/example"]]
      compileToAnnotatedHtml ir
        `shouldBe` Right "<p><a href=\"https://www.reuters.com/example\">Reuters</a></p>"

  describe "FromJSON parsing" $ do
    it "rejects unknown block type" $ do
      let json = "{\"type\":\"unknown\",\"content\":[]}"
      (Aeson.eitherDecode json :: Either String Block) `shouldSatisfy` isLeft

    it "rejects unknown inline type" $ do
      let json = "{\"type\":\"unknown\",\"value\":\"x\"}"
      (Aeson.eitherDecode json :: Either String Inline) `shouldSatisfy` isLeft

  describe "JSON round-trip" $ do
    it "round-trips ReportIR" $ do
      let ir =
            mkReportIR
              1
              [ ParagraphBlock [PlainText "hello", Currency 42.0 (CurrencyCode "USD")]
              , MathBlock "x^2"
              , HorizontalRule
              ]
      (Aeson.eitherDecode (Aeson.encode ir) :: Either String ReportIR) `shouldBe` Right ir

    it "round-trips provenance-aware ReportIR" $ do
      let ir =
            mkReportIRWithProvenance
              [ ParagraphBlock
                  [ PlainText "Price: "
                  , Sourced 1 (Currency 185.00 (CurrencyCode "USD"))
                  , PlainText " | Spread: "
                  , Sourced
                      2
                      (Currency 12.34 (CurrencyCode "USD"))
                  ]
              ]
              [ (1, Direct (Source "call_price" "$.price"))
              ,
                ( 2
                , Computed
                    [Source "call_bid" "$.bid", Source "call_ask" "$.ask"]
                    "ask - bid"
                )
              ]
      (Aeson.eitherDecode (Aeson.encode ir) :: Either String ReportIR) `shouldBe` Right ir

  describe "golden tests" $ do
    goldenTest "covered-call"
    goldenTest "table-escaping"
    goldenTest "math-delimiters"
    goldenTest "currency-formatting"
    goldenTest "embeds"
    goldenTest "empty-edge-cases"

goldenTest :: String -> Spec
goldenTest name =
  it ("golden: " <> name) $ do
    jsonBytes <- BSL.readFile ("test/fixtures/ir/" <> name <> ".json")
    expectedMd <- TIO.readFile ("test/fixtures/ir/" <> name <> ".md")
    case Aeson.eitherDecode jsonBytes of
      Left err -> expectationFailure ("JSON parse error: " <> err)
      Right ir ->
        case compileToMarkdown ir of
          Left (CompileError err) -> expectationFailure ("Compile error: " <> T.unpack err)
          Right compiled -> compiled `shouldBe` T.stripEnd expectedMd

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False

mkReportIR :: Int -> [Block] -> ReportIR
mkReportIR version blocks =
  ReportIR
    { reportVersion = version
    , reportBlocks = blocks
    , reportProvenance = Nothing
    }

mkReportIRWithProvenance :: [Block] -> [(Int, Provenance)] -> ReportIR
mkReportIRWithProvenance blocks provenanceEntries =
  ReportIR
    { reportVersion = 1
    , reportBlocks = blocks
    , reportProvenance = Just (Map.fromList provenanceEntries)
    }

genValidReportIR :: QC.Gen ReportIR
genValidReportIR = do
  blockCount <- QC.chooseInt (1, 5)
  blocks <- QC.vectorOf blockCount genBlock
  pure (mkReportIR 1 blocks)

genBlock :: QC.Gen Block
genBlock =
  QC.oneof
    [ genHeadingBlock
    , genParagraphBlock
    , genTableBlock
    , genBulletListBlock
    , genOrderedListBlock
    , genCodeBlock
    , genMathBlock
    , pure HorizontalRule
    ]

genHeadingBlock :: QC.Gen Block
genHeadingBlock = do
  level <- QC.elements [2 .. 6]
  itemCount <- QC.chooseInt (1, 3)
  HeadingBlock level <$> QC.vectorOf itemCount genInline

genParagraphBlock :: QC.Gen Block
genParagraphBlock = do
  itemCount <- QC.chooseInt (1, 4)
  ParagraphBlock <$> QC.vectorOf itemCount genInline

genTableBlock :: QC.Gen Block
genTableBlock = do
  columnCount <- QC.chooseInt (1, 4)
  rowCount <- QC.chooseInt (0, 3)
  columns <- QC.vectorOf columnCount genShortText
  useAlignments <- QC.arbitrary
  alignments <-
    if useAlignments
      then
        Just <$> QC.vectorOf columnCount (QC.elements [AlignLeft, AlignCenter, AlignRight, AlignDefault])
      else pure Nothing
  rows <- QC.vectorOf rowCount (QC.vectorOf columnCount genTableCell)
  pure (TableBlock (TableDef columns alignments rows))

genBulletListBlock :: QC.Gen Block
genBulletListBlock = do
  itemCount <- QC.chooseInt (1, 3)
  BulletListBlock <$> QC.vectorOf itemCount genListItem

genOrderedListBlock :: QC.Gen Block
genOrderedListBlock = do
  itemCount <- QC.chooseInt (1, 3)
  OrderedListBlock <$> QC.vectorOf itemCount genListItem

genCodeBlock :: QC.Gen Block
genCodeBlock = CodeBlock <$> QC.elements ["python", "sql", "text"] <*> genShortText

genMathBlock :: QC.Gen Block
genMathBlock = MathBlock <$> QC.elements ["x^2", "\\frac{a}{b}", "R = \\frac{p}{q}"]

genListItem :: QC.Gen [Inline]
genListItem = do
  inlineCount <- QC.chooseInt (1, 3)
  QC.vectorOf inlineCount genInline

genTableCell :: QC.Gen [Inline]
genTableCell = do
  inlineCount <- QC.chooseInt (1, 2)
  QC.vectorOf inlineCount genLeafInline

genInline :: QC.Gen Inline
genInline =
  QC.oneof
    [ genLeafInline
    , BoldText <$> QC.listOf1 genLeafInline
    , ItalicText <$> QC.listOf1 genLeafInline
    ]

genLeafInline :: QC.Gen Inline
genLeafInline =
  QC.oneof
    [ PlainText <$> genShortText
    , InlineCode <$> genShortText
    , InlineMath <$> QC.elements ["x^2", "\\alpha + \\beta", "\\frac{1}{2}"]
    , Currency <$> genScientificRange (-100000) 100000 <*> genCurrencyCode
    , Pct <$> genScientificRange (-10) 10
    , Link <$> genShortText <*> QC.elements ["https://example.com", "http://example.org"]
    , Embed <$> genEmbed
    ]

genEmbed :: QC.Gen EmbedSpec
genEmbed =
  QC.oneof
    [ PriceEmbed <$> QC.elements ["AAPL", "MSFT", "NVDA"]
    , ChartEmbed
        <$> QC.elements ["AAPL", "MSFT", "NVDA"]
        <*> QC.elements ["1D", "1W", "1M", "3M", "6M", "1Y", "YTD"]
        <*> QC.frequency [(2, pure Nothing), (1, Just <$> QC.elements ["area", "line"])]
    ]

genCurrencyCode :: QC.Gen CurrencyCode
genCurrencyCode = CurrencyCode <$> QC.elements ["USD", "EUR", "GBP", "JPY", "KWD", "SEK"]

genShortText :: QC.Gen T.Text
genShortText = T.pack <$> QC.listOf1 (QC.elements (['a' .. 'z'] <> ['A' .. 'Z'] <> " -"))

genScientificRange :: Integer -> Integer -> QC.Gen Scientific
genScientificRange minValue maxValue = fromInteger <$> QC.chooseInteger (minValue, maxValue)
