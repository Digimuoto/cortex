{- |
Module      : Cortex.Capability.Provider.OpenRouter.Embedding
Description : Cortex substrate support for embedding.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex substrate modules stay consumer-neutral and keep downstream product policy out of this repo.
-}
module Cortex.Capability.Provider.OpenRouter.Embedding
  ( openRouterEmbeddingModelId
  , requestOpenRouterEmbeddings
  , renderPgVectorLiteral
  )
where

import Control.Exception (throwIO, try)
import Control.Monad (void, when)
import Control.Monad.Catch qualified as MC
import Control.Retry (recovering)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
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

import Cortex.Capability.Provider.OpenRouter.Client
  ( OpenRouterHttpErrorDetails (httpErrorProviderMessage)
  , decodeOpenRouterHttpErrorDetails
  )

import Platform.HTTP.Retry
  ( retryPolicy
  , shouldRetry
  )
import Platform.Serde.Json.Text
  ( decodeLazyUtf8
  )

openRouterEmbeddingsUrl :: String
openRouterEmbeddingsUrl = "https://openrouter.ai/api/v1/embeddings"

openRouterEmbeddingModelId :: Text
openRouterEmbeddingModelId = "openai/text-embedding-3-small"

data OpenRouterEmbeddingResponse = OpenRouterEmbeddingResponse
  { orembData :: [OpenRouterEmbeddingDatum]
  }
  deriving stock (Eq, Show)

data OpenRouterEmbeddingDatum = OpenRouterEmbeddingDatum
  { orembIndex :: Int
  , orembEmbedding :: [Double]
  }
  deriving stock (Eq, Show)

instance Aeson.FromJSON OpenRouterEmbeddingResponse where
  parseJSON = Aeson.withObject "OpenRouterEmbeddingResponse" $ \o ->
    OpenRouterEmbeddingResponse
      <$> o Aeson..:? "data" Aeson..!= []

instance Aeson.FromJSON OpenRouterEmbeddingDatum where
  parseJSON = Aeson.withObject "OpenRouterEmbeddingDatum" $ \o ->
    OpenRouterEmbeddingDatum
      <$> o Aeson..:? "index" Aeson..!= 0
      <*> o Aeson..: "embedding"

requestOpenRouterEmbeddings
  :: Manager
  -> Text
  -> [Text]
  -> IO (Either Text [[Double]])
requestOpenRouterEmbeddings _manager _apiKey [] = pure (Right [])
requestOpenRouterEmbeddings manager apiKey inputs = do
  request <- parseEmbeddingsRequest apiKey inputs
  responseResult <- try @HttpException (executeRequest request)
  case responseResult of
    Left err ->
      pure . Left $
        "OpenRouter embedding request failed after network retries: "
          <> T.pack (show err)
    Right response -> do
      let responseCode = statusCode (responseStatus response)
          body = responseBody response
      if responseCode >= 400
        then do
          let maybeDetails = decodeOpenRouterHttpErrorDetails body
              providerSuffix =
                maybe
                  ""
                  (\details -> maybe "" (": " <>) details.httpErrorProviderMessage)
                  maybeDetails
          pure . Left $
            "OpenRouter embedding request failed with HTTP "
              <> T.pack (show responseCode)
              <> providerSuffix
        else case (Aeson.eitherDecode body :: Either String OpenRouterEmbeddingResponse) of
          Left err ->
            pure . Left $
              "OpenRouter embedding response decode failed: "
                <> T.pack err
                <> " body="
                <> T.take 600 (decodeLazyUtf8 body)
          Right parsed ->
            pure
              . Right
              . fmap orembEmbedding
              . sortOn orembIndex
              $ parsed.orembData
  where
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

parseEmbeddingsRequest :: Text -> [Text] -> IO Request
parseEmbeddingsRequest apiKey inputs = do
  base <- parseRequest openRouterEmbeddingsUrl
  let headers =
        [ ("Accept", "application/json")
        , ("Content-Type", "application/json")
        , ("User-Agent", "Portman/1.0")
        , ("Authorization", TE.encodeUtf8 ("Bearer " <> apiKey))
        ]
      payload =
        Aeson.object
          [ "model" .= openRouterEmbeddingModelId
          , "input" .= inputs
          ]
  pure
    base
      { method = "POST"
      , requestHeaders = headers
      , requestBody = RequestBodyLBS (Aeson.encode payload)
      }

renderPgVectorLiteral :: [Double] -> Either Text Text
renderPgVectorLiteral vector
  | any (\x -> isNaN x || isInfinite x) vector =
      Left "Embedding vector contains NaN or Infinity"
  | otherwise =
      Right $ "[" <> T.intercalate "," (fmap (T.pack . show) vector) <> "]"
