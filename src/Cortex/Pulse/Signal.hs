{- | Durable signal types for Pulse external event primitives.

A signal is a named, durably-stored event that a running stage can wait on.
When a stage suspends on a signal, the executor persists the wait and
transitions the run to 'waiting'. When the signal is delivered (via admin
API or internal event), the run is woken and resumes from the waiting node.
-}
module Cortex.Pulse.Signal
  ( -- * Signal identity
    SignalName (..)

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
import Data.Time (UTCTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)

-- | Named signal identifier. Scoped to a run.
newtype SignalName = SignalName {unSignalName :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

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
