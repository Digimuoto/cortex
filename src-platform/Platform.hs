{- | Supported Platform import surface for downstream consumers.

Downstream products should prefer @import Platform@ for the stable runtime
utility API. Area modules remain available for advanced use, but this module
is the boundary that accumulates public compatibility promises.
-}
module Platform
  ( module Platform.Config
  , module Platform.Crypto
  , module Platform.Database
  , module Platform.Database.Encode
  , module Platform.Database.Rel8TH
  , module Platform.DurableTask.Checkpoint
  , module Platform.DurableTask.Cron
  , module Platform.DurableTask.Error
  , module Platform.DurableTask.Polling
  , module Platform.DurableTask.Pool
  , module Platform.DurableTask.Schedule
  , module Platform.DurableTask.Types
  , module Platform.DurableTask.Workflow
  , module Platform.Error
  , module Platform.Error.Servant
  , module Platform.HTTP.Retry
  , module Platform.Observability
  , module Platform.Patch
  , module Platform.Require
  , module Platform.Serde
  , module Platform.Text
  )
where

import Platform.Config
import Platform.Crypto
import Platform.Database
import Platform.Database.Encode
import Platform.Database.Rel8TH
import Platform.DurableTask.Checkpoint
import Platform.DurableTask.Cron
import Platform.DurableTask.Error
import Platform.DurableTask.Polling
import Platform.DurableTask.Pool
import Platform.DurableTask.Schedule
import Platform.DurableTask.Types
import Platform.DurableTask.Workflow
import Platform.Error
import Platform.Error.Servant
import Platform.HTTP.Retry
import Platform.Observability
import Platform.Patch
import Platform.Require
import Platform.Serde
import Platform.Text
