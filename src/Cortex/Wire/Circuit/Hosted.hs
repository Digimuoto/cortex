{- |
Module      : Cortex.Wire.Circuit.Hosted
Description : Generic process host for generated circuit-engine executables.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The generated executable owns circuit scheduling and transition validation.
This module owns process lifecycle, bounded JSONL framing, durable checkpoint
acknowledgement, and dispatch to authority-bearing host callbacks.

Cancellation is inherently racy against engine output: a cancel request can
cross an effect request, a buffered completion, or the terminal event in
flight. The loop therefore treats every legal crossing as a drop, never a
protocol fault: post-cancel effect requests and completions are discarded, and
the engine's cancelled checkpoint is the single durable authority for what was
undone.
-}
module Cortex.Wire.Circuit.Hosted
  ( HostedRuntimeHost (..)
  , HostedResponseTimeout
  , defaultHostedResponseTimeout
  , mkHostedResponseTimeout
  , CheckpointCommitResult (..)
  , EffectResolution (..)
  , HostedRunError (..)
  , HostedRunErrorKind (..)
  , runHostedProgram
  , runHostedProgramWithResponseTimeout
  , runHostedReferenceHost
  , renderHostedRunError
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, AsyncCancelled, asyncWithUnmask, cancel, withAsync)
import Control.Concurrent.STM
  ( TQueue
  , TVar
  , atomically
  , check
  , modifyTVar'
  , newTQueueIO
  , newTVarIO
  , orElse
  , readTQueue
  , readTVar
  , readTVarIO
  , registerDelay
  , retry
  , writeTQueue
  )
import Control.Exception
  ( Exception
  , IOException
  , SomeAsyncException
  , SomeException
  , bracket
  , displayException
  , finally
  , fromException
  , mask_
  , throwIO
  , try
  )
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word32, Word64)
import System.Exit (ExitCode (..))
import System.IO
  ( BufferMode (NoBuffering)
  , Handle
  , hClose
  , hFlush
  , hSetBinaryMode
  , hSetBuffering
  )
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process
  ( CreateProcess (close_fds, std_err, std_in, std_out)
  , ProcessHandle
  , StdStream (CreatePipe)
  , createProcess
  , getPid
  , getProcessExitCode
  , proc
  , terminateProcess
  , waitForProcess
  )

import Cortex.Wire.Circuit.Engine
  ( EffectCompletion (..)
  , EngineEvent (..)
  , EngineState (..)
  , EngineTerminalState (..)
  , HostCommand (..)
  , HostedProgramArtifact
  , HostedProgramManifest (..)
  , decodeEngineEvent
  , encodeHostCommand
  , engineAbi
  , hostedProgramExecutable
  , hostedProgramManifest
  , sha256Hex
  , validateEngineState
  , validateRestorableEngineState
  )
import Cortex.Wire.Circuit.HostProtocol qualified as HostProtocol

maxProtocolLineBytes :: Int
maxProtocolLineBytes = 2 * 1024 * 1024

maxDiagnosticBytes :: Int
maxDiagnosticBytes = 64 * 1024

-- | Validated deadline for any response the hosted protocol mandates.
newtype HostedResponseTimeout = HostedResponseTimeout Int
  deriving stock (Eq, Show)

{- | Construct a positive hosted protocol response deadline in microseconds.
The deadline covers mandated engine output, cancellation follow-up after an
interrupted effect, and child exit after shutdown; it never times host effect
execution or checkpoint persistence.
-}
mkHostedResponseTimeout :: Int -> Either Text HostedResponseTimeout
mkHostedResponseTimeout timeoutMicros
  | timeoutMicros <= 0 = Left "hosted response timeout must be positive"
  | otherwise = Right (HostedResponseTimeout timeoutMicros)

-- | Production default: sixty seconds per mandatory response.
defaultHostedResponseTimeout :: HostedResponseTimeout
defaultHostedResponseTimeout = HostedResponseTimeout (60 * 1000000)

{- | Result of the durable checkpoint commit callback.

'CheckpointCommitAbortRun' means the run must stop here but has already been settled
by the callback's own authority (ownership lost to a newer claimant, or the
persistence layer already recorded the failure). The host terminates the child
and reports 'HostedRunAborted' — it must NOT be treated as a fresh fault to
record, or a run owned elsewhere gets clobbered.
-}
data CheckpointCommitResult
  = CheckpointCommitAccepted
  | -- | The snapshot is unacceptable; fail the run.
    CheckpointCommitRejected !Text
  | -- | Stop cleanly; the callback already settled or disowned the run.
    CheckpointCommitAbortRun !Text
  deriving stock (Eq, Show)

{- | Result of one effect execution.

'EffectInterrupted' means the worker was torn down by an imminent run-level
cancellation (operator cancel or host shutdown), not that the effect failed.
The host never forwards it to the engine: the node stays running from the
engine's perspective until the cancellation resets it to pending, so durable
state never records an interruption as a node failure. It is only legal when a
cancellation watcher is installed, because the watcher is what guarantees the
cancel that releases the engine follows promptly.
-}
data EffectResolution
  = EffectResolved !EffectCompletion
  | EffectInterrupted !Text
  deriving stock (Eq, Show)

data HostedRuntimeHost = HostedRuntimeHost
  { hostedCommitCheckpoint :: EngineState -> IO CheckpointCommitResult
  , hostedExecuteEffect :: Word32 -> IO EffectResolution
  , hostedAwaitCancellation :: !(Maybe (IO (Either Text Text)))
  -- ^ Wait for either a host failure or an authorized cancellation reason.
  }

-- | Why a hosted run stopped without a terminal snapshot.
data HostedRunErrorKind
  = -- | A protocol, process, or host fault: the caller should record a failure.
    HostedRunFault
  | {- | The commit callback aborted the run after settling it itself: the
    caller must NOT record another outcome on top.
    -}
    HostedRunAborted
  deriving stock (Eq, Show)

data HostedRunError = HostedRunError
  { hostedRunErrorKind :: !HostedRunErrorKind
  , hostedRunErrorMessage :: !Text
  , hostedRunLastCommitted :: !(Maybe EngineState)
  }
  deriving stock (Eq, Show)

renderHostedRunError :: HostedRunError -> Text
renderHostedRunError err =
  err.hostedRunErrorMessage
    <> maybe
      ""
      ( \state ->
          "; last committed checkpoint "
            <> T.pack (show state.esCheckpointSequence)
      )
      err.hostedRunLastCommitted

data HostInput
  = HostEngineEvent !(Either Text EngineEvent)
  | HostEffectFinished !Word64 !Word32 !(Either Text EffectResolution)
  | HostCancellationRequested !Text
  | HostRuntimeFailed !Text
  | HostChildExited !ExitCode

data LoopState = LoopState
  { loopLastCommitted :: !(Maybe EngineState)
  , loopLastCheckpointSequence :: !(Maybe Word64)
  , loopNextRequestSequence :: !Word64
  , loopAwaitingCheckpoint :: !Bool
  , loopWorkers :: !(Map Word64 (Word32, Async ()))
  , loopActiveNodes :: !(Set Word32)
  , loopInterruptedNodes :: !(Set Word32)
  , loopBufferedCompletions :: !(Map Word64 (Word32, Either Text EffectResolution))
  , loopTerminalSeen :: !(Maybe EngineTerminalState)
  , loopCancellationSent :: !Bool
  , loopEngineDeadline :: !(Maybe (TVar Bool))
  , loopCancellationDeadline :: !(Maybe (TVar Bool))
  {- ^ Engine output and cancellation follow-up are independent obligations.
  Keeping separate timers prevents an unrelated checkpoint from clearing or
  extending the promise that an interrupted effect will be followed by an
  authorized run-level cancel.
  -}
  }

initialLoopState :: Maybe EngineState -> LoopState
initialLoopState maybeRestore =
  LoopState
    { loopLastCommitted = maybeRestore
    , loopLastCheckpointSequence =
        (\state -> state.esCheckpointSequence - 1) <$> maybeRestore
    , loopNextRequestSequence = 1
    , loopAwaitingCheckpoint = False
    , loopWorkers = Map.empty
    , loopActiveNodes = Set.empty
    , loopInterruptedNodes = Set.empty
    , loopBufferedCompletions = Map.empty
    , loopTerminalSeen = Nothing
    , loopCancellationSent = False
    , loopEngineDeadline = Nothing
    , loopCancellationDeadline = Nothing
    }

{- | Forget IO payloads and project only the lifecycle facts consumed by the
pure host-protocol transition policy.
-}
protocolView :: LoopState -> HostProtocol.ProtocolView
protocolView state =
  HostProtocol.ProtocolView
    { protocolCommittedTerminal = (.esTerminal) <$> state.loopLastCommitted
    , protocolAwaitingCheckpoint = state.loopAwaitingCheckpoint
    , protocolWorkerCount = Map.size state.loopWorkers
    , protocolInterruptedCount = Set.size state.loopInterruptedNodes
    , protocolBufferedCompletionCount = Map.size state.loopBufferedCompletions
    , protocolTerminalSeen = state.loopTerminalSeen
    , protocolCancellationSent = state.loopCancellationSent
    }

-- | Start a fresh deadline for a newly-created response obligation.
armFreshEngineDeadline :: Int -> LoopState -> IO LoopState
armFreshEngineDeadline responseTimeoutMicros state = do
  deadline <- registerDelay responseTimeoutMicros
  pure state {loopEngineDeadline = Just deadline}

{- | Ensure an engine-response deadline exists without extending an
outstanding one. This is used when cancellation crosses an already-mandated
checkpoint: the same earliest deadline continues to govern both outputs.
-}
ensureEngineDeadline :: Int -> LoopState -> IO LoopState
ensureEngineDeadline responseTimeoutMicros state = case state.loopEngineDeadline of
  Just _existing -> pure state
  Nothing -> armFreshEngineDeadline responseTimeoutMicros state

ensureCancellationDeadline :: Int -> LoopState -> IO LoopState
ensureCancellationDeadline responseTimeoutMicros state = case state.loopCancellationDeadline of
  Just _existing -> pure state
  Nothing -> do
    deadline <- registerDelay responseTimeoutMicros
    pure state {loopCancellationDeadline = Just deadline}

applyEngineDeadlineUpdate
  :: Int
  -> HostProtocol.DeadlineUpdate
  -> LoopState
  -> IO LoopState
applyEngineDeadlineUpdate responseTimeoutMicros = \case
  HostProtocol.KeepDeadline -> pure
  HostProtocol.ClearDeadline -> \state -> pure state {loopEngineDeadline = Nothing}
  HostProtocol.ArmFreshDeadline -> armFreshEngineDeadline responseTimeoutMicros
  HostProtocol.EnsureDeadline -> ensureEngineDeadline responseTimeoutMicros

applyCancellationDeadlineUpdate
  :: Int
  -> HostProtocol.DeadlineUpdate
  -> LoopState
  -> IO LoopState
applyCancellationDeadlineUpdate responseTimeoutMicros = \case
  HostProtocol.KeepDeadline -> pure
  HostProtocol.ClearDeadline -> \state -> pure state {loopCancellationDeadline = Nothing}
  HostProtocol.ArmFreshDeadline -> \state -> do
    deadline <- registerDelay responseTimeoutMicros
    pure state {loopCancellationDeadline = Just deadline}
  HostProtocol.EnsureDeadline -> ensureCancellationDeadline responseTimeoutMicros

runHostedProgram
  :: HostedProgramArtifact
  -> Text
  -> HostedRuntimeHost
  -> Maybe EngineState
  -> IO (Either HostedRunError EngineState)
runHostedProgram = runHostedProgramWithResponseTimeout defaultHostedResponseTimeout

{- | 'runHostedProgram' with an explicit validated response deadline. Hosts
normally use 'defaultHostedResponseTimeout'; a shorter value is useful for
tightly supervised environments and deterministic protocol tests.
-}
runHostedProgramWithResponseTimeout
  :: HostedResponseTimeout
  -> HostedProgramArtifact
  -> Text
  -> HostedRuntimeHost
  -> Maybe EngineState
  -> IO (Either HostedRunError EngineState)
runHostedProgramWithResponseTimeout (HostedResponseTimeout responseTimeoutMicros) artifact runId runtimeHost maybeRestore =
  case validateRunId runId of
    Left message -> pure (Left (fault message))
    Right () ->
      case validateInitialState artifact maybeRestore of
        Left message -> pure (Left (fault message))
        Right () -> do
          digestResult <- validateExecutableDigest artifact
          case digestResult of
            Left message -> pure (Left (fault message))
            Right () -> runChild
  where
    fault message = HostedRunError HostedRunFault message Nothing
    manifest = hostedProgramManifest artifact
    nodeCount = fromIntegral (Map.size manifest.hpmNodeExecutors)
    startingState = initialLoopState maybeRestore

    -- 'bracket' masks acquisition, so an async exception between spawn and
    -- supervision can no longer leak the child process.
    runChild =
      bracket
        (try @IOException spawnChild)
        releaseChild
        superviseChild

    spawnChild =
      createProcess
        (proc (hostedProgramExecutable artifact) [])
          { std_in = CreatePipe
          , std_out = CreatePipe
          , std_err = CreatePipe
          , close_fds = True
          }

    releaseChild = \case
      Left (_err :: IOException) -> pure ()
      Right (maybeInput, maybeOutput, maybeError, processHandle) -> do
        terminateWithEscalation processHandle
        mapM_ closeQuietly (catMaybes [maybeInput, maybeOutput, maybeError])

    superviseChild = \case
      Left err ->
        pure
          (Left (fault ("starting hosted circuit engine: " <> exceptionText err)))
      Right (Just childInput, Just childOutput, Just childError, processHandle) ->
        supervise childInput childOutput childError processHandle
      Right _other ->
        pure (Left (fault "hosted circuit engine did not provide dedicated pipes"))

    supervise childInput childOutput childError processHandle = do
      mapM_ configurePipe [childInput, childOutput, childError]
      queue <- newTQueueIO
      workerRegistry <- newTVarIO Map.empty
      diagnosticBuffer <- newTVarIO BS.empty
      result <-
        withAsync (readProtocolEvents childOutput queue) $ \_reader ->
          withAsync (drainDiagnostics childError diagnosticBuffer) $ \_diagnostics ->
            withAsync (watchChildExit processHandle queue) $ \_childWatcher ->
              withMaybeAsync (watchCancellation queue <$> runtimeHost.hostedAwaitCancellation) $ \_cancellationWatcher -> do
                let run = do
                      helloResult <- awaitHello responseTimeoutMicros manifest queue
                      case helloResult of
                        Left message -> pure (Left (fault message))
                        Right () -> do
                          let command = maybe (HostStart runId) (HostRestore runId) maybeRestore
                          startResult <- try @IOException (writeCommand childInput command)
                          case startResult of
                            Left err ->
                              pure
                                (Left (fault ("starting hosted run: " <> exceptionText err)))
                            Right () -> do
                              armedState <- armFreshEngineDeadline responseTimeoutMicros startingState
                              fst
                                <$> eventLoop
                                  responseTimeoutMicros
                                  runId
                                  manifest.hpmProgramIdentity
                                  nodeCount
                                  childInput
                                  queue
                                  workerRegistry
                                  runtimeHost
                                  armedState
                run `finally` cancelRegisteredWorkers workerRegistry
      capturedDiagnostics <- readTVarIO diagnosticBuffer
      pure (attachDiagnostics capturedDiagnostics result)

    watchChildExit processHandle queue =
      waitForProcess processHandle >>= atomically . writeTQueue queue . HostChildExited

runHostedReferenceHost
  :: HostedProgramArtifact
  -> IO (Either HostedRunError EngineState)
runHostedReferenceHost artifact =
  runHostedProgram
    artifact
    "reference-host"
    HostedRuntimeHost
      { hostedCommitCheckpoint = \_state -> pure CheckpointCommitAccepted
      , hostedExecuteEffect = \nodeId ->
          pure (EffectResolved (EffectSucceeded (fromIntegral nodeId + 1)))
      , hostedAwaitCancellation = Nothing
      }
    Nothing

withMaybeAsync :: Maybe (IO ()) -> (Maybe (Async ()) -> IO r) -> IO r
withMaybeAsync = \case
  Nothing -> \use -> use Nothing
  Just action -> \use -> withAsync action (use . Just)

cancelRegisteredWorkers :: TVar (Map Word64 (Async ())) -> IO ()
cancelRegisteredWorkers workerRegistry = readTVarIO workerRegistry >>= mapM_ cancel

validateRunId :: Text -> Either Text ()
validateRunId runId
  | T.null runId = Left "hosted run id must not be empty"
  | BS.length (TE.encodeUtf8 runId) > 128 = Left "hosted run id exceeds 128 UTF-8 bytes"
  | not (T.all validCharacter runId) =
      Left "hosted run id may contain only ASCII letters, digits, '.', '_', '-', and ':'"
  | otherwise = Right ()
  where
    validCharacter character =
      (isAlphaNum character && fromEnum character < 128)
        || character `elem` ("._-:" :: String)

validateInitialState
  :: HostedProgramArtifact
  -> Maybe EngineState
  -> Either Text ()
validateInitialState artifact = \case
  Nothing -> Right ()
  Just state ->
    validateRestorableEngineState
      manifest.hpmProgramIdentity
      (fromIntegral (Map.size manifest.hpmNodeExecutors))
      state
  where
    manifest = hostedProgramManifest artifact

{- | A loaded artifact is an immutable descriptor, not a promise that the file at
its path still contains the verified bytes. Recheck immediately before every
spawn, including resumes.

A hash-then-exec of a path cannot be fully atomic with 'createProcess': a
replacement between this read and the exec is still possible. The residual
window is milliseconds instead of the artifact's whole lifetime; closing it
entirely would require pinning an @O_PATH@ descriptor and @fexecve@, which the
portable process API does not expose.
-}
validateExecutableDigest :: HostedProgramArtifact -> IO (Either Text ())
validateExecutableDigest artifact = do
  bytesResult <- try @IOException (BS.readFile (hostedProgramExecutable artifact))
  pure $ case bytesResult of
    Left err -> Left ("reading hosted executable before spawn: " <> exceptionText err)
    Right bytes
      | sha256Hex bytes == manifest.hpmExecutableSha256 -> Right ()
      | otherwise -> Left "hosted executable digest changed after artifact load"
  where
    manifest = hostedProgramManifest artifact

configurePipe :: Handle -> IO ()
configurePipe handle = do
  hSetBinaryMode handle True
  hSetBuffering handle NoBuffering

writeCommand :: Handle -> HostCommand -> IO ()
writeCommand handle command = BS.hPut handle (encodeHostCommand command) >> hFlush handle

watchCancellation :: TQueue HostInput -> IO (Either Text Text) -> IO ()
watchCancellation queue awaitCancellation = do
  watcherResult <- trySynchronous awaitCancellation
  let input = case watcherResult of
        Left err -> HostRuntimeFailed ("cancellation watcher threw: " <> exceptionText err)
        Right (Left message) -> HostRuntimeFailed message
        Right (Right reason) -> HostCancellationRequested reason
  atomically (writeTQueue queue input)

readProtocolEvents :: Handle -> TQueue HostInput -> IO ()
readProtocolEvents handle queue = go BS.empty
  where
    go buffered = do
      chunkResult <- try @IOException (BS.hGetSome handle 4096)
      case chunkResult of
        Left err -> emitError ("reading hosted protocol: " <> exceptionText err)
        Right chunk
          | BS.null chunk ->
              unless (BS.null buffered) $
                emitError "hosted protocol ended with an unterminated JSON line"
          | otherwise -> consume (buffered <> chunk)

    consume bytes =
      case BS.elemIndex 10 bytes of
        Nothing
          | BS.length bytes > maxProtocolLineBytes ->
              emitError "hosted protocol line exceeds 2 MiB"
          | otherwise -> go bytes
        Just newlineIndex -> do
          let line = BS.take newlineIndex bytes
              rest = BS.drop (newlineIndex + 1) bytes
          if BS.length line > maxProtocolLineBytes
            then emitError "hosted protocol line exceeds 2 MiB"
            else do
              atomically (writeTQueue queue (HostEngineEvent (decodeEngineEvent line)))
              consume rest

    emitError = atomically . writeTQueue queue . HostEngineEvent . Left

drainDiagnostics :: Handle -> TVar BS.ByteString -> IO ()
drainDiagnostics handle captured = go
  where
    go = do
      chunkResult <- try @IOException (BS.hGetSome handle 4096)
      case chunkResult of
        Left _err -> pure ()
        Right chunk
          | BS.null chunk -> pure ()
          | otherwise -> do
              atomically $
                modifyTVar' captured (BS.take maxDiagnosticBytes . (<> chunk))
              go

attachDiagnostics
  :: BS.ByteString
  -> Either HostedRunError EngineState
  -> Either HostedRunError EngineState
attachDiagnostics captured = \case
  Left err
    | not (BS.null captured) ->
        Left
          err
            { hostedRunErrorMessage =
                err.hostedRunErrorMessage
                  <> "; child stderr: "
                  <> T.strip (TE.decodeUtf8With lenientDecode captured)
            }
  result -> result

{- | Read the next input against a single persistent deadline. The deadline
alternative is tried first, so an already-elapsed deadline always wins over a
continuously ready queue — a wedged or flooding engine cannot starve the
timeout by keeping something (even something the caller will simply drop)
available to read.
-}
readInputWithDeadline :: TQueue HostInput -> Maybe (TVar Bool) -> IO (Maybe HostInput)
readInputWithDeadline queue = \case
  Nothing -> Just <$> atomically (readTQueue queue)
  Just deadline ->
    atomically $
      (readTVar deadline >>= check >> pure Nothing)
        `orElse` (Just <$> readTQueue queue)

data LoopWaitResult
  = LoopInput !HostInput
  | EngineDeadlineExpired
  | CancellationDeadlineExpired

{- | Wait for loop input while keeping engine output and cancellation
follow-up as distinct obligations. Deadline alternatives precede the queue so
a continuously-writing child cannot starve an already-expired watchdog.
-}
readLoopInput
  :: TQueue HostInput
  -> Maybe (TVar Bool)
  -> Maybe (TVar Bool)
  -> IO LoopWaitResult
readLoopInput queue engineDeadline cancellationDeadline =
  atomically $
    awaitDeadline cancellationDeadline CancellationDeadlineExpired
      `orElse` awaitDeadline engineDeadline EngineDeadlineExpired
      `orElse` (LoopInput <$> readTQueue queue)
  where
    awaitDeadline maybeDeadline expired =
      case maybeDeadline of
        Nothing -> retry
        Just deadline -> readTVar deadline >>= check >> pure expired

awaitHello
  :: Int
  -> HostedProgramManifest
  -> TQueue HostInput
  -> IO (Either Text ())
awaitHello responseTimeoutMicros manifest queue = do
  deadline <- registerDelay responseTimeoutMicros
  input <- readInputWithDeadline queue (Just deadline)
  pure $ case input of
    Nothing -> Left "hosted engine did not emit hello within the response deadline"
    Just (HostEngineEvent (Right (EngineHello programIdentity reportedAbi)))
      | programIdentity /= manifest.hpmProgramIdentity ->
          Left "hosted engine hello has the wrong program identity"
      | reportedAbi /= engineAbi -> Left "hosted engine hello has the wrong engine ABI"
      | otherwise -> Right ()
    Just (HostEngineEvent (Right _other)) -> Left "hosted engine did not emit hello first"
    Just (HostEngineEvent (Left message)) -> Left message
    Just (HostChildExited exitCode) ->
      Left ("hosted engine exited before hello: " <> T.pack (show exitCode))
    Just HostEffectFinished {} -> Left "host effect completed before engine hello"
    Just (HostCancellationRequested _reason) -> Left "hosted run cancelled before engine hello"
    Just (HostRuntimeFailed message) -> Left ("host runtime failed before engine hello: " <> message)

eventLoop
  :: Int
  -> Text
  -> Text
  -> Word32
  -> Handle
  -> TQueue HostInput
  -> TVar (Map Word64 (Async ()))
  -> HostedRuntimeHost
  -> LoopState
  -> IO (Either HostedRunError EngineState, LoopState)
eventLoop responseTimeoutMicros runId programIdentity nodeCount childInput queue workerRegistry runtimeHost = go
  where
    go state = do
      loopInput <-
        readLoopInput
          queue
          state.loopEngineDeadline
          state.loopCancellationDeadline
      case loopInput of
        CancellationDeadlineExpired ->
          enactTerminalDecision state $
            HostProtocol.transition
              (protocolView state)
              HostProtocol.CancellationDeadlineExpired
        EngineDeadlineExpired ->
          enactTerminalDecision state $
            HostProtocol.transition
              (protocolView state)
              HostProtocol.EngineDeadlineExpired
        LoopInput input -> dispatch state input

    dispatch state = \case
      HostEngineEvent (Left message) -> failWith state message
      HostEngineEvent (Right event) -> handleEvent state event
      HostEffectFinished sequenceNumber nodeId resolution ->
        handleCompletion state sequenceNumber nodeId resolution
      HostCancellationRequested reason -> do
        case HostProtocol.transition (protocolView state) HostProtocol.CancellationRequested of
          HostProtocol.IgnoreInput -> go state
          HostProtocol.SendCancellation engineUpdate cancellationUpdate -> do
            commandResult <- try @IOException (writeCommand childInput (HostCancel runId reason))
            case commandResult of
              Left err -> failWith state ("sending cancellation: " <> exceptionText err)
              Right () -> do
                cancellationUpdated <-
                  applyCancellationDeadlineUpdate
                    responseTimeoutMicros
                    cancellationUpdate
                    state
                armed <-
                  applyEngineDeadlineUpdate
                    responseTimeoutMicros
                    engineUpdate
                    cancellationUpdated
                go armed {loopCancellationSent = True}
          decision -> unexpectedDecision state "cancellation" decision
      HostRuntimeFailed message -> failWith state ("host runtime failed: " <> message)
      HostChildExited exitCode ->
        case HostProtocol.transition
          (protocolView state)
          ( HostProtocol.ChildExited $
              if exitCode == ExitSuccess
                then HostProtocol.ChildExitSuccess
                else HostProtocol.ChildExitAbnormal
          ) of
          HostProtocol.FinishCommittedTerminal -> finish state
          HostProtocol.ProtocolFault message
            | exitCode == ExitSuccess -> failWith state message
            | otherwise -> failWith state (message <> ": " <> T.pack (show exitCode))
          decision -> unexpectedDecision state "child exit" decision

    handleEvent state = \case
      EngineHello {} -> failWith state "hosted engine emitted duplicate hello"
      EngineProtocolError _maybeRunId message ->
        failWith state ("hosted engine rejected protocol: " <> message)
      EngineCheckpoint eventRunId snapshot
        | eventRunId /= runId -> failWith state "checkpoint run correlation mismatch"
        | otherwise -> handleCheckpoint state snapshot
      EngineEffectRequested eventRunId sequenceNumber nodeId
        | eventRunId /= runId -> failWith state "effect request run correlation mismatch"
        | otherwise -> handleRequest state sequenceNumber nodeId
      EngineTerminal eventRunId terminal
        | eventRunId /= runId -> failWith state "terminal run correlation mismatch"
        | otherwise -> handleTerminal state terminal

    handleCheckpoint state snapshot =
      case validateEngineState programIdentity nodeCount snapshot of
        Left message -> failWith state ("invalid engine checkpoint: " <> message)
        Right () ->
          case expectedCheckpoint state snapshot.esCheckpointSequence of
            Left message -> failWith state message
            Right () ->
              case HostProtocol.transition
                (protocolView state)
                (HostProtocol.CheckpointReceived snapshot.esTerminal) of
                HostProtocol.CommitCheckpoint deadlineUpdate -> do
                  checkpointReceived <-
                    applyEngineDeadlineUpdate responseTimeoutMicros deadlineUpdate state
                  commitCheckpoint checkpointReceived snapshot
                decision -> unexpectedDecision state "checkpoint" decision

    commitCheckpoint checkpointReceived snapshot = do
      commitResult <- trySynchronous (runtimeHost.hostedCommitCheckpoint snapshot)
      case commitResult of
        Left err -> failWith checkpointReceived ("checkpoint host threw: " <> exceptionText err)
        Right (CheckpointCommitRejected message) ->
          failWith checkpointReceived ("checkpoint commit failed: " <> message)
        Right (CheckpointCommitAbortRun message) -> abortWith checkpointReceived message
        Right CheckpointCommitAccepted -> do
          writeResult <-
            try @IOException $
              writeCommand
                childInput
                (HostCheckpointCommitted runId snapshot.esCheckpointSequence)
          case writeResult of
            Left err -> failWith checkpointReceived ("acknowledging checkpoint: " <> exceptionText err)
            Right () ->
              dispatchBuffered
                checkpointReceived
                  { loopLastCommitted = Just snapshot
                  , loopLastCheckpointSequence = Just snapshot.esCheckpointSequence
                  , loopAwaitingCheckpoint = False
                  }

    handleRequest state sequenceNumber nodeId
      | nodeId >= nodeCount = failWith state "engine requested an out-of-range node"
      | sequenceNumber /= state.loopNextRequestSequence =
          failWith state "engine effect request sequence is not monotonic"
      | nodeId `Set.member` state.loopActiveNodes
          || nodeId `Set.member` state.loopInterruptedNodes =
          failWith state "engine requested a node already in flight"
      | otherwise =
          case HostProtocol.transition (protocolView state) HostProtocol.SuccessorRequested of
            HostProtocol.ProtocolFault message -> failWith state message
            HostProtocol.SuppressSuccessor ->
              -- The request crossed cancellation or interruption. Track its
              -- sequence, but do not start authority-bearing work.
              go state {loopNextRequestSequence = sequenceNumber + 1}
            HostProtocol.StartSuccessor deadlineUpdate -> do
              startSuccessor state deadlineUpdate sequenceNumber nodeId
            decision -> unexpectedDecision state "successor request" decision

    startSuccessor state deadlineUpdate sequenceNumber nodeId = do
      -- Spawn-and-register is masked so an async exception cannot leave
      -- a live worker outside the registry; the worker body itself runs
      -- unmasked so it stays promptly cancellable.
      worker <- mask_ $ do
        spawned <- asyncWithUnmask $ \unmask -> do
          resolution <-
            trySynchronous (unmask (runtimeHost.hostedExecuteEffect nodeId))
          atomically $
            writeTQueue
              queue
              (HostEffectFinished sequenceNumber nodeId (firstException resolution))
        atomically (modifyTVar' workerRegistry (Map.insert sequenceNumber spawned))
        pure spawned
      let registered =
            state
              { loopNextRequestSequence = sequenceNumber + 1
              , loopWorkers = Map.insert sequenceNumber (nodeId, worker) state.loopWorkers
              , loopActiveNodes = Set.insert nodeId state.loopActiveNodes
              }
      deadlineUpdated <-
        applyEngineDeadlineUpdate responseTimeoutMicros deadlineUpdate registered
      go deadlineUpdated

    handleCompletion state sequenceNumber nodeId resolution =
      case Map.lookup sequenceNumber state.loopWorkers of
        Nothing
          | state.loopCancellationSent -> go state
        Nothing -> failWith state "received an unknown or duplicate effect completion"
        Just (expectedNodeId, _worker)
          | expectedNodeId /= nodeId -> failWith state "effect completion node mismatch"
          | otherwise -> do
              atomically (modifyTVar' workerRegistry (Map.delete sequenceNumber))
              let completedState =
                    state
                      { loopWorkers = Map.delete sequenceNumber state.loopWorkers
                      , loopActiveNodes = Set.delete nodeId state.loopActiveNodes
                      }
              case resolution of
                Right (EffectInterrupted _reason) ->
                  handleInterruptedCompletion completedState nodeId
                Left message ->
                  handleResolvedCompletion
                    completedState
                    sequenceNumber
                    nodeId
                    (Left message)
                Right (EffectResolved completion) ->
                  handleResolvedCompletion
                    completedState
                    sequenceNumber
                    nodeId
                    (Right (EffectResolved completion))

    handleInterruptedCompletion state nodeId =
      case HostProtocol.transition
        (protocolView state)
        ( HostProtocol.InterruptedCompletionArrived $
            isJust runtimeHost.hostedAwaitCancellation
        ) of
        HostProtocol.DropCompletion -> go state
        HostProtocol.ProtocolFault message -> failWith state message
        HostProtocol.AwaitCancellation deadlineUpdate -> do
          -- The run-level cancel that interrupted the worker is in flight;
          -- the engine keeps the node running until cancellation resets it.
          deadlineUpdated <-
            applyCancellationDeadlineUpdate
              responseTimeoutMicros
              deadlineUpdate
              state
                { loopInterruptedNodes =
                    Set.insert nodeId state.loopInterruptedNodes
                }
          go deadlineUpdated
        decision -> unexpectedDecision state "interrupted completion" decision

    handleResolvedCompletion state sequenceNumber nodeId resolution =
      case HostProtocol.transition (protocolView state) HostProtocol.ResolvedCompletionArrived of
        HostProtocol.DropCompletion -> go state
        HostProtocol.BufferCompletion ->
          go
            state
              { loopBufferedCompletions =
                  Map.insert
                    sequenceNumber
                    (nodeId, resolution)
                    state.loopBufferedCompletions
              }
        HostProtocol.ForwardCompletion deadlineUpdate ->
          sendCompletion state deadlineUpdate sequenceNumber nodeId resolution
        decision -> unexpectedDecision state "resolved completion" decision

    sendCompletion state deadlineUpdate sequenceNumber nodeId = \case
      Left message -> failWith state ("effect host threw: " <> message)
      Right (EffectInterrupted _reason) ->
        -- Unreachable: interruptions are intercepted before buffering, and
        -- buffered entries are dropped once a cancel is sent.
        failWith state "interrupted effect reached the completion path"
      Right (EffectResolved completion) -> do
        writeResult <-
          try @IOException $
            writeCommand
              childInput
              (HostEffectCompleted runId sequenceNumber nodeId completion)
        case writeResult of
          Left err -> failWith state ("sending effect completion: " <> exceptionText err)
          Right () -> do
            armed <-
              applyEngineDeadlineUpdate responseTimeoutMicros deadlineUpdate state
            go armed {loopAwaitingCheckpoint = True}

    dispatchBuffered state =
      case state.loopLastCommitted of
        Nothing -> failWith state "checkpoint acknowledgement lost committed authority"
        Just snapshot ->
          case HostProtocol.transition
            (protocolView state)
            (HostProtocol.CheckpointAcknowledged snapshot.esTerminal) of
            HostProtocol.DropBufferedCompletions ->
              -- Cancellation supersedes completions buffered before the
              -- cancelled checkpoint was acknowledged.
              dispatchBuffered state {loopBufferedCompletions = Map.empty}
            HostProtocol.DispatchBufferedCompletion ->
              case Map.minViewWithKey state.loopBufferedCompletions of
                Nothing -> failWith state "protocol selected an absent buffered completion"
                Just ((sequenceNumber, (nodeId, resolution)), remaining) ->
                  sendCompletion
                    state {loopBufferedCompletions = remaining}
                    HostProtocol.ArmFreshDeadline
                    sequenceNumber
                    nodeId
                    resolution
            HostProtocol.AwaitTerminal deadlineUpdate ->
              applyEngineDeadlineUpdate responseTimeoutMicros deadlineUpdate state >>= go
            HostProtocol.AwaitCancellationCheckpoint deadlineUpdate ->
              applyEngineDeadlineUpdate responseTimeoutMicros deadlineUpdate state >>= go
            HostProtocol.AwaitEngineProgress deadlineUpdate ->
              applyEngineDeadlineUpdate responseTimeoutMicros deadlineUpdate state >>= go
            HostProtocol.AwaitWorkers -> go state
            decision -> unexpectedDecision state "checkpoint acknowledgement" decision

    handleTerminal state terminal =
      case HostProtocol.transition
        (protocolView state)
        (HostProtocol.TerminalReceived terminal) of
        HostProtocol.ProtocolFault message -> failWith state message
        HostProtocol.CancelWorkersAndSendShutdown -> do
          cancelledState <- cancelLiveWorkers state
          writeShutdown cancelledState terminal
        HostProtocol.SendShutdown -> writeShutdown state terminal
        decision -> unexpectedDecision state "terminal" decision

    writeShutdown state terminal = do
      writeResult <- try @IOException (writeCommand childInput (HostShutdown runId))
      case writeResult of
        Left err -> failWith state ("sending hosted shutdown: " <> exceptionText err)
        Right () ->
          armFreshEngineDeadline responseTimeoutMicros (state {loopTerminalSeen = Just terminal}) >>= go

    cancelLiveWorkers state = do
      forM_ (Map.elems state.loopWorkers) (cancel . snd)
      let workerKeys = Map.keys state.loopWorkers
      atomically $
        modifyTVar' workerRegistry (\registry -> foldr Map.delete registry workerKeys)
      pure
        state
          { loopWorkers = Map.empty
          , loopActiveNodes = Set.empty
          , loopInterruptedNodes = Set.empty
          , loopBufferedCompletions = Map.empty
          }

    enactTerminalDecision state = \case
      HostProtocol.FinishCommittedTerminal -> finish state
      HostProtocol.ProtocolFault message -> failWith state message
      decision -> unexpectedDecision state "terminal decision" decision

    unexpectedDecision state crossing decision =
      failWith
        state
        ( "host protocol policy returned an invalid "
            <> crossing
            <> " action: "
            <> T.pack (show decision)
        )

    expectedCheckpoint state actual =
      case state.loopLastCheckpointSequence of
        Nothing
          | actual == 1 -> Right ()
          | otherwise -> Left "initial engine checkpoint sequence must be exactly one"
        Just previous
          | actual == previous + 1 -> Right ()
          | otherwise -> Left "engine checkpoint sequence is not monotonic"

    finish state =
      case state.loopLastCommitted of
        Nothing -> failWith state "hosted run has no committed terminal snapshot"
        Just snapshot -> pure (Right snapshot, state)

    failWith state message =
      pure (Left (HostedRunError HostedRunFault message state.loopLastCommitted), state)

    abortWith state message =
      pure (Left (HostedRunError HostedRunAborted message state.loopLastCommitted), state)

{- | Terminate the child, escalating to SIGKILL if it ignores SIGTERM, then reap
it. Polls instead of a fixed sleep so a prompt exit costs milliseconds.
-}
terminateWithEscalation :: ProcessHandle -> IO ()
terminateWithEscalation processHandle = do
  running <- getProcessExitCode processHandle
  case running of
    Just _exitCode -> pure ()
    Nothing -> do
      _terminateResult <- try @IOException (terminateProcess processHandle)
      exited <- pollExit terminationPollAttempts
      unless exited $ do
        maybePid <- getPid processHandle
        forM_ maybePid $ \pid -> do
          _killResult <- try @IOException (signalProcess sigKILL pid)
          pure ()
  _ <- try @IOException (waitForProcess processHandle)
  pure ()
  where
    terminationPollAttempts = 20 :: Int
    terminationPollIntervalMicros = 50000

    pollExit 0 = pure False
    pollExit attempts = do
      exited <- getProcessExitCode processHandle
      case exited of
        Just _exitCode -> pure True
        Nothing -> do
          threadDelay terminationPollIntervalMicros
          pollExit (attempts - 1)

firstException :: Either SomeException value -> Either Text value
firstException = \case
  Left err -> Left (exceptionText err)
  Right value -> Right value

{- | Catch ordinary callback failures without converting ownership-loss or
thread-cancellation signals into hosted run faults. Async exceptions must
reach the lease supervisor that issued them.
-}
trySynchronous :: IO value -> IO (Either SomeException value)
trySynchronous action = do
  result <- try action
  case result of
    Left err
      | isAsyncException err -> throwIO err
    _other -> pure result

isAsyncException :: SomeException -> Bool
isAsyncException err =
  isJust (fromException err :: Maybe SomeAsyncException)
    || isJust (fromException err :: Maybe AsyncCancelled)

exceptionText :: Exception exception => exception -> Text
exceptionText = T.pack . displayException

closeQuietly :: Handle -> IO ()
closeQuietly handle = do
  _ <- try @IOException (hClose handle)
  pure ()
