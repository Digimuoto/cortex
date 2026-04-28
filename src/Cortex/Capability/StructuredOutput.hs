module Cortex.Capability.StructuredOutput
  ( decodeStructuredChoice
  , decodeStructuredErrorMessage
  , shouldRetryWithJsonObjectFallback
  , structuredOutputSchemaRejected
  )
where

import Control.Monad (join)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Cortex.Capability.Model.Types
  ( CortexChoice (..)
  , CortexResponseFormat (..)
  )

decodeStructuredChoice :: Aeson.FromJSON a => CortexChoice -> Either Text a
decodeStructuredChoice choice
  | T.null stripped = Left "Structured output was empty."
  | otherwise =
      first T.pack $
        Aeson.eitherDecodeStrict' (TE.encodeUtf8 stripped)
  where
    stripped = T.strip choice.cortexChoiceContent

decodeStructuredErrorMessage :: Text -> Maybe Text
decodeStructuredErrorMessage rawBody =
  join (Aeson.decodeStrict' (TE.encodeUtf8 rawBody) >>= parseMaybe parseErrorObject)
  where
    parseErrorObject :: Aeson.Value -> Parser (Maybe Text)
    parseErrorObject =
      Aeson.withObject "errorBody" $ \obj -> do
        maybeMessage <- obj Aeson..:? "message"
        maybeError <- obj Aeson..:? "error" :: Parser (Maybe Aeson.Value)
        case maybeError of
          Just (Aeson.String errText) -> pure (Just errText)
          Just (Aeson.Object errObject) -> errObject Aeson..:? "message"
          _ -> pure maybeMessage

structuredOutputSchemaRejected :: Text -> Bool
structuredOutputSchemaRejected errText =
  let normalizedErr = T.toLower errText
   in any
        (`T.isInfixOf` normalizedErr)
        [ "structured-output schema"
        , "structured output schema"
        , "output_config.format.schema"
        , "json_schema"
        , "maxitems"
        ]

shouldRetryWithJsonObjectFallback :: CortexResponseFormat -> Text -> Bool
shouldRetryWithJsonObjectFallback responseFormat errText =
  case responseFormat of
    CortexResponseJsonSchema _ _ -> structuredOutputSchemaRejected errText
    _ -> False
