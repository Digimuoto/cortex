{- |
Module      : Cortex.Quantum.Qec
Description : Distance-3 repetition-code QEC catalog, analysis, and report.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The native distance-3 repetition-code QEC showcase: the four exported circuit
cases, the per-case correctness model (the expected corrected outcome and the
syndrome→correction lookup), and the deterministic Markdown report the sweep writes.

Each case names one exported graph value of @qec-repetition-realize.wire@. After a
case runs, @matchingShots@ counts the shots that landed exactly on the expected
labeled outcome (data bits @final_d0..final_d2@ plus syndrome bits @s01@, @s12@),
and the report gates on a per-circuit threshold.
-}
module Cortex.Quantum.Qec
  ( QecCase (..)
  , qecCases
  , RowStatus (..)
  , CaseRow (..)
  , completedRow
  , dryRunRow
  , failedRow
  , ReportInputs (..)
  , renderReport
  , reportExitCode
  , rowsValue
  )
where

import Data.Aeson (Value, object, toJSON, (.=))
import Data.Maybe (isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T

import Cortex.Quantum.Cost (formatUsd)
import Cortex.Quantum.Result (QuantumResult, matchingShots, quantumResultShots)

-- | One repetition-code case: a named export plus its expected corrected outcome.
data QecCase = QecCase
  { qcKey :: !Text
  , qcLabel :: !Text
  , qcReturn :: !Text
  , qcExpectedSyndrome :: !Text
  , qcExpectedDataSyndrome :: !Text
  , qcCorrection :: !Text
  , qcExpectedLabel :: !Text
  }
  deriving stock (Eq, Show)

{- | The four catalog cases. The @qcExpectedLabel@ strings are the labeled
outcomes 'Cortex.Quantum.Result.labeledKeyFor' produces (output ports sorted by
name: @final_d0,final_d1,final_d2,s01,s12@), so an exact-string lookup decides a
match.
-}
qecCases :: [QecCase]
qecCases =
  [ QecCase "none" "clean memory" "qec_repetition_none" "00" "000/00" "none" (labelFor 0 0 0 0 0)
  , QecCase "x0" "forced X on d0" "qec_repetition_x0" "10" "100/10" "X d0" (labelFor 1 0 0 1 0)
  , QecCase "x1" "forced X on d1" "qec_repetition_x1" "11" "010/11" "X d1" (labelFor 0 1 0 1 1)
  , QecCase "x2" "forced X on d2" "qec_repetition_x2" "01" "001/01" "X d2" (labelFor 0 0 1 0 1)
  ]
  where
    labelFor d0 d1 d2 s01 s12 =
      T.intercalate
        ","
        [ "final_d0=" <> bit d0
        , "final_d1=" <> bit d1
        , "final_d2=" <> bit d2
        , "s01=" <> bit s01
        , "s12=" <> bit s12
        ]
    bit :: Int -> Text
    bit n = T.pack (show n)

data RowStatus = RowCompleted | RowDryRun | RowFailed
  deriving stock (Eq, Show)

{- | One report row. A single constructor keeps the field selectors total under
@-Wpartial-fields@; status-specific fields default for the other statuses.
-}
data CaseRow = CaseRow
  { rowCase :: !QecCase
  , rowStatus :: !RowStatus
  , rowMatching :: !Int
  , rowShots :: !Int
  , rowLogicalFailures :: !Int
  , rowPassed :: !Bool
  , rowError :: !Text
  , rowCostAmount :: !(Maybe Rational)
  , rowDiagram :: !(Maybe Text)
  , rowOpenQasm :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | A completed case row: count matching shots and gate on the threshold.
completedRow :: QecCase -> Int -> Int -> QuantumResult -> Maybe Rational -> CaseRow
completedRow qec threshold fallbackShots result cost =
  CaseRow
    { rowCase = qec
    , rowStatus = RowCompleted
    , rowMatching = matching
    , rowShots = shots
    , rowLogicalFailures = max (shots - matching) 0
    , rowPassed = matching >= threshold
    , rowError = ""
    , rowCostAmount = cost
    , rowDiagram = Nothing
    , rowOpenQasm = Nothing
    }
  where
    matching = matchingShots result (qcExpectedLabel qec)
    shots = case quantumResultShots result of
      0 -> fallbackShots
      n -> n

-- | A dry-run case row.
dryRunRow :: QecCase -> Maybe Rational -> CaseRow
dryRunRow qec cost =
  CaseRow qec RowDryRun 0 0 0 False "" cost Nothing Nothing

-- | A failed case row carrying the error detail.
failedRow :: QecCase -> Text -> CaseRow
failedRow qec err =
  CaseRow qec RowFailed 0 0 0 False err Nothing Nothing Nothing

-- | The inputs the report is rendered from.
data ReportInputs = ReportInputs
  { riSource :: !Text
  , riBackend :: !Text
  , riShots :: !Int
  , riThreshold :: !Int
  , riCompletedAt :: !Text
  , riOutputPath :: !(Maybe Text)
  , riDryRun :: !Bool
  , riRows :: ![CaseRow]
  }
  deriving stock (Show)

-- | Render the experiment report as Markdown (always ends in a newline).
renderReport :: ReportInputs -> Text
renderReport inputs =
  T.unlines
    (headerBlock inputs <> verdictBlock inputs <> costBlock (riRows inputs) <> circuitsBlock inputs)

headerBlock :: ReportInputs -> [Text]
headerBlock inputs =
  [ "# Wire QEC repetition-code experiment"
  , ""
  , "- **Completed:** " <> riCompletedAt inputs
  , "- **Backend:** Amazon Braket — `"
      <> riBackend inputs
      <> "`"
      <> (if riDryRun inputs then " (dry run)" else "")
  , "- **Shots:** " <> tshow (riShots inputs) <> " per circuit"
  , "- **Source:** `" <> riSource inputs <> "`"
  ]
    <> ["- **Report written to:** `" <> path <> "`" | Just path <- [riOutputPath inputs]]
    <> [""]

-- The summary table + acceptance/verdict, or the error/dry-run notice.
verdictBlock :: ReportInputs -> [Text]
verdictBlock inputs
  | not (null failed) =
      [ "## Errors"
      , ""
      , "At least one circuit failed before analysis."
      , ""
      ]
        <> mdTable ["case", "target", "reason"] (map errorRow failed)
        <> ["", "**Run gate: error**", ""]
  | dryRun =
      [ "## Dry run"
      , ""
      , "All circuits compiled and lowered to Braket OpenQASM; no task was queued."
      , ""
      , "**Run gate: dry-run**"
      , ""
      ]
  | otherwise =
      [ "## Summary"
      , ""
      ]
        <> mdTable summaryHeaders (map summaryRow rows)
        <> [ ""
           , "**Acceptance criterion:** ≥ "
               <> tshow (riThreshold inputs)
               <> "/"
               <> tshow (riShots inputs)
               <> " ideal shots per circuit."
           , ""
           , "**Run gate: " <> verdict <> "**" <> verdictDetail
           , ""
           , "| syndrome (s01 s12) | correction |"
           , "| --- | --- |"
           , "| 00 | no correction |"
           , "| 10 | X d0 |"
           , "| 11 | X d1 |"
           , "| 01 | X d2 |"
           , ""
           ]
  where
    rows = riRows inputs
    failed = filter ((== RowFailed) . rowStatus) rows
    completed = filter ((== RowCompleted) . rowStatus) rows
    dryRun = not (null rows) && all ((== RowDryRun) . rowStatus) rows
    accepted = not (null completed) && all rowPassed completed
    verdict = if accepted then "accepted" else "rejected"
    verdictDetail =
      if accepted
        then ""
        else
          " — "
            <> T.intercalate ", " [shortfall r | r <- completed, not (rowPassed r)]
            <> " below the criterion."
    shortfall r = qcKey (rowCase r) <> " at " <> tshow (rowMatching r) <> "/" <> tshow (rowShots r)
    summaryHeaders =
      [ "case"
      , "injected error"
      , "expected syndrome"
      , "expected data/syndrome"
      , "correction"
      , "ideal shots"
      , "deviating shots"
      ]
    summaryRow row =
      let qec = rowCase row
       in [ qcKey qec
          , qcLabel qec
          , qcExpectedSyndrome qec
          , qcExpectedDataSyndrome qec
          , qcCorrection qec
          , tshow (rowMatching row) <> "/" <> tshow (rowShots row)
          , tshow (rowLogicalFailures row) <> "/" <> tshow (rowShots row)
          ]
    errorRow row =
      let qec = rowCase row
       in [ qcLabel qec
          , riSource inputs <> "#" <> qcReturn qec
          , if T.null (rowError row) then "(empty)" else rowError row
          ]

costBlock :: [CaseRow] -> [Text]
costBlock rows =
  case mapMaybe rowCostAmount rows of
    [] -> []
    amounts ->
      [ "## Cost"
      , ""
      , "Estimated total **$"
          <> formatUsd (sum amounts)
          <> " USD** — Braket quantum-task estimates (per-task + per-shot). Excludes S3, taxes, discounts, credits, reservations, and later AWS billing adjustments."
      , ""
      ]

-- One `### case` section per row, each with the circuit diagram and the OpenQASM
-- in a collapsible block, plus the closing note.
circuitsBlock :: ReportInputs -> [Text]
circuitsBlock inputs
  | all (\r -> isNothing (rowDiagram r) && isNothing (rowOpenQasm r)) rows = closingNote
  | otherwise = ["## Circuits", ""] <> concatMap circuitSection rows <> closingNote
  where
    rows = riRows inputs
    circuitSection row =
      let qec = rowCase row
          ideal = case rowStatus row of
            RowCompleted -> " · " <> tshow (rowMatching row) <> "/" <> tshow (rowShots row) <> " ideal"
            _ -> ""
       in ["### " <> qcKey qec <> " — " <> qcLabel qec <> ideal, ""]
            <> diagramBlock (rowDiagram row)
            <> qasmBlock (rowOpenQasm row)
    diagramBlock Nothing = []
    diagramBlock (Just d) = ["```text", d, "```", ""]
    qasmBlock Nothing = []
    qasmBlock (Just q) =
      ["<details><summary>OpenQASM 3</summary>", "", "```text", T.stripEnd q, "```", "", "</details>", ""]
    closingNote =
      [ "## What Wire did"
      , ""
      , "Wire authored the repetition-code circuit catalog directly against `use quantum.core` and `use quantum.braket`. Each data and ancilla qubit is measured by its own `@measure_z` node; the resulting symbolic measurement bits are collected into one `@realize` node that returns a single correlated `QuantumResult`. The runner lowers that realized frontier to OpenQASM for Amazon Braket — no `std.io.command` scaffold."
      ]

mdTable :: [Text] -> [[Text]] -> [Text]
mdTable headers rows =
  ("| " <> T.intercalate " | " headers <> " |")
    : ("|" <> T.concat (replicate (length headers) " --- |"))
    : ["| " <> T.intercalate " | " cells <> " |" | cells <- rows]

-- | The sweep exit code: 1 if any case failed or missed the acceptance gate.
reportExitCode :: [CaseRow] -> Int
reportExitCode rows =
  if any failed rows || any rejected rows then 1 else 0
  where
    failed row = rowStatus row == RowFailed
    rejected row = rowStatus row == RowCompleted && not (rowPassed row)

-- | The rows as JSON for the @--json@ output.
rowsValue :: [CaseRow] -> Value
rowsValue rows = toJSON (map rowValue rows)
  where
    rowValue row =
      object
        [ "case" .= qcKey (rowCase row)
        , "label" .= qcLabel (rowCase row)
        , "return" .= qcReturn (rowCase row)
        , "status" .= statusText (rowStatus row)
        , "matching_shots" .= rowMatching row
        , "shots" .= rowShots row
        , "logical_failures" .= rowLogicalFailures row
        , "passed_threshold" .= rowPassed row
        , "error" .= rowError row
        ]
    statusText RowCompleted = "completed" :: Text
    statusText RowDryRun = "dry_run"
    statusText RowFailed = "failed"

tshow :: Show a => a -> Text
tshow = T.pack . show
