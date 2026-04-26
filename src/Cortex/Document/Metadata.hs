{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Document.Metadata
  ( documentIrSchema,
    documentProvenanceCoverage,
    documentTitleFromIr,
  )
where

import Cortex.Document.IR qualified as IR
import Cortex.Text (stripNonEmptyText)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T

documentTitleFromIr :: IR.ReportIR -> Maybe Text
documentTitleFromIr ir =
  listToMaybe $
    mapMaybe headingTitle ir.reportBlocks
  where
    headingTitle (IR.HeadingBlock _ inlines) = stripNonEmptyText (flattenInlines inlines)
    headingTitle _ = Nothing

    flattenInlines = T.concat . fmap flattenInline

    flattenInline = \case
      IR.PlainText t -> t
      IR.BoldText inlines -> flattenInlines inlines
      IR.ItalicText inlines -> flattenInlines inlines
      IR.InlineCode t -> t
      IR.InlineMath t -> t
      IR.Currency amount code -> IR.formatCurrency amount code
      IR.Pct fraction -> IR.formatPct fraction
      IR.Ref label value -> label <> ": " <> value
      IR.Link text _ -> text
      IR.Embed spec -> case spec of
        IR.PriceEmbed symbol -> symbol
        IR.ChartEmbed symbol range _ -> symbol <> " " <> range
      IR.Sourced _ inner -> flattenInline inner

documentIrSchema :: Aeson.Value
documentIrSchema =
  Aeson.object
    [ "type" .= ("object" :: Text),
      "properties"
        .= Aeson.object
          [ "version" .= schemaInteger "IR version (must be 1)",
            "blocks"
              .= Aeson.object
                [ "type" .= ("array" :: Text),
                  "description"
                    .= T.intercalate
                      " "
                      [ "Array of block objects. Each block has a \"type\" field.",
                        "heading: {type,level,content}.",
                        "paragraph: {type,content}.",
                        "table: {type,columns,rows,alignments?}.",
                        "bullet_list/ordered_list: {type,items}.",
                        "code: {type,language,content}.",
                        "math_block: {type,content}.",
                        "horizontal_rule: {type}.",
                        "Heading levels must be integers from 2 through 6.",
                        "All content/items arrays contain inline objects: {type:\"text\",value:...}, {type:\"currency\",amount:...,currencyCode:...}, {type:\"pct\",value:...}, {type:\"bold\",content:[...]}, etc.",
                        "Pct values are decimal fractions: 0.4065 means 40.65%. Do not send whole-number percents such as 40.65.",
                        "Do not emit legacy ref nodes in new reports.",
                        "Link URLs must start with https:// or http://.",
                        "Chart embeds use range values from: 1D, 1W, 1M, 3M, 6M, 1Y, YTD. Optional style is area or line.",
                        "Source-traced values may use {type:\"sourced\",provenanceId:N,content:{...}} where N resolves against the optional root provenance object. Sourced wrappers may only wrap leaf values such as text, code, math, currency, or pct nodes.",
                        "Table rows are [[[Inline]]] — array of rows, each row is array of cells, each cell is array of inline objects.",
                        "Legacy report mode rejects payloads larger than 40 blocks, 10 headings, or 2 tables. Use /deep-report for larger multi-section analysis.",
                        "NEVER use bare strings where inline objects are expected."
                      ],
                  "items" .= Aeson.object ["type" .= ("object" :: Text)]
                ],
            "provenance"
              .= Aeson.object
                [ "type" .= ("object" :: Text),
                  "description"
                    .= T.intercalate
                      " "
                      [ "Optional report-local provenance index keyed by positive integers.",
                        "Each entry is either {kind:\"direct\",source:{toolCallId,fieldPath}} or {kind:\"computed\",sources:[...],operation:\"...\"}.",
                        "Authored narrative text is represented by the absence of sourced wrappers."
                      ],
                  "additionalProperties" .= Aeson.object ["type" .= ("object" :: Text)]
                ]
          ],
      "required" .= (["version", "blocks"] :: [Text]),
      "additionalProperties" .= False
    ]

documentProvenanceCoverage :: IR.ReportIR -> Maybe Double
documentProvenanceCoverage ir =
  let counts = foldMap coverageFromBlock ir.reportBlocks
   in if counts.coverageEligibleLeaves <= 0
        then Nothing
        else
          Just
            ( fromIntegral counts.coverageSourcedLeaves
                / fromIntegral counts.coverageEligibleLeaves
            )

data CoverageCounts = CoverageCounts
  { coverageEligibleLeaves :: Int,
    coverageSourcedLeaves :: Int
  }

instance Semigroup CoverageCounts where
  left <> right =
    CoverageCounts
      { coverageEligibleLeaves = left.coverageEligibleLeaves + right.coverageEligibleLeaves,
        coverageSourcedLeaves = left.coverageSourcedLeaves + right.coverageSourcedLeaves
      }

instance Monoid CoverageCounts where
  mempty =
    CoverageCounts
      { coverageEligibleLeaves = 0,
        coverageSourcedLeaves = 0
      }

coverageFromBlock :: IR.Block -> CoverageCounts
coverageFromBlock block =
  case block of
    IR.HeadingBlock _ inlines -> foldMap (coverageFromInline False) inlines
    IR.ParagraphBlock inlines -> foldMap (coverageFromInline False) inlines
    IR.TableBlock tableDef ->
      foldMap (foldMap (foldMap (coverageFromInline False))) tableDef.tableRows
    IR.BulletListBlock items -> foldMap (foldMap (coverageFromInline False)) items
    IR.OrderedListBlock items -> foldMap (foldMap (coverageFromInline False)) items
    IR.CodeBlock _ _ -> mempty
    IR.MathBlock _ -> mempty
    IR.HorizontalRule -> mempty

coverageFromInline :: Bool -> IR.Inline -> CoverageCounts
coverageFromInline sourcedContext inline =
  case inline of
    IR.PlainText _ -> coverageLeaf sourcedContext sourcedContext
    IR.BoldText inlines -> foldMap (coverageFromInline sourcedContext) inlines
    IR.ItalicText inlines -> foldMap (coverageFromInline sourcedContext) inlines
    IR.InlineCode _ -> coverageLeaf sourcedContext sourcedContext
    IR.InlineMath _ -> coverageLeaf sourcedContext sourcedContext
    IR.Currency _ _ -> coverageLeaf True sourcedContext
    IR.Pct _ -> coverageLeaf True sourcedContext
    IR.Ref _ _ -> coverageLeaf True sourcedContext
    IR.Link _ _ -> coverageLeaf True sourcedContext
    IR.Embed _ -> coverageLeaf True sourcedContext
    IR.Sourced _ inner -> coverageFromInline True inner

coverageLeaf :: Bool -> Bool -> CoverageCounts
coverageLeaf isEligible isSourced
  | not isEligible = mempty
  | otherwise =
      CoverageCounts
        { coverageEligibleLeaves = 1,
          coverageSourcedLeaves = if isSourced then 1 else 0
        }

schemaInteger :: Text -> Aeson.Value
schemaInteger description =
  Aeson.object
    [ "type" .= ("integer" :: Text),
      "description" .= description
    ]
