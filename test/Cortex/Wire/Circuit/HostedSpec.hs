{- |
Module      : Cortex.Wire.Circuit.HostedSpec
Description : Protocol tests for the generic hosted-circuit process host.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Drives 'runHostedProgram' against scripted fake engines — small shell scripts
speaking exact protocol JSONL — to pin the host loop's behavior under
conforming exchanges, cancellation races, effect interruption, nonconforming
engines, and commit aborts. The scripts assert direction too: a fake engine
exits nonzero if the host forwards something the protocol forbids (for
example, an effect completion after cancellation).
-}
module Cortex.Wire.Circuit.HostedSpec (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Exception (AsyncException (ThreadKilled), throwIO)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Directory (getPermissions, setOwnerExecutable, setPermissions)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec

import Cortex.Wire.Circuit.Engine
  ( EffectCompletion (..)
  , EngineEvent (..)
  , EngineNodeStatus (..)
  , EngineState (..)
  , EngineTerminalState (..)
  , HostedProgramArtifact
  , HostedProgramManifest (..)
  , encodeEngineEvent
  , engineAbi
  , engineStateSchema
  , hostedLinuxTarget
  , hostedProcessProtocol
  , hostedProgramManifestSchema
  , loadHostedProgramArtifact
  , sha256Hex
  )
import Cortex.Wire.Circuit.Hosted
  ( CheckpointCommitResult (..)
  , EffectResolution (..)
  , HostedRunError (..)
  , HostedRunErrorKind (..)
  , HostedRuntimeHost (..)
  , mkHostedResponseTimeout
  , runHostedProgram
  , runHostedProgramWithResponseTimeout
  )

programIdentity :: Text
programIdentity = "hosted-spec-program"

specRunId :: Text
specRunId = "hosted-spec-run"

{- | One protocol line as the engine would write it (without the newline;
the script's emit helper appends it).
-}
eventLine :: EngineEvent -> Text
eventLine event = TE.decodeUtf8 (BS.init (encodeEngineEvent event))

engineState :: Int -> EngineTerminalState -> [EngineNodeStatus] -> [Int] -> EngineState
engineState sequenceNumber terminal statuses handles =
  EngineState
    { esSchema = engineStateSchema
    , esProgramIdentity = programIdentity
    , esCheckpointSequence = fromIntegral sequenceNumber
    , esTerminal = terminal
    , esNodeStatuses = statuses
    , esOutputHandles = fmap fromIntegral handles
    }

hello :: Text
hello = eventLine (EngineHello programIdentity engineAbi)

checkpoint :: EngineState -> Text
checkpoint = eventLine . EngineCheckpoint specRunId

effectRequested :: Int -> Int -> Text
effectRequested sequenceNumber nodeId =
  eventLine (EngineEffectRequested specRunId (fromIntegral sequenceNumber) (fromIntegral nodeId))

terminalEvent :: EngineTerminalState -> Text
terminalEvent = eventLine . EngineTerminal specRunId

{- | Script steps: emit a protocol line, read (and optionally police) a host
command, or block forever awaiting a command the host must never send.
-}
data Step
  = Emit Text
  | Await
  | PauseMilliseconds Int
  | ExitWith Int
  | -- | Read a line and exit 7 if the host forwarded an effect completion.
    AwaitNotCompletion

renderScript :: [Step] -> Text
renderScript steps =
  T.unlines
    ( [ "#!/bin/sh"
      , "set -u"
      , "emit() { printf '%s\\n' \"$1\"; }"
      ]
        <> concatMap renderStep steps
        <> ["exit 0"]
    )
  where
    renderStep = \case
      Emit line -> ["emit '" <> line <> "'"]
      Await -> ["read -r line || exit 9"]
      PauseMilliseconds milliseconds ->
        ["sleep " <> T.pack (show milliseconds) <> "e-3"]
      ExitWith exitCode -> ["exit " <> T.pack (show exitCode)]
      AwaitNotCompletion ->
        [ "read -r line || exit 9"
        , "case \"$line\" in *effect_completed*) exit 7 ;; esac"
        ]

withFakeEngine :: [Step] -> (HostedProgramArtifact -> IO ()) -> IO ()
withFakeEngine steps use =
  withSystemTempDirectory "hosted-spec" $ \bundleDir -> do
    let executablePath = bundleDir </> "circuit-engine"
        scriptText = renderScript steps
        scriptBytes = TE.encodeUtf8 scriptText
    TIO.writeFile executablePath scriptText
    permissions <- getPermissions executablePath
    setPermissions executablePath (setOwnerExecutable True permissions)
    let manifest =
          HostedProgramManifest
            { hpmSchema = hostedProgramManifestSchema
            , hpmTarget = hostedLinuxTarget
            , hpmTargetTriple = "x86_64-unknown-linux-gnu"
            , hpmProtocol = hostedProcessProtocol
            , hpmEngineStateSchema = engineStateSchema
            , hpmEngineAbi = engineAbi
            , hpmProgramIdentity = programIdentity
            , hpmExecutable = "circuit-engine"
            , hpmExecutableSha256 = sha256Hex scriptBytes
            , hpmStaticProgramSha256 = sha256Hex "hosted-spec-static-program"
            , hpmNodeExecutors = Map.fromList [(0, "exec-a"), (1, "exec-b")]
            , hpmGeneratedDigests = Map.empty
            , hpmToolchainProvenance = Map.empty
            }
    BSL.writeFile (bundleDir </> "hosted.manifest.json") (Aeson.encode manifest)
    artifactResult <- loadHostedProgramArtifact bundleDir
    case artifactResult of
      Left err -> expectationFailure ("fake engine artifact rejected: " <> show err)
      Right artifact -> use artifact

runHost
  :: HostedRuntimeHost
  -> HostedProgramArtifact
  -> IO (Either HostedRunError EngineState)
runHost runtimeHost artifact = do
  result <- timeout (30 * 1000000) (runHostedProgram artifact specRunId runtimeHost Nothing)
  case result of
    Nothing -> do
      expectationFailure "hosted run did not finish within the test deadline"
      fail "unreachable"
    Just hostedResult -> pure hostedResult

runHostWithResponseTimeout
  :: Int
  -> HostedRuntimeHost
  -> HostedProgramArtifact
  -> IO (Either HostedRunError EngineState)
runHostWithResponseTimeout responseTimeoutMicros runtimeHost artifact = do
  responseTimeout <-
    case mkHostedResponseTimeout responseTimeoutMicros of
      Left message -> do
        expectationFailure (T.unpack message)
        fail "unreachable"
      Right validTimeout -> pure validTimeout
  result <-
    timeout
      (2 * 1000000)
      (runHostedProgramWithResponseTimeout responseTimeout artifact specRunId runtimeHost Nothing)
  case result of
    Nothing -> do
      expectationFailure "hosted run did not finish within the test deadline"
      fail "unreachable"
    Just hostedResult -> pure hostedResult

succeedingHost :: HostedRuntimeHost
succeedingHost =
  HostedRuntimeHost
    { hostedCommitCheckpoint = \_state -> pure CheckpointCommitAccepted
    , hostedExecuteEffect = \nodeId ->
        pure (EffectResolved (EffectSucceeded (fromIntegral nodeId * 2 + 7)))
    , hostedAwaitCancellation = Nothing
    }

spec :: Spec
spec = describe "Cortex.Wire.Circuit.Hosted" $ do
  it "drives a conforming engine through two effects to a completed terminal" $ do
    let steps =
          [ Emit hello
          , Await -- start
          , Emit (checkpoint (engineState 1 EngineActive [EnginePending, EnginePending] [0, 0]))
          , Await -- ack 1
          , Emit (effectRequested 1 0)
          , Await -- effect_completed node 0 (handle 7)
          , Emit (checkpoint (engineState 2 EngineActive [EngineCompleted, EnginePending] [7, 0]))
          , Await -- ack 2
          , Emit (effectRequested 2 1)
          , Await -- effect_completed node 1 (handle 9)
          , Emit (checkpoint (engineState 3 EngineSucceeded [EngineCompleted, EngineCompleted] [7, 9]))
          , Await -- ack 3
          , Emit (terminalEvent EngineSucceeded)
          , Await -- shutdown
          ]
    withFakeEngine steps $ \artifact -> do
      result <- runHost succeedingHost artifact
      case result of
        Left err -> expectationFailure ("expected success, got: " <> show err)
        Right finalState -> do
          finalState.esTerminal `shouldBe` EngineSucceeded
          finalState.esCheckpointSequence `shouldBe` 3

  it "honors a committed terminal when the child exits nonzero after shutdown" $ do
    let steps =
          [ Emit hello
          , Await -- start
          , Emit (checkpoint (engineState 1 EngineSucceeded [EngineCompleted, EngineCompleted] [7, 9]))
          , Await -- ack 1
          , Emit (terminalEvent EngineSucceeded)
          , Await -- shutdown
          , ExitWith 7
          ]
    withFakeEngine steps $ \artifact -> do
      result <- runHost succeedingHost artifact
      case result of
        Left err -> expectationFailure ("expected committed success, got: " <> show err)
        Right finalState -> finalState.esTerminal `shouldBe` EngineSucceeded

  it "cancels a run with an effect in flight without failing it" $ do
    let steps =
          [ Emit hello
          , Await -- start
          , Emit (checkpoint (engineState 1 EngineActive [EnginePending, EnginePending] [0, 0]))
          , Await -- ack 1
          , Emit (effectRequested 1 0)
          , AwaitNotCompletion -- must be the cancel, never a completion
          , Emit (checkpoint (engineState 2 EngineCancelled [EnginePending, EnginePending] [0, 0]))
          , Await -- ack 2
          , Emit (terminalEvent EngineCancelled)
          , Await -- shutdown
          ]
    withFakeEngine steps $ \artifact -> do
      effectStarted <- newEmptyMVar
      neverResolves <- newEmptyMVar
      let runtimeHost =
            HostedRuntimeHost
              { hostedCommitCheckpoint = \_state -> pure CheckpointCommitAccepted
              , hostedExecuteEffect = \_nodeId -> do
                  putMVar effectStarted ()
                  () <- readMVar neverResolves
                  pure (EffectResolved EffectSkipped)
              , hostedAwaitCancellation =
                  Just (readMVar effectStarted >> pure (Right "operator cancellation"))
              }
      result <- runHost runtimeHost artifact
      case result of
        Left err -> expectationFailure ("expected cancelled terminal, got: " <> show err)
        Right finalState -> finalState.esTerminal `shouldBe` EngineCancelled

  it "intercepts interrupted effects instead of forwarding them as failures" $ do
    let steps =
          [ Emit hello
          , Await -- start
          , Emit (checkpoint (engineState 1 EngineActive [EnginePending, EnginePending] [0, 0]))
          , Await -- ack 1
          , Emit (effectRequested 1 0)
          , AwaitNotCompletion -- must be the cancel; an interruption is never forwarded
          , Emit (checkpoint (engineState 2 EngineCancelled [EnginePending, EnginePending] [0, 0]))
          , Await -- ack 2
          , Emit (terminalEvent EngineCancelled)
          , Await -- shutdown
          ]
    withFakeEngine steps $ \artifact -> do
      interrupted <- newEmptyMVar
      let runtimeHost =
            HostedRuntimeHost
              { hostedCommitCheckpoint = \_state -> pure CheckpointCommitAccepted
              , hostedExecuteEffect = \_nodeId -> do
                  putMVar interrupted ()
                  pure (EffectInterrupted "Pulse is shutting down")
              , hostedAwaitCancellation =
                  Just (readMVar interrupted >> pure (Right "Pulse host shutdown"))
              }
      result <- runHost runtimeHost artifact
      case result of
        Left err -> expectationFailure ("expected cancelled terminal, got: " <> show err)
        Right finalState -> finalState.esTerminal `shouldBe` EngineCancelled

  it "keeps a completion deadline when a request crosses that completion" $ do
    let steps =
          [ Emit hello
          , Await -- start
          , Emit (checkpoint (engineState 1 EngineActive [EnginePending, EnginePending] [0, 0]))
          , Await -- ack 1
          , Emit (effectRequested 1 0)
          , PauseMilliseconds 100 -- request 2 crosses completion 1 in flight
          , Emit (effectRequested 2 1)
          , Await -- completion 1
          , Await -- no checkpoint: the host must time out, not wait on effect 2 forever
          ]
    withFakeEngine steps $ \artifact -> do
      neverResolves <- newEmptyMVar
      let runtimeHost =
            succeedingHost
              { hostedExecuteEffect = \case
                  0 -> pure (EffectResolved (EffectSucceeded 7))
                  _otherNode -> readMVar neverResolves >> pure (EffectResolved EffectSkipped)
              }
      result <- runHostWithResponseTimeout 1000000 runtimeHost artifact
      case result of
        Right _state -> expectationFailure "expected a checkpoint-response timeout"
        Left err ->
          T.unpack err.hostedRunErrorMessage
            `shouldContain` "mandated protocol output did not arrive"

  it "fails closed when an interrupted effect is not followed by an authorized cancel" $ do
    let steps =
          [ Emit hello
          , Await -- start
          , Emit (checkpoint (engineState 1 EngineActive [EnginePending, EnginePending] [0, 0]))
          , Await -- ack 1
          , Emit (effectRequested 1 0)
          , AwaitNotCompletion -- interruption must never become a completion
          ]
    withFakeEngine steps $ \artifact -> do
      interrupted <- newEmptyMVar
      let runtimeHost =
            HostedRuntimeHost
              { hostedCommitCheckpoint = \_state -> pure CheckpointCommitAccepted
              , hostedExecuteEffect = \_nodeId -> do
                  putMVar interrupted ()
                  pure (EffectInterrupted "host is stopping")
              , hostedAwaitCancellation =
                  Just (readMVar interrupted >> pure (Left "cancellation authority unavailable"))
              }
      result <- runHost runtimeHost artifact
      case result of
        Right _state -> expectationFailure "expected cancellation watcher failure"
        Left err -> do
          err.hostedRunErrorKind `shouldBe` HostedRunFault
          T.unpack err.hostedRunErrorMessage `shouldContain` "cancellation authority unavailable"

  it "surfaces synchronous cancellation-watcher exceptions as host faults" $ do
    let steps = [Emit hello, Await]
    withFakeEngine steps $ \artifact -> do
      let runtimeHost =
            succeedingHost
              { hostedAwaitCancellation = Just (ioError (userError "watcher exploded"))
              }
      result <- runHost runtimeHost artifact
      case result of
        Right _state -> expectationFailure "expected cancellation watcher failure"
        Left err ->
          T.unpack err.hostedRunErrorMessage
            `shouldContain` "cancellation watcher threw: user error (watcher exploded)"

  it "does not convert asynchronous checkpoint cancellation into a run fault" $ do
    let steps =
          [ Emit hello
          , Await -- start
          , Emit (checkpoint (engineState 1 EngineActive [EnginePending, EnginePending] [0, 0]))
          , Await -- host tears the process down without acknowledging
          ]
    withFakeEngine steps $ \artifact -> do
      let runtimeHost =
            succeedingHost
              { hostedCommitCheckpoint = \_state -> throwIO ThreadKilled
              }
      runHostedProgram artifact specRunId runtimeHost Nothing
        `shouldThrow` (== ThreadKilled)

  it "fails an engine that requests an effect before its initial checkpoint" $ do
    let steps =
          [ Emit hello
          , Await -- start
          , Emit (effectRequested 1 0)
          , Await -- blocks until the host tears the child down
          ]
    withFakeEngine steps $ \artifact -> do
      result <- runHost succeedingHost artifact
      case result of
        Right _state -> expectationFailure "expected a protocol fault"
        Left err -> do
          err.hostedRunErrorKind `shouldBe` HostedRunFault
          T.unpack err.hostedRunErrorMessage
            `shouldContain` "before its initial checkpoint"

  it "fails an engine whose first checkpoint sequence is not one" $ do
    let steps =
          [ Emit hello
          , Await -- start
          , Emit (checkpoint (engineState 2 EngineActive [EnginePending, EnginePending] [0, 0]))
          , Await -- blocks until the host tears the child down
          ]
    withFakeEngine steps $ \artifact -> do
      result <- runHost succeedingHost artifact
      case result of
        Right _state -> expectationFailure "expected a protocol fault"
        Left err -> do
          err.hostedRunErrorKind `shouldBe` HostedRunFault
          T.unpack err.hostedRunErrorMessage
            `shouldContain` "initial engine checkpoint sequence must be exactly one"

  it "reports a commit abort as HostedRunAborted, not a fault" $ do
    let steps =
          [ Emit hello
          , Await -- start
          , Emit (checkpoint (engineState 1 EngineActive [EnginePending, EnginePending] [0, 0]))
          , Await -- blocks; the host aborts without acknowledging
          ]
    withFakeEngine steps $ \artifact -> do
      let runtimeHost =
            succeedingHost
              { hostedCommitCheckpoint =
                  \_state -> pure (CheckpointCommitAbortRun "ownership lost to a newer claimant")
              }
      result <- runHost runtimeHost artifact
      case result of
        Right _state -> expectationFailure "expected an abort"
        Left err -> do
          err.hostedRunErrorKind `shouldBe` HostedRunAborted
          T.unpack err.hostedRunErrorMessage `shouldContain` "ownership lost"
