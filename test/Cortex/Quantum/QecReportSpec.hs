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

import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Cortex.Quantum.Provenance
  ( CaseProvenance (..)
  , ClientTokenSource (..)
  , RedactionMode (..)
  , RunProvenance (..)
  , SchemaHeader (..)
  )
import Cortex.Quantum.Qec

backendArn :: Text
backendArn = "arn:aws:braket:eu-north-1::device/qpu/iqm/Emerald"

sampleProvenance :: CaseProvenance
sampleProvenance =
  CaseProvenance
    { cpTaskArn =
        "arn:aws:braket:eu-north-1:123456789012:quantum-task/22222222-2222-4222-8222-222222222222"
    , cpTaskUuid = "22222222-2222-4222-8222-222222222222"
    , cpStatus = "COMPLETED"
    , cpDeviceId = backendArn
    , cpRequestedShots = 100
    , cpObservedShots = 100
    , cpCreatedAt = "2026-06-23T18:20:00.000Z"
    , cpEndedAt = "2026-06-23T18:22:00.000Z"
    , cpResultSchema = Just (SchemaHeader "braket.task_result.gate_model_task_result" "1")
    , cpDeviceParamsSchema = Just (SchemaHeader "braket.device_schema.iqm.iqm_device_parameters" "1")
    , cpActionSchema = Just (SchemaHeader "braket.ir.openqasm.program" "1")
    , cpIqmSchema = Just (SchemaHeader "braket.device_schema.iqm.iqm_metadata" "1")
    , cpQubitCount = Just 5
    , cpDisableQubitRewiring = Just False
    , cpOpenQasmSource = "OPENQASM 3;\n"
    , cpOpenQasmSha256 = "a1b2c3"
    , cpCompiledProgram = Just "#pragma braket verbatim\nbox {}\n"
    , cpCompiledProgramSha256 = Just "d4e5f6"
    , cpResultSha256 = "0011223344556677"
    , cpClientToken = Just "client-token"
    , cpClientTokenSource = TokenExact
    , cpS3Bucket = "amazon-braket-example-123456789012-eu-north-1"
    , cpS3Directory = "cortex/dev/run/22222222-2222-4222-8222-222222222222"
    , cpS3Uri =
        "s3://amazon-braket-example-123456789012-eu-north-1/cortex/dev/run/22222222-2222-4222-8222-222222222222/results.json"
    }

sampleRunProvenance :: RunProvenance
sampleRunProvenance =
  RunProvenance
    { rpCortexCommit = "0123456789abcdef0123456789abcdef01234567"
    , rpWireSourcePath = "examples/wire/qec-repetition-realize.wire"
    , rpWireSourceSha256 = "feedface"
    , rpRegion = "eu-north-1"
    , rpSdkVersion = "aws-cli/2.15.0"
    , rpReportUuid = "33333333-3333-4333-8333-333333333333"
    }

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
        (provenanceFor status)
    provenanceFor RowCompleted = Just sampleProvenance
    provenanceFor _ = Nothing

inputs :: Bool -> [CaseRow] -> ReportInputs
inputs dry rows =
  ReportInputs
    { riSource = "examples/wire/qec-repetition-realize.wire"
    , riBackend = backendArn
    , riShots = 100
    , riThreshold = 90
    , riCompletedAt = "2026-06-23T14:15:30Z"
    , riOutputPath = Nothing
    , riDryRun = dry
    , riRows = rows
    , riRunProvenance = if dry then Nothing else Just sampleRunProvenance
    , riRedaction = Redacted
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

    it "embeds per-case provenance, run-level provenance, and verification steps" $ do
      let report =
            renderReport . inputs False . rowsFor $
              [ (RowCompleted, 99, True, "")
              , (RowCompleted, 94, True, "")
              , (RowCompleted, 95, True, "")
              , (RowCompleted, 96, True, "")
              ]
      report `shouldSatisfy` T.isInfixOf "<summary>Provenance</summary>"
      report `shouldSatisfy` T.isInfixOf "result sha256"
      report `shouldSatisfy` T.isInfixOf "## Provenance & reproduction"
      report `shouldSatisfy` T.isInfixOf "How to verify"
      report `shouldSatisfy` T.isInfixOf "22222222-2222-4222-8222-222222222222"
      report `shouldSatisfy` T.isInfixOf "#pragma braket verbatim"

    it "redacts the AWS account id by default in a committed report" $ do
      let report =
            renderReport . inputs False . rowsFor $
              [(RowCompleted, 99, True, "")]
      report `shouldNotSatisfy` T.isInfixOf "123456789012"
      report `shouldSatisfy` T.isInfixOf ":***:"

    it "accepts a report whose every case ran on the backend device" $
      reportDeviceInvariant (inputs False (rowsFor [(RowCompleted, 99, True, "")]))
        `shouldBe` Right ()

    it "fails the device invariant when a case ran on a different device" $ do
      let garnetProvenance = sampleProvenance {cpDeviceId = "arn:aws:braket:eu-north-1::device/qpu/iqm/Garnet"}
          mismatchedRows =
            [ row {rowProvenance = Just garnetProvenance}
            | row <- rowsFor [(RowCompleted, 99, True, "")]
            ]
      reportDeviceInvariant (inputs False mismatchedRows) `shouldSatisfy` isLeft
