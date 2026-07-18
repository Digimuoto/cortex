{- |
Module      : Main
Description : Criterion benchmarks for the hosted Circuit JSONL protocol.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

These opt-in benchmarks record process-protocol codec and framing overhead.
They intentionally carry no timing threshold; transport changes require an
end-to-end workload or a future streaming-dataflow requirement.
-}
module Main (main) where

import Criterion.Main (bench, bgroup, defaultMain, nf)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)

import Cortex.Wire
  ( EffectCompletion (..)
  , EngineEvent (..)
  , EngineNodeStatus (..)
  , EngineState (..)
  , EngineTerminalState (..)
  , HostCommand (..)
  , decodeEngineEvent
  , encodeEngineEvent
  , encodeHostCommand
  , engineAbi
  , engineStateSchema
  )

main :: IO ()
main =
  defaultMain
    [ bgroup
        "host-command-encode"
        [ bench "start" (nf encodedLength startCommand)
        , bench "restore-32" (nf encodedLength restoreCommand)
        , bench "effect-completed" (nf encodedLength completionCommand)
        ]
    , bgroup
        "engine-event-jsonl-roundtrip"
        [ bench "hello" (nf roundTripEvent helloLine)
        , bench "checkpoint-32" (nf roundTripEvent checkpointLine)
        , bench "effect-requested" (nf roundTripEvent effectLine)
        , bench "terminal" (nf roundTripEvent terminalLine)
        , bench "checkpoint-32-batch-128" (nf roundTripBatch checkpointBatch)
        ]
    ]

runId :: Text
runId = "protocol-benchmark"

programIdentity :: Text
programIdentity = "sha256:protocol-benchmark"

startCommand :: HostCommand
startCommand = HostStart runId

restoreCommand :: HostCommand
restoreCommand = HostRestore runId checkpointState

completionCommand :: HostCommand
completionCommand = HostEffectCompleted runId 17 16 (EffectSucceeded 17)

checkpointState :: EngineState
checkpointState =
  EngineState
    { esSchema = engineStateSchema
    , esProgramIdentity = programIdentity
    , esCheckpointSequence = 17
    , esTerminal = EngineActive
    , esNodeStatuses = replicate 16 EngineCompleted <> replicate 16 EnginePending
    , esOutputHandles = [1 .. 16] <> replicate 16 0
    }

helloLine :: ByteString
helloLine = encodeEngineEvent (EngineHello programIdentity engineAbi)

checkpointLine :: ByteString
checkpointLine = encodeEngineEvent (EngineCheckpoint runId checkpointState)

effectLine :: ByteString
effectLine = encodeEngineEvent (EngineEffectRequested runId 17 16)

terminalLine :: ByteString
terminalLine = encodeEngineEvent (EngineTerminal runId EngineSucceeded)

checkpointBatch :: ByteString
checkpointBatch = BS.concat (replicate 128 checkpointLine)

encodedLength :: HostCommand -> Int
encodedLength = BS.length . encodeHostCommand

roundTripEvent :: ByteString -> Int
roundTripEvent bytes =
  case decodeEngineEvent (dropNewline bytes) of
    Left message -> error (show message)
    Right event -> BS.length (encodeEngineEvent event)

roundTripBatch :: ByteString -> Int
roundTripBatch =
  sum
    . fmap roundTripEvent
    . filter (not . BS.null)
    . BS.split 10

dropNewline :: ByteString -> ByteString
dropNewline bytes =
  case BS.unsnoc bytes of
    Just (body, 10) -> body
    _other -> bytes
