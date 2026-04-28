module Cortex.Capability.StructuredOutputSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Test.Hspec

import Cortex.Capability.Model.Types
  ( CortexChoice (..)
  , CortexResponseFormat (..)
  )
import Cortex.Capability.StructuredOutput
  ( decodeStructuredChoice
  , decodeStructuredErrorMessage
  , shouldRetryWithJsonObjectFallback
  , structuredOutputSchemaRejected
  )

spec :: Spec
spec = do
  describe "decodeStructuredChoice" $ do
    it "decodes structured JSON output from the choice content" $ do
      decodeStructuredChoice (jsonChoice (Aeson.object ["answer" Aeson..= ("ok" :: T.Text)]))
        `shouldBe` Right (Aeson.object ["answer" Aeson..= ("ok" :: T.Text)])

    it "rejects empty structured output" $ do
      decodeStructuredChoice (emptyChoice "   ")
        `shouldBe` (Left "Structured output was empty." :: Either T.Text Aeson.Value)

  describe "decodeStructuredErrorMessage" $ do
    it "extracts nested error messages from structured bodies" $ do
      decodeStructuredErrorMessage "{\"error\":\"schema rejected\"}"
        `shouldBe` Just "schema rejected"

    it "extracts nested error.message fields from structured bodies" $ do
      decodeStructuredErrorMessage "{\"error\":{\"message\":\"schema rejected\"}}"
        `shouldBe` Just "schema rejected"

    it "extracts top-level message fields from structured bodies" $ do
      decodeStructuredErrorMessage "{\"message\":\"provider rejected the request\"}"
        `shouldBe` Just "provider rejected the request"

    it "returns Nothing for non-json error bodies" $ do
      decodeStructuredErrorMessage "plain text error" `shouldBe` Nothing

  describe "structuredOutputSchemaRejected" $ do
    it "recognizes schema rejection messages across provider variants" $ do
      structuredOutputSchemaRejected "output_config.format.schema is not supported"
        `shouldBe` True

    it "does not classify unrelated errors as schema rejection" $ do
      structuredOutputSchemaRejected "timeout while contacting provider"
        `shouldBe` False

  describe "shouldRetryWithJsonObjectFallback" $ do
    it "retries json-schema requests when the provider rejects the schema" $ do
      shouldRetryWithJsonObjectFallback
        (CortexResponseJsonSchema "sample" (Aeson.object ["type" Aeson..= ("object" :: T.Text)]))
        "structured-output schema rejected"
        `shouldBe` True

    it "does not retry text responses with json-object fallback" $ do
      shouldRetryWithJsonObjectFallback CortexResponseText "structured-output schema rejected"
        `shouldBe` False

jsonChoice :: Aeson.Value -> CortexChoice
jsonChoice value =
  emptyChoice (TE.decodeUtf8 (BSL.toStrict (Aeson.encode value)))

emptyChoice :: T.Text -> CortexChoice
emptyChoice content =
  CortexChoice
    { cortexChoiceContent = content
    , cortexChoiceSourceLinks = []
    , cortexChoiceToolCalls = []
    , cortexChoiceFinishReason = Nothing
    , cortexChoiceUsage = Nothing
    , cortexChoiceReasoning = Nothing
    , cortexChoiceReasoningDetails = Nothing
    }
