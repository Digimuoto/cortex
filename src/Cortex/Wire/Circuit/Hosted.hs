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
-}
module Cortex.Wire.Circuit.Hosted
  ( HostedRuntimeHost (..)
  , HostedRunError (..)
  , runHostedProgram
  , runHostedReferenceHost
  , renderHostedRunError
  )
where

import Control.Concurrent.Async (Async, async, cancel, waitCatch)
import Control.Concurrent.STM (TQueue, atomically, newTQueueIO, readTQueue, writeTQueue)
import Control.Exception (Exception, IOException, SomeException, displayException, try)
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
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
import System.Process
  ( CreateProcess (close_fds, std_err, std_in, std_out)
  , ProcessHandle
  , StdStream (CreatePipe)
  , createProcess
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
  , validateEngineState
  , validateRestorableEngineState
  )

maxProtocolLineBytes :: Int
maxProtocolLineBytes = 2 * 1024 * 1024

maxDiagnosticBytes :: Int
maxDiagnosticBytes = 64 * 1024

data HostedRuntimeHost = HostedRuntimeHost
  { hostedCommitCheckpoint :: EngineState -> IO (Either Text ())
  , hostedExecuteEffect :: Word32 -> IO EffectCompletion
  , hostedAwaitCancellation :: !(Maybe (IO Text))
  }

data HostedRunError = HostedRunError
  { hostedRunErrorMessage :: !Text
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
  | HostEffectFinished !Word64 !Word32 !(Either Text EffectCompletion)
  | HostCancellationRequested !Text
  | HostChildExited !ExitCode

data LoopState = LoopState
  { loopLastCommitted :: !(Maybe EngineState)
  , loopLastCheckpointSequence :: !(Maybe Word64)
  , loopNextRequestSequence :: !Word64
  , loopAwaitingCheckpoint :: !Bool
  , loopWorkers :: !(Map Word64 (Word32, Async ()))
  , loopActiveNodes :: !(Set Word32)
  , loopBufferedCompletions :: !(Map Word64 (Word32, Either Text EffectCompletion))
  , loopTerminalSeen :: !(Maybe EngineTerminalState)
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
    , loopBufferedCompletions = Map.empty
    , loopTerminalSeen = Nothing
    }

runHostedProgram
  :: HostedProgramArtifact
  -> Text
  -> HostedRuntimeHost
  -> Maybe EngineState
  -> IO (Either HostedRunError EngineState)
runHostedProgram artifact runId runtimeHost maybeRestore =
  case validateRunId runId of
    Left message -> pure (Left (HostedRunError message Nothing))
    Right () ->
      case validateInitialState artifact maybeRestore of
        Left message -> pure (Left (HostedRunError message Nothing))
        Right () -> runChild
  where
    manifest = hostedProgramManifest artifact
    nodeCount = fromIntegral (Map.size manifest.hpmNodeExecutors)
    startingState = initialLoopState maybeRestore

    runChild = do
      processResult <-
        try @IOException $
          createProcess
            (proc (hostedProgramExecutable artifact) [])
              { std_in = CreatePipe
              , std_out = CreatePipe
              , std_err = CreatePipe
              , close_fds = True
              }
      case processResult of
        Left err ->
          pure
            ( Left
                (HostedRunError ("starting hosted circuit engine: " <> exceptionText err) Nothing)
            )
        Right (Just childInput, Just childOutput, Just childError, processHandle) ->
          supervise childInput childOutput childError processHandle
        Right _other ->
          pure (Left (HostedRunError "hosted circuit engine did not provide dedicated pipes" Nothing))

    supervise childInput childOutput childError processHandle = do
      mapM_ configurePipe [childInput, childOutput, childError]
      queue <- newTQueueIO
      reader <- async (readProtocolEvents childOutput queue)
      diagnostics <- async (drainDiagnostics childError)
      childWatcher <-
        async
          (waitForProcess processHandle >>= atomically . writeTQueue queue . HostChildExited)
      cancellationWatcher <-
        traverse (async . watchCancellation queue) runtimeHost.hostedAwaitCancellation
      helloResult <- awaitHello manifest queue
      (runResult, finalState) <- case helloResult of
        Left message -> pure (Left (HostedRunError message Nothing), startingState)
        Right () -> do
          let command = maybe (HostStart runId) (HostRestore runId) maybeRestore
          startResult <- try @IOException (writeCommand childInput command)
          case startResult of
            Left err ->
              pure
                ( Left (HostedRunError ("starting hosted run: " <> exceptionText err) Nothing)
                , startingState
                )
            Right () ->
              eventLoop
                runId
                manifest.hpmProgramIdentity
                nodeCount
                childInput
                queue
                runtimeHost
                startingState
      cleanupProcess
        childInput
        childOutput
        childError
        processHandle
        reader
        diagnostics
        childWatcher
        cancellationWatcher
        finalState
      pure runResult

runHostedReferenceHost
  :: HostedProgramArtifact
  -> IO (Either HostedRunError EngineState)
runHostedReferenceHost artifact =
  runHostedProgram
    artifact
    "reference-host"
    HostedRuntimeHost
      { hostedCommitCheckpoint = \_state -> pure (Right ())
      , hostedExecuteEffect = \nodeId -> pure (EffectSucceeded (fromIntegral nodeId + 1))
      , hostedAwaitCancellation = Nothing
      }
    Nothing

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

configurePipe :: Handle -> IO ()
configurePipe handle = do
  hSetBinaryMode handle True
  hSetBuffering handle NoBuffering

writeCommand :: Handle -> HostCommand -> IO ()
writeCommand handle command = BS.hPut handle (encodeHostCommand command) >> hFlush handle

watchCancellation :: TQueue HostInput -> IO Text -> IO ()
watchCancellation queue awaitCancellation =
  awaitCancellation >>= atomically . writeTQueue queue . HostCancellationRequested

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

drainDiagnostics :: Handle -> IO BS.ByteString
drainDiagnostics handle = go BS.empty
  where
    go captured = do
      chunkResult <- try @IOException (BS.hGetSome handle 4096)
      case chunkResult of
        Left _err -> pure captured
        Right chunk
          | BS.null chunk -> pure captured
          | otherwise -> go (BS.take maxDiagnosticBytes (captured <> chunk))

awaitHello
  :: HostedProgramManifest
  -> TQueue HostInput
  -> IO (Either Text ())
awaitHello manifest queue = do
  input <- atomically (readTQueue queue)
  pure $ case input of
    HostEngineEvent (Right (EngineHello programIdentity reportedAbi))
      | programIdentity /= manifest.hpmProgramIdentity ->
          Left "hosted engine hello has the wrong program identity"
      | reportedAbi /= engineAbi -> Left "hosted engine hello has the wrong engine ABI"
      | otherwise -> Right ()
    HostEngineEvent (Right _other) -> Left "hosted engine did not emit hello first"
    HostEngineEvent (Left message) -> Left message
    HostChildExited exitCode ->
      Left ("hosted engine exited before hello: " <> T.pack (show exitCode))
    HostEffectFinished {} -> Left "host effect completed before engine hello"
    HostCancellationRequested _reason -> Left "hosted run cancelled before engine hello"

eventLoop
  :: Text
  -> Text
  -> Word32
  -> Handle
  -> TQueue HostInput
  -> HostedRuntimeHost
  -> LoopState
  -> IO (Either HostedRunError EngineState, LoopState)
eventLoop runId programIdentity nodeCount childInput queue runtimeHost = go
  where
    go state = do
      input <- atomically (readTQueue queue)
      case input of
        HostEngineEvent (Left message) -> failWith state message
        HostEngineEvent (Right event) -> handleEvent state event
        HostEffectFinished sequenceNumber nodeId completion ->
          handleCompletion state sequenceNumber nodeId completion
        HostCancellationRequested reason -> do
          commandResult <- try @IOException (writeCommand childInput (HostCancel runId reason))
          case commandResult of
            Left err -> failWith state ("sending cancellation: " <> exceptionText err)
            Right () -> go state
        HostChildExited ExitSuccess ->
          case state.loopTerminalSeen of
            Just _terminal -> finish state
            Nothing -> failWith state "hosted engine exited before a terminal event"
        HostChildExited exitCode ->
          failWith state ("hosted engine exited unexpectedly: " <> T.pack (show exitCode))

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
            Right () -> do
              commitResult <- try @SomeException (runtimeHost.hostedCommitCheckpoint snapshot)
              case commitResult of
                Left err -> failWith state ("checkpoint host threw: " <> exceptionText err)
                Right (Left message) -> failWith state ("checkpoint commit failed: " <> message)
                Right (Right ()) -> do
                  writeResult <-
                    try @IOException $
                      writeCommand
                        childInput
                        (HostCheckpointCommitted runId snapshot.esCheckpointSequence)
                  case writeResult of
                    Left err -> failWith state ("acknowledging checkpoint: " <> exceptionText err)
                    Right () ->
                      dispatchBuffered
                        state
                          { loopLastCommitted = Just snapshot
                          , loopLastCheckpointSequence = Just snapshot.esCheckpointSequence
                          , loopAwaitingCheckpoint = False
                          }

    handleRequest state sequenceNumber nodeId
      | nodeId >= nodeCount = failWith state "engine requested an out-of-range node"
      | sequenceNumber /= state.loopNextRequestSequence =
          failWith state "engine effect request sequence is not monotonic"
      | nodeId `Set.member` state.loopActiveNodes =
          failWith state "engine requested a node already in flight"
      | isJust state.loopTerminalSeen =
          failWith state "engine requested an effect after terminal"
      | otherwise = do
          worker <-
            async $ do
              completion <- try @SomeException (runtimeHost.hostedExecuteEffect nodeId)
              atomically $
                writeTQueue
                  queue
                  (HostEffectFinished sequenceNumber nodeId (firstException completion))
          go
            state
              { loopNextRequestSequence = sequenceNumber + 1
              , loopWorkers = Map.insert sequenceNumber (nodeId, worker) state.loopWorkers
              , loopActiveNodes = Set.insert nodeId state.loopActiveNodes
              }

    handleCompletion state sequenceNumber nodeId completion =
      case Map.lookup sequenceNumber state.loopWorkers of
        Nothing -> failWith state "received an unknown or duplicate effect completion"
        Just (expectedNodeId, _worker)
          | expectedNodeId /= nodeId -> failWith state "effect completion node mismatch"
          | otherwise ->
              let completedState =
                    state
                      { loopWorkers = Map.delete sequenceNumber state.loopWorkers
                      , loopActiveNodes = Set.delete nodeId state.loopActiveNodes
                      }
               in if completedState.loopAwaitingCheckpoint
                    then
                      go
                        completedState
                          { loopBufferedCompletions =
                              Map.insert sequenceNumber (nodeId, completion) completedState.loopBufferedCompletions
                          }
                    else sendCompletion completedState sequenceNumber nodeId completion

    sendCompletion state sequenceNumber nodeId = \case
      Left message -> failWith state ("effect host threw: " <> message)
      Right completion -> do
        writeResult <-
          try @IOException $
            writeCommand
              childInput
              (HostEffectCompleted runId sequenceNumber nodeId completion)
        case writeResult of
          Left err -> failWith state ("sending effect completion: " <> exceptionText err)
          Right () -> go state {loopAwaitingCheckpoint = True}

    dispatchBuffered state =
      case Map.minViewWithKey state.loopBufferedCompletions of
        Nothing -> go state
        Just ((sequenceNumber, (nodeId, completion)), remaining) ->
          sendCompletion
            state {loopBufferedCompletions = remaining}
            sequenceNumber
            nodeId
            completion

    handleTerminal state terminal =
      case state.loopLastCommitted of
        Nothing -> failWith state "engine emitted terminal before a committed checkpoint"
        Just snapshot
          | snapshot.esTerminal /= terminal ->
              failWith state "terminal event disagrees with the committed checkpoint"
          | state.loopAwaitingCheckpoint ->
              failWith state "engine emitted terminal before checkpoint acknowledgement"
          | not (Map.null state.loopWorkers) ->
              failWith state "engine emitted terminal with effects still running"
          | not (Map.null state.loopBufferedCompletions) ->
              failWith state "engine emitted terminal with buffered completions"
          | otherwise -> do
              writeResult <- try @IOException (writeCommand childInput (HostShutdown runId))
              case writeResult of
                Left err -> failWith state ("sending hosted shutdown: " <> exceptionText err)
                Right () -> go state {loopTerminalSeen = Just terminal}

    expectedCheckpoint state actual =
      case state.loopLastCheckpointSequence of
        Nothing
          | actual == 0 -> Left "initial engine checkpoint sequence must be positive"
          | otherwise -> Right ()
        Just previous
          | actual == previous + 1 -> Right ()
          | otherwise -> Left "engine checkpoint sequence is not monotonic"

    finish state =
      case state.loopLastCommitted of
        Nothing -> failWith state "hosted run has no committed terminal snapshot"
        Just snapshot -> pure (Right snapshot, state)

    failWith state message =
      pure (Left (HostedRunError message state.loopLastCommitted), state)

cleanupProcess
  :: Handle
  -> Handle
  -> Handle
  -> ProcessHandle
  -> Async ()
  -> Async BS.ByteString
  -> Async ()
  -> Maybe (Async ())
  -> LoopState
  -> IO ()
cleanupProcess childInput childOutput childError processHandle reader diagnostics childWatcher cancellationWatcher state = do
  forM_ state.loopWorkers (cancel . snd)
  forM_ cancellationWatcher cancel
  cancel reader
  running <- getProcessExitCode processHandle
  case running of
    Nothing -> terminateProcess processHandle
    Just _exitCode -> pure ()
  _ <- waitCatch childWatcher
  _ <- waitCatch diagnostics
  mapM_ closeQuietly [childInput, childOutput, childError]

firstException :: Either SomeException value -> Either Text value
firstException = \case
  Left err -> Left (exceptionText err)
  Right value -> Right value

exceptionText :: Exception exception => exception -> Text
exceptionText = T.pack . displayException

closeQuietly :: Handle -> IO ()
closeQuietly handle = do
  _ <- try @IOException (hClose handle)
  pure ()
