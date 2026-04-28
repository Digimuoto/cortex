{- |
Module      : Cortex.Pulse.Node
Description : Pulse runtime support for node.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Pulse modules implement durable runtime mechanics without binding consumer task registries.
-}
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
