{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Platform.Observability.Runtime
  ( -- * Public API (re-exported by Platform.Observability)
    loadObservabilityConfig,
    initObservabilityRuntime,
    installGlobalObservabilityRuntime,
    resetGlobalObservabilityRuntime,
    currentRuntime,
    debugEnabled,
    stateLogFile,
    stateTraceFile,

    -- * Internal (used by sibling modules)
    globalRuntimeVar,
    serviceStateDir,
    defaultMaxStateFileBytes,
    defaultMaxStateFiles,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar, readMVar)
import Control.Concurrent.STM (newTVarIO)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Platform.Observability.Types
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)
import System.Log.FastLogger (defaultBufSize, newStderrLoggerSet)
import Text.Read (readMaybe)

globalRuntimeVar :: MVar (Maybe ObservabilityRuntime)
globalRuntimeVar = unsafePerformIO (newMVar Nothing)
{-# NOINLINE globalRuntimeVar #-}

currentRuntime :: IO (Maybe ObservabilityRuntime)
currentRuntime = readMVar globalRuntimeVar

installGlobalObservabilityRuntime :: ObservabilityRuntime -> IO ()
installGlobalObservabilityRuntime runtime =
  modifyMVar_ globalRuntimeVar $ \current ->
    case current of
      Nothing -> pure (Just runtime)
      Just _existing -> do
        hPutStrLn stderr "observability: global runtime already installed, ignoring"
        pure current

resetGlobalObservabilityRuntime :: IO ()
resetGlobalObservabilityRuntime =
  modifyMVar_ globalRuntimeVar (const (pure Nothing))

loadObservabilityConfig :: ObservabilityEnvConfig -> Text -> IO ObservabilityConfig
loadObservabilityConfig envCfg service = do
  maybeEnvironment <- lookupEnv envCfg.envEnvironment
  maybeDeployment <- lookupEnv envCfg.envDeployment
  maybeHost <- lookupEnv "HOSTNAME"
  maybeStateDir <- lookupEnv envCfg.envStateDir
  maybeVersion <- lookupEnv envCfg.envVersion
  maybeLogLevel <- lookupEnv envCfg.envLogLevel
  maybeMaxStateFileBytes <- lookupEnv envCfg.envMaxFileBytes
  maybeMaxStateFiles <- lookupEnv envCfg.envMaxFiles
  pure
    ObservabilityConfig
      { serviceName = service,
        environment = maybe "local" T.pack maybeEnvironment,
        deployment = T.pack <$> maybeDeployment,
        host = T.pack <$> maybeHost,
        version = maybe "dev" T.pack maybeVersion,
        minLogLevel = maybe ObsInfo (parseLogLevel . T.pack) maybeLogLevel,
        stateDir = fromMaybe ".portman" maybeStateDir,
        maxStateFileBytes =
          maybe defaultMaxStateFileBytes (max 1024) (maybeMaxStateFileBytes >>= readMaybe),
        maxStateFiles =
          maybe defaultMaxStateFiles (max 1) (maybeMaxStateFiles >>= readMaybe)
      }

initObservabilityRuntime :: ObservabilityConfig -> IO ObservabilityRuntime
initObservabilityRuntime cfg = do
  createDirectoryIfMissing True (serviceStateDir cfg)
  logger <- newStderrLoggerSet defaultBufSize
  lock <- newMVar ()
  contexts <- newTVarIO Map.empty
  pure
    ObservabilityRuntime
      { config = cfg,
        loggerSet = logger,
        writeLock = lock,
        threadContexts = contexts
      }

debugEnabled :: ObservabilityRuntime -> Bool
debugEnabled runtime = runtime.config.minLogLevel == ObsDebug

stateLogFile :: ObservabilityRuntime -> FilePath
stateLogFile runtime = serviceStateDir runtime.config </> "events.ndjson"

stateTraceFile :: ObservabilityRuntime -> FilePath
stateTraceFile runtime = serviceStateDir runtime.config </> "traces.ndjson"

serviceStateDir :: ObservabilityConfig -> FilePath
serviceStateDir cfg =
  cfg.stateDir </> "observability" </> T.unpack cfg.serviceName

defaultMaxStateFileBytes :: Integer
defaultMaxStateFileBytes = 4 * 1024 * 1024

defaultMaxStateFiles :: Int
defaultMaxStateFiles = 4
