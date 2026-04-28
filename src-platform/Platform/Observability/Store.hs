{- | On-disk NDJSON observability store.

This store is designed for a single-process writer. Concurrent writes from
the same process are serialized by the 'writeLock' MVar in 'ObservabilityRuntime'.
Multiple processes writing to the same state directory will race on file
rotation and may produce interleaved or truncated NDJSON lines.

If multi-process write support is needed, introduce file-level locking (e.g.
@flock@) or switch to a shared append medium.
-}
module Platform.Observability.Store
  ( -- * Public API (re-exported by Platform.Observability)
    queryLogs
  , queryTraces
  , valueTextField
  , valueIntField

    -- * Internal (used by sibling modules)
  , appendValue
  , appendLogValue
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (modifyMVar_)
import Control.Exception (IOException, displayException, try)
import Control.Monad (void, when)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseJSON, parseMaybe)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Lazy.Char8 qualified as BSL8
import Data.List (sort, sortBy)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , getFileSize
  , listDirectory
  , removeFile
  , renameFile
  )
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Error (isAlreadyInUseError)
import System.Log.FastLogger (pushLogStrLn, toLogStr)
import Text.Read (readMaybe)

import Platform.Observability.Redaction (sanitizeStoredValue)
import Platform.Observability.Types

queryLogs :: ObservabilityRuntime -> ObservabilityQuery -> IO [Value]
queryLogs runtime query = do
  values <-
    readObservabilityValues runtime "events.ndjson" query.queryLimit (matchesObservabilityQuery query)
  pure
    . fmap (sanitizeStoredValue runtime)
    $ values

queryTraces :: ObservabilityRuntime -> TraceQuery -> IO [Value]
queryTraces runtime query = do
  values <-
    readObservabilityValues runtime "traces.ndjson" query.traceQueryLimit (matchesTraceQuery query)
  pure
    . fmap (sanitizeStoredValue runtime)
    $ values

valueTextField :: Text -> Value -> Maybe Text
valueTextField fieldName value =
  fieldValue fieldName value >>= \case
    String txt -> Just txt
    Number num -> Just (T.pack (show num))
    Bool boolValue -> Just (if boolValue then "true" else "false")
    _ -> Nothing

valueIntField :: Text -> Value -> Maybe Int
valueIntField fieldName value =
  fieldValue fieldName value >>= \case
    Number num -> parseMaybe parseJSON (Number num)
    String txt -> readMaybe (T.unpack txt)
    _ -> Nothing

appendValue :: ObservabilityRuntime -> FilePath -> Value -> IO ()
appendValue runtime filePath value = do
  let bytes = BSL.toStrict (Aeson.encode value) <> "\n"
  result <- try @IOException $
    modifyMVar_ runtime.writeLock $ \() -> do
      rotateStateFileIfNeeded runtime filePath (fromIntegral (BS.length bytes))
      BS.appendFile filePath bytes
      pure ()
  case result of
    Right () -> pure ()
    Left exc ->
      hPutStrLn
        stderr
        ("observability: failed to append value to " <> filePath <> ": " <> displayException exc)

appendLogValue :: ObservabilityRuntime -> FilePath -> Value -> IO ()
appendLogValue runtime filePath value = do
  let encoded = Aeson.encode value
      bytes = BSL.toStrict encoded <> "\n"
  pushLogStrLn runtime.loggerSet (toLogStr encoded)
  result <- try @IOException $
    modifyMVar_ runtime.writeLock $ \() -> do
      rotateStateFileIfNeeded runtime filePath (fromIntegral (BS.length bytes))
      BS.appendFile filePath bytes
      pure ()
  case result of
    Right () -> pure ()
    Left exc ->
      hPutStrLn stderr ("observability: failed to append log: " <> displayException exc)

-- Internal helpers

matchesObservabilityQuery :: ObservabilityQuery -> Value -> Bool
matchesObservabilityQuery query value =
  and
    [ matchText "service" query.queryService value
    , matchText "request_id" query.queryRequestId value
    , matchText "trace_id" query.queryTraceId value
    , matchText "run_id" query.queryRunId value
    , matchText "account_id" query.queryAccountId value
    , matchText "user_id" query.queryUserId value
    , matchText "provider" query.queryProvider value
    , matchText "level" query.queryLevel value
    , matchText "operation" query.queryOperation value
    , matchText "route" query.queryRoute value
    , matchText "tool_name" query.queryToolName value
    , matchText "assistant_phase" query.queryAssistantPhase value
    , matchText "stage" query.queryStage value
    , matchText "error_type" query.queryErrorType value
    , matchTimeRange query.querySince query.queryUntil value
    ]

matchesTraceQuery :: TraceQuery -> Value -> Bool
matchesTraceQuery query value =
  and
    [ matchText "service" query.traceQueryService value
    , matchText "trace_id" query.traceQueryTraceId value
    , matchText "run_id" query.traceQueryRunId value
    , matchText "request_id" query.traceQueryRequestId value
    , matchTimeRange query.traceQuerySince query.traceQueryUntil value
    ]

matchText :: Text -> Maybe Text -> Value -> Bool
matchText _ Nothing _ = True
matchText fieldName (Just expected) value =
  fmap T.toLower (valueTextField fieldName value) == Just (T.toLower expected)

matchTimeRange :: Maybe UTCTime -> Maybe UTCTime -> Value -> Bool
matchTimeRange maybeSince maybeUntil value =
  case fieldValue "timestamp" value >>= parseMaybe parseJSON of
    Nothing -> isNothing maybeSince && isNothing maybeUntil
    Just timestamp ->
      maybe True (<= timestamp) maybeSince
        && maybe True (>= timestamp) maybeUntil

fieldValue :: Text -> Value -> Maybe Value
fieldValue fieldName = \case
  Object obj -> KeyMap.lookup (Key.fromText fieldName) obj
  _ -> Nothing

readObservabilityValues :: ObservabilityRuntime -> FilePath -> Int -> (Value -> Bool) -> IO [Value]
readObservabilityValues runtime fileName limit predicate = do
  exists <- doesDirectoryExist rootDir
  if not exists
    then pure []
    else do
      entries <- sort <$> listDirectory rootDir
      let boundedLimit = max 1 limit
      fmap snd
        <$> foldl'
          (\accIO entry -> accIO >>= \acc -> readMatchingEntry entry acc boundedLimit)
          (pure [])
          entries
  where
    rootDir = runtime.config.stateDir </> "observability"

    readMatchingEntry entry acc limit' = do
      let serviceDir = rootDir </> entry
      isDir <- doesDirectoryExist serviceDir
      if not isDir
        then pure acc
        else
          foldl'
            (\accIO' filePath -> accIO' >>= \acc' -> readMatchingFile filePath acc' limit')
            (pure acc)
            (rotatedStateFiles runtime.config.maxStateFiles (serviceDir </> fileName))

    readMatchingFile filePath acc limit' = do
      isFile <- doesFileExist filePath
      if not isFile
        then pure acc
        else do
          maybeRaw <- readObservabilityFile filePath
          pure $
            maybe
              acc
              ( foldl'
                  (accumulateMatchingValue limit')
                  acc
                  . BSL8.lines
              )
              maybeRaw

    accumulateMatchingValue limit' acc line =
      case Aeson.eitherDecode line of
        Left _ -> acc
        Right value
          | predicate value ->
              take limit'
                . sortBy compareTimedValue
                $ (valueTimestamp value, value) : acc
          | otherwise ->
              acc

rotateStateFileIfNeeded :: ObservabilityRuntime -> FilePath -> Integer -> IO ()
rotateStateFileIfNeeded runtime filePath pendingBytes = do
  let cfg = runtime.config
  result <- try @IOException $ do
    exists <- doesFileExist filePath
    if not exists
      then pure ()
      else do
        currentBytes <- getFileSize filePath
        if currentBytes + pendingBytes <= cfg.maxStateFileBytes
          then pure ()
          else rotateStateFiles cfg.maxStateFiles filePath
  case result of
    Right () -> pure ()
    Left _exc -> pure () -- best-effort rotation; failure is harmless

rotateStateFiles :: Int -> FilePath -> IO ()
rotateStateFiles maxFiles filePath
  | maxFiles <= 1 = do
      exists <- doesFileExist filePath
      when exists $ void (try @IOException (removeFile filePath))
  | otherwise = do
      let oldestFile = rotatedStateFile filePath (maxFiles - 1)
      oldestExists <- doesFileExist oldestFile
      when oldestExists $ void (try @IOException (removeFile oldestFile))
      foldl'
        (\ioAction index -> ioAction >> rotateIndex index)
        (pure ())
        [maxFiles - 2, maxFiles - 3 .. 0]
  where
    rotateIndex index = do
      let sourceFile =
            if index == 0
              then filePath
              else rotatedStateFile filePath index
          targetFile = rotatedStateFile filePath (index + 1)
      sourceExists <- doesFileExist sourceFile
      when sourceExists $ void (try @IOException (renameFile sourceFile targetFile))

rotatedStateFiles :: Int -> FilePath -> [FilePath]
rotatedStateFiles maxFiles filePath =
  filePath : fmap (rotatedStateFile filePath) [1 .. max 0 (maxFiles - 1)]

readObservabilityFile :: FilePath -> IO (Maybe BSL.ByteString)
readObservabilityFile = go 0
  where
    maxReadAttempts = 3

    go :: Int -> FilePath -> IO (Maybe BSL.ByteString)
    go attempt filePath = do
      result <- try @IOException (BS.readFile filePath)
      case result of
        Right raw -> pure (Just (BSL.fromStrict raw))
        Left err
          | isAlreadyInUseError err && attempt + 1 < maxReadAttempts -> do
              threadDelay (50000 * (attempt + 1))
              go (attempt + 1) filePath
          | otherwise -> pure Nothing

rotatedStateFile :: FilePath -> Int -> FilePath
rotatedStateFile filePath index =
  filePath <> "." <> show index

compareTimedValue :: (Maybe UTCTime, Value) -> (Maybe UTCTime, Value) -> Ordering
compareTimedValue (timeA, _) (timeB, _) = compare timeB timeA

valueTimestamp :: Value -> Maybe UTCTime
valueTimestamp value =
  fieldValue "timestamp" value >>= parseMaybe parseJSON
