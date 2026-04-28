-- | Pulse health endpoint: minimal Warp server exposing runtime state.
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
