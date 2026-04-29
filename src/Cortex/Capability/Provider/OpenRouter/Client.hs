{- |
Module      : Cortex.Capability.Provider.OpenRouter.Client
Description : Cortex substrate support for client.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex substrate modules stay consumer-neutral and keep downstream product policy out of this repo.
-}
module Cortex.Capability.Provider.OpenRouter.Client
  ( OpenRouterChoiceResponse (..)
  , OpenRouterHttpErrorDetails (..)
  , OpenRouterRequestFailure (..)
  , choiceHeavyTimeoutMicros
  , choiceStageLabel
  , choiceStandardTimeoutMicros
  , choiceTimeoutClassText
  , choiceTimeoutMicrosForClass
  , openRouterRequestPayload
  , openRouterResolvedMaxOutputTokens
  , decodeOpenRouterHttpErrorDetails
  , isOpenRouterSchemaRejection
  , openRouterChatUrl
  , openRouterHttpFailureErrorType
  , openRouterHttpFailureMessage
  , parseOpenRouterRequest
  , requestOpenRouterChoice
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (displayException, throwIO, try)
import Control.Monad (join, void, when)
import Control.Monad.Catch qualified as MC
import Control.Retry (recovering)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (diffUTCTime, getCurrentTime)
import Network.HTTP.Client
  ( HttpException (..)
  , HttpExceptionContent (StatusCodeException)
  , Manager
  , Request
  , RequestBody (RequestBodyLBS)
  , httpLbs
  , method
  , parseRequest
  , requestBody
  , requestHeaders
  , responseBody
  , responseStatus
  )
import Network.HTTP.Types.Status (status429, status500, status503, status504, statusCode)
import System.Timeout (timeout)

import Cortex.Capability.Model.Types
  ( CortexChoice (..)
  , CortexChoiceRequest (..)
  , CortexChoiceTimeoutClass (..)
  , CortexUsage
  )
import Cortex.Capability.Provider.OpenRouter qualified as OpenRouterProvider
import Cortex.Capability.Provider.OpenRouter.Wire
  ( OpenRouterCompletion (..)
  )

import Platform.HTTP.Retry (retryPolicy, shouldRetry)
import Platform.Serde.Json.Preview
  ( truncateText
  )
import Platform.Serde.Json.Text
  ( decodeLazyUtf8
  )

openRouterChatUrl :: String
openRouterChatUrl = "https://openrouter.ai/api/v1/chat/completions"

choiceStandardTimeoutMicros :: Int
choiceStandardTimeoutMicros = 5 * 60 * 1000000

choiceHeavyTimeoutMicros :: Int
choiceHeavyTimeoutMicros = 15 * 60 * 1000000

data OpenRouterRequestFailure = OpenRouterRequestFailure
  { requestFailureOutcome :: Text
  , requestFailureErrorType :: Text
  , requestFailureMessage :: Text
  , requestFailurePayloadPreview :: Maybe Aeson.Value
  , requestFailureDurationMs :: Maybe Int
  , requestFailureHttpStatusCode :: Maybe Int
  , requestFailureHttpErrorDetails :: Maybe OpenRouterHttpErrorDetails
  , requestFailureUsage :: Maybe CortexUsage
  }
  deriving stock (Eq, Show)

data OpenRouterHttpErrorDetails = OpenRouterHttpErrorDetails
  { httpErrorProviderName :: Maybe Text
  , httpErrorProviderMessage :: Maybe Text
  , httpErrorProviderRequestId :: Maybe Text
  }
  deriving stock (Eq, Show)

data OpenRouterChoiceResponse = OpenRouterChoiceResponse
  { openRouterResponseChoice :: CortexChoice
  , openRouterResponseDurationMs :: Int
  , openRouterResponseHttpStatusCode :: Int
  }
  deriving stock (Eq, Show)

decodeOpenRouterHttpErrorDetails :: BSL.ByteString -> Maybe OpenRouterHttpErrorDetails
decodeOpenRouterHttpErrorDetails body = do
  root <- Aeson.decode body
  let metadataRaw =
        parseMaybe
          ( Aeson.withObject "root" $ \o -> do
              err <- o Aeson..: "error"
              Aeson.withObject
                "error"
                ( \errObj -> do
                    metadata <- errObj Aeson..:? "metadata"
                    case metadata of
                      Nothing -> pure Nothing
                      Just metadataValue ->
                        Aeson.withObject "metadata" (Aeson..:? "raw") metadataValue
                )
                err
          )
          root
      providerName =
        parseMaybe
          ( Aeson.withObject "root" $ \o -> do
              err <- o Aeson..: "error"
              Aeson.withObject
                "error"
                ( \errObj -> do
                    metadata <- errObj Aeson..:? "metadata"
                    case metadata of
                      Nothing -> pure Nothing
                      Just metadataValue ->
                        Aeson.withObject "metadata" (Aeson..:? "provider_name") metadataValue
                )
                err
          )
          root
      decodedRaw = join metadataRaw >>= Aeson.decodeStrict' . TE.encodeUtf8
      providerMessage =
        decodedRaw
          >>= parseMaybe
            ( Aeson.withObject "providerRaw" $ \o -> do
                err <- o Aeson..:? "error"
                case err of
                  Nothing -> pure Nothing
                  Just errValue ->
                    Aeson.withObject "providerError" (Aeson..:? "message") errValue
            )
      providerRequestId =
        decodedRaw
          >>= parseMaybe
            (Aeson.withObject "providerRaw" (Aeson..:? "request_id"))
  pure
    OpenRouterHttpErrorDetails
      { httpErrorProviderName = join providerName
      , httpErrorProviderMessage = join providerMessage
      , httpErrorProviderRequestId = join providerRequestId
      }

isOpenRouterSchemaRejection :: OpenRouterHttpErrorDetails -> Bool
isOpenRouterSchemaRejection details =
  case details.httpErrorProviderMessage of
    Nothing -> False
    Just providerMessage ->
      let normalized = T.toLower providerMessage
       in "output_config.format.schema" `T.isInfixOf` normalized
            || "structured output schema" `T.isInfixOf` normalized
            || "maxitems" `T.isInfixOf` normalized

openRouterHttpFailureErrorType :: Int -> Maybe OpenRouterHttpErrorDetails -> Text
openRouterHttpFailureErrorType responseCode maybeDetails
  | maybe False isOpenRouterSchemaRejection maybeDetails = "schema_rejected"
  | responseCode >= 400 && responseCode < 500 = "request_rejected"
  | otherwise = "external_service_error"

openRouterHttpFailureMessage :: Text -> Int -> Maybe OpenRouterHttpErrorDetails -> Text
openRouterHttpFailureMessage requestPhaseLabel responseCode maybeDetails
  | maybe False isOpenRouterSchemaRejection maybeDetails =
      requestPhaseLabel <> " failed because the provider rejected the structured-output schema."
  | responseCode >= 400 && responseCode < 500 =
      requestPhaseLabel <> " failed because the provider rejected the request payload."
  | otherwise =
      requestPhaseLabel <> " failed with upstream HTTP " <> T.pack (show responseCode) <> "."

choiceTimeoutMicrosForClass :: CortexChoiceTimeoutClass -> Int
choiceTimeoutMicrosForClass = \case
  CortexChoiceTimeoutStandard -> choiceStandardTimeoutMicros
  CortexChoiceTimeoutHeavy -> choiceHeavyTimeoutMicros

choiceTimeoutClassText :: CortexChoiceTimeoutClass -> Text
choiceTimeoutClassText = \case
  CortexChoiceTimeoutStandard -> "standard"
  CortexChoiceTimeoutHeavy -> "heavy"

choiceStageLabel :: CortexChoiceRequest -> Text
choiceStageLabel choiceReq =
  case choiceReq.cortexChoiceAgentName of
    Just agentName -> agentName <> " phase"
    Nothing -> choiceReq.cortexChoiceStageName <> " phase"

openRouterRequestPayload :: CortexChoiceRequest -> Aeson.Value
openRouterRequestPayload choiceReq =
  OpenRouterProvider.buildOpenRouterRequestPayload
    choiceReq.cortexChoiceModelId
    choiceReq.cortexChoiceGroundingMode
    choiceReq.cortexChoiceMessages
    choiceReq.cortexChoiceTools
    choiceReq.cortexChoiceResponseFormat
    (openRouterResolvedMaxOutputTokens choiceReq)
    choiceReq.cortexChoiceReasoningEnabled

openRouterResolvedMaxOutputTokens :: CortexChoiceRequest -> Int
openRouterResolvedMaxOutputTokens choiceReq =
  fromMaybe OpenRouterProvider.defaultMaxOutputTokens choiceReq.cortexChoiceMaxOutputTokens

requestOpenRouterChoice
  :: Manager
  -> Text
  -> CortexChoiceRequest
  -> IO (Either OpenRouterRequestFailure OpenRouterChoiceResponse)
requestOpenRouterChoice manager apiKey choiceReq = do
  let timeoutMicros = choiceTimeoutMicrosForClass choiceReq.cortexChoiceTimeoutClass
      timeoutMinutes = max 1 ((timeoutMicros `div` 1000000) `div` 60)
      requestPhaseLabel = choiceStageLabel choiceReq
      requestPayload = openRouterRequestPayload choiceReq
      requestTimeoutFailure durationMs =
        OpenRouterRequestFailure
          { requestFailureOutcome = "timeout"
          , requestFailureErrorType = "timeout"
          , requestFailureMessage =
              requestPhaseLabel <> " timed out after " <> T.pack (show timeoutMinutes) <> " minutes."
          , requestFailurePayloadPreview = Nothing
          , requestFailureDurationMs = Just durationMs
          , requestFailureHttpStatusCode = Nothing
          , requestFailureHttpErrorDetails = Nothing
          , requestFailureUsage = Nothing
          }
      requestFailureFromHttpError durationMs err =
        OpenRouterRequestFailure
          { requestFailureOutcome = "error"
          , requestFailureErrorType = "network_error"
          , requestFailureMessage = requestPhaseLabel <> " failed after network retries."
          , requestFailurePayloadPreview =
              Just
                ( Aeson.object
                    [ "error" .= truncateText 1000 (T.pack (displayException err))
                    ]
                )
          , requestFailureDurationMs = Just durationMs
          , requestFailureHttpStatusCode = Nothing
          , requestFailureHttpErrorDetails = Nothing
          , requestFailureUsage = Nothing
          }
      executeRequest request =
        recovering retryPolicy [\_ -> MC.Handler $ \(e :: HttpException) -> pure (shouldRetry e)] $ \_ -> do
          response <- httpLbs request manager
          let status = responseStatus response
          when (status == status429 || status == status500 || status == status503 || status == status504)
            . throwIO
            $ HttpExceptionRequest
              request
              (StatusCodeException (void response) (BSL.toStrict $ responseBody response))
          pure response
      -- Some providers intermittently return HTTP 200 with an empty `choices`
      -- array (the "returned no completion choices" failure class). This is
      -- not caught by the HTTP retry policy inside executeRequest because the
      -- response status is 200. Wrap the per-request decoding loop in a
      -- bounded retry so a single empty-choice blip does not bubble up as a
      -- stage failure. Retries are bounded and back off linearly; hard
      -- failures (network, decode, non-2xx HTTP) fall through unchanged.
      maxEmptyChoicesRetries :: Int
      maxEmptyChoicesRetries = 2
      emptyChoicesBackoffMicros :: Int -> Int
      emptyChoicesBackoffMicros attempt = 750_000 * (attempt + 1)
      isEmptyChoicesFailure failure =
        failure.requestFailureErrorType == "external_service_error"
          && "returned no completion choices." `T.isInfixOf` failure.requestFailureMessage
      runSingleAttempt request = do
        startedAt <- getCurrentTime
        maybeResponseResult <- timeout timeoutMicros $ try @HttpException (executeRequest request)
        finishedAt <- getCurrentTime
        let requestDurationMs = max 0 (floor (diffUTCTime finishedAt startedAt * 1000))
        case maybeResponseResult of
          Nothing ->
            pure (Left (requestTimeoutFailure requestDurationMs))
          Just (Left err) ->
            pure (Left (requestFailureFromHttpError requestDurationMs err))
          Just (Right response) -> do
            let responseCode = statusCode (responseStatus response)
                body = responseBody response
            if responseCode >= 400
              then do
                let maybeErrorDetails = decodeOpenRouterHttpErrorDetails body
                pure . Left $
                  OpenRouterRequestFailure
                    { requestFailureOutcome = "error"
                    , requestFailureErrorType = openRouterHttpFailureErrorType responseCode maybeErrorDetails
                    , requestFailureMessage =
                        openRouterHttpFailureMessage requestPhaseLabel responseCode maybeErrorDetails
                    , requestFailurePayloadPreview =
                        Just
                          ( Aeson.object $
                              [ "body" .= truncateText 1500 (decodeLazyUtf8 body)
                              ]
                                <> foldMap
                                  (\providerName -> ["provider" .= providerName])
                                  (maybeErrorDetails >>= (.httpErrorProviderName))
                                <> foldMap
                                  (\providerMessage -> ["providerError" .= truncateText 600 providerMessage])
                                  (maybeErrorDetails >>= (.httpErrorProviderMessage))
                                <> foldMap
                                  (\providerRequestId -> ["providerRequestId" .= providerRequestId])
                                  (maybeErrorDetails >>= (.httpErrorProviderRequestId))
                          )
                    , requestFailureDurationMs = Just requestDurationMs
                    , requestFailureHttpStatusCode = Just responseCode
                    , requestFailureHttpErrorDetails = maybeErrorDetails
                    , requestFailureUsage = Nothing
                    }
              else case (Aeson.eitherDecode body :: Either String OpenRouterCompletion) of
                Left err ->
                  pure . Left $
                    OpenRouterRequestFailure
                      { requestFailureOutcome = "error"
                      , requestFailureErrorType = "decode_error"
                      , requestFailureMessage = requestPhaseLabel <> " returned an unreadable completion response."
                      , requestFailurePayloadPreview =
                          Just
                            ( Aeson.object
                                [ "body" .= truncateText 1500 (decodeLazyUtf8 body)
                                , "decodeError" .= truncateText 1000 (T.pack err)
                                ]
                            )
                      , requestFailureDurationMs = Just requestDurationMs
                      , requestFailureHttpStatusCode = Just responseCode
                      , requestFailureHttpErrorDetails = Nothing
                      , requestFailureUsage = Nothing
                      }
                Right completion ->
                  case completion.openRouterChoices of
                    [] ->
                      let usage = fmap OpenRouterProvider.openRouterUsageToCortex completion.openRouterUsage
                       in pure . Left $
                            OpenRouterRequestFailure
                              { requestFailureOutcome = "error"
                              , requestFailureErrorType = "external_service_error"
                              , requestFailureMessage = requestPhaseLabel <> " returned no completion choices."
                              , requestFailurePayloadPreview = Nothing
                              , requestFailureDurationMs = Just requestDurationMs
                              , requestFailureHttpStatusCode = Just responseCode
                              , requestFailureHttpErrorDetails = Nothing
                              , requestFailureUsage = usage
                              }
                    (choice : _) -> do
                      let mergedUsage = fmap OpenRouterProvider.openRouterUsageToCortex completion.openRouterUsage
                          mergedChoice =
                            (OpenRouterProvider.openRouterChoiceToCortex choice)
                              { cortexChoiceUsage = mergedUsage
                              , cortexChoiceReasoning = Nothing
                              , cortexChoiceReasoningDetails = Nothing
                              }
                      pure . Right $
                        OpenRouterChoiceResponse
                          { openRouterResponseChoice = mergedChoice
                          , openRouterResponseDurationMs = requestDurationMs
                          , openRouterResponseHttpStatusCode = responseCode
                          }
      runWithEmptyChoicesRetry request = loop 0
        where
          loop attempt = do
            result <- runSingleAttempt request
            case result of
              Left failure
                | isEmptyChoicesFailure failure
                , attempt < maxEmptyChoicesRetries -> do
                    threadDelay (emptyChoicesBackoffMicros attempt)
                    loop (attempt + 1)
              _ -> pure result
  request <- parseOpenRouterRequest apiKey requestPayload
  runWithEmptyChoicesRetry request

parseOpenRouterRequest :: Text -> Aeson.Value -> IO Request
parseOpenRouterRequest apiKey payload = do
  base <- parseRequest openRouterChatUrl
  let headers =
        [ ("Accept", "application/json")
        , ("Content-Type", "application/json")
        , ("User-Agent", "Cortex/0.1")
        , ("Authorization", TE.encodeUtf8 ("Bearer " <> apiKey))
        ]
  pure
    base
      { method = "POST"
      , requestHeaders = headers
      , requestBody = RequestBodyLBS (Aeson.encode payload)
      }
