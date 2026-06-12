{- |
Module      : Cortex.Pulse.Health
Description : Pulse health endpoint: minimal Warp server exposing runtime state.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Health
  ( PulseHealthState (..)
  , initialHealthState
  , runHealthServer
  )
where

import Control.Concurrent.STM (TVar, readTVarIO)
import Data.Aeson (ToJSON, encode)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Network.HTTP.Types (status200, status404)
import Network.Wai (Application, pathInfo, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp

-- | Mutable health state updated by the scheduler and startup recovery.
data PulseHealthState = PulseHealthState
  { phsStatus :: Text
  , phsLeaseOwner :: Text
  , phsHeartbeatAt :: Maybe UTCTime
  , phsReclaimedRunCount :: Int
  , phsExpiredRecoveryCount :: Int
  , phsActiveRunCount :: Int
  , phsMaxConcurrent :: Int
  , phsActiveRunsByType :: Map Text Int
  , phsPendingRunCount :: Int
  -- ^ Runnable-but-unclaimed runs at the last poll tick.
  , phsOldestPendingAgeSeconds :: Maybe Double
  {- ^ Queue age of the oldest pending run — the starvation indicator: a
  saturated pool with this climbing means queued work is not progressing.
  -}
  , phsWaitingRunCount :: Int
  -- ^ Runs parked on signals (not occupying slots).
  }
  deriving stock (Show, Generic)
  deriving anyclass (ToJSON)

initialHealthState :: Text -> Int -> PulseHealthState
initialHealthState leaseOwner maxConcurrent =
  PulseHealthState
    { phsStatus = "starting"
    , phsLeaseOwner = leaseOwner
    , phsHeartbeatAt = Nothing
    , phsReclaimedRunCount = 0
    , phsExpiredRecoveryCount = 0
    , phsActiveRunCount = 0
    , phsMaxConcurrent = maxConcurrent
    , phsActiveRunsByType = Map.empty
    , phsPendingRunCount = 0
    , phsOldestPendingAgeSeconds = Nothing
    , phsWaitingRunCount = 0
    }

-- | Run the health server on the given port, bound to localhost only.
runHealthServer :: Int -> TVar PulseHealthState -> IO ()
runHealthServer port stateVar =
  Warp.runSettings settings (healthApp stateVar)
  where
    settings =
      Warp.setPort port $
        Warp.setHost "127.0.0.1" Warp.defaultSettings

healthApp :: TVar PulseHealthState -> Application
healthApp stateVar request respond = do
  case pathInfo request of
    ["pulse", "v1", "health"] -> do
      state <- readTVarIO stateVar
      let body = encode state
      respond $ responseLBS status200 [("Content-Type", "application/json")] body
    _ ->
      respond $ responseLBS status404 [("Content-Type", "text/plain")] "Not Found"
