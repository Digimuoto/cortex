{- |
Module      : Cortex.Wire.ContractValidationSpec
Description : Tests for ADR 0085 Wire contract schema validation.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Exercises the upstreamed contract-schema validator (Logos ADR 0015 subset):
the twelve incubator cases, the recorded @artifact_ref@ divergence, and the
dialect-pinning cases mirrored by the Lean fixtures under
@theory/Cortex/Wire/ContractValidation/Emitted@.
-}
module Cortex.Wire.ContractValidationSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Test.Hspec

import Cortex.Wire
  ( WireContractRegistry
  , WireContractSpec (..)
  , WirePayloadKind (..)
  , wireContractRegistryFromList
  )
import Cortex.Wire.ContractValidation
import Cortex.Wire.LeanFixture
  ( ContractValidationFixture (..)
  , contractValidationFixtures
  , renderContractValidationFixtureModule
  , renderContractValidationUmbrellaModule
  )

spec :: Spec
spec = describe "Cortex.Wire.ContractValidation" $ do
  describe "incubator cases (Logos ADR 0015)" $ do
    it "reports a missing contract id" $
      validateWireContractPayload sampleRegistry "MissingRequest" (Aeson.object [])
        `shouldBe` Left (WireContractValidationMissingContract "MissingRequest")

    it "rejects text Wire payload kinds" $
      validateWireContractPayload textKindRegistry "SearchRequest" (Aeson.object [])
        `shouldBe` Left (WireContractValidationNonJsonPayload "SearchRequest" WirePayloadText)

    it "returns an object schema for JSON object contracts" $
      fmap Aeson.Object (wireContractJsonObjectSchema sampleRegistry "SearchRequest")
        `shouldBe` Right searchSchema

    it "requires object contracts to expose an object schema" $
      wireContractJsonObjectSchema missingSchemaRegistry "SearchRequest"
        `shouldBe` Left (WireContractValidationMissingSchema "SearchRequest")

    it "accepts a payload that matches the supported schema subset" $
      validateWireContractPayload sampleRegistry "SearchRequest" validPayload
        `shouldBe` Right ()

    it "rejects missing required nested properties with a JSON path" $
      validateWireContractPayload
        sampleRegistry
        "SearchRequest"
        ( Aeson.object
            [ "query" .= ("amd" :: String)
            , "filters" .= Aeson.object []
            , "tags" .= ["filing" :: String]
            ]
        )
        `shouldBe` Left
          ( WireContractValidationRequiredPropertyMissing
              "SearchRequest"
              (WireJsonPathProperty WireJsonPathRoot "filters")
              "region"
          )

    it "rejects unexpected properties when additionalProperties is false" $
      validateWireContractPayload
        sampleRegistry
        "SearchRequest"
        ( Aeson.object
            [ "query" .= ("amd" :: String)
            , "private" .= True
            , "filters" .= Aeson.object ["region" .= ("us" :: String)]
            , "tags" .= ["filing" :: String]
            ]
        )
        `shouldBe` Left
          (WireContractValidationUnexpectedProperty "SearchRequest" WireJsonPathRoot "private")

    it "rejects enum values outside the schema enum" $
      validateWireContractPayload
        sampleRegistry
        "SearchRequest"
        ( Aeson.object
            [ "query" .= ("amd" :: String)
            , "category" .= ("social" :: String)
            , "filters" .= Aeson.object ["region" .= ("us" :: String)]
            , "tags" .= ["filing" :: String]
            ]
        )
        `shouldBe` Left
          ( WireContractValidationEnumMismatch
              "SearchRequest"
              (WireJsonPathProperty WireJsonPathRoot "category")
              (Aeson.String "social")
          )

    it "validates array items and reports indexed paths" $
      validateWireContractPayload
        sampleRegistry
        "SearchRequest"
        ( Aeson.object
            [ "query" .= ("amd" :: String)
            , "filters" .= Aeson.object ["region" .= ("us" :: String)]
            , "tags" .= ["filing" :: String, ""]
            ]
        )
        `shouldBe` Left
          ( WireContractValidationStringTooShort
              "SearchRequest"
              (WireJsonPathIndex (WireJsonPathProperty WireJsonPathRoot "tags") 1)
              1
              0
          )

    it "validates string length bounds" $
      validateWireContractPayload
        sampleRegistry
        "SearchRequest"
        ( Aeson.object
            [ "query" .= ("" :: String)
            , "filters" .= Aeson.object ["region" .= ("us" :: String)]
            , "tags" .= ["filing" :: String]
            ]
        )
        `shouldBe` Left
          ( WireContractValidationStringTooShort
              "SearchRequest"
              (WireJsonPathProperty WireJsonPathRoot "query")
              1
              0
          )

    it "validates numeric bounds" $
      validateWireContractPayload
        sampleRegistry
        "SearchRequest"
        ( Aeson.object
            [ "query" .= ("amd" :: String)
            , "limit" .= (101 :: Int)
            , "filters" .= Aeson.object ["region" .= ("us" :: String)]
            , "tags" .= ["filing" :: String]
            ]
        )
        `shouldBe` Left
          ( WireContractValidationNumberTooLarge
              "SearchRequest"
              (WireJsonPathProperty WireJsonPathRoot "limit")
              100
              101
          )

    it "validates examples with the same payload rules" $
      validateWireContractExamples invalidExampleRegistry "SearchRequest"
        `shouldBe` Left
          ( WireContractValidationEnumMismatch
              "SearchRequest"
              (WireJsonPathProperty WireJsonPathRoot "category")
              (Aeson.String "social")
          )

  describe "artifact_ref divergence (ADR 0085)" $ do
    it "accepts artifact_ref payload kinds through the gate" $
      validateWireContractPayload artifactRefRegistry "ReportRef" validReference
        `shouldBe` Right ()

    it "validates the reference object against the declared schema" $
      validateWireContractPayload artifactRefRegistry "ReportRef" (Aeson.object [])
        `shouldBe` Left
          ( WireContractValidationRequiredPropertyMissing
              "ReportRef"
              WireJsonPathRoot
              "artifact_id"
          )

    it "shape-gates artifact_ref payloads even when the schema would permit otherwise" $
      -- The declared schema is a string enum, but an artifact_ref payload
      -- must still be a reference object: the exported validator applies the
      -- same shallow shape gate as runtime egress.
      validateWireContractPayload permissiveRefRegistry "LooseRef" (Aeson.String "artifact-1")
        `shouldBe` Left
          ( WireContractValidationShapeMismatch
              "LooseRef"
              WirePayloadArtifactRef
              "a JSON object"
          )

    it "shape-gates examples with the same rule" $
      validateWireContractExamples permissiveRefRegistry "LooseRef"
        `shouldBe` Left
          ( WireContractValidationShapeMismatch
              "LooseRef"
              WirePayloadArtifactRef
              "a JSON object"
          )

  describe "dialect pins (mirrored by the Lean fixtures)" $ do
    it "integer accepts a whole-valued decimal and a literal integer" $ do
      validateAgainst integerSchema (Aeson.Number 2) `shouldBe` Right ()
      validateAgainst integerSchema (Aeson.Number 2.0) `shouldBe` Right ()

    it "integer rejects a fractional number" $
      validateAgainst integerSchema (Aeson.Number 2.5)
        `shouldBe` Left
          (WireContractValidationTypeMismatch "Pin" WireJsonPathRoot ["integer"] "number")

    it "type unions admit any member and unknown names admit nothing" $ do
      validateAgainst unionSchema (Aeson.String "ok") `shouldBe` Right ()
      validateAgainst unionSchema Aeson.Null `shouldBe` Right ()
      validateAgainst unionSchema (Aeson.Bool True)
        `shouldBe` Left
          ( WireContractValidationTypeMismatch
              "Pin"
              WireJsonPathRoot
              ["string", "null", "mystery"]
              "boolean"
          )

    it "an empty enum rejects everything while an empty type list admits everything" $ do
      validateAgainst (Aeson.object ["enum" .= ([] :: [Aeson.Value])]) Aeson.Null
        `shouldBe` Left (WireContractValidationEnumMismatch "Pin" WireJsonPathRoot Aeson.Null)
      validateAgainst (Aeson.object ["type" .= ([] :: [String])]) Aeson.Null
        `shouldBe` Right ()

    it "enum matching performs no type coercion" $
      validateAgainst
        (Aeson.object ["enum" .= [Aeson.Number 1]])
        (Aeson.String "1")
        `shouldBe` Left
          (WireContractValidationEnumMismatch "Pin" WireJsonPathRoot (Aeson.String "1"))

    it "string and number bounds are inclusive" $ do
      validateAgainst
        (Aeson.object ["minLength" .= (2 :: Int), "maxLength" .= (2 :: Int)])
        (Aeson.String "ab")
        `shouldBe` Right ()
      validateAgainst
        (Aeson.object ["minimum" .= (2 :: Int), "maximum" .= (2 :: Int)])
        (Aeson.Number 2)
        `shouldBe` Right ()

    it "ignores unsupported schema keywords" $
      validateAgainst
        (Aeson.object ["pattern" .= ("^a" :: String), "format" .= ("uri" :: String)])
        (Aeson.String "zzz")
        `shouldBe` Right ()

    it "requires the schema node to be an object" $
      validateAgainst (Aeson.String "not a schema") Aeson.Null
        `shouldBe` Left
          ( WireContractValidationInvalidSchema
              "Pin"
              WireJsonPathRoot
              "schema node must be an object"
          )

    it "rejects a schema-valued additionalProperties" $
      validateAgainst
        ( Aeson.object
            [ "additionalProperties" .= Aeson.object ["type" .= ("string" :: String)]
            ]
        )
        (Aeson.object ["k" .= True])
        `shouldBe` Left
          ( WireContractValidationInvalidSchema
              "Pin"
              (WireJsonPathProperty WireJsonPathRoot "additionalProperties")
              "additionalProperties must be a boolean"
          )

  -- Regenerate with `just wire-lean-fixtures` when the renderer or the
  -- fixture corpus changes; a drift failure here means the checked-in Lean
  -- modules no longer match current renderer output.
  describe "emitted Lean dialect fixtures" $ do
    forM_ contractValidationFixtures $ \fixture ->
      it ("matches the checked-in module for " <> T.unpack fixture.cvFixtureSlug) $
        case renderContractValidationFixtureModule fixture of
          Left err -> expectationFailure (T.unpack (renderWireContractValidationError err))
          Right rendered -> do
            checkedIn <-
              TIO.readFile
                ( "theory/Cortex/Wire/ContractValidation/Emitted/"
                    <> T.unpack fixture.cvFixtureSlug
                    <> ".lean"
                )
            rendered `shouldBe` checkedIn

    it "matches the checked-in umbrella (dialect version pin included)" $ do
      checkedIn <- TIO.readFile "theory/Cortex/Wire/ContractValidation/Emitted.lean"
      renderContractValidationUmbrellaModule contractValidationFixtures `shouldBe` checkedIn

validateAgainst :: Aeson.Value -> Aeson.Value -> Either WireContractValidationError ()
validateAgainst = validateJsonValueAgainstSchema "Pin"

integerSchema :: Aeson.Value
integerSchema = Aeson.object ["type" .= ("integer" :: String)]

unionSchema :: Aeson.Value
unionSchema = Aeson.object ["type" .= (["string", "null", "mystery"] :: [String])]

validPayload :: Aeson.Value
validPayload =
  Aeson.object
    [ "query" .= ("amd" :: String)
    , "limit" .= (10 :: Int)
    , "category" .= ("filings" :: String)
    , "filters" .= Aeson.object ["region" .= ("us" :: String)]
    , "tags" .= ["filing" :: String, "earnings"]
    ]

validReference :: Aeson.Value
validReference =
  Aeson.object
    [ "artifact_id" .= ("artifact-1" :: String)
    , "digest" .= ("sha256:abc" :: String)
    ]

sampleRegistry :: WireContractRegistry
sampleRegistry =
  wireContractRegistryFromList [sampleContract]

textKindRegistry :: WireContractRegistry
textKindRegistry =
  wireContractRegistryFromList [sampleContract {wireContractSpecPayloadKind = WirePayloadText}]

missingSchemaRegistry :: WireContractRegistry
missingSchemaRegistry =
  wireContractRegistryFromList [sampleContract {wireContractSpecSchema = Nothing}]

invalidExampleRegistry :: WireContractRegistry
invalidExampleRegistry =
  wireContractRegistryFromList
    [ sampleContract
        { wireContractSpecExamples =
            [ Aeson.object
                [ "query" .= ("amd" :: String)
                , "category" .= ("social" :: String)
                , "filters" .= Aeson.object ["region" .= ("us" :: String)]
                , "tags" .= ["filing" :: String]
                ]
            ]
        }
    ]

artifactRefRegistry :: WireContractRegistry
artifactRefRegistry =
  wireContractRegistryFromList
    [ WireContractSpec
        { wireContractSpecId = "ReportRef"
        , wireContractSpecPayloadKind = WirePayloadArtifactRef
        , wireContractSpecDescription = "Report artifact reference."
        , wireContractSpecRecordFields = Nothing
        , wireContractSpecSchema =
            Just
              ( Aeson.object
                  [ "type" .= ("object" :: String)
                  , "required" .= ["artifact_id" :: String]
                  , "properties"
                      .= Aeson.object
                        [ "artifact_id" .= Aeson.object ["type" .= ("string" :: String)]
                        , "digest" .= Aeson.object ["type" .= ("string" :: String)]
                        ]
                  ]
              )
        , wireContractSpecExamples = []
        }
    ]

{- | An artifact_ref contract whose schema would accept a bare string — used
to pin that the shape gate still requires a reference object.
-}
permissiveRefRegistry :: WireContractRegistry
permissiveRefRegistry =
  wireContractRegistryFromList
    [ WireContractSpec
        { wireContractSpecId = "LooseRef"
        , wireContractSpecPayloadKind = WirePayloadArtifactRef
        , wireContractSpecDescription = "Reference with a permissive schema."
        , wireContractSpecRecordFields = Nothing
        , wireContractSpecSchema =
            Just (Aeson.object ["enum" .= [Aeson.String "artifact-1"]])
        , wireContractSpecExamples = [Aeson.String "artifact-1"]
        }
    ]

sampleContract :: WireContractSpec
sampleContract =
  WireContractSpec
    { wireContractSpecId = "SearchRequest"
    , wireContractSpecPayloadKind = WirePayloadJson
    , wireContractSpecDescription = "Search request payload."
    , wireContractSpecRecordFields = Nothing
    , wireContractSpecSchema = Just searchSchema
    , wireContractSpecExamples = [validPayload]
    }

searchSchema :: Aeson.Value
searchSchema =
  Aeson.object
    [ "type" .= ("object" :: String)
    , "additionalProperties" .= False
    , "required" .= ["query" :: String, "filters", "tags"]
    , "properties"
        .= Aeson.object
          [ "query"
              .= Aeson.object
                [ "type" .= ("string" :: String)
                , "minLength" .= (1 :: Int)
                , "maxLength" .= (40 :: Int)
                ]
          , "limit"
              .= Aeson.object
                [ "type" .= ("integer" :: String)
                , "minimum" .= (1 :: Int)
                , "maximum" .= (100 :: Int)
                ]
          , "category"
              .= Aeson.object
                [ "type" .= ("string" :: String)
                , "enum" .= ["news" :: String, "filings"]
                ]
          , "filters"
              .= Aeson.object
                [ "type" .= ("object" :: String)
                , "additionalProperties" .= False
                , "required" .= ["region" :: String]
                , "properties"
                    .= Aeson.object
                      [ "region" .= Aeson.object ["type" .= ("string" :: String)]
                      ]
                ]
          , "tags"
              .= Aeson.object
                [ "type" .= ("array" :: String)
                , "items"
                    .= Aeson.object
                      [ "type" .= ("string" :: String)
                      , "minLength" .= (1 :: Int)
                      ]
                ]
          ]
    ]
