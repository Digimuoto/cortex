{- |
Module      : Cortex.Wire.Circuit.EngineSpec
Description : Hosted circuit-engine boundary tests.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Exercises the versioned host-process envelope, engine snapshot validation,
and executable artifact integrity boundary.
-}
module Cortex.Wire.Circuit.EngineSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Cortex.Wire.Circuit.Engine

spec :: Spec
spec = do
  describe "hosted process protocol" $ do
    it "round-trips every host command" $ do
      let state = sampleState
          commands =
            [ HostStart "run-1"
            , HostRestore "run-1" state
            , HostEffectCompleted "run-1" 3 0 (EffectSucceeded 1)
            , HostEffectCompleted "run-1" 4 1 EffectSkipped
            , HostEffectCompleted "run-1" 5 2 (EffectFailed "boom")
            , HostCheckpointCommitted "run-1" 5
            , HostCancel "run-1" "operator request"
            , HostShutdown "run-1"
            ]
      shouldBe
        (traverse (decodeHostCommand . encodeHostCommand) commands)
        (traverse Right commands)

    it "round-trips every engine event" $ do
      let events =
            [ EngineHello "program-1" "cortex.wire.engine/v1"
            , EngineCheckpoint "run-1" sampleState
            , EngineEffectRequested "run-1" 2 0
            , EngineTerminal "run-1" EngineSucceeded
            , EngineProtocolError (Just "run-1") "bad sequence"
            ]
      shouldBe
        (traverse (decodeEngineEvent . encodeEngineEvent) events)
        (traverse Right events)

    it "rejects a protocol version mismatch" $ do
      let encoded =
            "{\"type\":\"start\",\"protocol\":\"cortex.wire.host-process/v2\",\"run_id\":\"run-1\"}"
      shouldSatisfy (decodeHostCommand encoded) isLeft

  describe "engine-state validation" $ do
    it "accepts stable nonzero handles for completed nodes" $ do
      shouldBe (validateEngineState "program-1" 2 sampleState) (Right ())

    it "rejects a completed node with handle zero" $ do
      let invalid = sampleState {esOutputHandles = [0, 0]}
      shouldBe
        (validateEngineState "program-1" 2 invalid)
        (Left "completed node has zero output handle at index 0")

    it "rejects values attached to non-completed nodes" $ do
      let invalid = sampleState {esOutputHandles = [1, 2]}
      shouldBe
        (validateEngineState "program-1" 2 invalid)
        (Left "non-completed node has an output handle at index 1")

    it "distinguishes live running state from normalized restore state" $ do
      let live =
            sampleState
              { esNodeStatuses = [EngineCompleted, EngineRunning]
              }
      shouldBe (validateEngineState "program-1" 2 live) (Right ())
      shouldBe
        (validateRestorableEngineState "program-1" 2 live)
        (Left "restored engine state contains running node at index 1")

    it "requires a positive checkpoint sequence" $ do
      let invalid = sampleState {esCheckpointSequence = 0}
      shouldBe
        (validateEngineState "program-1" 2 invalid)
        (Left "engine-state checkpoint sequence must be positive")

    it "rejects a completed terminal with pending work" $ do
      let invalid = sampleState {esTerminal = EngineSucceeded}
      shouldBe
        (validateEngineState "program-1" 2 invalid)
        (Left "completed terminal state contains an unsettled or failed node")

  describe "hosted artifact loading" $ do
    it "verifies the executable digest and stable schemas"
      . withSystemTempDirectory "cortex-hosted-artifact"
      $ \directory -> do
        BS.writeFile (directory </> "circuit-engine") "engine"
        BS.writeFile
          (directory </> "hosted.manifest.json")
          (BSL.toStrict (Aeson.encode validManifest))
        loaded <- loadHostedProgramArtifact directory
        case loaded of
          Left err -> expectationFailure (show err)
          Right artifact -> do
            shouldBe
              (hostedProgramExecutable artifact)
              (directory </> "circuit-engine")
            shouldBe (hostedProgramManifest artifact) validManifest

    it "rejects executable substitution"
      . withSystemTempDirectory "cortex-hosted-artifact"
      $ \directory -> do
        BS.writeFile (directory </> "circuit-engine") "substituted"
        BS.writeFile
          (directory </> "hosted.manifest.json")
          (BSL.toStrict (Aeson.encode validManifest))
        loaded <- loadHostedProgramArtifact directory
        shouldSatisfy loaded isDigestMismatch

    it "rejects a sparse executor map"
      . withSystemTempDirectory "cortex-hosted-artifact"
      $ \directory -> do
        BS.writeFile (directory </> "circuit-engine") "engine"
        BS.writeFile
          (directory </> "hosted.manifest.json")
          ( BSL.toStrict
              ( Aeson.encode
                  validManifest
                    { hpmNodeExecutors = Map.fromList [(1, "std.io.stdout")]
                    }
              )
          )
        loaded <- loadHostedProgramArtifact directory
        shouldSatisfy loaded isNodeMapInvalid

sampleState :: EngineState
sampleState =
  EngineState
    { esSchema = engineStateSchema
    , esProgramIdentity = "program-1"
    , esCheckpointSequence = 2
    , esTerminal = EngineActive
    , esNodeStatuses = [EngineCompleted, EnginePending]
    , esOutputHandles = [1, 0]
    }

validManifest :: HostedProgramManifest
validManifest =
  HostedProgramManifest
    { hpmSchema = hostedProgramManifestSchema
    , hpmTarget = hostedLinuxTarget
    , hpmTargetTriple = "x86_64-unknown-linux-gnu"
    , hpmProtocol = hostedProcessProtocol
    , hpmEngineStateSchema = engineStateSchema
    , hpmEngineAbi = engineAbi
    , hpmProgramIdentity = "program-1"
    , hpmExecutable = "circuit-engine"
    , hpmExecutableSha256 =
        "ed9f6f25068608efd412958da4dfc19328ca3511251fa6d5f9c42baf230e32f8"
    , hpmStaticProgramSha256 =
        "0000000000000000000000000000000000000000000000000000000000000000"
    , hpmNodeExecutors = Map.fromList [(0, "std.io.stdout")]
    , hpmGeneratedDigests = Map.fromList [("program.c", "generated-digest")]
    , hpmToolchainProvenance = Map.fromList [("clang", "fixture-clang")]
    }

isLeft :: Either a b -> Bool
isLeft = \case
  Left _err -> True
  Right _value -> False

isDigestMismatch :: Either HostedProgramError HostedProgramArtifact -> Bool
isDigestMismatch = \case
  Left HostedExecutableDigestMismatch {} -> True
  Left HostedManifestMissing {} -> False
  Left HostedManifestReadFailed {} -> False
  Left HostedManifestDecodeFailed {} -> False
  Left HostedManifestSchemaMismatch {} -> False
  Left HostedTargetMismatch {} -> False
  Left HostedTargetTripleMismatch {} -> False
  Left HostedProtocolMismatch {} -> False
  Left HostedStateSchemaMismatch {} -> False
  Left HostedEngineAbiMismatch {} -> False
  Left HostedNodeMapInvalid {} -> False
  Left HostedExecutableMissing {} -> False
  Left HostedExecutablePathInvalid {} -> False
  Left HostedExecutableReadFailed {} -> False
  Right _artifact -> False

isNodeMapInvalid :: Either HostedProgramError HostedProgramArtifact -> Bool
isNodeMapInvalid = \case
  Left HostedNodeMapInvalid {} -> True
  Left _other -> False
  Right _artifact -> False
