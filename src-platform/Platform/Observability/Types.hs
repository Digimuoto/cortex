{- |
Module      : Platform.Observability.Types
Description : Platform runtime support for types.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Platform modules provide generic runtime substrate utilities and do not import Cortex or consumers.
-}
module Platform.Observability.Types
  ( -- * Public API (re-exported by Platform.Observability)
    ObservabilityLogLevel (..)
  , PreviewVisibility (..)
  , ObservabilityConfig (..)
  , ObservabilityContext (..)
  , ObservabilityQuery (..)
  , TraceQuery (..)
  , LogEventSpec (..)
  , SpanSpec (..)
  , SpanOutcomeSpec (..)
  , ObservabilityRuntime (..)
  , defaultLogEvent
  , defaultSpanSpec
  , ObservabilityEnvConfig (..)
  , defaultPortmanEnvConfig

    -- * Internal (used by sibling modules)
  , renderLevel
  , parseLogLevel
  , renderPreviewVisibility
  )
where

import Control.Concurrent (ThreadId)
import Control.Concurrent.MVar (MVar)
import Control.Concurrent.STM (TVar)
import Data.Aeson (FromJSON (..), ToJSON (..), Value)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import System.Log.FastLogger (LoggerSet)

data ObservabilityLogLevel
  = ObsDebug
  | ObsInfo
  | ObsWarn
  | ObsError
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PreviewVisibility
  = PreviewUserSafe
  | PreviewAdminOnly
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data ObservabilityConfig = ObservabilityConfig
  { serviceName :: !Text
  , environment :: !Text
  , deployment :: !(Maybe Text)
  , host :: !(Maybe Text)
  , version :: !Text
  , minLogLevel :: !ObservabilityLogLevel
  , stateDir :: !FilePath
  , maxStateFileBytes :: !Integer
  , maxStateFiles :: !Int
  }
  deriving stock (Eq, Show, Generic)

data ObservabilityContext = ObservabilityContext
  { requestId :: !(Maybe Text)
  , upstreamRequestId :: !(Maybe Text)
  , traceId :: !Text
  , spanId :: !Text
  , runId :: !(Maybe Text)
  , userId :: !(Maybe Text)
  , accountId :: !(Maybe Text)
  , assetId :: !(Maybe Text)
  , provider :: !(Maybe Text)
  , httpMethod :: !(Maybe Text)
  , route :: !(Maybe Text)
  , operation :: !(Maybe Text)
  , stage :: !(Maybe Text)
  , toolName :: !(Maybe Text)
  , assistantPhase :: !(Maybe Text)
  , model :: !(Maybe Text)
  , stepIndex :: !(Maybe Int)
  , linkedTraceId :: !(Maybe Text)
  , linkedRequestId :: !(Maybe Text)
  , linkedSpanId :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

data ObservabilityQuery = ObservabilityQuery
  { queryService :: !(Maybe Text)
  , queryRequestId :: !(Maybe Text)
  , queryTraceId :: !(Maybe Text)
  , queryRunId :: !(Maybe Text)
  , queryAccountId :: !(Maybe Text)
  , queryUserId :: !(Maybe Text)
  , queryProvider :: !(Maybe Text)
  , queryLevel :: !(Maybe Text)
  , queryOperation :: !(Maybe Text)
  , queryRoute :: !(Maybe Text)
  , queryToolName :: !(Maybe Text)
  , queryAssistantPhase :: !(Maybe Text)
  , queryStage :: !(Maybe Text)
  , queryErrorType :: !(Maybe Text)
  , querySince :: !(Maybe UTCTime)
  , queryUntil :: !(Maybe UTCTime)
  , queryLimit :: !Int
  }
  deriving stock (Eq, Show, Generic)

data TraceQuery = TraceQuery
  { traceQueryService :: !(Maybe Text)
  , traceQueryTraceId :: !(Maybe Text)
  , traceQueryRunId :: !(Maybe Text)
  , traceQueryRequestId :: !(Maybe Text)
  , traceQuerySince :: !(Maybe UTCTime)
  , traceQueryUntil :: !(Maybe UTCTime)
  , traceQueryLimit :: !Int
  }
  deriving stock (Eq, Show, Generic)

data LogEventSpec = LogEventSpec
  { eventLevel :: !ObservabilityLogLevel
  , eventComponent :: !Text
  , eventOperation :: !Text
  , eventMessage :: !Text
  , eventOutcome :: !Text
  , eventHttpStatusCode :: !(Maybe Int)
  , eventUpstreamStatusCode :: !(Maybe Int)
  , eventStage :: !(Maybe Text)
  , eventAttempt :: !(Maybe Int)
  , eventModel :: !(Maybe Text)
  , eventInputTokens :: !(Maybe Int)
  , eventOutputTokens :: !(Maybe Int)
  , eventFinishReason :: !(Maybe Text)
  , eventStepIndex :: !(Maybe Int)
  , eventErrorType :: !(Maybe Text)
  , eventErrorCode :: !(Maybe Text)
  , eventRetryable :: !(Maybe Bool)
  , eventDurationMs :: !(Maybe Int)
  , eventToolName :: !(Maybe Text)
  , eventToolCallId :: !(Maybe Text)
  , eventAssistantPhase :: !(Maybe Text)
  , eventProvider :: !(Maybe Text)
  , eventRunId :: !(Maybe Text)
  , eventUserId :: !(Maybe Text)
  , eventAccountId :: !(Maybe Text)
  , eventAssetId :: !(Maybe Text)
  , eventHttpMethod :: !(Maybe Text)
  , eventRoute :: !(Maybe Text)
  , eventPayloadPreviewVisibility :: !(Maybe PreviewVisibility)
  , eventPayloadPreview :: !(Maybe Value)
  , eventExtraFields :: ![(Text, Value)]
  }
  deriving stock (Eq, Show, Generic)

data SpanSpec = SpanSpec
  { spanComponent :: !Text
  , spanOperation :: !Text
  , spanMessage :: !Text
  , spanStage :: !(Maybe Text)
  , spanToolName :: !(Maybe Text)
  , spanAssistantPhase :: !(Maybe Text)
  , spanProvider :: !(Maybe Text)
  , spanModel :: !(Maybe Text)
  , spanStepIndex :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)

data SpanOutcomeSpec = SpanOutcomeSpec
  { spanOutcome :: !Text
  , spanErrorType :: !(Maybe Text)
  , spanErrorMessage :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

data ObservabilityRuntime = ObservabilityRuntime
  { config :: !ObservabilityConfig
  , loggerSet :: !LoggerSet
  , writeLock :: !(MVar ())
  , threadContexts :: !(TVar (Map ThreadId ObservabilityContext))
  }

{- | Configuration for environment variable names used by the observability runtime.
Different applications can customize which env vars are read.
-}
data ObservabilityEnvConfig = ObservabilityEnvConfig
  { envEnvironment :: !String
  , envDeployment :: !String
  , envStateDir :: !String
  , envVersion :: !String
  , envLogLevel :: !String
  , envMaxFileBytes :: !String
  , envMaxFiles :: !String
  }
  deriving stock (Eq, Show)

-- | Default env var names used by Portman applications.
defaultPortmanEnvConfig :: ObservabilityEnvConfig
defaultPortmanEnvConfig =
  ObservabilityEnvConfig
    { envEnvironment = "PORTMAN_ENVIRONMENT"
    , envDeployment = "PORTMAN_DEPLOYMENT"
    , envStateDir = "PORTFOLIO_STATE_DIR"
    , envVersion = "PORTMAN_VERSION"
    , envLogLevel = "PORTFOLIO_LOG_LEVEL"
    , envMaxFileBytes = "PORTMAN_OBSERVABILITY_MAX_FILE_BYTES"
    , envMaxFiles = "PORTMAN_OBSERVABILITY_MAX_FILES"
    }

defaultLogEvent :: ObservabilityLogLevel -> Text -> Text -> Text -> LogEventSpec
defaultLogEvent level component operation message =
  LogEventSpec
    { eventLevel = level
    , eventComponent = component
    , eventOperation = operation
    , eventMessage = message
    , eventOutcome = "success"
    , eventHttpStatusCode = Nothing
    , eventUpstreamStatusCode = Nothing
    , eventStage = Nothing
    , eventAttempt = Nothing
    , eventModel = Nothing
    , eventInputTokens = Nothing
    , eventOutputTokens = Nothing
    , eventFinishReason = Nothing
    , eventStepIndex = Nothing
    , eventErrorType = Nothing
    , eventErrorCode = Nothing
    , eventRetryable = Nothing
    , eventDurationMs = Nothing
    , eventToolName = Nothing
    , eventToolCallId = Nothing
    , eventAssistantPhase = Nothing
    , eventProvider = Nothing
    , eventRunId = Nothing
    , eventUserId = Nothing
    , eventAccountId = Nothing
    , eventAssetId = Nothing
    , eventHttpMethod = Nothing
    , eventRoute = Nothing
    , eventPayloadPreviewVisibility = Nothing
    , eventPayloadPreview = Nothing
    , eventExtraFields = []
    }

defaultSpanSpec :: Text -> Text -> Text -> SpanSpec
defaultSpanSpec component operation message =
  SpanSpec
    { spanComponent = component
    , spanOperation = operation
    , spanMessage = message
    , spanStage = Nothing
    , spanToolName = Nothing
    , spanAssistantPhase = Nothing
    , spanProvider = Nothing
    , spanModel = Nothing
    , spanStepIndex = Nothing
    }

renderLevel :: ObservabilityLogLevel -> Text
renderLevel = \case
  ObsDebug -> "debug"
  ObsInfo -> "info"
  ObsWarn -> "warn"
  ObsError -> "error"

parseLogLevel :: Text -> ObservabilityLogLevel
parseLogLevel raw =
  case T.toLower raw of
    "debug" -> ObsDebug
    "info" -> ObsInfo
    "warning" -> ObsWarn
    "warn" -> ObsWarn
    "error" -> ObsError
    _ -> ObsInfo

renderPreviewVisibility :: PreviewVisibility -> Text
renderPreviewVisibility = \case
  PreviewUserSafe -> "user_safe"
  PreviewAdminOnly -> "admin_only"
