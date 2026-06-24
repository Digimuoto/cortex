{- |
Module      : Cortex.Quantum.Provenance
Description : Self-authenticating provenance for Amazon Braket quantum-task runs.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Every Braket run report must be independently verifiable from AWS-generated
evidence. This module captures that evidence — the @create-quantum-task@ /
@get-quantum-task@ fields, the @results.json@ schema headers, task metadata, the
submitted OpenQASM 3 source, and (for IQM hardware) the native @prx@
@compiledProgram@ — and the integrity hashes that pin it: @sha256@ of the raw
@results.json@ artifact, of the submitted OpenQASM source, and of the compiled
program.

The captured 'CaseProvenance' is a source of truth for the report: the device the
task ran on is read back from @taskMetadata.deviceId@ and checked against the
device the runner submitted to, so a report can never claim a device it did not
use. 'RedactionMode' masks the AWS account id, S3 bucket, and key before a report
is committed to a public repository; the task UUID, region, device ARN, all
hashes, and the compiled program stay intact because they are independently
verifiable through @aws braket get-quantum-task@.
-}
module Cortex.Quantum.Provenance
  ( -- * Hashing
    sha256OfText
  , sha256OfBytes
  , fileSha256

    -- * Schema headers
  , SchemaHeader (..)
  , renderSchemaHeader

    -- * Per-case provenance
  , ClientTokenSource (..)
  , CaseProvenance (..)
  , ProvenanceSources (..)
  , extractCaseProvenance
  , observedShots

    -- * Run-level provenance
  , RunProvenance (..)
  , freshReportUuid
  , gitCommitSha
  , awsCliVersion
  , taskUuidFromArn

    -- * Redaction
  , RedactionMode (..)
  , redactArn
  , redactCaseProvenance
  , redactResultsJson

    -- * Rendering
  , renderCaseProvenanceBlock
  , renderRunProvenanceBlock
  , caseProvenanceJSON
  )
where

import Control.Applicative ((<|>))
import Control.Exception (SomeException, try)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (SystemDRG, getSystemDRG, randomBytesGenerate)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits (shiftR, (.&.), (.|.))
import Data.ByteString qualified as BS
import Data.Foldable (asum, toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word8)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

-- Hashing.

-- | Lowercase hex @sha256@ of a strict 'BS.ByteString'.
sha256OfBytes :: BS.ByteString -> Text
sha256OfBytes bytes = T.pack (show (hash bytes :: Digest SHA256))

-- | Lowercase hex @sha256@ of UTF-8-encoded 'Text'.
sha256OfText :: Text -> Text
sha256OfText = sha256OfBytes . TE.encodeUtf8

-- | Lowercase hex @sha256@ of a file's exact bytes.
fileSha256 :: FilePath -> IO Text
fileSha256 path = sha256OfBytes <$> BS.readFile path

-- Schema headers.

-- | A Braket @braketSchemaHeader@: the schema name and its version.
data SchemaHeader = SchemaHeader
  { shName :: !Text
  , shVersion :: !Text
  }
  deriving stock (Eq, Show)

-- | @name/version@, e.g. @braket.task_result.gate_model_task_result/1@.
renderSchemaHeader :: SchemaHeader -> Text
renderSchemaHeader header = shName header <> "/" <> shVersion header

-- Per-case provenance.

-- | How the recorded @clientToken@ relates to the original create request.
data ClientTokenSource
  = -- | The exact token the runner computed when it submitted the task.
    TokenExact
  | -- | Recomputed from create parameters recovered from task metadata.
    TokenRecomputed
  | -- | Not recoverable (Braket does not echo @clientToken@).
    TokenUnavailable
  deriving stock (Eq, Show)

{- | Everything needed to independently confirm one Braket task run. Captured from
the @get-quantum-task@ response and the @results.json@ artifact; the device,
schema headers, OpenQASM source, and compiled program are all AWS-generated.
-}
data CaseProvenance = CaseProvenance
  { cpTaskArn :: !Text
  , cpTaskUuid :: !Text
  , cpStatus :: !Text
  , cpDeviceId :: !Text
  , cpRequestedShots :: !Int
  , cpObservedShots :: !Int
  , cpCreatedAt :: !Text
  , cpEndedAt :: !Text
  , cpResultSchema :: !(Maybe SchemaHeader)
  , cpDeviceParamsSchema :: !(Maybe SchemaHeader)
  , cpActionSchema :: !(Maybe SchemaHeader)
  , cpIqmSchema :: !(Maybe SchemaHeader)
  , cpQubitCount :: !(Maybe Int)
  , cpDisableQubitRewiring :: !(Maybe Bool)
  , cpOpenQasmSource :: !Text
  , cpOpenQasmSha256 :: !Text
  , cpCompiledProgram :: !(Maybe Text)
  , cpCompiledProgramSha256 :: !(Maybe Text)
  , cpResultSha256 :: !Text
  , cpClientToken :: !(Maybe Text)
  , cpClientTokenSource :: !ClientTokenSource
  , cpS3Bucket :: !Text
  , cpS3Directory :: !Text
  , cpS3Uri :: !Text
  }
  deriving stock (Eq, Show)

{- | The raw inputs the extractor reads: the @get-quantum-task@ response, the
parsed @results.json@, the hash of its exact bytes, the device the runner
submitted to (for the invariant), and the @clientToken@ the runner knows.
-}
data ProvenanceSources = ProvenanceSources
  { psTaskValue :: !Value
  , psResultValue :: !Value
  , psResultRawSha256 :: !Text
  , psExpectedDeviceArn :: !Text
  , psClientToken :: !(Maybe Text)
  , psClientTokenSource :: !ClientTokenSource
  }

{- | Build 'CaseProvenance' from the AWS sources, failing if the device the task
ran on does not match the device the runner submitted to (the report can then
never claim a device it did not use), or if the task ARN cannot be recovered.
-}
extractCaseProvenance :: ProvenanceSources -> Either Text CaseProvenance
extractCaseProvenance sources = do
  taskArn <-
    maybe (Left "Braket provenance is missing the quantum-task ARN") Right $
      objText "quantumTaskArn" task
        <|> (objPath ["taskMetadata", "id"] result >>= asTextValue)
  deviceId <-
    maybe (Left "Braket provenance is missing the result deviceId") Right $
      (objPath ["taskMetadata", "deviceId"] result >>= asTextValue)
        <|> objText "deviceArn" task
  let expected = psExpectedDeviceArn sources
  if not (T.null expected) && expected /= deviceId
    then
      Left
        ( "Braket device invariant violated: submitted "
            <> expected
            <> " but task result deviceId is "
            <> deviceId
        )
    else do
      let openqasm = fromMaybe "" (objPath ["additionalMetadata", "action", "source"] result >>= asTextValue)
          compiled = objPath ["additionalMetadata", "iqmMetadata", "compiledProgram"] result >>= asTextValue
          requested =
            fromMaybe 0 $
              (objPath ["taskMetadata", "shots"] result >>= asIntValue)
                <|> (objLookup "shots" task >>= asIntValue)
      Right
        CaseProvenance
          { cpTaskArn = taskArn
          , cpTaskUuid = taskUuidFromArn taskArn
          , cpStatus =
              fromMaybe "UNKNOWN" $
                (objPath ["taskMetadata", "status"] result >>= asTextValue)
                  <|> objText "status" task
          , cpDeviceId = deviceId
          , cpRequestedShots = requested
          , cpObservedShots = observedShots result
          , cpCreatedAt =
              fromMaybe "" $
                (objPath ["taskMetadata", "createdAt"] result >>= asTextValue)
                  <|> objText "createdAt" task
          , cpEndedAt =
              fromMaybe "" $
                (objPath ["taskMetadata", "endedAt"] result >>= asTextValue)
                  <|> objText "endedAt" task
          , cpResultSchema = schemaHeaderAt ["braketSchemaHeader"] result
          , cpDeviceParamsSchema =
              schemaHeaderAt ["taskMetadata", "deviceParameters", "braketSchemaHeader"] result
          , cpActionSchema = schemaHeaderAt ["additionalMetadata", "action", "braketSchemaHeader"] result
          , cpIqmSchema = schemaHeaderAt ["additionalMetadata", "iqmMetadata", "braketSchemaHeader"] result
          , cpQubitCount =
              objPath ["taskMetadata", "deviceParameters", "paradigmParameters", "qubitCount"] result
                >>= asIntValue
          , cpDisableQubitRewiring =
              objPath
                ["taskMetadata", "deviceParameters", "paradigmParameters", "disableQubitRewiring"]
                result
                >>= asBoolValue
          , cpOpenQasmSource = openqasm
          , cpOpenQasmSha256 = sha256OfText openqasm
          , cpCompiledProgram = compiled
          , cpCompiledProgramSha256 = sha256OfText <$> compiled
          , cpResultSha256 = psResultRawSha256 sources
          , cpClientToken = psClientToken sources
          , cpClientTokenSource = psClientTokenSource sources
          , cpS3Bucket = fromMaybe "" (objText "outputS3Bucket" task)
          , cpS3Directory = directory
          , cpS3Uri = s3Uri (objText "outputS3Bucket" task) directory
          }
  where
    task = psTaskValue sources
    result = psResultValue sources
    directory = fromMaybe "" (objText "outputS3Directory" task)
    s3Uri (Just bucket) dir
      | not (T.null bucket) =
          "s3://" <> bucket <> "/" <> T.dropWhileEnd (== '/') dir <> "/results.json"
    s3Uri _ _ = ""

{- | Observed shot count: the number of per-shot rows in @measurements@, or the
summed direct histogram under any Braket count key we decode, or 0 if neither is
present.
-}
observedShots :: Value -> Int
observedShots result =
  case findKey "measurements" result of
    Just (Array rows) | not (null rows) -> length rows
    _ ->
      fromMaybe 0 $
        asum
          [ histogramShots <$> directCounts
          | key <- directCountKeys
          , let directCounts = case findKey key result of
                  Just (Object km) -> Just km
                  _ -> Nothing
          ]
  where
    histogramShots km = sum [n | (_, v) <- KeyMap.toList km, Just n <- [asIntValue v]]

directCountKeys :: [Text]
directCountKeys = ["measurementCounts", "measurement_counts", "counts"]

-- Run-level provenance.

{- | Provenance that is the same across every case in one report run: the cortex
commit, the Wire source and its hash, the region, the AWS CLI/SDK version, and a
freshly minted report UUID distinct from any task UUID.
-}
data RunProvenance = RunProvenance
  { rpCortexCommit :: !Text
  , rpWireSourcePath :: !Text
  , rpWireSourceSha256 :: !Text
  , rpRegion :: !Text
  , rpSdkVersion :: !Text
  , rpReportUuid :: !Text
  }
  deriving stock (Eq, Show)

-- | A fresh random version-4 UUID for the report (distinct from task UUIDs).
freshReportUuid :: IO Text
freshReportUuid = do
  drg <- getSystemDRG
  let (bytes, _) = randomBytesGenerate 16 drg :: (BS.ByteString, SystemDRG)
  pure (formatUuidV4 (BS.unpack bytes))

-- | The current @git@ commit SHA, or @unknown@ outside a checkout.
gitCommitSha :: IO Text
gitCommitSha = fromMaybe "unknown" <$> runCommandFirstLine "git" ["rev-parse", "HEAD"]

-- | The AWS CLI version string, or @unknown@ if the binary cannot be queried.
awsCliVersion :: FilePath -> IO Text
awsCliVersion awsBin = fromMaybe "unknown" <$> runCommandFirstLine awsBin ["--version"]

-- | The UUID segment of a quantum-task ARN, e.g. the part after @quantum-task/@.
taskUuidFromArn :: Text -> Text
taskUuidFromArn arn = T.takeWhileEnd (/= '/') arn

-- Redaction.

-- | Whether AWS account/bucket identifiers are masked before a report is written.
data RedactionMode = Redacted | Unredacted
  deriving stock (Eq, Show)

{- | Mask the 12-digit account id in an ARN with @***@, leaving the partition,
service, region, and resource (including any task UUID) intact. Device ARNs carry
an empty account field and pass through unchanged.
-}
redactArn :: Text -> Text
redactArn arn =
  case T.splitOn ":" arn of
    partition : aws : service : region : account : rest
      | isAccountId account ->
          T.intercalate ":" (partition : aws : service : region : "***" : rest)
    _ -> arn
  where
    isAccountId t = T.length t == 12 && T.all (\c -> c >= '0' && c <= '9') t

{- | Mask the account id, S3 bucket, and S3 key of one case's provenance. The task
UUID, device ARN, all hashes, the OpenQASM source, and the compiled program stay
intact because they are verifiable through the task ARN.
-}
redactCaseProvenance :: RedactionMode -> CaseProvenance -> CaseProvenance
redactCaseProvenance Unredacted prov = prov
redactCaseProvenance Redacted prov =
  prov
    { cpTaskArn = redactArn (cpTaskArn prov)
    , cpDeviceId = redactArn (cpDeviceId prov)
    , cpS3Bucket = mask (cpS3Bucket prov)
    , cpS3Directory = mask (cpS3Directory prov)
    , cpS3Uri = mask (cpS3Uri prov)
    }
  where
    mask t = if T.null t then t else "***"

{- | Mask account/bucket/key identifiers throughout a @results.json@ value so a
redacted copy can be committed alongside the report. Any ARN-shaped string has its
account masked; @outputS3Bucket@/@outputS3Directory@ values become @***@.
-}
redactResultsJson :: Value -> Value
redactResultsJson = go
  where
    go (Object km) = Object (KeyMap.mapWithKey redactEntry km)
    go (Array a) = Array (fmap go a)
    go (String s) = String (redactArn s)
    go other = other
    redactEntry key value
      | Key.toText key `elem` ["outputS3Bucket", "outputS3Directory", "s3Bucket", "s3Directory"] =
          String "***"
      | otherwise = go value

-- Rendering.

{- | A per-case @<details>@ provenance block: the verifiable field table and the
compiled native program (or a note that a simulator emits none).
-}
renderCaseProvenanceBlock :: CaseProvenance -> [Text]
renderCaseProvenanceBlock prov =
  [ "<details><summary>Provenance</summary>"
  , ""
  ]
    <> kvTable
      ( [ ("task ARN", code (cpTaskArn prov))
        , ("task UUID", cpTaskUuid prov)
        , ("status", cpStatus prov)
        , ("device (result deviceId)", code (cpDeviceId prov))
        , ("requested shots", tshow (cpRequestedShots prov))
        , ("observed shots", tshow (cpObservedShots prov))
        , ("createdAt", orDash (cpCreatedAt prov))
        , ("endedAt", orDash (cpEndedAt prov))
        , ("result schema", schema (cpResultSchema prov))
        , ("device-parameters schema", schema (cpDeviceParamsSchema prov))
        , ("action schema", schema (cpActionSchema prov))
        ]
          <> [("IQM metadata schema", schema (cpIqmSchema prov)) | Just _ <- [cpIqmSchema prov]]
          <> [("qubit count", tshow n) | Just n <- [cpQubitCount prov]]
          <> [("disableQubitRewiring", lower (tshow b)) | Just b <- [cpDisableQubitRewiring prov]]
          <> [ ("result sha256", code (cpResultSha256 prov))
             , ("OpenQASM sha256", code (cpOpenQasmSha256 prov))
             ]
          <> [("compiledProgram sha256", code h) | Just h <- [cpCompiledProgramSha256 prov]]
          <> [("clientToken", clientToken)]
          <> [("S3 URI", s3Field)]
      )
    <> compiledBlock
    <> ["", "</details>", ""]
  where
    clientToken = case cpClientToken prov of
      Just token -> code token <> clientTokenNote (cpClientTokenSource prov)
      Nothing -> "n/a — Braket does not echo the client token"
    clientTokenNote TokenExact = ""
    clientTokenNote TokenRecomputed = " (recomputed from recovered create parameters)"
    clientTokenNote TokenUnavailable = ""
    s3Field
      | T.null (cpS3Uri prov) = "n/a"
      | cpS3Uri prov == "***" = "`***` (recover via `aws braket get-quantum-task`)"
      | otherwise = code (cpS3Uri prov)
    compiledBlock = case cpCompiledProgram prov of
      Just program ->
        [ ""
        , "Compiled native program (IQM `prx` verbatim — a simulator never emits this):"
        , ""
        , "```text"
        , T.stripEnd program
        , "```"
        ]
      Nothing ->
        [ ""
        , "_No `compiledProgram`: this device returned no native-hardware compilation (managed simulator)._"
        ]
    schema = maybe "n/a" (code . renderSchemaHeader)
    orDash t = if T.null t then "—" else t
    lower = T.toLower

{- | The run-level @## Provenance & reproduction@ block, including the
how-to-verify steps. @arn@ is the first verifiable case ARN to show in step 1.
-}
renderRunProvenanceBlock :: RedactionMode -> RunProvenance -> Maybe Text -> [Text]
renderRunProvenanceBlock redaction run firstArn =
  [ "## Provenance & reproduction"
  , ""
  ]
    <> kvTable
      [ ("cortex commit", code (rpCortexCommit run))
      , ("Wire source", code (rpWireSourcePath run))
      , ("Wire source sha256", code (rpWireSourceSha256 run))
      , ("region", rpRegion run)
      , ("Braket CLI/SDK", code (rpSdkVersion run))
      , ("report UUID", rpReportUuid run)
      , ("redaction", redactionNote redaction)
      ]
    <> [ ""
       , "### How to verify"
       , ""
       , "1. `aws braket get-quantum-task --quantum-task-arn "
           <> arnExample
           <> "` — AWS confirms the deviceArn, `COMPLETED` status, shots, and timestamps."
       , "2. `aws s3 cp <outputS3Directory>/results.json - | sha256sum` — must equal the recorded result sha256."
       , "3. The `compiledProgram` (IQM `prx` verbatim) demonstrates native-hardware compilation; a managed simulator never emits one."
       , ""
       ]
  where
    arnExample = fromMaybe "<task-arn>" firstArn
    redactionNote Redacted =
      "account id, S3 bucket, and S3 key masked (`***`); UUIDs, hashes, device ARN, and compiled program kept"
    redactionNote Unredacted = "none (full AWS identifiers shown)"

-- | The per-case provenance as a JSON object for the runner's @--json@ output.
caseProvenanceJSON :: CaseProvenance -> Value
caseProvenanceJSON prov =
  object
    [ "task_arn" .= cpTaskArn prov
    , "task_uuid" .= cpTaskUuid prov
    , "status" .= cpStatus prov
    , "device_id" .= cpDeviceId prov
    , "requested_shots" .= cpRequestedShots prov
    , "observed_shots" .= cpObservedShots prov
    , "created_at" .= cpCreatedAt prov
    , "ended_at" .= cpEndedAt prov
    , "result_schema" .= fmap renderSchemaHeader (cpResultSchema prov)
    , "device_parameters_schema" .= fmap renderSchemaHeader (cpDeviceParamsSchema prov)
    , "iqm_metadata_schema" .= fmap renderSchemaHeader (cpIqmSchema prov)
    , "qubit_count" .= cpQubitCount prov
    , "disable_qubit_rewiring" .= cpDisableQubitRewiring prov
    , "openqasm_sha256" .= cpOpenQasmSha256 prov
    , "compiled_program_sha256" .= cpCompiledProgramSha256 prov
    , "result_sha256" .= cpResultSha256 prov
    , "client_token" .= cpClientToken prov
    , "s3_uri" .= cpS3Uri prov
    ]

-- Markdown + JSON helpers.

kvTable :: [(Text, Text)] -> [Text]
kvTable rows =
  ["| field | value |", "| --- | --- |"]
    <> ["| " <> key <> " | " <> value <> " |" | (key, value) <- rows]

code :: Text -> Text
code t = "`" <> t <> "`"

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | A version-4 UUID string from 16 bytes (version and variant bits forced).
formatUuidV4 :: [Word8] -> Text
formatUuidV4 bytes =
  case bytes of
    (b0 : b1 : b2 : b3 : b4 : b5 : b6 : b7 : b8 : b9 : b10 : b11 : b12 : b13 : b14 : b15 : _) ->
      T.concat
        [ hexes [b0, b1, b2, b3]
        , "-"
        , hexes [b4, b5]
        , "-"
        , hexes [(b6 .&. 0x0f) .|. 0x40, b7]
        , "-"
        , hexes [(b8 .&. 0x3f) .|. 0x80, b9]
        , "-"
        , hexes [b10, b11, b12, b13, b14, b15]
        ]
    _ -> "00000000-0000-4000-8000-000000000000"
  where
    hexes = foldMap word8Hex

word8Hex :: Word8 -> Text
word8Hex w = T.pack [nibble (w `shiftR` 4), nibble (w .&. 0x0f)]
  where
    nibble n
      | n < 10 = toEnum (fromEnum '0' + fromIntegral n)
      | otherwise = toEnum (fromEnum 'a' + fromIntegral n - 10)

runCommandFirstLine :: String -> [String] -> IO (Maybe Text)
runCommandFirstLine bin args = do
  outcome <-
    try (readProcessWithExitCode bin args "") :: IO (Either SomeException (ExitCode, String, String))
  pure $ case outcome of
    Right (ExitSuccess, out, _) -> firstNonEmptyLine out
    _ -> Nothing
  where
    firstNonEmptyLine raw =
      case filter (not . T.null) (map T.strip (T.lines (T.pack raw))) of
        (line : _) -> Just line
        [] -> Nothing

-- Small JSON accessors.

objLookup :: Text -> Value -> Maybe Value
objLookup key (Object km) = KeyMap.lookup (Key.fromText key) km
objLookup _ _ = Nothing

objPath :: [Text] -> Value -> Maybe Value
objPath [] value = Just value
objPath (key : rest) value = objLookup key value >>= objPath rest

objText :: Text -> Value -> Maybe Text
objText key value = objLookup key value >>= asTextValue

asTextValue :: Value -> Maybe Text
asTextValue (String t) = Just t
asTextValue _ = Nothing

asIntValue :: Value -> Maybe Int
asIntValue (Number n) = case properFraction n of
  (i, frac) | frac == 0 -> Just (i :: Int)
  _ -> Nothing
asIntValue _ = Nothing

asBoolValue :: Value -> Maybe Bool
asBoolValue (Bool b) = Just b
asBoolValue _ = Nothing

schemaHeaderAt :: [Text] -> Value -> Maybe SchemaHeader
schemaHeaderAt path value = do
  header <- objPath path value
  name <- objText "name" header
  version <- schemaVersion header
  Just (SchemaHeader name version)
  where
    schemaVersion header =
      (objLookup "version" header >>= asTextValue)
        <|> (objLookup "version" header >>= fmap tshow . asIntValue)

-- | Find the first value under @key@ anywhere in a JSON tree (breadth into children).
findKey :: Text -> Value -> Maybe Value
findKey key = go
  where
    go (Object km) =
      KeyMap.lookup (Key.fromText key) km
        <|> asum (map go (KeyMap.elems km))
    go (Array a) = asum (map go (toList a))
    go _ = Nothing
