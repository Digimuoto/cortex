module Platform.Observability.Wai
  ( -- * Public API (re-exported by Platform.Observability)
    newRequestContext
  , mkRequestMiddleware
  )
where

import Control.Exception (SomeException, displayException, throwIO, try)
import Data.Aeson (object, (.=))
import Data.Char (isDigit, isHexDigit)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time (diffUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Network.HTTP.Types (HeaderName, statusCode)
import Network.Wai
  ( Middleware
  , Request
  , mapResponseHeaders
  , pathInfo
  , requestHeaders
  , requestMethod
  , responseStatus
  )

import Platform.Observability.Context (nextRequestId, randomHexText, withThreadContext)
import Platform.Observability.Emit (emitEvent, withSpanIO)
import Platform.Observability.Runtime (debugEnabled)
import Platform.Observability.Types

newRequestContext :: Request -> IO ObservabilityContext
newRequestContext req = do
  requestIdText <- nextRequestId
  traceTxt <- randomHexText 16
  spanTxt <- randomHexText 8
  let incomingRequestId = lookupHeaderText "X-Request-ID" req
      normalizedRoute = normalizeRoute req
      methodText = decodeMethod req
  pure
    ObservabilityContext
      { requestId = Just requestIdText
      , upstreamRequestId = incomingRequestId
      , traceId = traceTxt
      , spanId = spanTxt
      , runId = Nothing
      , userId = Nothing
      , accountId = Nothing
      , assetId = Nothing
      , provider = Nothing
      , httpMethod = Just methodText
      , route = Just normalizedRoute
      , operation = Just "http.request"
      , stage = Nothing
      , toolName = Nothing
      , assistantPhase = Nothing
      , model = Nothing
      , stepIndex = Nothing
      , linkedTraceId = Nothing
      , linkedRequestId = Nothing
      , linkedSpanId = Nothing
      }

mkRequestMiddleware :: ObservabilityRuntime -> Middleware
mkRequestMiddleware runtime app req respond = do
  ctx <- newRequestContext req
  let requestHeader =
        foldMap (\rid -> [("X-Request-ID", TE.encodeUtf8 rid)]) ctx.requestId
  let requestSpec =
        (defaultSpanSpec "http" "http.request" "HTTP request")
          { spanStage = Just "request"
          }
  withThreadContext runtime ctx $ do
    startedAt <- getCurrentTime
    result <-
      try @SomeException $
        withSpanIO (Just runtime) requestSpec . app req $ \response -> do
          finishedAt <- getCurrentTime
          let code = statusCode (responseStatus response)
              durationMs = max 0 (floor (realToFrac (diffUTCTime finishedAt startedAt) * (1000 :: Double)))
              level
                | code >= 500 = ObsError
                | code >= 400 = ObsWarn
                | otherwise = ObsInfo
              outcome
                | code >= 500 = "error"
                | code >= 400 = "error"
                | otherwise = "success"
              spec =
                (defaultLogEvent level "http" "http.request.complete" "HTTP request completed")
                  { eventOutcome = outcome
                  , eventHttpStatusCode = Just code
                  , eventDurationMs = Just durationMs
                  , eventRoute = ctx.route
                  , eventHttpMethod = ctx.httpMethod
                  }
          emitEvent (Just runtime) spec
          respond (mapResponseHeaders (requestHeader <>) response)
    case result of
      Left err -> do
        finishedAt <- getCurrentTime
        let durationMs = max 0 (floor (realToFrac (diffUTCTime finishedAt startedAt) * (1000 :: Double)))
            spec =
              (defaultLogEvent ObsError "http" "http.request.exception" "HTTP request failed")
                { eventOutcome = "error"
                , eventDurationMs = Just durationMs
                , eventRoute = ctx.route
                , eventHttpMethod = ctx.httpMethod
                , eventErrorType = Just "internal_error"
                , eventPayloadPreviewVisibility =
                    if debugEnabled runtime
                      then Just PreviewAdminOnly
                      else Nothing
                , eventPayloadPreview =
                    if debugEnabled runtime
                      then
                        Just $
                          object
                            [ "exception" .= T.pack (displayException err)
                            ]
                      else Nothing
                }
        emitEvent (Just runtime) spec
        throwIO err
      Right responseReceived ->
        pure responseReceived

-- WAI request helpers

lookupHeaderText :: HeaderName -> Request -> Maybe Text
lookupHeaderText headerName req =
  lookup headerName (requestHeaders req)
    >>= either (const Nothing) Just . TE.decodeUtf8'

decodeMethod :: Request -> Text
decodeMethod req = TE.decodeUtf8With lenientDecode (requestMethod req)

normalizeRoute :: Request -> Text
normalizeRoute req =
  "/" <> T.intercalate "/" (fmap normalizeSegment (pathInfo req))

normalizeSegment :: Text -> Text
normalizeSegment segment
  | isJust (UUID.fromText segment) = ":id"
  | T.all isDigit segment && not (T.null segment) = ":id"
  | T.length segment > 24 && T.all (\char -> isHexDigit char || char == '-') segment = ":id"
  | otherwise = segment
