{- |
Module      : Platform.Observability.Emit
Description : Platform runtime support for emit.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Platform modules provide generic runtime substrate utilities and do not import Cortex or consumers.
-}
module Platform.Observability.Emit
  ( -- * Public API (re-exported by Platform.Observability)
    emitEvent
  , emitGlobalEvent
  , emitObsEvent
  , withSpanIO
  , withSpanOutcomeIO
  , SubsystemEmitter (..)
  , emitSubsystemEvent
  )
where

import Control.Applicative ((<|>))
import Control.Exception (SomeException, displayException, mask, throwIO, try)
import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Pair)
import Data.Functor ((<&>))
import Data.List (partition)
import Data.Maybe (catMaybes)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import System.IO (hPutStrLn, stderr)

import Platform.Observability.Context (currentContextForRuntime, randomHexText, withThreadContext)
import Platform.Observability.Fields (ObsEventCode (..), ToObsEvent (..), toFieldList)
import Platform.Observability.Redaction (redactText, sanitizeExtraValue, sanitizePreview)
import Platform.Observability.Runtime (currentRuntime, debugEnabled, stateLogFile, stateTraceFile)
import Platform.Observability.Store (appendLogValue, appendValue)
import Platform.Observability.Types

emitGlobalEvent :: LogEventSpec -> IO ()
emitGlobalEvent spec = do
  maybeRuntime <- currentRuntime
  emitEvent maybeRuntime spec

{- | Emit an event from a typed 'ToObsEvent' value.
Constructs a 'LogEventSpec' from the typeclass methods and delegates to 'emitGlobalEvent'.
-}
emitObsEvent :: ToObsEvent a => a -> IO ()
emitObsEvent evt =
  emitGlobalEvent $
    (defaultLogEvent (obsLevel evt) (obsComponent evt) (unObsEventCode (obsCode evt)) (obsMessage evt))
      { eventExtraFields = toFieldList (obsFields evt)
      }

emitEvent :: Maybe ObservabilityRuntime -> LogEventSpec -> IO ()
emitEvent Nothing _ = pure ()
emitEvent (Just runtime) spec
  | eventLevel spec < runtime.config.minLogLevel = pure ()
  | otherwise = do
      now <- getCurrentTime
      maybeCtx <- currentContextForRuntime runtime
      let (safeExtras, droppedExtras) = filterReservedKeys (eventExtraFields spec)
          payloadPreview =
            if debugEnabled runtime
              then
                sanitizePreview runtime
                  <$> eventPayloadPreview spec
              else Nothing
          eventValue =
            object $
              catMaybes
                [ Just ("timestamp" .= now)
                , Just ("level" .= renderLevel (eventLevel spec))
                , Just ("service" .= runtime.config.serviceName)
                , Just ("component" .= eventComponent spec)
                , Just ("operation" .= eventOperation spec)
                , Just ("environment" .= runtime.config.environment)
                , ("deployment" .=) <$> runtime.config.deployment
                , ("host" .=) <$> runtime.config.host
                , Just ("version" .= runtime.config.version)
                , Just ("message" .= redactText runtime (eventMessage spec))
                , Just ("outcome" .= eventOutcome spec)
                , buildContextField "request_id" maybeCtx (.requestId)
                , buildContextField "upstream_request_id" maybeCtx (.upstreamRequestId)
                , buildContextField "trace_id" maybeCtx (Just . (.traceId))
                , buildContextField "span_id" maybeCtx (Just . (.spanId))
                , buildField "run_id" (eventRunId spec <|> (maybeCtx >>= (.runId)))
                , buildField "user_id" (eventUserId spec <|> (maybeCtx >>= (.userId)))
                , buildField "account_id" (eventAccountId spec <|> (maybeCtx >>= (.accountId)))
                , buildField "asset_id" (eventAssetId spec <|> (maybeCtx >>= (.assetId)))
                , buildField "provider" (eventProvider spec <|> (maybeCtx >>= (.provider)))
                , buildField "http_method" (eventHttpMethod spec <|> (maybeCtx >>= (.httpMethod)))
                , buildField "route" (eventRoute spec <|> (maybeCtx >>= (.route)))
                , buildField "http_status_code" (eventHttpStatusCode spec)
                , buildField "upstream_status_code" (eventUpstreamStatusCode spec)
                , buildField "stage" (eventStage spec <|> (maybeCtx >>= (.stage)))
                , buildField "attempt" (eventAttempt spec)
                , buildField "model" (eventModel spec <|> (maybeCtx >>= (.model)))
                , buildField "input_tokens" (eventInputTokens spec)
                , buildField "output_tokens" (eventOutputTokens spec)
                , buildField "finish_reason" (eventFinishReason spec)
                , buildField "step_index" (eventStepIndex spec <|> (maybeCtx >>= (.stepIndex)))
                , buildField "error_type" (eventErrorType spec)
                , buildField "error_code" (eventErrorCode spec)
                , buildField "retryable" (eventRetryable spec)
                , buildField "duration_ms" (eventDurationMs spec)
                , buildField "tool_name" (eventToolName spec <|> (maybeCtx >>= (.toolName)))
                , buildField "tool_call_id" (eventToolCallId spec)
                , buildField "assistant_phase" (eventAssistantPhase spec <|> (maybeCtx >>= (.assistantPhase)))
                , ("payload_preview_visibility" .=)
                    <$> fmap renderPreviewVisibility (eventPayloadPreviewVisibility spec)
                , ("payload_preview" .=) <$> payloadPreview
                ]
                <> fmap (\(name, value) -> Key.fromText name .= sanitizeExtraValue runtime value) safeExtras
      case droppedExtras of
        [] -> pure ()
        dropped ->
          hPutStrLn
            stderr
            ( "observability: extra-field keys collide with built-in keys and were dropped: "
                <> show (fmap fst dropped)
            )
      appendLogValue runtime (stateLogFile runtime) eventValue

withSpanIO :: Maybe ObservabilityRuntime -> SpanSpec -> IO a -> IO a
withSpanIO runtime spec =
  withSpanOutcomeIO runtime spec $ \case
    Left err ->
      SpanOutcomeSpec
        { spanOutcome = "error"
        , spanErrorType = Nothing
        , spanErrorMessage = Just (T.pack (displayException err))
        }
    Right _ ->
      SpanOutcomeSpec
        { spanOutcome = "success"
        , spanErrorType = Nothing
        , spanErrorMessage = Nothing
        }

withSpanOutcomeIO
  :: Maybe ObservabilityRuntime
  -> SpanSpec
  -> (Either SomeException a -> SpanOutcomeSpec)
  -> IO a
  -> IO a
withSpanOutcomeIO Nothing _ _ action = action
withSpanOutcomeIO (Just runtime) spec classify action = mask $ \restore -> do
  parentCtx <- currentContextForRuntime runtime
  traceTxt <- maybe (randomHexText 16) (pure . (.traceId)) parentCtx
  spanTxt <- randomHexText 8
  let nextCtx =
        case parentCtx of
          Just ctx ->
            ctx
              { spanId = spanTxt
              , operation = Just spec.spanOperation
              , stage = spec.spanStage <|> ctx.stage
              , toolName = spec.spanToolName <|> ctx.toolName
              , assistantPhase = spec.spanAssistantPhase <|> ctx.assistantPhase
              , provider = spec.spanProvider <|> ctx.provider
              , model = spec.spanModel <|> ctx.model
              , stepIndex = spec.spanStepIndex <|> ctx.stepIndex
              }
          Nothing ->
            ObservabilityContext
              { requestId = Nothing
              , upstreamRequestId = Nothing
              , traceId = traceTxt
              , spanId = spanTxt
              , runId = Nothing
              , userId = Nothing
              , accountId = Nothing
              , assetId = Nothing
              , provider = spec.spanProvider
              , httpMethod = Nothing
              , route = Nothing
              , operation = Just spec.spanOperation
              , stage = spec.spanStage
              , toolName = spec.spanToolName
              , assistantPhase = spec.spanAssistantPhase
              , model = spec.spanModel
              , stepIndex = spec.spanStepIndex
              , linkedTraceId = Nothing
              , linkedRequestId = Nothing
              , linkedSpanId = Nothing
              }
      parentSpanId = parentCtx <&> (.spanId)
      linkedTrace = nextCtx.linkedTraceId
      linkedRequest = nextCtx.linkedRequestId
      linkedSpan = nextCtx.linkedSpanId
  start <- getCurrentTime
  result <- try @SomeException $ withThreadContext runtime nextCtx (restore action)
  finished <- getCurrentTime
  let outcomeSpec = classify result
      durationMs :: Int
      durationMs = max 0 (floor (realToFrac (diffUTCTime finished start) * (1000 :: Double)))
      traceValue =
        object $
          catMaybes
            [ Just ("timestamp" .= finished)
            , Just ("service" .= runtime.config.serviceName)
            , Just ("component" .= spec.spanComponent)
            , Just ("operation" .= spec.spanOperation)
            , Just ("environment" .= runtime.config.environment)
            , ("deployment" .=) <$> runtime.config.deployment
            , ("host" .=) <$> runtime.config.host
            , Just ("version" .= runtime.config.version)
            , Just ("message" .= redactText runtime spec.spanMessage)
            , Just ("trace_id" .= nextCtx.traceId)
            , Just ("span_id" .= nextCtx.spanId)
            , ("parent_span_id" .=) <$> parentSpanId
            , ("linked_trace_id" .=) <$> linkedTrace
            , ("linked_request_id" .=) <$> linkedRequest
            , ("linked_span_id" .=) <$> linkedSpan
            , ("request_id" .=) <$> nextCtx.requestId
            , ("run_id" .=) <$> nextCtx.runId
            , ("user_id" .=) <$> nextCtx.userId
            , ("account_id" .=) <$> nextCtx.accountId
            , ("asset_id" .=) <$> nextCtx.assetId
            , ("provider" .=) <$> (spec.spanProvider <|> nextCtx.provider)
            , ("stage" .=) <$> (spec.spanStage <|> nextCtx.stage)
            , ("tool_name" .=) <$> (spec.spanToolName <|> nextCtx.toolName)
            , ("assistant_phase" .=) <$> (spec.spanAssistantPhase <|> nextCtx.assistantPhase)
            , ("model" .=) <$> (spec.spanModel <|> nextCtx.model)
            , ("step_index" .=) <$> (spec.spanStepIndex <|> nextCtx.stepIndex)
            , Just ("duration_ms" .= durationMs)
            , Just ("outcome" .= outcomeSpec.spanOutcome)
            , ("error_type" .=) <$> outcomeSpec.spanErrorType
            , (("error" .=) . redactText runtime) <$> outcomeSpec.spanErrorMessage
            ]
  appendValue runtime (stateTraceFile runtime) traceValue
  case result of
    Left err -> throwIO err
    Right value -> pure value

-- Internal helpers

buildField :: ToJSON a => Text -> Maybe a -> Maybe Pair
buildField _ Nothing = Nothing
buildField name (Just value) = Just (Key.fromText name .= value)

buildContextField
  :: ToJSON a
  => Text
  -> Maybe ObservabilityContext
  -> (ObservabilityContext -> Maybe a)
  -> Maybe Pair
buildContextField name maybeCtx selector = buildField name (maybeCtx >>= selector)

filterReservedKeys :: [(Text, a)] -> ([(Text, a)], [(Text, a)])
filterReservedKeys = partition (\(k, _) -> not (Set.member k reservedKeys))

reservedKeys :: Set.Set Text
reservedKeys =
  Set.fromList
    [ "timestamp"
    , "level"
    , "service"
    , "component"
    , "operation"
    , "environment"
    , "deployment"
    , "host"
    , "version"
    , "message"
    , "outcome"
    , "request_id"
    , "upstream_request_id"
    , "trace_id"
    , "span_id"
    , "run_id"
    , "user_id"
    , "account_id"
    , "asset_id"
    , "provider"
    , "http_method"
    , "route"
    , "http_status_code"
    , "upstream_status_code"
    , "stage"
    , "attempt"
    , "model"
    , "input_tokens"
    , "output_tokens"
    , "finish_reason"
    , "step_index"
    , "error_type"
    , "error_code"
    , "retryable"
    , "duration_ms"
    , "tool_name"
    , "tool_call_id"
    , "assistant_phase"
    , "payload_preview_visibility"
    , "payload_preview"
    , "parent_span_id"
    , "linked_trace_id"
    , "linked_request_id"
    , "linked_span_id"
    ]

{- | Pre-configured emitter for a subsystem.
Reduces boilerplate in worker modules that emit events with fixed component/stage/provider.
-}
data SubsystemEmitter = SubsystemEmitter
  { seComponent :: !Text
  , seStage :: !(Maybe Text)
  , seProvider :: !(Maybe Text)
  }

-- | Emit an event using a pre-configured subsystem emitter.
emitSubsystemEvent
  :: SubsystemEmitter
  -> ObservabilityLogLevel
  -> Text
  -- ^ operation
  -> Text
  -- ^ message
  -> Text
  -- ^ outcome
  -> Maybe Text
  -- ^ error type (optional)
  -> [(Text, Value)]
  -- ^ extra fields
  -> IO ()
emitSubsystemEvent emitter level operation message outcome maybeErrorType extraFields =
  emitGlobalEvent $
    (defaultLogEvent level (seComponent emitter) operation message)
      { eventOutcome = outcome
      , eventStage = seStage emitter
      , eventProvider = seProvider emitter
      , eventErrorType = maybeErrorType
      , eventExtraFields = extraFields
      }
