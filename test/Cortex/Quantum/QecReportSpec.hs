{- |
Module      : Cortex.Quantum.QecReportSpec
Description : Markdown QEC experiment report rendering.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Checks that the QEC sweep report renders as Markdown across its branches —
accepted, rejected, dry-run, and error — with the summary table, verdict wording,
acceptance criterion, and collapsible OpenQASM block.
-}
module Cortex.Quantum.QecReportSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Cortex.Quantum.Qec

rowsFor :: [(RowStatus, Int, Bool, Text)] -> [CaseRow]
rowsFor = zipWith mk qecCases
  where
    mk qec (status, matching, passed, err) =
      CaseRow
        qec
        status
        matching
        100
        (100 - matching)
        passed
        err
        (Just (0.445 :: Rational))
        (Just "DIAGRAM")
        (Just "QASM")

inputs :: Bool -> [CaseRow] -> ReportInputs
inputs dry rows =
  ReportInputs
    { riSource = "examples/wire/qec-repetition-realize.wire"
    , riBackend = "arn:aws:braket:eu-north-1::device/qpu/iqm/Garnet"
    , riShots = 100
    , riThreshold = 90
    , riCompletedAt = "2026-06-23T14:15:30Z"
    , riOutputPath = Nothing
    , riDryRun = dry
    , riRows = rows
    }

spec :: Spec
spec =
  describe "QEC Markdown report" $ do
    it "renders a rejected results report as Markdown" $ do
      let report =
            renderReport . inputs False . rowsFor $
              [ (RowCompleted, 99, True, "")
              , (RowCompleted, 94, True, "")
              , (RowCompleted, 88, False, "")
              , (RowCompleted, 95, True, "")
              ]
      report `shouldSatisfy` T.isInfixOf "# Wire QEC repetition-code experiment"
      report `shouldSatisfy` T.isInfixOf "## Summary"
      report `shouldSatisfy` T.isInfixOf "| case | injected error |"
      report `shouldSatisfy` T.isInfixOf "ideal shots | deviating shots |"
      report `shouldSatisfy` T.isInfixOf "**Run gate: rejected**"
      report `shouldSatisfy` T.isInfixOf "Acceptance criterion"
      report `shouldSatisfy` T.isInfixOf "<details><summary>OpenQASM 3</summary>"
      report `shouldSatisfy` T.isInfixOf "## Cost"

    it "renders accepted when every circuit meets the criterion" $ do
      let report =
            renderReport . inputs False . rowsFor $
              [ (RowCompleted, 99, True, "")
              , (RowCompleted, 94, True, "")
              , (RowCompleted, 95, True, "")
              , (RowCompleted, 96, True, "")
              ]
      report `shouldSatisfy` T.isInfixOf "**Run gate: accepted**"

    it "returns a failing exit code when the gate rejects a completed run" $ do
      let rows =
            rowsFor
              [ (RowCompleted, 99, True, "")
              , (RowCompleted, 94, True, "")
              , (RowCompleted, 88, False, "")
              , (RowCompleted, 95, True, "")
              ]
      reportExitCode rows `shouldBe` 1

    it "renders a dry-run report" $ do
      let report = renderReport . inputs True . rowsFor $ replicate 4 (RowDryRun, 0, False, "")
      report `shouldSatisfy` T.isInfixOf "## Dry run"
      report `shouldSatisfy` T.isInfixOf "**Run gate: dry-run**"

    it "renders an error report listing the failed circuit" $ do
      let report =
            renderReport . inputs False . rowsFor $
              [ (RowFailed, 0, False, "device offline")
              , (RowCompleted, 99, True, "")
              , (RowCompleted, 99, True, "")
              , (RowCompleted, 99, True, "")
              ]
      report `shouldSatisfy` T.isInfixOf "## Errors"
      report `shouldSatisfy` T.isInfixOf "**Run gate: error**"
      report `shouldSatisfy` T.isInfixOf "device offline"
