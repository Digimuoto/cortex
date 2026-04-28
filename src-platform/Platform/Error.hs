{- |
Module      : Platform.Error
Description : Unified application error handling with safe client messages
Copyright   : (c) 2026
License     : MIT
Maintainer  : julius@koskela.email

Unified error type for the Portman application. This module provides:

- Single source of truth for application errors
- Safe client-facing messages that never leak internal details
- Internal messages for logging with full context
- Log level classification for proper observability
- HTTP status code mapping for API responses

Design principles:
- NEVER expose database errors, stack traces, or internal state to clients
- Log all server errors with full context for debugging
- Client errors (4xx) get informative but safe messages
- Server errors (5xx) get generic "something went wrong" messages
-}
module Platform.Error
  ( -- * Core Types
    AppError (..)
  , ErrorContext (..)
  , LogLevel (..)

    -- * Error Construction
  , dbError
  , validationError
  , validationErrorWithField
  , notFoundError
  , notFoundWithId
  , authError
  , authzError
  , rateLimitError
  , externalError
  , internalError
  , configError

    -- * Error Context
  , withContext
  , addContext

    -- * HTTP Conversion
  , toServantError
  , toStatusCode

    -- * Messages
  , clientMessage
  , internalMessage

    -- * Classification
  , logLevel
  , isRetryable
  , shouldLog

    -- * Handler Utilities
  , throwAppError
  , logError
  )
where

import Control.Monad (when)
import Control.Monad.Error.Class (throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Servant.Server
  ( Handler
  , ServerError (..)
  , err401
  , err403
  , err404
  , err422
  , err429
  , err500
  , err503
  , errBody
  )
import System.IO (hPutStrLn, stderr)

import Platform.Observability
  ( LogEventSpec (..)
  , ObservabilityLogLevel (..)
  , currentRuntime
  , defaultLogEvent
  , emitGlobalEvent
  )

-- | Log levels for error classification
data LogLevel
  = -- | Detailed debugging information
    LogDebug
  | -- | General operational information
    LogInfo
  | -- | Warning conditions that might need attention
    LogWarn
  | -- | Error conditions that need immediate attention
    LogError
  deriving stock (Eq, Ord, Show)

-- | Context information for error reporting (internal use only)
data ErrorContext = ErrorContext
  { contextOperation :: !Text
  -- ^ What operation was being performed
  , contextDetails :: !(Maybe Text)
  -- ^ Additional context details (may contain sensitive info)
  }
  deriving stock (Eq, Show)

{- | Unified application error type

Each error variant contains internal details for logging.
Use 'clientMessage' to get the safe message for API responses.

The constructors use positional arguments to avoid partial record field warnings.
Use the smart constructors ('dbError', 'validationError', etc.) for convenience.
-}
data AppError
  = {- | Database operation failed (NEVER expose to client)
     Args: message, context
    -}
    DatabaseError !Text !(Maybe ErrorContext)
  | {- | Input validation failed (safe to expose field info)
     Args: message, field, context
    -}
    ValidationError !Text !(Maybe Text) !(Maybe ErrorContext)
  | {- | Resource not found (safe to expose resource type)
     Args: resource, identifier, context
    -}
    NotFoundError !Text !(Maybe Text) !(Maybe ErrorContext)
  | {- | Authentication failed (don't leak auth state)
     Args: internal message, context
    -}
    AuthenticationError !Text !(Maybe ErrorContext)
  | {- | Authorization failed (user authenticated but not permitted)
     Args: internal message, context
    -}
    AuthorizationError !Text !(Maybe ErrorContext)
  | {- | Request rejected because caller exceeded an allowed rate
     Args: internal message, context
    -}
    RateLimitError !Text !(Maybe ErrorContext)
  | {- | External service integration error (don't expose service details)
     Args: service name, message, context
    -}
    ExternalServiceError !Text !Text !(Maybe ErrorContext)
  | {- | Configuration error
     Args: message, context
    -}
    ConfigurationError !Text !(Maybe ErrorContext)
  | {- | Internal server error (NEVER expose details to client)
     Args: message, context
    -}
    InternalError !Text !(Maybe ErrorContext)
  deriving stock (Eq, Show)

{- | JSON representation for structured logging (internal use)
This is NOT sent to clients - only used in log aggregation
-}
instance ToJSON AppError where
  toJSON err =
    object
      [ "error_type" .= errorTypeName err
      , "internal_message" .= internalMessage err
      , "client_message" .= clientMessage err
      , "status_code" .= toStatusCode err
      , "log_level" .= show (logLevel err)
      , "retryable" .= isRetryable err
      ]

errorTypeName :: AppError -> Text
errorTypeName DatabaseError {} = "database_error"
errorTypeName ValidationError {} = "validation_error"
errorTypeName NotFoundError {} = "not_found"
errorTypeName AuthenticationError {} = "authentication_error"
errorTypeName AuthorizationError {} = "authorization_error"
errorTypeName RateLimitError {} = "rate_limit"
errorTypeName ExternalServiceError {} = "external_service_error"
errorTypeName ConfigurationError {} = "configuration_error"
errorTypeName InternalError {} = "internal_error"

-- * Error Constructors

-- | Database error - internal details are logged, client sees generic message
dbError :: Text -> AppError
dbError msg = DatabaseError msg Nothing

-- | Validation error - safe to show field and message to client
validationError :: Text -> AppError
validationError msg = ValidationError msg Nothing Nothing

-- | Validation error with specific field
validationErrorWithField :: Text -> Text -> AppError
validationErrorWithField field msg = ValidationError msg (Just field) Nothing

-- | Resource not found - safe to show resource type
notFoundError :: Text -> AppError
notFoundError resource = NotFoundError resource Nothing Nothing

-- | Not found with identifier - be careful with identifier exposure
notFoundWithId :: Text -> Text -> AppError
notFoundWithId resource identifier = NotFoundError resource (Just identifier) Nothing

-- | Authentication error - generic message to avoid leaking auth details
authError :: Text -> AppError
authError msg = AuthenticationError msg Nothing

-- | Authorization error - user is authenticated but not permitted
authzError :: Text -> AppError
authzError msg = AuthorizationError msg Nothing

-- | Rate limit error - safe retry guidance for clients
rateLimitError :: Text -> AppError
rateLimitError msg = RateLimitError msg Nothing

-- | External service error - don't expose which service failed
externalError :: Text -> Text -> AppError
externalError service msg = ExternalServiceError service msg Nothing

-- | Configuration error
configError :: Text -> AppError
configError msg = ConfigurationError msg Nothing

-- | Internal error - never expose details to client
internalError :: Text -> AppError
internalError msg = InternalError msg Nothing

-- * Error Context

-- | Add context to an existing error
withContext :: Text -> Maybe Text -> AppError -> AppError
withContext op details = addContext (ErrorContext op details)

-- | Add context to an error
addContext :: ErrorContext -> AppError -> AppError
addContext ctx (DatabaseError msg _) = DatabaseError msg (Just ctx)
addContext ctx (ValidationError msg field _) = ValidationError msg field (Just ctx)
addContext ctx (NotFoundError resource identifier _) = NotFoundError resource identifier (Just ctx)
addContext ctx (AuthenticationError msg _) = AuthenticationError msg (Just ctx)
addContext ctx (AuthorizationError msg _) = AuthorizationError msg (Just ctx)
addContext ctx (RateLimitError msg _) = RateLimitError msg (Just ctx)
addContext ctx (ExternalServiceError service msg _) = ExternalServiceError service msg (Just ctx)
addContext ctx (ConfigurationError msg _) = ConfigurationError msg (Just ctx)
addContext ctx (InternalError msg _) = InternalError msg (Just ctx)

-- * Client-Safe Messages

{- | Get a SAFE message to send to the client

This function ensures no internal details, database errors,
stack traces, or sensitive information leaks to the client.
-}
clientMessage :: AppError -> Text
clientMessage (DatabaseError _ _) =
  -- NEVER expose database errors
  "A database error occurred. Please try again later."
clientMessage (ValidationError msg field _) =
  -- Validation errors are safe to expose
  case field of
    Nothing -> msg
    Just f -> f <> ": " <> msg
clientMessage (NotFoundError resource mId _) =
  -- Resource type is safe, but be careful with identifiers
  case mId of
    Nothing -> resource <> " not found"
    Just i -> resource <> " not found: " <> i
clientMessage (AuthenticationError _ _) =
  -- Generic auth message to avoid leaking auth state
  "Authentication failed. Please check your credentials."
clientMessage (AuthorizationError _ _) =
  -- Don't reveal what they tried to access
  "You don't have permission to perform this action."
clientMessage (RateLimitError msg _) = msg
clientMessage (ExternalServiceError service msg _) =
  fromMaybe
    "An external service is temporarily unavailable. Please try again later."
    (safeExternalClientMessage service msg)
clientMessage (ConfigurationError _ _) =
  -- Don't expose configuration details
  "A configuration error occurred. Please contact support."
clientMessage (InternalError _ _) =
  -- NEVER expose internal errors
  "An unexpected error occurred. Please try again later."

safeExternalClientMessage :: Text -> Text -> Maybe Text
safeExternalClientMessage service msg
  | service /= "OpenRouter" = Nothing
  | otherwise =
      if isSafeOpenRouterClientMessage msg
        then Just msg
        else Nothing

isSafeOpenRouterClientMessage :: Text -> Bool
isSafeOpenRouterClientMessage msg =
  any (`T.isInfixOf` normalizedMsg) safeFragments
  where
    normalizedMsg = T.toLower msg
    safeFragments =
      [ "phase timed out after "
      , "phase failed because the provider rejected the structured-output schema."
      , "phase failed after network retries."
      , "phase failed with upstream http "
      , "phase returned an unreadable completion response."
      , "phase returned no completion choices."
      , "phase failed because the provider rejected the request payload."
      ]

{- | Get the full internal message for logging

This contains all details and should ONLY be written to logs,
NEVER sent to clients.
-}
internalMessage :: AppError -> Text
internalMessage (DatabaseError msg ctx) =
  formatWithContext "DatabaseError" msg ctx
internalMessage (ValidationError msg field ctx) =
  let fieldStr = maybe "" (\f -> " [field=" <> f <> "]") field
   in formatWithContext "ValidationError" (msg <> fieldStr) ctx
internalMessage (NotFoundError resource mId ctx) =
  let idStr = maybe "" (\i -> " (id=" <> i <> ")") mId
   in formatWithContext "NotFoundError" (resource <> idStr) ctx
internalMessage (AuthenticationError msg ctx) =
  formatWithContext "AuthenticationError" msg ctx
internalMessage (AuthorizationError msg ctx) =
  formatWithContext "AuthorizationError" msg ctx
internalMessage (RateLimitError msg ctx) =
  formatWithContext "RateLimitError" msg ctx
internalMessage (ExternalServiceError service msg ctx) =
  formatWithContext "ExternalServiceError" (service <> ": " <> msg) ctx
internalMessage (ConfigurationError msg ctx) =
  formatWithContext "ConfigurationError" msg ctx
internalMessage (InternalError msg ctx) =
  formatWithContext "InternalError" msg ctx

formatWithContext :: Text -> Text -> Maybe ErrorContext -> Text
formatWithContext errType msg Nothing = "[" <> errType <> "] " <> msg
formatWithContext errType msg (Just ctx) =
  let details = maybe "" (\d -> " (" <> d <> ")") (contextDetails ctx)
   in "[" <> errType <> "] " <> contextOperation ctx <> details <> ": " <> msg

-- * HTTP Conversion

{- | Convert AppError to Servant ServerError

Uses 'clientMessage' to ensure safe error bodies
-}
toServantError :: AppError -> ServerError
toServantError err =
  let statusErr = case err of
        DatabaseError {} -> err500
        ValidationError {} -> err422
        NotFoundError {} -> err404
        AuthenticationError {} -> err401
        AuthorizationError {} -> err403
        RateLimitError {} -> err429
        ExternalServiceError {} -> err503
        ConfigurationError {} -> err500
        InternalError {} -> err500
      safeMsg = clientMessage err
   in statusErr {errBody = BSL.fromStrict (TE.encodeUtf8 safeMsg)}

-- | Get HTTP status code for error
toStatusCode :: AppError -> Int
toStatusCode DatabaseError {} = 500
toStatusCode ValidationError {} = 422
toStatusCode NotFoundError {} = 404
toStatusCode AuthenticationError {} = 401
toStatusCode AuthorizationError {} = 403
toStatusCode RateLimitError {} = 429
toStatusCode ExternalServiceError {} = 503
toStatusCode ConfigurationError {} = 500
toStatusCode InternalError {} = 500

-- * Error Classification

-- | Determine the appropriate log level for an error
logLevel :: AppError -> LogLevel
logLevel ValidationError {} = LogDebug -- Client errors, low priority
logLevel NotFoundError {} = LogDebug -- Expected errors
logLevel AuthenticationError {} = LogInfo -- Track auth failures
logLevel AuthorizationError {} = LogWarn -- May indicate attack
logLevel RateLimitError {} = LogWarn -- Caller exceeded expected limits
logLevel ExternalServiceError {} = LogWarn -- External dep issues
logLevel ConfigurationError {} = LogError -- Config problems are serious
logLevel DatabaseError {} = LogError -- DB issues need attention
logLevel InternalError {} = LogError -- Unexpected errors

-- | Determine if an error is retryable
isRetryable :: AppError -> Bool
isRetryable ExternalServiceError {} = True
isRetryable DatabaseError {} = True -- May be transient connection issue
isRetryable _ = False

-- | Determine if an error should be logged at all
shouldLog :: AppError -> Bool
shouldLog ValidationError {} = False -- Too noisy
shouldLog NotFoundError {} = False -- Expected behavior
shouldLog _ = True

-- * Handler Utilities

-- | Log an error with timestamp and level (for use outside handlers)
logError :: MonadIO m => AppError -> m ()
logError err = liftIO $ do
  maybeRuntime <- currentRuntime
  case maybeRuntime of
    Just _runtime ->
      emitGlobalEvent $
        (defaultLogEvent (observabilityLevel (logLevel err)) "app_error" "app.error" (internalMessage err))
          { eventOutcome = "error"
          , eventErrorType = Just (errorTypeName err)
          , eventRetryable = Just (isRetryable err)
          , eventHttpStatusCode = Just (toStatusCode err)
          }
    Nothing -> do
      timestamp <- getCurrentTime
      let levelStr = case logLevel err of
            LogDebug -> "DEBUG"
            LogInfo -> "INFO"
            LogWarn -> "WARN"
            LogError -> "ERROR"
          msg = internalMessage err
      hPutStrLn stderr $
        "["
          <> iso8601Show timestamp
          <> "] "
          <> levelStr
          <> " "
          <> T.unpack msg

{- | Throw an AppError as a Servant Handler error

- Logs server errors with full internal details
- Sends ONLY the safe client message in the HTTP response
-}
throwAppError :: AppError -> Handler a
throwAppError err = do
  when (shouldLog err) $ logError err
  throwError (toServantError err)

observabilityLevel :: LogLevel -> ObservabilityLogLevel
observabilityLevel LogDebug = ObsDebug
observabilityLevel LogInfo = ObsInfo
observabilityLevel LogWarn = ObsWarn
observabilityLevel LogError = ObsError
