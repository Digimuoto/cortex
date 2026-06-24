{- |
Module      : Cortex.Quantum.ProvenanceSpec
Description : Braket run-report provenance capture, redaction, and rendering.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Checks that provenance is captured from AWS-generated evidence (the
@get-quantum-task@ response and the @results.json@ artifact), that the device
invariant rejects a mismatch between the submitted device and the device the task
ran on, that redaction masks the account/bucket while keeping the verifiable
fields, and that the rendered Markdown carries the integrity hashes, the compiled
native program, and the how-to-verify steps.
-}
module Cortex.Quantum.ProvenanceSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Cortex.Quantum.Provenance

emeraldArn :: Text
emeraldArn = "arn:aws:braket:eu-north-1::device/qpu/iqm/Emerald"

garnetArn :: Text
garnetArn = "arn:aws:braket:eu-north-1::device/qpu/iqm/Garnet"

taskArn :: Text
taskArn = "arn:aws:braket:eu-north-1:123456789012:quantum-task/00000000-0000-4000-8000-000000000000"

bucket :: Text
bucket = "amazon-braket-example-123456789012-eu-north-1"

directory :: Text
directory = "cortex/dev/wire-openqasm-20260623T182217Z/00000000-0000-4000-8000-000000000000"

openqasmSource :: Text
openqasmSource = "OPENQASM 3;\nqubit[5] q;\nbit[5] c;\n"

compiledProgram :: Text
compiledProgram = "#pragma braket verbatim\nbox {\nprx(1.5707963, 0.0) $0;\n}\n"

-- A realistic IQM gate-model @results.json@.
resultValue :: Value
resultValue =
  object
    [ "braketSchemaHeader"
        .= object
          [ "name" .= ("braket.task_result.gate_model_task_result" :: Text)
          , "version" .= ("1" :: Text)
          ]
    , "measuredQubits" .= ([0, 1, 2, 3, 4] :: [Int])
    , "measurements" .= ([[0, 0, 0, 0, 0], [0, 0, 0, 0, 0]] :: [[Int]])
    , "taskMetadata"
        .= object
          [ "id" .= taskArn
          , "status" .= ("COMPLETED" :: Text)
          , "deviceId" .= emeraldArn
          , "shots" .= (100 :: Int)
          , "createdAt" .= ("2026-06-23T18:20:00.000Z" :: Text)
          , "endedAt" .= ("2026-06-23T18:22:00.000Z" :: Text)
          , "deviceParameters"
              .= object
                [ "braketSchemaHeader"
                    .= object
                      [ "name" .= ("braket.device_schema.iqm.iqm_device_parameters" :: Text)
                      , "version" .= ("1" :: Text)
                      ]
                , "paradigmParameters"
                    .= object
                      [ "qubitCount" .= (5 :: Int)
                      , "disableQubitRewiring" .= False
                      ]
                ]
          ]
    , "additionalMetadata"
        .= object
          [ "action"
              .= object
                [ "braketSchemaHeader"
                    .= object
                      [ "name" .= ("braket.ir.openqasm.program" :: Text)
                      , "version" .= ("1" :: Text)
                      ]
                , "source" .= openqasmSource
                ]
          , "iqmMetadata"
              .= object
                [ "braketSchemaHeader"
                    .= object
                      [ "name" .= ("braket.device_schema.iqm.iqm_metadata" :: Text)
                      , "version" .= ("1" :: Text)
                      ]
                , "compiledProgram" .= compiledProgram
                ]
          ]
    ]

-- The @get-quantum-task@ response.
taskValue :: Value
taskValue =
  object
    [ "quantumTaskArn" .= taskArn
    , "status" .= ("COMPLETED" :: Text)
    , "deviceArn" .= emeraldArn
    , "shots" .= (100 :: Int)
    , "createdAt" .= ("2026-06-23T18:20:00.000Z" :: Text)
    , "endedAt" .= ("2026-06-23T18:22:00.000Z" :: Text)
    , "outputS3Bucket" .= bucket
    , "outputS3Directory" .= directory
    ]

sources :: Text -> ProvenanceSources
sources expected =
  ProvenanceSources
    { psTaskValue = taskValue
    , psResultValue = resultValue
    , psResultRawSha256 = "deadbeef"
    , psExpectedDeviceArn = expected
    , psClientToken = Just "client-token-abc"
    , psClientTokenSource = TokenExact
    }

runProvenance :: RunProvenance
runProvenance =
  RunProvenance
    { rpCortexCommit = "0123456789abcdef0123456789abcdef01234567"
    , rpWireSourcePath = "examples/wire/qec-repetition-realize.wire"
    , rpWireSourceSha256 = "feedface"
    , rpRegion = "eu-north-1"
    , rpSdkVersion = "aws-cli/2.15.0"
    , rpReportUuid = "11111111-1111-4111-8111-111111111111"
    }

spec :: Spec
spec = do
  describe "sha256OfText"
    . it "matches the SHA-256 vector for the empty string"
    $ sha256OfText ""
      `shouldBe` "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  describe "extractCaseProvenance" $ do
    it "captures AWS-generated provenance from the task and result" $
      case extractCaseProvenance (sources emeraldArn) of
        Left err -> expectationFailure (T.unpack err)
        Right prov -> do
          cpDeviceId prov `shouldBe` emeraldArn
          cpTaskUuid prov `shouldBe` "00000000-0000-4000-8000-000000000000"
          cpStatus prov `shouldBe` "COMPLETED"
          cpRequestedShots prov `shouldBe` 100
          cpObservedShots prov `shouldBe` 2
          cpQubitCount prov `shouldBe` Just 5
          cpDisableQubitRewiring prov `shouldBe` Just False
          cpResultSha256 prov `shouldBe` "deadbeef"
          cpOpenQasmSha256 prov `shouldBe` sha256OfText openqasmSource
          cpCompiledProgram prov `shouldBe` Just compiledProgram
          cpCompiledProgramSha256 prov `shouldBe` Just (sha256OfText compiledProgram)
          fmap renderSchemaHeader (cpResultSchema prov)
            `shouldBe` Just "braket.task_result.gate_model_task_result/1"

    it "fails the device invariant when the submitted device differs from the result" $
      extractCaseProvenance (sources garnetArn) `shouldSatisfy` isLeft

  describe "observedShots" $ do
    it "counts alternate direct histogram keys accepted by the decoder" $ do
      observedShots (object ["measurement_counts" .= object ["00" .= (2 :: Int), "11" .= (3 :: Int)]])
        `shouldBe` 5
      observedShots (object ["counts" .= object ["00" .= (7 :: Int), "11" .= (11 :: Int)]])
        `shouldBe` 18

  describe "redaction" $ do
    it "masks the 12-digit account id in a task ARN" $
      redactArn taskArn
        `shouldBe` "arn:aws:braket:eu-north-1:***:quantum-task/00000000-0000-4000-8000-000000000000"

    it "leaves an account-less device ARN unchanged" $
      redactArn emeraldArn `shouldBe` emeraldArn

    it "masks bucket and account but keeps UUIDs, hashes, device, and compiled program" $
      case extractCaseProvenance (sources emeraldArn) of
        Left err -> expectationFailure (T.unpack err)
        Right prov -> do
          let redacted = redactCaseProvenance Redacted prov
          cpS3Bucket redacted `shouldBe` "***"
          cpTaskArn redacted `shouldSatisfy` T.isInfixOf ":***:"
          cpTaskUuid redacted `shouldBe` cpTaskUuid prov
          cpDeviceId redacted `shouldBe` emeraldArn
          cpResultSha256 redacted `shouldBe` cpResultSha256 prov
          cpCompiledProgram redacted `shouldBe` cpCompiledProgram prov

    it "masks account and bucket throughout a results.json copy" $ do
      let redacted = T.pack (show (redactResultsJson resultValue))
      redacted `shouldNotSatisfy` T.isInfixOf "123456789012"
      redacted `shouldNotSatisfy` T.isInfixOf bucket
      redacted `shouldSatisfy` T.isInfixOf "00000000-0000-4000-8000-000000000000"

  describe "rendering" $ do
    it "renders a per-case provenance block with hashes and the compiled program" $ do
      let block =
            either (const []) (renderCaseProvenanceBlock . redactCaseProvenance Redacted) $
              extractCaseProvenance (sources emeraldArn)
          rendered = T.unlines block
      rendered `shouldSatisfy` T.isInfixOf "<summary>Provenance</summary>"
      rendered `shouldSatisfy` T.isInfixOf "result sha256"
      rendered `shouldSatisfy` T.isInfixOf "OpenQASM sha256"
      rendered `shouldSatisfy` T.isInfixOf "00000000-0000-4000-8000-000000000000"
      rendered `shouldSatisfy` T.isInfixOf "#pragma braket verbatim"

    it "renders run-level provenance with how-to-verify steps" $ do
      let rendered = T.unlines (renderRunProvenanceBlock Redacted runProvenance (Just taskArn))
      rendered `shouldSatisfy` T.isInfixOf "## Provenance & reproduction"
      rendered `shouldSatisfy` T.isInfixOf "How to verify"
      rendered `shouldSatisfy` T.isInfixOf "sha256sum"
      rendered `shouldSatisfy` T.isInfixOf "11111111-1111-4111-8111-111111111111"
      -- The verify command is one clean code span: the ARN is inline, not
      -- re-wrapped in nested backticks.
      rendered `shouldSatisfy` T.isInfixOf ("--quantum-task-arn " <> taskArn)
      rendered `shouldNotSatisfy` T.isInfixOf "--quantum-task-arn `"

  describe "freshReportUuid"
    . it "is a version-4 UUID"
    $ do
      uuid <- freshReportUuid
      T.length uuid `shouldBe` 36
      T.index uuid 14 `shouldBe` '4'
      T.index uuid 19 `shouldSatisfy` (`elem` ("89ab" :: String))
