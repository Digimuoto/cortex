{- |
Module      : Cortex.Wire.Package.Manifest
Description : Filesystem manifests for inert downstream Wire packages.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Manifest loading is compile-time only. A loaded 'WirePackage' contributes
namespace `use` entries, contract specs, and executor admission projections; it
does not carry credentials or runnable Pulse actions.
-}
module Cortex.Wire.Package.Manifest
  ( WirePackageManifestError (..)
  , decodeWirePackageManifest
  , loadWirePackageManifest
  , loadWirePackageManifests
  , renderWirePackageManifestError
  )
where

import Control.Applicative ((<|>))
import Control.Exception (IOException, displayException, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific qualified as Scientific
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Vector qualified as Vector
import Toml qualified
import Toml.Schema qualified as Toml

import Cortex.Wire.AST
  ( WireInputCardinality (..)
  , WireInputPort (..)
  , WireOutputPort (..)
  , WirePorts (..)
  )
import Cortex.Wire.Contract (WireContractSpec (..))
import Cortex.Wire.Executor
  ( WireExecutorConfigShape (..)
  , WireExecutorEffect (..)
  , WireExecutorId (..)
  , WireExecutorPortPolicy (..)
  , WireExecutorProjection (..)
  )
import Cortex.Wire.Package (NamespaceEntry (..), WirePackage (..))
import Cortex.Wire.Syntax (ContractId (..))
import Cortex.Wire.Value (WirePayloadKind, parseWirePayloadKindText)

data WirePackageManifestError
  = WirePackageManifestReadError !FilePath !Text
  | WirePackageManifestDecodeError !FilePath !Text
  deriving stock (Eq, Show)

renderWirePackageManifestError :: WirePackageManifestError -> Text
renderWirePackageManifestError = \case
  WirePackageManifestReadError path errText ->
    "could not read Wire package manifest " <> T.pack path <> ": " <> errText
  WirePackageManifestDecodeError path errText ->
    "invalid Wire package manifest " <> T.pack path <> ": " <> errText

loadWirePackageManifests :: [FilePath] -> IO (Either WirePackageManifestError [WirePackage])
loadWirePackageManifests =
  foldr step (pure (Right []))
  where
    step path acc = do
      loaded <- loadWirePackageManifest path
      case loaded of
        Left err -> pure (Left err)
        Right package -> fmap (package :) <$> acc

loadWirePackageManifest :: FilePath -> IO (Either WirePackageManifestError WirePackage)
loadWirePackageManifest path = do
  readResult <- tryReadManifest path
  pure $
    case readResult of
      Left err ->
        Left (WirePackageManifestReadError path (T.pack (displayException err)))
      Right bytes ->
        decodeWirePackageManifest path bytes

tryReadManifest :: FilePath -> IO (Either IOException Text)
tryReadManifest path = try (TIO.readFile path)

decodeWirePackageManifest
  :: FilePath -> Text -> Either WirePackageManifestError WirePackage
decodeWirePackageManifest path source =
  case Toml.decode source of
    Toml.Failure errs ->
      Left (WirePackageManifestDecodeError path (renderTomlMessages errs))
    Toml.Success warnings manifest
      | null warnings ->
          Right (manifestToWirePackage manifest)
      | otherwise ->
          Left (WirePackageManifestDecodeError path (renderTomlMessages warnings))

renderTomlMessages :: [String] -> Text
renderTomlMessages =
  T.intercalate "; " . fmap T.pack

data WirePackageManifest = WirePackageManifest
  { wpmId :: !Text
  , wpmNamespaces :: ![NamespaceManifest]
  , wpmExecutorProjections :: ![WireExecutorProjection]
  , wpmContracts :: ![WireContractSpec]
  }
  deriving stock (Eq, Show)

instance Toml.FromValue WirePackageManifest where
  fromValue =
    Toml.parseTableFromValue $
      WirePackageManifest . pmId
        <$> Toml.reqKey "package"
        <*> optionalList "namespace"
        <*> optionalList "executor"
        <*> optionalList "contract"

data PackageManifest = PackageManifest
  { pmId :: !Text
  }
  deriving stock (Eq, Show)

instance Toml.FromValue PackageManifest where
  fromValue =
    Toml.parseTableFromValue $
      PackageManifest
        <$> Toml.reqKey "id"

data NamespaceManifest = NamespaceManifest
  { nmName :: !Text
  , nmExecutors :: !(Map Text Text)
  , nmContracts :: !(Map Text Text)
  }
  deriving stock (Eq, Show)

instance Toml.FromValue NamespaceManifest where
  fromValue =
    Toml.parseTableFromValue $
      NamespaceManifest
        <$> Toml.reqKey "name"
        <*> optionalMap "executors"
        <*> optionalMap "contracts"

manifestToWirePackage :: WirePackageManifest -> WirePackage
manifestToWirePackage manifest =
  WirePackage
    { wpId = manifest.wpmId
    , wpNamespaceEntries = fmap namespaceManifestEntry manifest.wpmNamespaces
    , wpExecutorProjections = manifest.wpmExecutorProjections
    , wpContractSpecs = manifest.wpmContracts
    }

namespaceManifestEntry :: NamespaceManifest -> NamespaceEntry
namespaceManifestEntry manifest =
  NamespaceEntry
    { nsNamespace = manifest.nmName
    , nsResolveExecutorLeaf = (`Map.lookup` manifest.nmExecutors)
    , nsResolveContract = (`Map.lookup` manifest.nmContracts)
    }

instance Toml.FromValue WireContractSpec where
  fromValue = Toml.parseTableFromValue $ do
    rawFields <- Toml.optKey "record_fields"
    rawSchema <- Toml.optKey "schema"
    rawExamples <- optionalList "examples"
    WireContractSpec
      <$> Toml.reqKey "id"
      <*> Toml.reqKey "payload_kind"
      <*> optionalText "description"
      <*> pure (fmap (fmap ContractId) rawFields)
      <*> pure (fmap unTomlJsonValue rawSchema)
      <*> pure (fmap unTomlJsonValue rawExamples)

instance Toml.FromValue WireExecutorProjection where
  fromValue = Toml.parseTableFromValue $ do
    rawId <- Toml.reqKey "id"
    rawVocabulary <- optionalList "vocabulary"
    WireExecutorProjection (WireExecutorId rawId)
      <$> optionalValue "ports" emptyPorts
      <*> pure (Set.fromList rawVocabulary)
      <*> Toml.reqKey "effect"
      <*> optionalValue "config_shape" WireExecutorConfigUnchecked
      <*> optionalValue "port_policy" WireExecutorFixedPorts

emptyPorts :: WirePorts
emptyPorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs = Map.empty
    }

instance Toml.FromValue WireExecutorEffect where
  fromValue rawValue = do
    raw <- Toml.fromValue rawValue
    case T.toCaseFold (T.strip raw) of
      "pure" -> pure WireExecutorPure
      "model" -> pure WireExecutorModel
      "host_effect" -> pure WireExecutorHostEffect
      "host-effect" -> pure WireExecutorHostEffect
      "hosteffect" -> pure WireExecutorHostEffect
      "impure" -> pure WireExecutorImpure
      other -> fail ("unknown Wire executor effect: " <> T.unpack other)

instance Toml.FromValue WireExecutorPortPolicy where
  fromValue rawValue = do
    raw <- Toml.fromValue rawValue
    case T.toCaseFold (T.strip raw) of
      "fixed" -> pure WireExecutorFixedPorts
      "fixed_ports" -> pure WireExecutorFixedPorts
      "author_declared" -> pure WireExecutorAuthorDeclaredPorts
      "author-declared" -> pure WireExecutorAuthorDeclaredPorts
      "authordeclared" -> pure WireExecutorAuthorDeclaredPorts
      other -> fail ("unknown Wire executor port policy: " <> T.unpack other)

instance Toml.FromValue WireExecutorConfigShape where
  fromValue rawValue = parseUnchecked rawValue <|> parseSchema rawValue
    where
      parseUnchecked value = do
        raw <- Toml.fromValue value
        case T.toCaseFold (T.strip raw) of
          "unchecked" -> pure WireExecutorConfigUnchecked
          other -> fail ("unknown Wire executor config shape: " <> T.unpack other)

      parseSchema =
        Toml.parseTableFromValue $
          WireExecutorConfigSchema . unTomlJsonValue <$> Toml.reqKey "schema"

instance Toml.FromValue WirePorts where
  fromValue =
    Toml.parseTableFromValue $
      WirePorts
        <$> optionalMap "inputs"
        <*> optionalMap "outputs"

instance Toml.FromValue WireInputPort where
  fromValue =
    Toml.parseTableFromValue $
      WireInputPort
        <$> Toml.reqKey "accepts"
        <*> optionalValue "cardinality" WireInputCardinalityMany
        <*> optionalValue "required" False

instance Toml.FromValue WireOutputPort where
  fromValue =
    Toml.parseTableFromValue $
      WireOutputPort
        <$> Toml.reqKey "contract"

instance Toml.FromValue WireInputCardinality where
  fromValue rawValue = do
    raw <- Toml.fromValue rawValue
    case T.toCaseFold (T.strip raw) of
      "one" -> pure WireInputCardinalityOne
      "many" -> pure WireInputCardinalityMany
      other -> fail ("unknown input port cardinality: " <> T.unpack other)

instance Toml.FromValue WirePayloadKind where
  fromValue rawValue = do
    raw <- Toml.fromValue rawValue
    case parseWirePayloadKindText raw of
      Just payloadKind -> pure payloadKind
      Nothing -> fail ("unknown Wire payload kind: " <> T.unpack raw)

newtype TomlJsonValue = TomlJsonValue
  { unTomlJsonValue :: Aeson.Value
  }
  deriving stock (Eq, Show)

instance Toml.FromValue TomlJsonValue where
  fromValue =
    pure . TomlJsonValue . tomlValueToAeson

tomlValueToAeson :: Toml.Value' l -> Aeson.Value
tomlValueToAeson = \case
  Toml.Integer' _ value ->
    Aeson.Number (fromInteger value)
  Toml.Double' _ value ->
    Aeson.Number (Scientific.fromFloatDigits value)
  Toml.List' _ values ->
    Aeson.Array (Vector.fromList (fmap tomlValueToAeson values))
  Toml.Table' _ (Toml.MkTable values) ->
    Aeson.Object
      ( AesonKeyMap.fromList
          [ (AesonKey.fromText key, tomlValueToAeson value)
          | (key, (_, value)) <- Map.toList values
          ]
      )
  Toml.Bool' _ value ->
    Aeson.Bool value
  Toml.Text' _ value ->
    Aeson.String value
  Toml.TimeOfDay' _ value ->
    Aeson.String (T.pack (show value))
  Toml.ZonedTime' _ value ->
    Aeson.String (T.pack (show value))
  Toml.LocalTime' _ value ->
    Aeson.String (T.pack (show value))
  Toml.Day' _ value ->
    Aeson.String (T.pack (show value))

optionalList :: Toml.FromValue a => Text -> Toml.ParseTable l [a]
optionalList key =
  fromMaybe [] <$> Toml.optKey key

optionalMap :: Toml.FromValue a => Text -> Toml.ParseTable l (Map Text a)
optionalMap key =
  fromMaybe Map.empty <$> Toml.optKey key

optionalText :: Text -> Toml.ParseTable l Text
optionalText key =
  optionalValue key ""

optionalValue :: Toml.FromValue a => Text -> a -> Toml.ParseTable l a
optionalValue key defaultValue =
  fromMaybe defaultValue <$> Toml.optKey key
