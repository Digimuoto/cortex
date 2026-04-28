module Cortex.Pulse.Node
  ( NodeId (..)
  )
where

import Data.Aeson (FromJSON, FromJSONKey, ToJSON, ToJSONKey)
import Data.Text (Text)
import GHC.Generics (Generic)

{- | Serialized node identifier for durable runtime persistence.

At plan-definition time, workflow plans use typed stage IDs. Pulse lowers
those into 'NodeId' values for JSON serialization, database storage, and
rewrite namespacing.
-}
newtype NodeId = NodeId {unNodeId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey)
