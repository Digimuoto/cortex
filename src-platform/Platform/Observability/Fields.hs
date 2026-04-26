{-# LANGUAGE DerivingStrategies #-}

-- |
-- Module      : Platform.Observability.Fields
-- Description : Typed event codes and safe field builders for observability
--
-- Provides a type-safe layer over the raw 'LogEventSpec' interface:
--
-- * 'ObsEventCode' wraps a dot-separated event code string
-- * 'ObsFields' wraps extra fields with a builder API
-- * 'field' constructs individual fields without raw tuple syntax
-- * 'fields' combines multiple fields
--
-- Domain-specific event code values (e.g. Pulse executor codes) are defined
-- in their respective downstream modules, not here.
module Platform.Observability.Fields
  ( -- * Typed event code
    ObsEventCode (..),

    -- * Safe field builders
    ObsFields (..),
    field,
    fields,
    noFields,
    toFieldList,

    -- * Typed event typeclass
    ToObsEvent (..),
  )
where

import Data.Aeson (ToJSON, Value)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Platform.Observability.Types (ObservabilityLogLevel)

-- | A dot-separated event code string identifying an observability event.
-- Downstream modules define their own code values as 'ObsEventCode' constants.
newtype ObsEventCode = ObsEventCode {unObsEventCode :: Text}
  deriving stock (Eq, Show)

-- | Safe extra-field accumulator with Monoid instance for composition.
--
-- @
-- field "run_id" runId <> field "stage" stageName <> field "attempt" attempt
-- @
newtype ObsFields = ObsFields {unObsFields :: [(Text, Value)]}
  deriving stock (Eq, Show)

instance Semigroup ObsFields where
  ObsFields a <> ObsFields b = ObsFields (a <> b)

instance Monoid ObsFields where
  mempty = ObsFields []

-- | Construct a single observation field.
--
-- @
-- field "run_id" runId    -- instead of ("run_id", Aeson.toJSON runId)
-- @
field :: (ToJSON a) => Text -> a -> ObsFields
field key value = ObsFields [(key, Aeson.toJSON value)]

-- | Construct multiple fields from a list of pairs.
fields :: [(Text, Value)] -> ObsFields
fields = ObsFields

-- | Empty fields.
noFields :: ObsFields
noFields = mempty

-- | Extract the raw field list for passing to 'LogEventSpec'.
toFieldList :: ObsFields -> [(Text, Value)]
toFieldList = unObsFields

-- ============================================================================
-- Typed event typeclass
-- ============================================================================

-- | Typeclass for values that can be emitted as observability events.
-- Implement this for domain-specific event ADTs to get type-safe emission.
--
-- @
-- data ExecutorEvent = StageCompleted { ... } | StageFailed { ... }
--
-- instance ToObsEvent ExecutorEvent where
--   obsLevel (StageCompleted _) = ObsInfo
--   obsLevel (StageFailed _)    = ObsError
--   obsCode  (StageCompleted _) = ObsEventCode "pulse.executor.stage.completed"
--   obsCode  (StageFailed _)    = ObsEventCode "pulse.executor.stage.failed"
--   ...
--
-- emitObsEvent (StageCompleted env stageName)
-- @
class ToObsEvent a where
  -- | The severity level of this event.
  obsLevel :: a -> ObservabilityLogLevel

  -- | The typed event code.
  obsCode :: a -> ObsEventCode

  -- | The component that emitted this event (e.g., "cortex-pulse").
  obsComponent :: a -> Text

  -- | Human-readable message describing what happened.
  obsMessage :: a -> Text

  -- | Structured extra fields for this event.
  obsFields :: a -> ObsFields
