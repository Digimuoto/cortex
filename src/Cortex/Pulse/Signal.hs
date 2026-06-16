{- |
Module      : Cortex.Pulse.Signal
Description : Durable signal types for Pulse external event primitives.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

A signal is a named, durably-stored event that a running stage can wait on.
When a stage suspends on a signal, the executor persists the wait and
transitions the run to 'waiting'. When the signal is delivered (via admin
API or internal event), the run is woken and resumes from the waiting node.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
module Cortex.Pulse.Signal
  ( -- * Signal identity
    SignalName (..)
  , runTerminalSignalName
  , parseRunTerminalSignal

    -- * Signal records
  , SignalWait (..)
  , SignalDelivery (..)
  , SignalStatus (..)
  , signalStatusToText
  , signalStatusFromText
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import GHC.Generics (Generic)

-- | Named signal identifier. Scoped to a run.
newtype SignalName = SignalName {unSignalName :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

{- | The signal the runtime delivers when the named run reaches a terminal
status (completed, failed, cancelled, or timeout). A run that needs to await
another run suspends on this name instead of polling; an already-terminal
target resolves the wait at registration time, so the waiter never parks.
-}
runTerminalSignalName :: UUID -> SignalName
runTerminalSignalName runId =
  SignalName ("run-terminal:" <> UUID.toText runId)

-- | Recognize a run-terminal signal name and recover the awaited run id.
parseRunTerminalSignal :: SignalName -> Maybe UUID
parseRunTerminalSignal (SignalName name) =
  T.stripPrefix "run-terminal:" name >>= UUID.fromText

-- | A pending signal wait registered by a stage.
data SignalWait = SignalWait
  { swRunId :: UUID
  , swNodeId :: Text
  , swSignalName :: SignalName
  , swCreatedAt :: UTCTime
  , swExpiresAt :: Maybe UTCTime
  }
  deriving stock (Eq, Show, Generic)

-- | A delivered signal with payload.
data SignalDelivery = SignalDelivery
  { sdRunId :: UUID
  , sdSignalName :: SignalName
  , sdPayload :: Aeson.Value
  , sdDeliveredAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)

-- | Status of a signal record.
data SignalStatus
  = SignalPending
  | SignalDelivered
  | SignalExpired
  deriving stock (Eq, Ord, Show, Bounded, Enum, Generic)

signalStatusToText :: SignalStatus -> Text
signalStatusToText = \case
  SignalPending -> "pending"
  SignalDelivered -> "delivered"
  SignalExpired -> "expired"

signalStatusFromText :: Text -> Maybe SignalStatus
signalStatusFromText = \case
  "pending" -> Just SignalPending
  "delivered" -> Just SignalDelivered
  "expired" -> Just SignalExpired
  _ -> Nothing
