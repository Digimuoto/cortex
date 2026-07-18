{- |
Module      : Cortex.Wire.Circuit.Engine
Description : Hosted circuit-engine artifact, state, and process protocol.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The generated circuit engine owns fixed-topology transition decisions but
carries no runtime authority. Actual values, credentials, durable storage, and
effect implementations remain host-owned.
-}
module Cortex.Wire.Circuit.Engine
  ( engineStateSchema
  , engineAbi
  , hostedProcessProtocol
  , hostedLinuxTarget
  , hostedProgramManifestSchema
  , HostedProgramArtifact
  , HostedProgramManifest (..)
  , HostedProgramError (..)
  , CircuitExecutionBackend (..)
  , circuitExecutionBackendTag
  , hostedBackendTag
  , CircuitRunOptions (..)
  , defaultCircuitRunOptions
  , loadHostedProgramArtifact
  , hostedProgramExecutable
  , hostedProgramManifest
  , renderHostedProgramError
  , sha256Hex
  , EngineNodeStatus (..)
  , EngineTerminalState (..)
  , renderEngineTerminalState
  , parseEngineTerminalState
  , EngineState (..)
  , validateEngineState
  , validateRestorableEngineState
  , EffectCompletion (..)
  , HostCommand (..)
  , EngineEvent (..)
  , encodeHostCommand
  , encodeEngineEvent
  , decodeHostCommand
  , decodeEngineEvent
  )
where

import Control.Exception (IOException, try)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32, Word64)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

engineStateSchema :: Text
engineStateSchema = "cortex.wire.engine-state/v1"

engineAbi :: Text
engineAbi = "cortex.wire.engine/v1"

hostedProcessProtocol :: Text
hostedProcessProtocol = "cortex.wire.host-process/v1"

hostedLinuxTarget :: Text
hostedLinuxTarget = "cortex.wire.target/x86_64-linux-v1"

hostedProgramManifestSchema :: Text
hostedProgramManifestSchema = "cortex.wire.hosted-program-manifest/v1"

data HostedProgramManifest = HostedProgramManifest
  { hpmSchema :: !Text
  , hpmTarget :: !Text
  , hpmTargetTriple :: !Text
  , hpmProtocol :: !Text
  , hpmEngineStateSchema :: !Text
  , hpmEngineAbi :: !Text
  , hpmProgramIdentity :: !Text
  , hpmExecutable :: !FilePath
  , hpmExecutableSha256 :: !Text
  , hpmStaticProgramSha256 :: !Text
  , hpmNodeExecutors :: !(Map Word32 Text)
  , hpmGeneratedDigests :: !(Map Text Text)
  , hpmToolchainProvenance :: !(Map Text Text)
  }
  deriving stock (Eq, Show)

instance ToJSON HostedProgramManifest where
  toJSON manifest =
    Aeson.object
      [ "schema" .= manifest.hpmSchema
      , "target" .= manifest.hpmTarget
      , "target_triple" .= manifest.hpmTargetTriple
      , "protocol" .= manifest.hpmProtocol
      , "engine_state_schema" .= manifest.hpmEngineStateSchema
      , "engine_abi" .= manifest.hpmEngineAbi
      , "program_identity" .= manifest.hpmProgramIdentity
      , "executable" .= manifest.hpmExecutable
      , "executable_sha256" .= manifest.hpmExecutableSha256
      , "static_program_sha256" .= manifest.hpmStaticProgramSha256
      , "node_executors" .= manifest.hpmNodeExecutors
      , "generated_digests" .= manifest.hpmGeneratedDigests
      , "toolchain_provenance" .= manifest.hpmToolchainProvenance
      ]

instance FromJSON HostedProgramManifest where
  parseJSON = Aeson.withObject "HostedProgramManifest" $ \objectValue ->
    HostedProgramManifest
      <$> objectValue .: "schema"
      <*> objectValue .: "target"
      <*> objectValue .: "target_triple"
      <*> objectValue .: "protocol"
      <*> objectValue .: "engine_state_schema"
      <*> objectValue .: "engine_abi"
      <*> objectValue .: "program_identity"
      <*> objectValue .: "executable"
      <*> objectValue .: "executable_sha256"
      <*> objectValue .: "static_program_sha256"
      <*> objectValue .: "node_executors"
      <*> objectValue .: "generated_digests"
      <*> objectValue .: "toolchain_provenance"

data HostedProgramArtifact = HostedProgramArtifact
  { hostedProgramExecutable :: !FilePath
  , hostedProgramManifest :: !HostedProgramManifest
  }
  deriving stock (Eq, Show)

-- | Whole-run execution backend selected for one compiled Circuit run.
data CircuitExecutionBackend
  = PulseGraphRuntimeV1
  | HostedX86_64LinuxV1 !HostedProgramArtifact
  deriving stock (Eq, Show)

-- | Stable database/manifest tag for the hosted Linux backend.
hostedBackendTag :: Text
hostedBackendTag = "hosted_x86_64_linux_v1"

-- | Stable database/manifest tag for the selected whole-run backend.
circuitExecutionBackendTag :: CircuitExecutionBackend -> Text
circuitExecutionBackendTag = \case
  PulseGraphRuntimeV1 -> "pulse_graph_runtime_v1"
  HostedX86_64LinuxV1 _artifact -> hostedBackendTag

-- | Per-run execution options. The graph-native Pulse runtime remains the default.
newtype CircuitRunOptions = CircuitRunOptions
  { croExecutionBackend :: CircuitExecutionBackend
  }
  deriving stock (Eq, Show)

defaultCircuitRunOptions :: CircuitRunOptions
defaultCircuitRunOptions = CircuitRunOptions {croExecutionBackend = PulseGraphRuntimeV1}

data HostedProgramError
  = HostedManifestMissing !FilePath
  | HostedManifestReadFailed !FilePath !Text
  | HostedManifestDecodeFailed !FilePath !Text
  | HostedManifestSchemaMismatch !Text
  | HostedTargetMismatch !Text
  | HostedTargetTripleMismatch !Text
  | HostedProtocolMismatch !Text
  | HostedStateSchemaMismatch !Text
  | HostedEngineAbiMismatch !Text
  | HostedNodeMapInvalid !Text
  | HostedExecutableMissing !FilePath
  | HostedExecutablePathInvalid !FilePath
  | HostedExecutableReadFailed !FilePath !Text
  | HostedExecutableDigestMismatch !Text !Text
  deriving stock (Eq, Show)

loadHostedProgramArtifact :: FilePath -> IO (Either HostedProgramError HostedProgramArtifact)
loadHostedProgramArtifact directory = do
  let manifestPath = directory </> "hosted.manifest.json"
  manifestExists <- doesFileExist manifestPath
  if not manifestExists
    then pure (Left (HostedManifestMissing manifestPath))
    else do
      manifestBytesResult <- readBytes HostedManifestReadFailed manifestPath
      case manifestBytesResult of
        Left err -> pure (Left err)
        Right manifestBytes ->
          case Aeson.eitherDecodeStrict' manifestBytes of
            Left err -> pure (Left (HostedManifestDecodeFailed manifestPath (T.pack err)))
            Right manifest -> validateManifest directory manifest

validateManifest
  :: FilePath
  -> HostedProgramManifest
  -> IO (Either HostedProgramError HostedProgramArtifact)
validateManifest directory manifest =
  case validateManifestSchemas manifest of
    Left err -> pure (Left err)
    Right () -> do
      let executablePath = directory </> manifest.hpmExecutable
      executableExists <- doesFileExist executablePath
      if not executableExists
        then pure (Left (HostedExecutableMissing executablePath))
        else do
          executableBytesResult <- readBytes HostedExecutableReadFailed executablePath
          pure $ do
            executableBytes <- executableBytesResult
            let actualDigest = sha256Hex executableBytes
            if actualDigest == manifest.hpmExecutableSha256
              then Right (HostedProgramArtifact executablePath manifest)
              else
                Left
                  ( HostedExecutableDigestMismatch
                      manifest.hpmExecutableSha256
                      actualDigest
                  )

validateManifestSchemas :: HostedProgramManifest -> Either HostedProgramError ()
validateManifestSchemas manifest
  | manifest.hpmSchema /= hostedProgramManifestSchema =
      Left (HostedManifestSchemaMismatch manifest.hpmSchema)
  | manifest.hpmTarget /= hostedLinuxTarget =
      Left (HostedTargetMismatch manifest.hpmTarget)
  | manifest.hpmTargetTriple /= "x86_64-unknown-linux-gnu" =
      Left (HostedTargetTripleMismatch manifest.hpmTargetTriple)
  | manifest.hpmProtocol /= hostedProcessProtocol =
      Left (HostedProtocolMismatch manifest.hpmProtocol)
  | manifest.hpmEngineStateSchema /= engineStateSchema =
      Left (HostedStateSchemaMismatch manifest.hpmEngineStateSchema)
  | manifest.hpmEngineAbi /= engineAbi =
      Left (HostedEngineAbiMismatch manifest.hpmEngineAbi)
  | manifest.hpmExecutable /= "circuit-engine" =
      Left (HostedExecutablePathInvalid manifest.hpmExecutable)
  | Map.keys manifest.hpmNodeExecutors
      /= take (Map.size manifest.hpmNodeExecutors) [0 ..] =
      Left (HostedNodeMapInvalid "node executor identifiers must be dense from zero")
  | Map.size manifest.hpmNodeExecutors > 32768 =
      Left (HostedNodeMapInvalid "node executor map exceeds the hosted runner bound")
  | otherwise = Right ()

readBytes
  :: (FilePath -> Text -> HostedProgramError)
  -> FilePath
  -> IO (Either HostedProgramError BS.ByteString)
readBytes wrap path = do
  result <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
  pure $ case result of
    Left err -> Left (wrap path (T.pack (show err)))
    Right bytes -> Right bytes

sha256Hex :: BS.ByteString -> Text
sha256Hex bytes = T.pack (show (hash bytes :: Digest SHA256))

renderHostedProgramError :: HostedProgramError -> Text
renderHostedProgramError = \case
  HostedManifestMissing path -> "hosted manifest does not exist: " <> T.pack path
  HostedManifestReadFailed path message -> "reading hosted manifest " <> T.pack path <> ": " <> message
  HostedManifestDecodeFailed path message -> "decoding hosted manifest " <> T.pack path <> ": " <> message
  HostedManifestSchemaMismatch schema -> "unsupported hosted manifest schema: " <> schema
  HostedTargetMismatch target -> "unsupported hosted target: " <> target
  HostedTargetTripleMismatch target ->
    "unsupported hosted target triple: " <> target
  HostedProtocolMismatch protocol -> "unsupported hosted process protocol: " <> protocol
  HostedStateSchemaMismatch schema -> "unsupported engine-state schema: " <> schema
  HostedEngineAbiMismatch abi -> "unsupported generated engine ABI: " <> abi
  HostedNodeMapInvalid message -> "invalid hosted node map: " <> message
  HostedExecutableMissing path -> "hosted executable does not exist: " <> T.pack path
  HostedExecutablePathInvalid path ->
    "hosted executable path must be exactly circuit-engine, got: " <> T.pack path
  HostedExecutableReadFailed path message -> "reading hosted executable " <> T.pack path <> ": " <> message
  HostedExecutableDigestMismatch expected actual ->
    "hosted executable digest mismatch; expected " <> expected <> ", got " <> actual

data EngineNodeStatus
  = EnginePending
  | EngineRunning
  | EngineCompleted
  | EngineFailed
  | EngineSkipped
  deriving stock (Eq, Ord, Show)

instance ToJSON EngineNodeStatus where
  toJSON = Aeson.String . renderEngineNodeStatus

instance FromJSON EngineNodeStatus where
  parseJSON = Aeson.withText "EngineNodeStatus" $ \value ->
    case parseEngineNodeStatus value of
      Nothing -> fail ("invalid engine node status: " <> T.unpack value)
      Just status -> pure status

renderEngineNodeStatus :: EngineNodeStatus -> Text
renderEngineNodeStatus = \case
  EnginePending -> "pending"
  EngineRunning -> "running"
  EngineCompleted -> "completed"
  EngineFailed -> "failed"
  EngineSkipped -> "skipped"

parseEngineNodeStatus :: Text -> Maybe EngineNodeStatus
parseEngineNodeStatus = \case
  "pending" -> Just EnginePending
  "running" -> Just EngineRunning
  "completed" -> Just EngineCompleted
  "failed" -> Just EngineFailed
  "skipped" -> Just EngineSkipped
  _other -> Nothing

data EngineTerminalState
  = EngineActive
  | EngineSucceeded
  | EngineTerminalFailed
  | EngineCancelled
  deriving stock (Eq, Show)

instance ToJSON EngineTerminalState where
  toJSON = Aeson.String . renderEngineTerminalState

instance FromJSON EngineTerminalState where
  parseJSON = Aeson.withText "EngineTerminalState" $ \value ->
    case parseEngineTerminalState value of
      Left message -> fail (T.unpack message)
      Right terminal -> pure terminal

renderEngineTerminalState :: EngineTerminalState -> Text
renderEngineTerminalState = \case
  EngineActive -> "active"
  EngineSucceeded -> "completed"
  EngineTerminalFailed -> "failed"
  EngineCancelled -> "cancelled"

parseEngineTerminalState :: Text -> Either Text EngineTerminalState
parseEngineTerminalState = \case
  "active" -> Right EngineActive
  "completed" -> Right EngineSucceeded
  "failed" -> Right EngineTerminalFailed
  "cancelled" -> Right EngineCancelled
  other -> Left ("invalid engine terminal state: " <> other)

data EngineState = EngineState
  { esSchema :: !Text
  , esProgramIdentity :: !Text
  , esCheckpointSequence :: !Word64
  , esTerminal :: !EngineTerminalState
  , esNodeStatuses :: ![EngineNodeStatus]
  , esOutputHandles :: ![Word64]
  }
  deriving stock (Eq, Show)

instance ToJSON EngineState where
  toJSON state =
    Aeson.object
      [ "schema" .= state.esSchema
      , "program_identity" .= state.esProgramIdentity
      , "checkpoint_sequence" .= state.esCheckpointSequence
      , "terminal" .= state.esTerminal
      , "node_statuses" .= state.esNodeStatuses
      , "output_handles" .= state.esOutputHandles
      ]

instance FromJSON EngineState where
  parseJSON = Aeson.withObject "EngineState" $ \objectValue ->
    EngineState
      <$> objectValue .: "schema"
      <*> objectValue .: "program_identity"
      <*> objectValue .: "checkpoint_sequence"
      <*> objectValue .: "terminal"
      <*> objectValue .: "node_statuses"
      <*> objectValue .: "output_handles"

validateEngineState :: Text -> Word32 -> EngineState -> Either Text ()
validateEngineState expectedIdentity expectedNodeCount state
  | state.esSchema /= engineStateSchema = Left "engine-state schema mismatch"
  | state.esProgramIdentity /= expectedIdentity = Left "engine-state program identity mismatch"
  | state.esCheckpointSequence == 0 = Left "engine-state checkpoint sequence must be positive"
  | length state.esNodeStatuses /= fromIntegral expectedNodeCount =
      Left "engine-state status count mismatch"
  | length state.esOutputHandles /= fromIntegral expectedNodeCount =
      Left "engine-state output count mismatch"
  | otherwise = do
      validateOutputs 0 state.esNodeStatuses state.esOutputHandles
      validateTerminal state.esTerminal state.esNodeStatuses
  where
    validateOutputs
      :: Int
      -> [EngineNodeStatus]
      -> [Word64]
      -> Either Text ()
    validateOutputs _index [] [] = Right ()
    validateOutputs index (status : statuses) (output : outputs) =
      case (status, output) of
        (EngineCompleted, 0) ->
          Left ("completed node has zero output handle at index " <> T.pack (show index))
        (EngineCompleted, _nonzero) -> validateOutputs (index + 1) statuses outputs
        (EnginePending, 0) -> validateOutputs (index + 1) statuses outputs
        (EngineRunning, 0) -> validateOutputs (index + 1) statuses outputs
        (EngineFailed, 0) -> validateOutputs (index + 1) statuses outputs
        (EngineSkipped, 0) -> validateOutputs (index + 1) statuses outputs
        (EnginePending, _nonzero) -> invalidNonCompleted index
        (EngineRunning, _nonzero) -> invalidNonCompleted index
        (EngineFailed, _nonzero) -> invalidNonCompleted index
        (EngineSkipped, _nonzero) -> invalidNonCompleted index
    validateOutputs _index _statuses _outputs =
      Left "engine-state arrays have different lengths"
    invalidNonCompleted :: Int -> Either Text ()
    invalidNonCompleted index =
      Left ("non-completed node has an output handle at index " <> T.pack (show index))

    validateTerminal :: EngineTerminalState -> [EngineNodeStatus] -> Either Text ()
    validateTerminal = \case
      EngineActive -> \_statuses -> Right ()
      EngineSucceeded -> \statuses ->
        if all (\status -> status == EngineCompleted || status == EngineSkipped) statuses
          then Right ()
          else Left "completed terminal state contains an unsettled or failed node"
      EngineTerminalFailed -> \statuses ->
        if EngineFailed `elem` statuses
          then Right ()
          else Left "failed terminal state contains no failed node"
      EngineCancelled -> \statuses ->
        if EngineRunning `elem` statuses
          then Left "cancelled terminal state contains a running node"
          else Right ()

{- | Validate a durable snapshot before importing it into a fresh engine.

A live engine may transiently contain running nodes, but durable recovery
snapshots normalize them to pending so no abandoned host work is retained.
-}
validateRestorableEngineState :: Text -> Word32 -> EngineState -> Either Text ()
validateRestorableEngineState expectedIdentity expectedNodeCount state = do
  validateEngineState expectedIdentity expectedNodeCount state
  rejectRunning 0 state.esNodeStatuses
  where
    rejectRunning :: Int -> [EngineNodeStatus] -> Either Text ()
    rejectRunning _index [] = Right ()
    rejectRunning index (EngineRunning : _statuses) =
      Left ("restored engine state contains running node at index " <> T.pack (show index))
    rejectRunning index (_status : statuses) = rejectRunning (index + 1) statuses

data EffectCompletion
  = EffectSucceeded !Word64
  | EffectSkipped
  | EffectFailed !Text
  deriving stock (Eq, Show)

data HostCommand
  = HostStart !Text
  | HostRestore !Text !EngineState
  | HostEffectCompleted !Text !Word64 !Word32 !EffectCompletion
  | HostCheckpointCommitted !Text !Word64
  | HostCancel !Text !Text
  | HostShutdown !Text
  deriving stock (Eq, Show)

data EngineEvent
  = EngineHello !Text !Text
  | EngineCheckpoint !Text !EngineState
  | EngineEffectRequested !Text !Word64 !Word32
  | EngineTerminal !Text !EngineTerminalState
  | EngineProtocolError !(Maybe Text) !Text
  deriving stock (Eq, Show)

instance ToJSON HostCommand where
  toJSON = \case
    HostStart runId -> envelope "start" runId []
    HostRestore runId state -> envelope "restore" runId ["state" .= state]
    HostEffectCompleted runId sequenceNumber nodeId completion ->
      let (outcome, outputHandle, maybeMessage) = case completion of
            EffectSucceeded handle -> ("success" :: Text, handle, Nothing)
            EffectSkipped -> ("skipped", 0, Nothing)
            EffectFailed message -> ("failure", 0, Just message)
       in envelope
            "effect_completed"
            runId
            [ "sequence" .= sequenceNumber
            , "node_id" .= nodeId
            , "outcome" .= outcome
            , "output_handle" .= outputHandle
            , "message" .= maybeMessage
            ]
    HostCheckpointCommitted runId sequenceNumber ->
      envelope "checkpoint_committed" runId ["sequence" .= sequenceNumber]
    HostCancel runId reason -> envelope "cancel" runId ["reason" .= reason]
    HostShutdown runId -> envelope "shutdown" runId []

instance FromJSON HostCommand where
  parseJSON = Aeson.withObject "HostCommand" $ \objectValue -> do
    requireProtocol objectValue
    commandType <- objectValue .: "type"
    runId <- objectValue .: "run_id"
    case commandType :: Text of
      "start" -> pure (HostStart runId)
      "restore" -> HostRestore runId <$> objectValue .: "state"
      "effect_completed" -> do
        sequenceNumber <- objectValue .: "sequence"
        nodeId <- objectValue .: "node_id"
        outcome <- objectValue .: "outcome"
        outputHandle <- objectValue .: "output_handle"
        maybeMessage <- objectValue .:? "message"
        completion <- parseCompletion outcome outputHandle maybeMessage
        pure (HostEffectCompleted runId sequenceNumber nodeId completion)
      "checkpoint_committed" ->
        HostCheckpointCommitted runId <$> objectValue .: "sequence"
      "cancel" -> HostCancel runId <$> objectValue .: "reason"
      "shutdown" -> pure (HostShutdown runId)
      _other -> fail ("unknown host command: " <> T.unpack commandType)

instance ToJSON EngineEvent where
  toJSON = \case
    EngineHello programIdentity reportedAbi ->
      Aeson.object
        [ "type" .= ("hello" :: Text)
        , "protocol" .= hostedProcessProtocol
        , "program_identity" .= programIdentity
        , "engine_abi" .= reportedAbi
        ]
    EngineCheckpoint runId state -> envelope "checkpoint" runId ["state" .= state]
    EngineEffectRequested runId sequenceNumber nodeId ->
      envelope
        "effect_requested"
        runId
        ["sequence" .= sequenceNumber, "node_id" .= nodeId]
    EngineTerminal runId terminal ->
      envelope "terminal" runId ["terminal" .= terminal]
    EngineProtocolError maybeRunId message ->
      Aeson.object
        [ "type" .= ("protocol_error" :: Text)
        , "protocol" .= hostedProcessProtocol
        , "run_id" .= maybeRunId
        , "message" .= message
        ]

instance FromJSON EngineEvent where
  parseJSON = Aeson.withObject "EngineEvent" $ \objectValue -> do
    requireProtocol objectValue
    eventType <- objectValue .: "type"
    case eventType :: Text of
      "hello" ->
        EngineHello
          <$> objectValue .: "program_identity"
          <*> objectValue .: "engine_abi"
      "checkpoint" ->
        EngineCheckpoint <$> objectValue .: "run_id" <*> objectValue .: "state"
      "effect_requested" ->
        EngineEffectRequested
          <$> objectValue .: "run_id"
          <*> objectValue .: "sequence"
          <*> objectValue .: "node_id"
      "terminal" ->
        EngineTerminal <$> objectValue .: "run_id" <*> objectValue .: "terminal"
      "protocol_error" ->
        EngineProtocolError <$> objectValue .:? "run_id" <*> objectValue .: "message"
      _other -> fail ("unknown engine event: " <> T.unpack eventType)

envelope :: Text -> Text -> [AesonTypes.Pair] -> Aeson.Value
envelope messageType runId fields =
  Aeson.object
    (["type" .= messageType, "protocol" .= hostedProcessProtocol, "run_id" .= runId] <> fields)

requireProtocol :: Aeson.Object -> AesonTypes.Parser ()
requireProtocol objectValue = do
  protocol <- objectValue .: "protocol"
  if protocol == hostedProcessProtocol
    then pure ()
    else fail ("unsupported hosted process protocol: " <> T.unpack protocol)

parseCompletion :: Text -> Word64 -> Maybe Text -> AesonTypes.Parser EffectCompletion
parseCompletion outcome outputHandle maybeMessage =
  case outcome of
    "success"
      | outputHandle == 0 ->
          fail "successful effect completion requires a nonzero output handle"
      | otherwise -> pure (EffectSucceeded outputHandle)
    "skipped"
      | outputHandle == 0 -> pure EffectSkipped
      | otherwise -> fail "skipped effect completion must carry output handle zero"
    "failure"
      | outputHandle /= 0 ->
          fail "failed effect completion must carry output handle zero"
      | otherwise -> pure (EffectFailed (fromMaybe "effect failed" maybeMessage))
    _other -> fail ("unknown effect completion outcome: " <> T.unpack outcome)

encodeHostCommand :: HostCommand -> BS.ByteString
encodeHostCommand command = BSL.toStrict (BSL.snoc (Aeson.encode command) 10)

encodeEngineEvent :: EngineEvent -> BS.ByteString
encodeEngineEvent event = BSL.toStrict (BSL.snoc (Aeson.encode event) 10)

decodeHostCommand :: BS.ByteString -> Either Text HostCommand
decodeHostCommand = firstText . Aeson.eitherDecodeStrict'

decodeEngineEvent :: BS.ByteString -> Either Text EngineEvent
decodeEngineEvent = firstText . Aeson.eitherDecodeStrict'

firstText :: Either String a -> Either Text a
firstText = \case
  Left err -> Left (T.pack err)
  Right value -> Right value
