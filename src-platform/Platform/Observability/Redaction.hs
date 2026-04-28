{- |
Module      : Platform.Observability.Redaction
Description : Platform runtime support for redaction.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Platform modules provide generic runtime substrate utilities and do not import Cortex or consumers.
-}
module Platform.Observability.Redaction
  ( -- * Public API (re-exported by Platform.Observability)
    redactText
  , redactValue

    -- * Internal (used by sibling modules)
  , sanitizeStoredValue
  , sanitizePreview
  , sanitizeExtraValue
  , truncatePreviewValue
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (second)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V

import Platform.Observability.Types

redactText :: ObservabilityRuntime -> Text -> Text
redactText runtime =
  redactDelimitedToken "Bearer "
    . redactDelimitedToken "pmadm_"
    . redactSensitiveQueryParams runtime

redactValue :: ObservabilityRuntime -> Value -> Value
redactValue runtime = \case
  Object obj ->
    Object $
      KeyMap.mapWithKey
        ( \key value -> if isSensitiveKey (Key.toText key) then String "[REDACTED]" else redactValue runtime value
        )
        obj
  Array arr -> Array (fmap (redactValue runtime) arr)
  String txt -> String (redactText runtime txt)
  other -> other

sanitizeStoredValue :: ObservabilityRuntime -> Value -> Value
sanitizeStoredValue = redactValue

sanitizePreview :: ObservabilityRuntime -> Value -> Value
sanitizePreview runtime =
  truncatePreviewValue . redactValue runtime

sanitizeExtraValue :: ObservabilityRuntime -> Value -> Value
sanitizeExtraValue = redactValue

truncatePreviewValue :: Value -> Value
truncatePreviewValue = \case
  Object obj ->
    Object
      . KeyMap.fromList
      . take 50
      . fmap (second truncatePreviewValue)
      $ KeyMap.toList obj
  Array arr ->
    Array (fmap truncatePreviewValue (V.take 50 arr))
  String txt ->
    String $
      if T.length txt <= 2048
        then txt
        else T.take 2045 txt <> "..."
  other -> other

redactSensitiveQueryParams :: ObservabilityRuntime -> Text -> Text
redactSensitiveQueryParams _runtime input =
  case T.breakOn "?" input of
    (prefix, suffix)
      | T.null suffix -> input
      | otherwise ->
          let queryText = T.drop 1 suffix
              params = T.splitOn "&" queryText
              sanitized =
                fmap
                  ( \param ->
                      case T.breakOn "=" param of
                        (name, "")
                          | isSensitiveKey name -> name <> "=[REDACTED]"
                          | otherwise -> param
                        (name, value)
                          | isSensitiveKey name -> name <> "=[REDACTED]"
                          | otherwise -> name <> value
                  )
                  params
           in prefix <> "?" <> T.intercalate "&" sanitized

redactDelimitedToken :: Text -> Text -> Text
redactDelimitedToken marker = go
  where
    go input =
      case T.breakOn marker input of
        (before, remainder)
          | T.null remainder -> input
          | otherwise ->
              let afterMarker = T.drop (T.length marker) remainder
                  (tokenValue, rest) = T.break isTokenBoundary afterMarker
                  replacement =
                    if T.null tokenValue
                      then marker
                      else marker <> "[REDACTED]"
               in before <> replacement <> go rest
    isTokenBoundary char = char == ' ' || char == '\n' || char == '\t' || char == '"' || char == '\''

isSensitiveKey :: Text -> Bool
isSensitiveKey keyName =
  let lowered = T.toLower keyName
   in or
        [ lowered == "authorization"
        , lowered == "x-admin-key"
        , lowered == "cookie"
        , lowered == "set-cookie"
        , lowered == "api_token"
        , lowered == "apikey"
        , lowered == "api-key"
        , lowered == "token"
        , lowered == "key"
        , lowered == "secret"
        , lowered == "password"
        , lowered == "jwt"
        ]
