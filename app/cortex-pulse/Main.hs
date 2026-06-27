{- |
Module      : Main
Description : Command-line entry point for the Cortex Pulse substrate shell.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The executable is a substrate shell with an empty task registry; consumers link their own registry
in separate binaries.
-}
module Main (main) where

import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word16)
import Options.Applicative
import System.Environment (setEnv)

import Cortex.Pulse (runPulse)
import Cortex.Pulse.Types (PulseConfig (..))

main :: IO ()
main = do
  args <- execParser opts
  maybe (pure ()) (setEnv "CORTEX_WORKFLOW_DIR") (paWorkflowDir args)
  -- Load secrets from files
  password <-
    if null (paDbPasswordFile args)
      then pure T.empty
      else T.strip <$> TIO.readFile (paDbPasswordFile args)
  jwtSecret <- readRequiredSecretFile "--jwt-secret-file" (paJwtSecretFile args)
  adminApiKey <-
    if null (paAdminApiKeyFile args)
      then pure Nothing
      else Just . T.strip <$> TIO.readFile (paAdminApiKeyFile args)
  serviceCredential <-
    if null (paServiceCredentialFile args)
      then pure Nothing
      else Just . T.strip <$> TIO.readFile (paServiceCredentialFile args)

  let config =
        PulseConfig
          { pulseDbHost = paDbHost args
          , pulseDbPort = paDbPort args
          , pulseDbUser = paDbUser args
          , pulseDbPassword = password
          , pulseDbName = paDbName args
          , pulseDbPoolSize = paDbPoolSize args
          , pulseApiUrl = paApiUrl args
          , pulseJwtSecret = jwtSecret
          , pulseJwtExpirationSeconds = paJwtExpiration args
          , pulseJwtIssuer = paJwtIssuer args
          , pulseJwtAudience = paJwtAudience args
          , pulseAdminApiKey = adminApiKey
          , pulseServiceCredential = serviceCredential
          , pulseHealthPort = paHealthPort args
          , pulseLeaseOwner = paLeaseOwner args
          , pulseLeaseDurationSeconds = paLeaseDuration args
          , pulsePollIntervalSeconds = paPollInterval args
          , pulseMaxConcurrentTasks = paMaxConcurrentTasks args
          , pulseMaxFrontierConcurrency = paMaxFrontierConcurrency args
          , pulseTaskTypeLimits = Map.fromList (paTaskTypeLimits args)
          }
  -- Substrate shell: empty task registry. Consumers
  -- build their own binary that imports Cortex.Pulse and passes a
  -- populated registry. Per ADR 0002 (and Architecture ch.02) the runtime
  -- never imports reasoning-layer or consumer-specific task definitions.
  runPulse Map.empty config

readRequiredSecretFile :: String -> FilePath -> IO T.Text
readRequiredSecretFile flagName path
  | null path =
      ioError . userError $
        "Missing required " <> flagName <> ". Pulse must be able to mint runner tokens."
  | otherwise = do
      secret <- T.strip <$> TIO.readFile path
      if T.null secret
        then
          ioError . userError $
            "Secret file for " <> flagName <> " is empty."
        else pure secret

data PulseArgs = PulseArgs
  { paDbHost :: T.Text
  , paWorkflowDir :: Maybe FilePath
  , paDbPort :: Word16
  , paDbUser :: T.Text
  , paDbName :: T.Text
  , paDbPoolSize :: Int
  , paDbPasswordFile :: FilePath
  , paApiUrl :: T.Text
  , paJwtSecretFile :: FilePath
  , paJwtExpiration :: Int64
  , paJwtIssuer :: T.Text
  , paJwtAudience :: T.Text
  , paAdminApiKeyFile :: FilePath
  , paServiceCredentialFile :: FilePath
  , paHealthPort :: Int
  , paLeaseOwner :: T.Text
  , paLeaseDuration :: Int
  , paPollInterval :: Int
  , paMaxConcurrentTasks :: Int
  , paMaxFrontierConcurrency :: Int
  , paTaskTypeLimits :: [(T.Text, Int)]
  }

opts :: ParserInfo PulseArgs
opts =
  info
    (pulseArgsParser <**> helper)
    ( fullDesc
        <> progDesc "Cortex Pulse - durable graph execution runtime"
        <> header "cortex-pulse"
    )

pulseArgsParser :: Parser PulseArgs
pulseArgsParser =
  PulseArgs
    <$> fmap
      T.pack
      ( strOption
          ( long "db-host"
              <> value "localhost"
              <> metavar "HOST"
              <> help "Database host"
          )
      )
    <*> optional
      ( strOption
          ( long "workflow-dir"
              <> metavar "DIR"
              <> help "Directory containing hot-loadable .cr workflows. Sets CORTEX_WORKFLOW_DIR for this process."
          )
      )
    <*> option
      auto
      ( long "db-port"
          <> value 5432
          <> metavar "PORT"
          <> help "Database port"
      )
    <*> fmap
      T.pack
      ( strOption
          ( long "db-user"
              <> value "cortex"
              <> metavar "USER"
              <> help "Database user"
          )
      )
    <*> fmap
      T.pack
      ( strOption
          ( long "db-name"
              <> value "cortex"
              <> metavar "NAME"
              <> help "Database name"
          )
      )
    <*> option
      auto
      ( long "db-pool-size"
          <> value 5
          <> metavar "N"
          <> help "Database connection pool size"
      )
    <*> strOption
      ( long "db-password-file"
          <> value ""
          <> metavar "FILE"
          <> help "Path to database password file"
      )
    <*> fmap
      T.pack
      ( strOption
          ( long "api-url"
              <> value "http://127.0.0.1:8080"
              <> metavar "URL"
              <> help "Base host API URL used by Pulse task runners"
          )
      )
    <*> strOption
      ( long "jwt-secret-file"
          <> value ""
          <> metavar "FILE"
          <> help "Path to the JWT signing secret file used to mint runner tokens"
      )
    <*> option
      auto
      ( long "jwt-expiration"
          <> value 86400
          <> metavar "SECONDS"
          <> help "JWT token expiration in seconds"
      )
    <*> fmap
      T.pack
      ( strOption
          ( long "jwt-issuer"
              <> value "cortex-pulse"
              <> metavar "ISSUER"
              <> help "JWT issuer claim"
          )
      )
    <*> fmap
      T.pack
      ( strOption
          ( long "jwt-audience"
              <> value "cortex-host"
              <> metavar "AUDIENCE"
              <> help "JWT audience claim"
          )
      )
    <*> strOption
      ( long "admin-api-key-file"
          <> value ""
          <> metavar "FILE"
          <> help "Path to the admin API key file (legacy, prefer --service-credential-file)"
      )
    <*> strOption
      ( long "service-credential-file"
          <> value ""
          <> metavar "FILE"
          <> help "Path to the dedicated Pulse service credential file for internal host actions"
      )
    <*> option
      auto
      ( long "health-port"
          <> value 9090
          <> metavar "PORT"
          <> help "Health endpoint port"
      )
    <*> fmap
      T.pack
      ( strOption
          ( long "lease-owner"
              <> value "pulse-primary"
              <> metavar "ID"
              <> help "Stable logical instance ID for lease ownership"
          )
      )
    <*> option
      auto
      ( long "lease-duration"
          <> value 300
          <> metavar "SECONDS"
          <> help "Lease duration in seconds"
      )
    <*> option
      auto
      ( long "poll-interval"
          <> value 5
          <> metavar "SECONDS"
          <> help "Scheduler poll interval in seconds"
      )
    <*> option
      auto
      ( long "max-concurrent-tasks"
          <> value 4
          <> metavar "N"
          <> help "Maximum number of concurrent task executions (default 4)"
      )
    <*> option
      auto
      ( long "max-frontier-concurrency"
          <> value 1
          <> metavar "N"
          <> help "Maximum concurrent nodes within a single run frontier (default 1 = sequential)"
      )
    <*> many
      ( option
          parseTaskTypeLimit
          ( long "task-type-max-concurrent"
              <> metavar "TYPE=N"
              <> help "Per-task-type concurrency limit (e.g. response_eval_run=2). Repeatable."
          )
      )

parseTaskTypeLimit :: ReadM (T.Text, Int)
parseTaskTypeLimit = eitherReader $ \s ->
  case break (== '=') s of
    (_, []) -> Left "Expected TYPE=N format (e.g. response_eval_run=2)"
    (typePart, '=' : nPart) ->
      let taskType = T.strip (T.pack typePart)
          nPartTrimmed = T.unpack (T.strip (T.pack nPart))
       in if T.null taskType
            then Left "Task type must be non-empty in TYPE=N format"
            else case reads nPartTrimmed of
              [(n, "")] | n >= 1 -> Right (taskType, n)
              [(_, "")] -> Left "Concurrency limit must be >= 1"
              _ -> Left ("Invalid number: " <> nPart)
    _ -> Left "Expected TYPE=N format (e.g. response_eval_run=2)"
