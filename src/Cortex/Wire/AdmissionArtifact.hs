{- |
Module      : Cortex.Wire.AdmissionArtifact
Description : Proof-shaped Wire admission artifacts.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

These artifacts mirror the Lean Wire admission carriers closely enough for the
Haskell compiler to expose its lowering decisions without serializing Lean proof
terms. They are deterministic evidence records, intended for tests and later
Lean-side validation.
-}
module Cortex.Wire.AdmissionArtifact
  ( AdmissionPortLabel (..)
  , AdmissionBoundaryPort (..)
  , AdmissionConnection (..)
  , PrimitiveGraphStep (..)
  , ProductShapeArtifact (..)
  , PhantomAdapterDirection (..)
  , PhantomAdapterArtifact (..)
  , AdmissionStaticField (..)
  , AdmissionStaticValue (..)
  , GeneratedChildSourceArtifact (..)
  , GeneratedChildArtifact (..)
  , GeneratedFormKind (..)
  , GeneratedFormArtifact (..)
  , SelectResolutionMode (..)
  , SelectVariantArtifact (..)
  , SelectArmAdmissionArtifact (..)
  , SelectAdmissionArtifact (..)
  , WireAdmissionClosureMode (..)
  , AdmissionTerminalDischargeKind (..)
  , AdmissionInputUseKind (..)
  , AdmissionInputUseWitness (..)
  , AdmissionOutputUseKind (..)
  , AdmissionOutputUseWitness (..)
  , AdmissionEndpointUseWitness (..)
  , WireAdmissionArtifact (..)
  , wireAdmissionCurrentSchemaVersion
  , emptyWireAdmissionArtifact
  , emptyAdmissionEndpointUseWitness
  , deriveAdmissionEndpointUseWitness
  , finalizeWireAdmissionArtifact
  , appendPrimitiveStep
  , appendGeneratedFormArtifact
  , appendPhantomAdapterArtifact
  , appendSelectAdmissionArtifact
  , combineWireAdmissionArtifacts
  , wireAdmissionArtifactValidatorReady
  , wireAdmissionEndpointUseLinear
  , wireAdmissionMetadataKey
  , wireAdmissionMetadataValue
  )
where

import Data.Aeson (FromJSON, ToJSON, Value, (.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Aeson.Types (Parser)
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

import Cortex.Wire.AST (Connection (..), EndpointRef (..))
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..))
import Cortex.Wire.Syntax (boundedIndexedContractName)

data AdmissionPortLabel
  = AdmissionNoLabel
  | AdmissionLabel !Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data AdmissionBoundaryPort = AdmissionBoundaryPort
  { admissionBoundaryNode :: !CircuitNodeRef
  , admissionBoundaryPort :: !Text
  , admissionBoundaryContract :: !Text
  , admissionBoundaryLabel :: !AdmissionPortLabel
  , admissionBoundaryExclusiveGroup :: !(Maybe (CircuitNodeRef, Natural))
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON AdmissionBoundaryPort where
  parseJSON =
    Aeson.withObject "AdmissionBoundaryPort" $ \obj -> do
      boundaryNode <- obj .: "admissionBoundaryNode"
      boundaryPort <- obj .: "admissionBoundaryPort"
      boundaryContract <- obj .: "admissionBoundaryContract"
      boundaryLabel <- obj .: "admissionBoundaryLabel"
      boundaryExclusiveGroup <- parseExclusiveGroup =<< obj .: "admissionBoundaryExclusiveGroup"
      pure
        AdmissionBoundaryPort
          { admissionBoundaryNode = boundaryNode
          , admissionBoundaryPort = boundaryPort
          , admissionBoundaryContract = boundaryContract
          , admissionBoundaryLabel = boundaryLabel
          , admissionBoundaryExclusiveGroup = boundaryExclusiveGroup
          }
    where
      parseExclusiveGroup
        :: Maybe (CircuitNodeRef, Integer) -> Parser (Maybe (CircuitNodeRef, Natural))
      parseExclusiveGroup = \case
        Nothing ->
          pure Nothing
        Just (groupOwner, groupIndex) ->
          Just . (groupOwner,)
            <$> nonNegativeNatural "exclusive group index" groupIndex

data AdmissionConnection = AdmissionConnection
  { admissionConnectionFrom :: !AdmissionBoundaryPort
  , admissionConnectionTo :: !AdmissionBoundaryPort
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PrimitiveGraphStep
  = PrimitiveEmpty
  | PrimitiveNode !CircuitNodeRef ![AdmissionBoundaryPort] ![AdmissionBoundaryPort]
  | PrimitiveBindingRef !Text
  | PrimitiveOverlay ![CircuitNodeRef] ![CircuitNodeRef] ![Text] ![Text]
  | PrimitiveConnect
      ![AdmissionBoundaryPort]
      ![AdmissionBoundaryPort]
      ![AdmissionConnection]
      ![AdmissionBoundaryPort]
      ![AdmissionBoundaryPort]
  deriving stock (Eq, Show)

instance ToJSON PrimitiveGraphStep where
  toJSON = \case
    PrimitiveEmpty ->
      Aeson.object ["tag" Aeson..= ("PrimitiveEmpty" :: Text)]
    PrimitiveNode node entries exits ->
      Aeson.object
        [ "tag" Aeson..= ("PrimitiveNode" :: Text)
        , "node" Aeson..= node
        , "entries" Aeson..= entries
        , "exits" Aeson..= exits
        ]
    PrimitiveBindingRef binding ->
      Aeson.object
        [ "tag" Aeson..= ("PrimitiveBindingRef" :: Text)
        , "binding" Aeson..= binding
        ]
    PrimitiveOverlay leftNodes rightNodes leftBindings rightBindings ->
      Aeson.object
        [ "tag" Aeson..= ("PrimitiveOverlay" :: Text)
        , "leftNodes" Aeson..= leftNodes
        , "rightNodes" Aeson..= rightNodes
        , "leftBindings" Aeson..= leftBindings
        , "rightBindings" Aeson..= rightBindings
        ]
    PrimitiveConnect leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ->
      Aeson.object
        [ "tag" Aeson..= ("PrimitiveConnect" :: Text)
        , "leftExits" Aeson..= leftExits
        , "rightEntries" Aeson..= rightEntries
        , "matchedPairs" Aeson..= matchedPairs
        , "unmatchedLeftExits" Aeson..= unmatchedLeftExits
        , "unmatchedRightEntries" Aeson..= unmatchedRightEntries
        ]

instance FromJSON PrimitiveGraphStep where
  parseJSON =
    Aeson.withObject "PrimitiveGraphStep" $ \obj -> do
      tag <- obj .: "tag"
      case (tag :: Text) of
        "PrimitiveEmpty" ->
          pure PrimitiveEmpty
        "PrimitiveNode" ->
          PrimitiveNode
            <$> obj .: "node"
            <*> obj .: "entries"
            <*> obj .: "exits"
        "PrimitiveBindingRef" ->
          PrimitiveBindingRef <$> obj .: "binding"
        "PrimitiveOverlay" ->
          PrimitiveOverlay
            <$> obj .: "leftNodes"
            <*> obj .: "rightNodes"
            <*> obj .: "leftBindings"
            <*> obj .: "rightBindings"
        "PrimitiveConnect" ->
          PrimitiveConnect
            <$> obj .: "leftExits"
            <*> obj .: "rightEntries"
            <*> obj .: "matchedPairs"
            <*> obj .: "unmatchedLeftExits"
            <*> obj .: "unmatchedRightEntries"
        other ->
          fail ("unknown primitive graph step tag: " <> T.unpack other)

data ProductShapeArtifact
  = ProductRecord !Text ![(Text, Text)]
  | ProductIndexed !Text !Natural
  deriving stock (Eq, Show)

instance ToJSON ProductShapeArtifact where
  toJSON = \case
    ProductRecord contract fields ->
      Aeson.object
        [ "kind" Aeson..= ("record" :: Text)
        , "contract" Aeson..= contract
        , "fields" Aeson..= fields
        ]
    ProductIndexed elementContract count ->
      Aeson.object
        [ "kind" Aeson..= ("indexed" :: Text)
        , "elementContract" Aeson..= elementContract
        , "count" Aeson..= count
        ]

instance FromJSON ProductShapeArtifact where
  parseJSON =
    Aeson.withObject "ProductShapeArtifact" $ \obj -> do
      kind <- obj .: "kind"
      case (kind :: Text) of
        "record" ->
          ProductRecord <$> obj .: "contract" <*> obj .: "fields"
        "indexed" -> do
          elementContract <- obj .: "elementContract"
          count <- obj .: "count"
          ProductIndexed elementContract
            <$> nonNegativeNatural "indexed product count" count
        other ->
          fail ("unknown product shape kind: " <> T.unpack other)

data PhantomAdapterDirection
  = PhantomGather
  | PhantomScatter
  deriving stock (Eq, Show, Generic)

instance ToJSON PhantomAdapterDirection where
  toJSON = \case
    PhantomGather -> Aeson.String "gather"
    PhantomScatter -> Aeson.String "scatter"

instance FromJSON PhantomAdapterDirection where
  parseJSON =
    Aeson.withText "PhantomAdapterDirection" $ \case
      "gather" -> pure PhantomGather
      "scatter" -> pure PhantomScatter
      other -> fail ("unknown phantom adapter direction: " <> T.unpack other)

data PhantomAdapterArtifact = PhantomAdapterArtifact
  { phantomAdapterDirection :: !PhantomAdapterDirection
  , phantomAdapterNode :: !CircuitNodeRef
  , phantomAdapterProductShape :: !ProductShapeArtifact
  , phantomAdapterSingular :: !AdmissionBoundaryPort
  , phantomAdapterMulti :: ![AdmissionBoundaryPort]
  , phantomAdapterLeftBulk :: ![AdmissionConnection]
  , phantomAdapterRightBulk :: ![AdmissionConnection]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data AdmissionStaticField = AdmissionStaticField
  { admissionStaticFieldLabel :: !Text
  , admissionStaticFieldValue :: !AdmissionStaticValue
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON AdmissionStaticField where
  toJSON field =
    Aeson.object
      [ "label" Aeson..= field.admissionStaticFieldLabel
      , "value" Aeson..= field.admissionStaticFieldValue
      ]

instance FromJSON AdmissionStaticField where
  parseJSON =
    Aeson.withObject "AdmissionStaticField" $ \obj ->
      AdmissionStaticField
        <$> obj .: "label"
        <*> obj .: "value"

data AdmissionStaticValue
  = AdmissionStaticString !Text
  | AdmissionStaticBool !Bool
  | AdmissionStaticNat !Natural
  | AdmissionStaticList ![AdmissionStaticValue]
  | AdmissionStaticRecord ![AdmissionStaticField]
  deriving stock (Eq, Show, Generic)

instance ToJSON AdmissionStaticValue where
  toJSON = \case
    AdmissionStaticString text ->
      Aeson.object
        [ "kind" Aeson..= ("string" :: Text)
        , "value" Aeson..= text
        ]
    AdmissionStaticBool boolValue ->
      Aeson.object
        [ "kind" Aeson..= ("bool" :: Text)
        , "value" Aeson..= boolValue
        ]
    AdmissionStaticNat natValue ->
      Aeson.object
        [ "kind" Aeson..= ("nat" :: Text)
        , "value" Aeson..= natValue
        ]
    AdmissionStaticList values ->
      Aeson.object
        [ "kind" Aeson..= ("list" :: Text)
        , "values" Aeson..= values
        ]
    AdmissionStaticRecord fields ->
      Aeson.object
        [ "kind" Aeson..= ("record" :: Text)
        , "fields" Aeson..= fields
        ]

instance FromJSON AdmissionStaticValue where
  parseJSON =
    Aeson.withObject "AdmissionStaticValue" $ \obj -> do
      kind <- obj .: "kind"
      case (kind :: Text) of
        "string" ->
          AdmissionStaticString <$> obj .: "value"
        "bool" ->
          AdmissionStaticBool <$> obj .: "value"
        "nat" ->
          AdmissionStaticNat <$> obj .: "value"
        "list" ->
          AdmissionStaticList <$> obj .: "values"
        "record" ->
          AdmissionStaticRecord <$> obj .: "fields"
        other ->
          fail ("unknown admission static value kind: " <> T.unpack other)

data GeneratedChildSourceArtifact = GeneratedChildSourceArtifact
  { generatedSourceChildNode :: !CircuitNodeRef
  , generatedSourceChildLabel :: !Text
  , generatedSourceChildValue :: !(Maybe AdmissionStaticValue)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GeneratedChildArtifact = GeneratedChildArtifact
  { generatedChildNode :: !CircuitNodeRef
  , generatedChildLabel :: !Text
  , generatedChildOutputs :: ![AdmissionBoundaryPort]
  , generatedChildInputs :: ![AdmissionBoundaryPort]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GeneratedFormKind
  = GeneratedMake
  | GeneratedMakeEach
  deriving stock (Eq, Show, Generic)

instance ToJSON GeneratedFormKind where
  toJSON = \case
    GeneratedMake -> Aeson.String "GeneratedMake"
    GeneratedMakeEach -> Aeson.String "GeneratedMakeEach"

instance FromJSON GeneratedFormKind where
  parseJSON =
    Aeson.withText "GeneratedFormKind" $ \case
      "GeneratedMake" -> pure GeneratedMake
      "GeneratedMakeEach" -> pure GeneratedMakeEach
      other -> fail ("unknown generated form kind: " <> T.unpack other)

data GeneratedFormArtifact = GeneratedFormArtifact
  { generatedFormKind :: !GeneratedFormKind
  , generatedFormKindName :: !Text
  , generatedFormBinding :: !Text
  , generatedFormSourceChildren :: ![GeneratedChildSourceArtifact]
  , generatedFormUsedChildren :: ![GeneratedChildArtifact]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SelectResolutionMode
  = SelectResolvedByLabel
  | SelectResolvedByContract
  deriving stock (Eq, Show, Generic)

instance ToJSON SelectResolutionMode where
  toJSON = \case
    SelectResolvedByLabel -> Aeson.String "SelectResolvedByLabel"
    SelectResolvedByContract -> Aeson.String "SelectResolvedByContract"

instance FromJSON SelectResolutionMode where
  parseJSON =
    Aeson.withText "SelectResolutionMode" $ \case
      "SelectResolvedByLabel" -> pure SelectResolvedByLabel
      "SelectResolvedByContract" -> pure SelectResolvedByContract
      other -> fail ("unknown select resolution mode: " <> T.unpack other)

data SelectVariantArtifact = SelectVariantArtifact
  { selectVariantKey :: !Text
  , selectVariantPort :: !AdmissionBoundaryPort
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data SelectArmAdmissionArtifact = SelectArmAdmissionArtifact
  { selectArmSourceIndex :: !Natural
  , selectArmSourceKey :: !Text
  , selectArmCanonicalKey :: !Text
  , selectArmResolutionMode :: !SelectResolutionMode
  , selectArmBodyNodes :: ![CircuitNodeRef]
  , selectArmBodyEntries :: ![AdmissionBoundaryPort]
  , selectArmBodyExits :: ![AdmissionBoundaryPort]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

instance FromJSON SelectArmAdmissionArtifact where
  parseJSON =
    Aeson.withObject "SelectArmAdmissionArtifact" $ \obj -> do
      sourceIndex <- obj .: "selectArmSourceIndex"
      SelectArmAdmissionArtifact
        <$> nonNegativeNatural "select arm source index" sourceIndex
        <*> obj .: "selectArmSourceKey"
        <*> obj .: "selectArmCanonicalKey"
        <*> obj .: "selectArmResolutionMode"
        <*> obj .: "selectArmBodyNodes"
        <*> obj .: "selectArmBodyEntries"
        <*> obj .: "selectArmBodyExits"

nonNegativeNatural :: String -> Integer -> Parser Natural
nonNegativeNatural context integerValue
  | integerValue >= 0 = pure (fromInteger integerValue)
  | otherwise = fail (context <> " must be non-negative: " <> show integerValue)

data SelectAdmissionArtifact = SelectAdmissionArtifact
  { selectAdmissionOwner :: !CircuitNodeRef
  , selectAdmissionVariants :: ![SelectVariantArtifact]
  , selectAdmissionArms :: ![SelectArmAdmissionArtifact]
  , selectAdmissionConditionNode :: !CircuitNodeRef
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WireAdmissionClosureMode
  = AdmissionClosedExecutable
  | AdmissionOpenFragment
  deriving stock (Eq, Show, Generic)

instance ToJSON WireAdmissionClosureMode where
  toJSON = \case
    AdmissionClosedExecutable -> Aeson.String "closed_executable"
    AdmissionOpenFragment -> Aeson.String "open_fragment"

instance FromJSON WireAdmissionClosureMode where
  parseJSON =
    Aeson.withText "WireAdmissionClosureMode" $ \case
      "closed_executable" -> pure AdmissionClosedExecutable
      "open_fragment" -> pure AdmissionOpenFragment
      other -> fail ("unknown wire admission closure mode: " <> T.unpack other)

data AdmissionTerminalDischargeKind
  = AdmissionExportedBoundary
  | AdmissionHostReturn
  | AdmissionProofBoundarySink
  deriving stock (Eq, Show, Generic)

instance ToJSON AdmissionTerminalDischargeKind where
  toJSON = \case
    AdmissionExportedBoundary -> Aeson.String "exported_boundary"
    AdmissionHostReturn -> Aeson.String "host_return"
    AdmissionProofBoundarySink -> Aeson.String "proof_boundary_sink"

instance FromJSON AdmissionTerminalDischargeKind where
  parseJSON =
    Aeson.withText "AdmissionTerminalDischargeKind" $ \case
      "exported_boundary" -> pure AdmissionExportedBoundary
      "host_return" -> pure AdmissionHostReturn
      "proof_boundary_sink" -> pure AdmissionProofBoundarySink
      other -> fail ("unknown admission terminal discharge kind: " <> T.unpack other)

data AdmissionInputUseKind
  = AdmissionProducedByEdge !AdmissionBoundaryPort
  | AdmissionHostInput
  | AdmissionImportedObligation
  deriving stock (Eq, Show)

instance ToJSON AdmissionInputUseKind where
  toJSON = \case
    AdmissionProducedByEdge fromPort ->
      Aeson.object
        [ "tag" Aeson..= ("produced_by_edge" :: Text)
        , "from" Aeson..= fromPort
        ]
    AdmissionHostInput ->
      Aeson.object ["tag" Aeson..= ("host_input" :: Text)]
    AdmissionImportedObligation ->
      Aeson.object ["tag" Aeson..= ("imported_obligation" :: Text)]

instance FromJSON AdmissionInputUseKind where
  parseJSON =
    Aeson.withObject "AdmissionInputUseKind" $ \obj -> do
      tag <- obj .: "tag"
      case (tag :: Text) of
        "produced_by_edge" -> AdmissionProducedByEdge <$> obj .: "from"
        "host_input" -> pure AdmissionHostInput
        "imported_obligation" -> pure AdmissionImportedObligation
        other -> fail ("unknown admission input use tag: " <> T.unpack other)

data AdmissionInputUseWitness = AdmissionInputUseWitness
  { admissionInputUsePort :: !AdmissionBoundaryPort
  , admissionInputUseKind :: !AdmissionInputUseKind
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data AdmissionOutputUseKind
  = AdmissionConsumedByEdge !AdmissionBoundaryPort
  | AdmissionTerminalDischarge !AdmissionTerminalDischargeKind
  deriving stock (Eq, Show)

instance ToJSON AdmissionOutputUseKind where
  toJSON = \case
    AdmissionConsumedByEdge toPort ->
      Aeson.object
        [ "tag" Aeson..= ("consumed_by_edge" :: Text)
        , "to" Aeson..= toPort
        ]
    AdmissionTerminalDischarge kind ->
      Aeson.object
        [ "tag" Aeson..= ("terminal_discharge" :: Text)
        , "kind" Aeson..= kind
        ]

instance FromJSON AdmissionOutputUseKind where
  parseJSON =
    Aeson.withObject "AdmissionOutputUseKind" $ \obj -> do
      tag <- obj .: "tag"
      case (tag :: Text) of
        "consumed_by_edge" -> AdmissionConsumedByEdge <$> obj .: "to"
        "terminal_discharge" -> AdmissionTerminalDischarge <$> obj .: "kind"
        other -> fail ("unknown admission output use tag: " <> T.unpack other)

data AdmissionOutputUseWitness = AdmissionOutputUseWitness
  { admissionOutputUsePort :: !AdmissionBoundaryPort
  , admissionOutputUseKind :: !AdmissionOutputUseKind
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data AdmissionEndpointUseWitness = AdmissionEndpointUseWitness
  { admissionEndpointInputUses :: ![AdmissionInputUseWitness]
  , admissionEndpointOutputUses :: ![AdmissionOutputUseWitness]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data WireAdmissionArtifact = WireAdmissionArtifact
  { wireAdmissionSchemaVersion :: !Natural
  , wireAdmissionClosureMode :: !WireAdmissionClosureMode
  , wireAdmissionNodes :: ![CircuitNodeRef]
  , wireAdmissionBindingRefs :: ![Text]
  , wireAdmissionEntries :: ![AdmissionBoundaryPort]
  , wireAdmissionExits :: ![AdmissionBoundaryPort]
  , wireAdmissionConnections :: ![Connection]
  , wireAdmissionPrimitiveSteps :: ![PrimitiveGraphStep]
  , wireAdmissionGeneratedForms :: ![GeneratedFormArtifact]
  , wireAdmissionPhantomAdapters :: ![PhantomAdapterArtifact]
  , wireAdmissionSelects :: ![SelectAdmissionArtifact]
  , wireAdmissionEndpointUses :: !AdmissionEndpointUseWitness
  }
  deriving stock (Eq, Show, Generic)

wireAdmissionCurrentSchemaVersion :: Natural
wireAdmissionCurrentSchemaVersion = 4

instance ToJSON WireAdmissionArtifact where
  toJSON artifact =
    Aeson.object
      [ "wireAdmissionSchemaVersion" Aeson..= wireAdmissionSchemaVersion artifact
      , "wireAdmissionClosureMode" Aeson..= wireAdmissionClosureMode artifact
      , "wireAdmissionNodes" Aeson..= wireAdmissionNodes artifact
      , "wireAdmissionBindingRefs" Aeson..= wireAdmissionBindingRefs artifact
      , "wireAdmissionEntries" Aeson..= wireAdmissionEntries artifact
      , "wireAdmissionExits" Aeson..= wireAdmissionExits artifact
      , "wireAdmissionConnections" Aeson..= wireAdmissionConnections artifact
      , "wireAdmissionPrimitiveSteps" Aeson..= wireAdmissionPrimitiveSteps artifact
      , "wireAdmissionGeneratedForms" Aeson..= wireAdmissionGeneratedForms artifact
      , "wireAdmissionPhantomAdapters" Aeson..= wireAdmissionPhantomAdapters artifact
      , "wireAdmissionSelects" Aeson..= wireAdmissionSelects artifact
      , "wireAdmissionEndpointUses" Aeson..= wireAdmissionEndpointUses artifact
      ]

instance FromJSON WireAdmissionArtifact where
  parseJSON =
    Aeson.withObject "WireAdmissionArtifact" $ \obj -> do
      case unknownWireAdmissionArtifactFields obj of
        [] ->
          pure ()
        unknownFields ->
          fail
            ( "unknown wire admission artifact field(s): "
                <> T.unpack (T.intercalate ", " unknownFields)
            )
      rawSchemaVersion <- obj .: "wireAdmissionSchemaVersion"
      schemaVersion <- nonNegativeNatural "wire admission schema version" rawSchemaVersion
      if schemaVersion == wireAdmissionCurrentSchemaVersion
        then
          pure ()
        else
          fail ("unsupported wire admission schema version: " <> show schemaVersion)
      WireAdmissionArtifact schemaVersion
        <$> obj .: "wireAdmissionClosureMode"
        <*> obj .: "wireAdmissionNodes"
        <*> obj .: "wireAdmissionBindingRefs"
        <*> obj .: "wireAdmissionEntries"
        <*> obj .: "wireAdmissionExits"
        <*> obj .: "wireAdmissionConnections"
        <*> obj .: "wireAdmissionPrimitiveSteps"
        <*> obj .: "wireAdmissionGeneratedForms"
        <*> obj .: "wireAdmissionPhantomAdapters"
        <*> obj .: "wireAdmissionSelects"
        <*> obj .: "wireAdmissionEndpointUses"

unknownWireAdmissionArtifactFields :: Aeson.Object -> [Text]
unknownWireAdmissionArtifactFields obj =
  filter (`Set.notMember` expectedFields) (fmap AesonKey.toText (AesonKeyMap.keys obj))
  where
    expectedFields =
      Set.fromList
        [ "wireAdmissionSchemaVersion"
        , "wireAdmissionClosureMode"
        , "wireAdmissionNodes"
        , "wireAdmissionBindingRefs"
        , "wireAdmissionEntries"
        , "wireAdmissionExits"
        , "wireAdmissionConnections"
        , "wireAdmissionPrimitiveSteps"
        , "wireAdmissionGeneratedForms"
        , "wireAdmissionPhantomAdapters"
        , "wireAdmissionSelects"
        , "wireAdmissionEndpointUses"
        ]

emptyWireAdmissionArtifact :: WireAdmissionArtifact
emptyWireAdmissionArtifact =
  WireAdmissionArtifact
    { wireAdmissionSchemaVersion = wireAdmissionCurrentSchemaVersion
    , wireAdmissionClosureMode = AdmissionClosedExecutable
    , wireAdmissionNodes = []
    , wireAdmissionBindingRefs = []
    , wireAdmissionEntries = []
    , wireAdmissionExits = []
    , wireAdmissionConnections = []
    , wireAdmissionPrimitiveSteps = []
    , wireAdmissionGeneratedForms = []
    , wireAdmissionPhantomAdapters = []
    , wireAdmissionSelects = []
    , wireAdmissionEndpointUses = emptyAdmissionEndpointUseWitness
    }

emptyAdmissionEndpointUseWitness :: AdmissionEndpointUseWitness
emptyAdmissionEndpointUseWitness =
  AdmissionEndpointUseWitness
    { admissionEndpointInputUses = []
    , admissionEndpointOutputUses = []
    }

finalizeWireAdmissionArtifact
  :: WireAdmissionClosureMode -> WireAdmissionArtifact -> WireAdmissionArtifact
finalizeWireAdmissionArtifact closureMode artifact =
  finalized
    { wireAdmissionEndpointUses =
        fromMaybe
          emptyAdmissionEndpointUseWitness
          (deriveAdmissionEndpointUseWitness finalized)
    }
  where
    finalized =
      artifact
        { wireAdmissionSchemaVersion = wireAdmissionCurrentSchemaVersion
        , wireAdmissionClosureMode = closureMode
        }

deriveAdmissionEndpointUseWitness
  :: WireAdmissionArtifact -> Maybe AdmissionEndpointUseWitness
deriveAdmissionEndpointUseWitness artifact =
  AdmissionEndpointUseWitness
    <$> traverse inputUseFor primitiveInputs
    <*> traverse outputUseFor primitiveOutputs
  where
    primitiveInputs =
      [ input
      | PrimitiveNode _node inputs _outputs <- artifact.wireAdmissionPrimitiveSteps
      , input <- inputs
      ]

    primitiveOutputs =
      [ output
      | PrimitiveNode _node _inputs outputs <- artifact.wireAdmissionPrimitiveSteps
      , output <- outputs
      ]

    inputByEndpoint :: Map EndpointKey AdmissionBoundaryPort
    inputByEndpoint =
      Map.fromList
        [ (admissionBoundaryEndpointKey input, input)
        | input <- primitiveInputs
        ]

    outputByEndpoint :: Map EndpointKey AdmissionBoundaryPort
    outputByEndpoint =
      Map.fromList
        [ (admissionBoundaryEndpointKey output, output)
        | output <- primitiveOutputs
        ]

    upstreamOf :: Map EndpointKey AdmissionBoundaryPort
    upstreamOf =
      Map.fromList
        [ (toKey, upstream)
        | connection <- artifact.wireAdmissionConnections
        , let toKey = endpointRefKey connection.connectionTo
        , Just upstream <- [Map.lookup (endpointRefKey connection.connectionFrom) outputByEndpoint]
        ]

    downstreamOf :: Map EndpointKey AdmissionBoundaryPort
    downstreamOf =
      Map.fromList
        [ (fromKey, downstream)
        | connection <- artifact.wireAdmissionConnections
        , let fromKey = endpointRefKey connection.connectionFrom
        , Just downstream <- [Map.lookup (endpointRefKey connection.connectionTo) inputByEndpoint]
        ]

    entryKeys =
      Set.fromList (fmap admissionBoundaryKey artifact.wireAdmissionEntries)

    exitKeys =
      Set.fromList (fmap admissionBoundaryKey artifact.wireAdmissionExits)

    selectInternalExitKeys =
      Set.fromList
        ( concatMap
            (primitiveGraphStepSelectInternalExitKeys artifact.wireAdmissionSelects)
            artifact.wireAdmissionPrimitiveSteps
        )

    inputUseFor input =
      case Map.lookup (admissionBoundaryEndpointKey input) upstreamOf of
        Just upstream ->
          Just (AdmissionInputUseWitness input (AdmissionProducedByEdge upstream))
        Nothing
          | admissionBoundaryKey input `Set.member` entryKeys ->
              Just
                ( AdmissionInputUseWitness input $
                    case artifact.wireAdmissionClosureMode of
                      AdmissionClosedExecutable -> AdmissionHostInput
                      AdmissionOpenFragment -> AdmissionImportedObligation
                )
          | otherwise -> Nothing

    outputUseFor output =
      case Map.lookup (admissionBoundaryEndpointKey output) downstreamOf of
        Just downstream ->
          Just (AdmissionOutputUseWitness output (AdmissionConsumedByEdge downstream))
        Nothing
          | admissionBoundaryKey output `Set.member` selectInternalExitKeys ->
              Just
                ( AdmissionOutputUseWitness
                    output
                    (AdmissionTerminalDischarge AdmissionProofBoundarySink)
                )
          | admissionBoundaryKey output `Set.member` exitKeys ->
              Just
                ( AdmissionOutputUseWitness
                    output
                    (AdmissionTerminalDischarge carriedOutputDischarge)
                )
          | otherwise -> Nothing

    carriedOutputDischarge =
      case artifact.wireAdmissionClosureMode of
        AdmissionClosedExecutable -> AdmissionHostReturn
        AdmissionOpenFragment -> AdmissionExportedBoundary

combineWireAdmissionArtifacts
  :: WireAdmissionArtifact -> WireAdmissionArtifact -> WireAdmissionArtifact
combineWireAdmissionArtifacts left right =
  WireAdmissionArtifact
    { wireAdmissionSchemaVersion = wireAdmissionCurrentSchemaVersion
    , wireAdmissionClosureMode = AdmissionClosedExecutable
    , wireAdmissionNodes = wireAdmissionNodes left <> wireAdmissionNodes right
    , wireAdmissionBindingRefs = wireAdmissionBindingRefs left <> wireAdmissionBindingRefs right
    , wireAdmissionEntries = wireAdmissionEntries left <> wireAdmissionEntries right
    , wireAdmissionExits = wireAdmissionExits left <> wireAdmissionExits right
    , wireAdmissionConnections = wireAdmissionConnections left <> wireAdmissionConnections right
    , wireAdmissionPrimitiveSteps =
        wireAdmissionPrimitiveSteps left <> wireAdmissionPrimitiveSteps right
    , wireAdmissionGeneratedForms =
        wireAdmissionGeneratedForms left <> wireAdmissionGeneratedForms right
    , wireAdmissionPhantomAdapters =
        wireAdmissionPhantomAdapters left <> wireAdmissionPhantomAdapters right
    , wireAdmissionSelects = wireAdmissionSelects left <> wireAdmissionSelects right
    , wireAdmissionEndpointUses = emptyAdmissionEndpointUseWitness
    }

appendPrimitiveStep :: PrimitiveGraphStep -> WireAdmissionArtifact -> WireAdmissionArtifact
appendPrimitiveStep step artifact =
  artifact {wireAdmissionPrimitiveSteps = wireAdmissionPrimitiveSteps artifact <> [step]}

appendGeneratedFormArtifact
  :: GeneratedFormArtifact -> WireAdmissionArtifact -> WireAdmissionArtifact
appendGeneratedFormArtifact generated artifact =
  artifact {wireAdmissionGeneratedForms = wireAdmissionGeneratedForms artifact <> [generated]}

appendPhantomAdapterArtifact
  :: PhantomAdapterArtifact -> WireAdmissionArtifact -> WireAdmissionArtifact
appendPhantomAdapterArtifact phantom artifact =
  artifact {wireAdmissionPhantomAdapters = wireAdmissionPhantomAdapters artifact <> [phantom]}

appendSelectAdmissionArtifact
  :: SelectAdmissionArtifact -> WireAdmissionArtifact -> WireAdmissionArtifact
appendSelectAdmissionArtifact selectAdmission artifact =
  artifact {wireAdmissionSelects = wireAdmissionSelects artifact <> [selectAdmission]}

wireAdmissionArtifactValidatorReady :: WireAdmissionArtifact -> Bool
wireAdmissionArtifactValidatorReady artifact =
  wireAdmissionSchemaVersion artifact == wireAdmissionCurrentSchemaVersion
    && wireAdmissionEndpointUseWitnessExact artifact
    && wireAdmissionEndpointUseLinear artifact
    && wireAdmissionSummaryKeysUnique artifact
    && wireAdmissionSummaryRowsValid artifact
    && wireAdmissionSummaryDomainClosed artifact
    && wireAdmissionSummaryIdentitiesMatchPrimitive artifact
    && wireAdmissionSummaryFrontiersBackedByPrimitive artifact
    && wireAdmissionSummaryFrontiersMatchPrimitive artifact
    && wireAdmissionRawConnectionsMatchPrimitive artifact
    && wireAdmissionComponentDomainsClosed artifact
    && wireAdmissionComponentRowsUnique artifact
    && wireAdmissionGeneratedFormsReferenced artifact
    && wireAdmissionComponentFrontiersBackedByPrimitive artifact
    && wireAdmissionGeneratedChildFrontiersMatchPrimitive artifact
    && wireAdmissionPrimitiveTraceStackValid artifact
    && wireAdmissionPrimitiveOverlayLedgersPrefixAvailable artifact
    && wireAdmissionPrimitiveConnectFrontiersBackedByNodes artifact
    && wireAdmissionPrimitiveConnectFrontiersPrefixAvailable artifact
    && wireAdmissionSelectBridgeFrontiersBackedByPrimitive artifact
    && wireAdmissionSelectBridgeEntriesConsumed artifact
    && wireAdmissionSelectArmBodyBoundariesMatchCondition artifact
    && wireAdmissionSelectArmBodyNodesFreshFromSummary artifact
    && wireAdmissionSelectArmBodyNodesPairwiseDisjoint artifact
    && wireAdmissionPhantomBridgeFrontiersBackedByPrimitive artifact
    && wireAdmissionPhantomBridgeFrontiersMatchPrimitive artifact
    && wireAdmissionPhantomBridgeBulkConnectionsReplayed artifact
    && all primitiveGraphStepValid artifact.wireAdmissionPrimitiveSteps
    && all generatedFormArtifactValid artifact.wireAdmissionGeneratedForms
    && all phantomAdapterArtifactValid artifact.wireAdmissionPhantomAdapters
    && all selectAdmissionArtifactValid artifact.wireAdmissionSelects

wireAdmissionEndpointUseWitnessExact :: WireAdmissionArtifact -> Bool
wireAdmissionEndpointUseWitnessExact artifact =
  deriveAdmissionEndpointUseWitness artifact == Just artifact.wireAdmissionEndpointUses

{- | Haskell-side counterpart of the Lean
@AdmissionEndpointUseWitness.EndpointUseLinear@ rule (ADR 0081): the persisted
endpoint-use witness records a linear edge matching. Every internally produced
input names an output that is consumed by exactly that input, and every
edge-consumed output names an input produced by exactly that output. Boundary
endpoints (host input, imported obligation, terminal discharge) carry no
obligation. Implicit fan-out and fan-in break the symmetric edge correspondence
and are rejected.

This is the boundary-port-linear admission rule whose proof-side soundness is
@AdmissionEndpointUseWitness.artifactBoundaryWitness_boundaryPortLinear@. The
predicate is maintained in lockstep with the Lean executable checker; it is not
extracted from Lean.
-}
wireAdmissionEndpointUseLinear :: WireAdmissionArtifact -> Bool
wireAdmissionEndpointUseLinear artifact =
  all inputEdgeConsistent witness.admissionEndpointInputUses
    && all outputEdgeConsistent witness.admissionEndpointOutputUses
  where
    witness = artifact.wireAdmissionEndpointUses

    outputByKey :: Map (CircuitNodeRef, Text, Text) AdmissionOutputUseKind
    outputByKey =
      Map.fromList
        [ (admissionBoundaryKey row.admissionOutputUsePort, row.admissionOutputUseKind)
        | row <- witness.admissionEndpointOutputUses
        ]

    inputByKey :: Map (CircuitNodeRef, Text, Text) AdmissionInputUseKind
    inputByKey =
      Map.fromList
        [ (admissionBoundaryKey row.admissionInputUsePort, row.admissionInputUseKind)
        | row <- witness.admissionEndpointInputUses
        ]

    inputEdgeConsistent row =
      case row.admissionInputUseKind of
        AdmissionProducedByEdge fromPort ->
          case Map.lookup (admissionBoundaryKey fromPort) outputByKey of
            Just (AdmissionConsumedByEdge toPort) ->
              admissionBoundaryKey toPort == admissionBoundaryKey row.admissionInputUsePort
            _ -> False
        _ -> True

    outputEdgeConsistent row =
      case row.admissionOutputUseKind of
        AdmissionConsumedByEdge toPort ->
          case Map.lookup (admissionBoundaryKey toPort) inputByKey of
            Just (AdmissionProducedByEdge fromPort) ->
              admissionBoundaryKey fromPort == admissionBoundaryKey row.admissionOutputUsePort
            _ -> False
        _ -> True

wireAdmissionSummaryKeysUnique :: WireAdmissionArtifact -> Bool
wireAdmissionSummaryKeysUnique artifact =
  unique artifact.wireAdmissionNodes
    && unique artifact.wireAdmissionBindingRefs
    && unique (fmap admissionBoundaryKey artifact.wireAdmissionEntries)
    && unique (fmap admissionBoundaryKey artifact.wireAdmissionExits)
    && unique artifact.wireAdmissionConnections

wireAdmissionSummaryRowsValid :: WireAdmissionArtifact -> Bool
wireAdmissionSummaryRowsValid artifact =
  all circuitNodeRefValid artifact.wireAdmissionNodes
    && all nonEmptyText artifact.wireAdmissionBindingRefs
    && all admissionBoundaryPortValid artifact.wireAdmissionEntries
    && all admissionBoundaryPortValid artifact.wireAdmissionExits
    && all rawConnectionValid artifact.wireAdmissionConnections

wireAdmissionSummaryDomainClosed :: WireAdmissionArtifact -> Bool
wireAdmissionSummaryDomainClosed artifact =
  all entryClosed artifact.wireAdmissionEntries
    && all exitClosed artifact.wireAdmissionExits
    && all connectionClosed artifact.wireAdmissionConnections
  where
    nodes =
      Set.fromList artifact.wireAdmissionNodes

    entryClosed =
      admissionBoundaryInNodes nodes

    exitClosed =
      admissionBoundaryInNodes nodes

    connectionClosed connection =
      endpointNodeRef connection.connectionFrom `Set.member` nodes
        && endpointNodeRef connection.connectionTo `Set.member` nodes

wireAdmissionComponentDomainsClosed :: WireAdmissionArtifact -> Bool
wireAdmissionComponentDomainsClosed artifact =
  all
    (primitiveGraphStepDomainClosed nodes bindingRefs)
    artifact.wireAdmissionPrimitiveSteps
    && all
      (generatedFormArtifactDomainClosed nodes)
      artifact.wireAdmissionGeneratedForms
    && all
      (phantomAdapterArtifactDomainClosed nodes)
      artifact.wireAdmissionPhantomAdapters
    && all
      (selectAdmissionArtifactDomainClosed nodes)
      artifact.wireAdmissionSelects
  where
    nodes =
      Set.fromList artifact.wireAdmissionNodes

    bindingRefs =
      Set.fromList artifact.wireAdmissionBindingRefs

wireAdmissionComponentRowsUnique :: WireAdmissionArtifact -> Bool
wireAdmissionComponentRowsUnique artifact =
  unique (fmap generatedFormBinding artifact.wireAdmissionGeneratedForms)
    && unique (fmap phantomAdapterNode artifact.wireAdmissionPhantomAdapters)
    && unique (fmap selectAdmissionConditionNode artifact.wireAdmissionSelects)
    && unique componentRoleNodes
  where
    componentRoleNodes =
      concatMap generatedFormUsedChildNodes artifact.wireAdmissionGeneratedForms
        <> fmap phantomAdapterNode artifact.wireAdmissionPhantomAdapters
        <> fmap selectAdmissionConditionNode artifact.wireAdmissionSelects

    generatedFormUsedChildNodes =
      fmap generatedChildNode . generatedFormUsedChildren

wireAdmissionGeneratedFormsReferenced :: WireAdmissionArtifact -> Bool
wireAdmissionGeneratedFormsReferenced artifact =
  all generatedFormReferenced artifact.wireAdmissionGeneratedForms
  where
    bindingRefs =
      Set.fromList artifact.wireAdmissionBindingRefs

    generatedFormReferenced generated =
      not (null generated.generatedFormUsedChildren)
        || ( null generated.generatedFormSourceChildren
               && generated.generatedFormBinding `Set.member` bindingRefs
           )

data PrimitiveTraceFrame = PrimitiveTraceFrame
  { ptfNodes :: !(Set.Set CircuitNodeRef)
  , ptfBindingRefs :: !(Set.Set Text)
  , ptfEntries :: !(Set.Set AdmissionBoundaryPort)
  , ptfExits :: !(Set.Set AdmissionBoundaryPort)
  , ptfConnections :: !(Set.Set Connection)
  }
  deriving stock (Eq, Show)

wireAdmissionPrimitiveTraceStackValid :: WireAdmissionArtifact -> Bool
wireAdmissionPrimitiveTraceStackValid artifact =
  case replayPrimitiveTrace artifact [] artifact.wireAdmissionPrimitiveSteps of
    Just [frame] ->
      ptfNodes frame == Set.fromList artifact.wireAdmissionNodes
        && ptfBindingRefs frame == Set.fromList artifact.wireAdmissionBindingRefs
        && ptfEntries frame == Set.fromList artifact.wireAdmissionEntries
        && ptfExits frame == Set.fromList artifact.wireAdmissionExits
        && ptfConnections frame == Set.fromList artifact.wireAdmissionConnections
    _other ->
      False

primitiveTraceSelectInternalExit :: WireAdmissionArtifact -> AdmissionBoundaryPort -> Bool
primitiveTraceSelectInternalExit artifact exit =
  any (`selectInternalChoiceExit` exit) artifact.wireAdmissionSelects

replayPrimitiveTrace
  :: WireAdmissionArtifact
  -> [PrimitiveTraceFrame]
  -> [PrimitiveGraphStep]
  -> Maybe [PrimitiveTraceFrame]
replayPrimitiveTrace artifact stack = \case
  [] ->
    Just stack
  step : rest -> do
    nextStack <- replayPrimitiveTraceStep artifact stack step
    replayPrimitiveTrace artifact nextStack rest

replayPrimitiveTraceStep
  :: WireAdmissionArtifact
  -> [PrimitiveTraceFrame]
  -> PrimitiveGraphStep
  -> Maybe [PrimitiveTraceFrame]
replayPrimitiveTraceStep artifact stack = \case
  PrimitiveEmpty ->
    Just (emptyPrimitiveTraceFrame : stack)
  PrimitiveNode node entries exits ->
    Just
      ( PrimitiveTraceFrame
          { ptfNodes = Set.singleton node
          , ptfBindingRefs = Set.empty
          , ptfEntries = Set.fromList entries
          , ptfExits =
              Set.filter
                (not . primitiveTraceSelectInternalExit artifact)
                (Set.fromList exits)
          , ptfConnections = Set.empty
          }
          : stack
      )
  PrimitiveBindingRef binding ->
    case stack of
      frame : rest ->
        Just (frame {ptfBindingRefs = Set.insert binding frame.ptfBindingRefs} : rest)
      [] ->
        Nothing
  PrimitiveOverlay leftNodes rightNodes leftBindings rightBindings ->
    case stack of
      rightFrame : leftFrame : rest
        | ptfNodes leftFrame == Set.fromList leftNodes
            && ptfNodes rightFrame == Set.fromList rightNodes
            && ptfBindingRefs leftFrame == Set.fromList leftBindings
            && ptfBindingRefs rightFrame == Set.fromList rightBindings ->
            Just (mergePrimitiveTraceFrames leftFrame rightFrame : rest)
      _other ->
        Nothing
  PrimitiveConnect leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ->
    case stack of
      rightFrame : leftFrame : rest
        | ptfExits leftFrame == Set.fromList leftExits
            && ptfEntries rightFrame == Set.fromList rightEntries
            && matchedLeft `Set.isSubsetOf` ptfExits leftFrame
            && matchedRight `Set.isSubsetOf` ptfEntries rightFrame
            && Set.fromList unmatchedLeftExits
              == ptfExits leftFrame `Set.difference` matchedLeft
            && Set.fromList unmatchedRightEntries
              == ptfEntries rightFrame `Set.difference` matchedRight ->
            Just (connectPrimitiveTraceFrames leftFrame rightFrame matchedPairs : rest)
      _other ->
        Nothing
    where
      matchedLeft =
        Set.fromList (fmap admissionConnectionFrom matchedPairs)

      matchedRight =
        Set.fromList (fmap admissionConnectionTo matchedPairs)

emptyPrimitiveTraceFrame :: PrimitiveTraceFrame
emptyPrimitiveTraceFrame =
  PrimitiveTraceFrame
    { ptfNodes = Set.empty
    , ptfBindingRefs = Set.empty
    , ptfEntries = Set.empty
    , ptfExits = Set.empty
    , ptfConnections = Set.empty
    }

mergePrimitiveTraceFrames :: PrimitiveTraceFrame -> PrimitiveTraceFrame -> PrimitiveTraceFrame
mergePrimitiveTraceFrames leftFrame rightFrame =
  PrimitiveTraceFrame
    { ptfNodes = ptfNodes leftFrame `Set.union` ptfNodes rightFrame
    , ptfBindingRefs = ptfBindingRefs leftFrame `Set.union` ptfBindingRefs rightFrame
    , ptfEntries = ptfEntries leftFrame `Set.union` ptfEntries rightFrame
    , ptfExits = ptfExits leftFrame `Set.union` ptfExits rightFrame
    , ptfConnections = ptfConnections leftFrame `Set.union` ptfConnections rightFrame
    }

connectPrimitiveTraceFrames
  :: PrimitiveTraceFrame
  -> PrimitiveTraceFrame
  -> [AdmissionConnection]
  -> PrimitiveTraceFrame
connectPrimitiveTraceFrames leftFrame rightFrame matchedPairs =
  PrimitiveTraceFrame
    { ptfNodes = ptfNodes leftFrame `Set.union` ptfNodes rightFrame
    , ptfBindingRefs = ptfBindingRefs leftFrame `Set.union` ptfBindingRefs rightFrame
    , ptfEntries = ptfEntries leftFrame `Set.union` residualRightEntries
    , ptfExits = residualLeftExits `Set.union` ptfExits rightFrame
    , ptfConnections =
        ptfConnections leftFrame
          `Set.union` ptfConnections rightFrame
          `Set.union` Set.fromList (fmap rawConnectionFromAdmissionConnection matchedPairs)
    }
  where
    matchedLeft =
      Set.fromList (fmap admissionConnectionFrom matchedPairs)

    matchedRight =
      Set.fromList (fmap admissionConnectionTo matchedPairs)

    residualLeftExits =
      ptfExits leftFrame `Set.difference` matchedLeft

    residualRightEntries =
      ptfEntries rightFrame `Set.difference` matchedRight

wireAdmissionRawConnectionsMatchPrimitive :: WireAdmissionArtifact -> Bool
wireAdmissionRawConnectionsMatchPrimitive artifact =
  List.sort artifact.wireAdmissionConnections
    == List.sort
      (concatMap primitiveGraphStepRawConnections artifact.wireAdmissionPrimitiveSteps)

wireAdmissionSummaryIdentitiesMatchPrimitive :: WireAdmissionArtifact -> Bool
wireAdmissionSummaryIdentitiesMatchPrimitive artifact =
  List.sort artifact.wireAdmissionNodes
    == List.sort
      (concatMap primitiveGraphStepNodeRows artifact.wireAdmissionPrimitiveSteps)
    && List.sort artifact.wireAdmissionBindingRefs
      == List.sort
        (concatMap primitiveGraphStepBindingRows artifact.wireAdmissionPrimitiveSteps)

wireAdmissionSummaryFrontiersBackedByPrimitive :: WireAdmissionArtifact -> Bool
wireAdmissionSummaryFrontiersBackedByPrimitive artifact =
  all entryBacked artifact.wireAdmissionEntries
    && all exitBacked artifact.wireAdmissionExits
  where
    primitiveEntryKeys =
      Set.fromList
        (concatMap primitiveGraphStepEntryKeys artifact.wireAdmissionPrimitiveSteps)

    primitiveExitKeys =
      Set.fromList
        (concatMap primitiveGraphStepExitKeys artifact.wireAdmissionPrimitiveSteps)

    consumedEntryKeys =
      Set.fromList
        (concatMap primitiveGraphStepConsumedEntryKeys artifact.wireAdmissionPrimitiveSteps)

    consumedExitKeys =
      Set.fromList
        (concatMap primitiveGraphStepConsumedExitKeys artifact.wireAdmissionPrimitiveSteps)

    entryBacked entry =
      let key =
            admissionBoundaryKey entry
       in key `Set.member` primitiveEntryKeys
            && key `Set.notMember` consumedEntryKeys

    exitBacked exit =
      let key =
            admissionBoundaryKey exit
       in key `Set.member` primitiveExitKeys
            && key `Set.notMember` consumedExitKeys

wireAdmissionSummaryFrontiersMatchPrimitive :: WireAdmissionArtifact -> Bool
wireAdmissionSummaryFrontiersMatchPrimitive artifact =
  summaryEntryKeys == Set.difference primitiveEntryKeys consumedEntryKeys
    && summaryExitKeys
      == Set.difference
        (Set.difference primitiveExitKeys consumedExitKeys)
        selectInternalExitKeys
  where
    summaryEntryKeys =
      Set.fromList (fmap admissionBoundaryKey artifact.wireAdmissionEntries)

    summaryExitKeys =
      Set.fromList (fmap admissionBoundaryKey artifact.wireAdmissionExits)

    primitiveEntryKeys =
      Set.fromList
        (concatMap primitiveGraphStepEntryKeys artifact.wireAdmissionPrimitiveSteps)

    primitiveExitKeys =
      Set.fromList
        (concatMap primitiveGraphStepExitKeys artifact.wireAdmissionPrimitiveSteps)

    consumedEntryKeys =
      Set.fromList
        (concatMap primitiveGraphStepConsumedEntryKeys artifact.wireAdmissionPrimitiveSteps)

    consumedExitKeys =
      Set.fromList
        (concatMap primitiveGraphStepConsumedExitKeys artifact.wireAdmissionPrimitiveSteps)

    selectInternalExitKeys =
      Set.fromList
        ( concatMap
            (primitiveGraphStepSelectInternalExitKeys artifact.wireAdmissionSelects)
            artifact.wireAdmissionPrimitiveSteps
        )

wireAdmissionComponentFrontiersBackedByPrimitive :: WireAdmissionArtifact -> Bool
wireAdmissionComponentFrontiersBackedByPrimitive artifact =
  all generatedBacked artifact.wireAdmissionGeneratedForms
    && all phantomBacked artifact.wireAdmissionPhantomAdapters
    && all selectBacked artifact.wireAdmissionSelects
  where
    primitiveEntryKeys =
      Set.fromList
        (concatMap primitiveGraphStepEntryKeys artifact.wireAdmissionPrimitiveSteps)

    primitiveExitKeys =
      Set.fromList
        (concatMap primitiveGraphStepExitKeys artifact.wireAdmissionPrimitiveSteps)

    generatedBacked generated =
      all generatedChildBacked generated.generatedFormUsedChildren

    generatedChildBacked child =
      all ((`Set.member` primitiveExitKeys) . admissionBoundaryKey) child.generatedChildOutputs
        && all ((`Set.member` primitiveEntryKeys) . admissionBoundaryKey) child.generatedChildInputs

    phantomBacked phantom =
      case phantom.phantomAdapterDirection of
        PhantomGather ->
          admissionBoundaryKey phantom.phantomAdapterSingular `Set.member` primitiveEntryKeys
            && all
              ((`Set.member` primitiveExitKeys) . admissionBoundaryKey)
              phantom.phantomAdapterMulti
        PhantomScatter ->
          admissionBoundaryKey phantom.phantomAdapterSingular `Set.member` primitiveExitKeys
            && all
              ((`Set.member` primitiveEntryKeys) . admissionBoundaryKey)
              phantom.phantomAdapterMulti

    selectBacked selectAdmission =
      all
        ((`Set.member` primitiveExitKeys) . admissionBoundaryKey . selectVariantPort)
        selectAdmission.selectAdmissionVariants

wireAdmissionGeneratedChildFrontiersMatchPrimitive :: WireAdmissionArtifact -> Bool
wireAdmissionGeneratedChildFrontiersMatchPrimitive artifact =
  all generatedExact artifact.wireAdmissionGeneratedForms
  where
    generatedExact generated =
      all childExact generated.generatedFormUsedChildren

    childExact child =
      case primitiveNodeFrontiers artifact child.generatedChildNode of
        Nothing ->
          False
        Just (entries, exits) ->
          boundaryKeySet child.generatedChildInputs == boundaryKeySet entries
            && boundaryKeySet child.generatedChildOutputs == boundaryKeySet exits

    boundaryKeySet =
      Set.fromList . fmap admissionBoundaryKey

wireAdmissionPrimitiveConnectFrontiersBackedByNodes :: WireAdmissionArtifact -> Bool
wireAdmissionPrimitiveConnectFrontiersBackedByNodes artifact =
  all connectFrontiersBacked artifact.wireAdmissionPrimitiveSteps
  where
    primitiveEntryKeys =
      Set.fromList
        (concatMap primitiveGraphStepEntryKeys artifact.wireAdmissionPrimitiveSteps)

    primitiveExitKeys =
      Set.fromList
        (concatMap primitiveGraphStepExitKeys artifact.wireAdmissionPrimitiveSteps)

    connectFrontiersBacked = \case
      PrimitiveConnect leftExits rightEntries _matchedPairs _unmatchedLeftExits _unmatchedRightEntries ->
        all ((`Set.member` primitiveExitKeys) . admissionBoundaryKey) leftExits
          && all ((`Set.member` primitiveEntryKeys) . admissionBoundaryKey) rightEntries
      PrimitiveEmpty ->
        True
      PrimitiveNode _node _entries _exits ->
        True
      PrimitiveBindingRef _binding ->
        True
      PrimitiveOverlay _leftNodes _rightNodes _leftBindings _rightBindings ->
        True

wireAdmissionPrimitiveOverlayLedgersPrefixAvailable :: WireAdmissionArtifact -> Bool
wireAdmissionPrimitiveOverlayLedgersPrefixAvailable artifact =
  traceAvailable Set.empty Set.empty artifact.wireAdmissionPrimitiveSteps
  where
    traceAvailable availableNodes availableBindings = \case
      [] ->
        True
      PrimitiveEmpty : rest ->
        traceAvailable availableNodes availableBindings rest
      PrimitiveNode node _entries _exits : rest ->
        traceAvailable (Set.insert node availableNodes) availableBindings rest
      PrimitiveBindingRef binding : rest ->
        traceAvailable availableNodes (Set.insert binding availableBindings) rest
      PrimitiveOverlay leftNodes rightNodes leftBindings rightBindings : rest ->
        all (`Set.member` availableNodes) (leftNodes <> rightNodes)
          && all (`Set.member` availableBindings) (leftBindings <> rightBindings)
          && traceAvailable availableNodes availableBindings rest
      PrimitiveConnect
        _leftExits
        _rightEntries
        _matchedPairs
        _unmatchedLeftExits
        _unmatchedRightEntries
        : rest ->
          traceAvailable availableNodes availableBindings rest

wireAdmissionPrimitiveConnectFrontiersPrefixAvailable :: WireAdmissionArtifact -> Bool
wireAdmissionPrimitiveConnectFrontiersPrefixAvailable artifact =
  traceAvailable Set.empty Set.empty artifact.wireAdmissionPrimitiveSteps
  where
    traceAvailable availableEntries availableExits = \case
      [] ->
        True
      PrimitiveEmpty : rest ->
        traceAvailable availableEntries availableExits rest
      PrimitiveNode _node entries exits : rest ->
        traceAvailable
          (availableEntries `Set.union` Set.fromList (fmap admissionBoundaryKey entries))
          (availableExits `Set.union` Set.fromList (fmap admissionBoundaryKey exits))
          rest
      PrimitiveBindingRef _binding : rest ->
        traceAvailable availableEntries availableExits rest
      PrimitiveOverlay _leftNodes _rightNodes _leftBindings _rightBindings : rest ->
        traceAvailable availableEntries availableExits rest
      PrimitiveConnect
        leftExits
        rightEntries
        matchedPairs
        _unmatchedLeftExits
        _unmatchedRightEntries
        : rest ->
          all ((`Set.member` availableExits) . admissionBoundaryKey) leftExits
            && all ((`Set.member` availableEntries) . admissionBoundaryKey) rightEntries
            && traceAvailable
              (availableEntries `Set.difference` Set.fromList (fmap admissionConnectionToKey matchedPairs))
              (availableExits `Set.difference` Set.fromList (fmap admissionConnectionFromKey matchedPairs))
              rest

wireAdmissionSelectBridgeFrontiersBackedByPrimitive :: WireAdmissionArtifact -> Bool
wireAdmissionSelectBridgeFrontiersBackedByPrimitive artifact =
  all selectBacked artifact.wireAdmissionSelects
  where
    selectBacked selectAdmission =
      case primitiveNodeFrontiers artifact selectAdmission.selectAdmissionConditionNode of
        Nothing ->
          False
        Just (entries, exits) ->
          all
            (variantBacked selectAdmission.selectAdmissionConditionNode entries exits)
            selectAdmission.selectAdmissionVariants

    variantBacked conditionNode entries exits variant =
      exactlyOne
        (admissionBoundariesCompatible variant.selectVariantPort)
        entries
        && exactlyOne
          (selectInternalExitCompatible conditionNode variant.selectVariantPort)
          exits

    exactlyOne predicate values =
      case filter predicate values of
        [_one] ->
          True
        [] ->
          False
        _first : _second : _rest ->
          False

wireAdmissionSelectBridgeEntriesConsumed :: WireAdmissionArtifact -> Bool
wireAdmissionSelectBridgeEntriesConsumed artifact =
  all selectConsumed artifact.wireAdmissionSelects
  where
    matchedConnections =
      Set.fromList
        (concatMap primitiveGraphStepMatchedConnections artifact.wireAdmissionPrimitiveSteps)

    selectConsumed selectAdmission =
      case primitiveNodeFrontiers artifact selectAdmission.selectAdmissionConditionNode of
        Nothing ->
          False
        Just (entries, _exits) ->
          all (variantEntriesConsumed entries) selectAdmission.selectAdmissionVariants

    variantEntriesConsumed entries variant =
      all (entryConsumed variant.selectVariantPort) entries

    entryConsumed variantPort entry =
      not (admissionBoundariesCompatible variantPort entry)
        || AdmissionConnection variantPort entry `Set.member` matchedConnections

primitiveNodeFrontiers
  :: WireAdmissionArtifact -> CircuitNodeRef -> Maybe ([AdmissionBoundaryPort], [AdmissionBoundaryPort])
primitiveNodeFrontiers artifact targetNode =
  case [ (entries, exits)
       | PrimitiveNode node entries exits <- artifact.wireAdmissionPrimitiveSteps
       , node == targetNode
       ] of
    [(entries, exits)] ->
      Just (entries, exits)
    _other ->
      Nothing

selectInternalExitCompatible
  :: CircuitNodeRef -> AdmissionBoundaryPort -> AdmissionBoundaryPort -> Bool
selectInternalExitCompatible conditionNode variantPort exit =
  admissionBoundaryExclusiveGroupOwnedBy conditionNode exit
    && admissionBoundariesCompatible variantPort exit

wireAdmissionSelectArmBodyNodesPairwiseDisjoint :: WireAdmissionArtifact -> Bool
wireAdmissionSelectArmBodyNodesPairwiseDisjoint artifact =
  all selectBodyNodesPairwiseDisjoint artifact.wireAdmissionSelects
  where
    selectBodyNodesPairwiseDisjoint selectAdmission =
      all
        armsDisjoint
        [ (left, right)
        | left <- selectAdmission.selectAdmissionArms
        , right <- selectAdmission.selectAdmissionArms
        , selectArmCanonicalKey left /= selectArmCanonicalKey right
        ]

    armsDisjoint (left, right) =
      Set.disjoint
        (Set.fromList left.selectArmBodyNodes)
        (Set.fromList right.selectArmBodyNodes)

wireAdmissionSelectArmBodyBoundariesMatchCondition :: WireAdmissionArtifact -> Bool
wireAdmissionSelectArmBodyBoundariesMatchCondition artifact =
  all selectBodyBoundariesMatch artifact.wireAdmissionSelects
  where
    selectBodyBoundariesMatch selectAdmission =
      case primitiveNodeFrontiers artifact selectAdmission.selectAdmissionConditionNode of
        Nothing ->
          False
        Just (_entries, exits) ->
          all
            (armBodyBoundariesMatch selectAdmission (conditionBridgeShapes selectAdmission exits))
            selectAdmission.selectAdmissionArms

    conditionBridgeShapes selectAdmission exits =
      List.sort
        ( fmap
            admissionBoundaryOutputShape
            ( filter
                (not . selectInternalChoiceExit selectAdmission)
                exits
            )
        )

    armBodyBoundariesMatch selectAdmission bridgeShapes arm =
      case matchingVariants of
        [variant] ->
          if selectArmBodyIdentity arm
            then bridgeShapes == [admissionBoundaryIdentityOutputShape variant.selectVariantPort]
            else
              List.sort (fmap admissionBoundaryCompatibilityShape arm.selectArmBodyEntries)
                == [admissionBoundaryCompatibilityShape variant.selectVariantPort]
                && List.sort (fmap admissionBoundaryOutputShape arm.selectArmBodyExits) == bridgeShapes
        [] ->
          False
        _first : _second : _rest ->
          False
      where
        matchingVariants =
          filter
            ((== arm.selectArmCanonicalKey) . selectVariantKey)
            selectAdmission.selectAdmissionVariants

    selectArmBodyIdentity arm =
      null arm.selectArmBodyNodes
        && null arm.selectArmBodyEntries
        && null arm.selectArmBodyExits

wireAdmissionSelectArmBodyNodesFreshFromSummary :: WireAdmissionArtifact -> Bool
wireAdmissionSelectArmBodyNodesFreshFromSummary artifact =
  all selectBodyNodesFresh artifact.wireAdmissionSelects
  where
    summaryNodes =
      Set.fromList artifact.wireAdmissionNodes

    selectBodyNodesFresh selectAdmission =
      all
        (all (`Set.notMember` summaryNodes) . selectArmBodyNodes)
        selectAdmission.selectAdmissionArms

wireAdmissionPhantomBridgeFrontiersBackedByPrimitive :: WireAdmissionArtifact -> Bool
wireAdmissionPhantomBridgeFrontiersBackedByPrimitive artifact =
  all phantomBacked artifact.wireAdmissionPhantomAdapters
  where
    primitiveEntryKeys =
      Set.fromList
        (concatMap primitiveGraphStepEntryKeys artifact.wireAdmissionPrimitiveSteps)

    primitiveExitKeys =
      Set.fromList
        (concatMap primitiveGraphStepExitKeys artifact.wireAdmissionPrimitiveSteps)

    phantomBacked phantom =
      all
        ((`Set.member` primitiveEntryKeys) . admissionConnectionToKey)
        phantom.phantomAdapterLeftBulk
        && all
          ((`Set.member` primitiveExitKeys) . admissionConnectionFromKey)
          phantom.phantomAdapterRightBulk

wireAdmissionPhantomBridgeFrontiersMatchPrimitive :: WireAdmissionArtifact -> Bool
wireAdmissionPhantomBridgeFrontiersMatchPrimitive artifact =
  all phantomExact artifact.wireAdmissionPhantomAdapters
  where
    phantomExact phantom =
      case primitiveNodeFrontiers artifact phantom.phantomAdapterNode of
        Nothing ->
          False
        Just (entries, exits) ->
          boundaryKeySet entries == Set.fromList (fmap admissionConnectionToKey leftBulk)
            && boundaryKeySet exits == Set.fromList (fmap admissionConnectionFromKey rightBulk)
      where
        leftBulk =
          phantom.phantomAdapterLeftBulk

        rightBulk =
          phantom.phantomAdapterRightBulk

    boundaryKeySet =
      Set.fromList . fmap admissionBoundaryKey

wireAdmissionPhantomBridgeBulkConnectionsReplayed :: WireAdmissionArtifact -> Bool
wireAdmissionPhantomBridgeBulkConnectionsReplayed artifact =
  all phantomReplayed artifact.wireAdmissionPhantomAdapters
  where
    matchedConnections =
      Set.fromList
        (concatMap primitiveGraphStepMatchedConnections artifact.wireAdmissionPrimitiveSteps)

    phantomReplayed phantom =
      all (`Set.member` matchedConnections) phantom.phantomAdapterLeftBulk
        && all (`Set.member` matchedConnections) phantom.phantomAdapterRightBulk

primitiveGraphStepRawConnections :: PrimitiveGraphStep -> [Connection]
primitiveGraphStepRawConnections = \case
  PrimitiveEmpty ->
    []
  PrimitiveNode _node _entries _exits ->
    []
  PrimitiveBindingRef _binding ->
    []
  PrimitiveOverlay _leftNodes _rightNodes _leftBindings _rightBindings ->
    []
  PrimitiveConnect _leftExits _rightEntries matchedPairs _unmatchedLeftExits _unmatchedRightEntries ->
    fmap rawConnectionFromAdmissionConnection matchedPairs

primitiveGraphStepMatchedConnections :: PrimitiveGraphStep -> [AdmissionConnection]
primitiveGraphStepMatchedConnections = \case
  PrimitiveEmpty ->
    []
  PrimitiveNode _node _entries _exits ->
    []
  PrimitiveBindingRef _binding ->
    []
  PrimitiveOverlay _leftNodes _rightNodes _leftBindings _rightBindings ->
    []
  PrimitiveConnect _leftExits _rightEntries matchedPairs _unmatchedLeftExits _unmatchedRightEntries ->
    matchedPairs

primitiveGraphStepNodeRows :: PrimitiveGraphStep -> [CircuitNodeRef]
primitiveGraphStepNodeRows = \case
  PrimitiveEmpty ->
    []
  PrimitiveNode node _entries _exits ->
    [node]
  PrimitiveBindingRef _binding ->
    []
  PrimitiveOverlay _leftNodes _rightNodes _leftBindings _rightBindings ->
    []
  PrimitiveConnect _leftExits _rightEntries _matchedPairs _unmatchedLeftExits _unmatchedRightEntries ->
    []

primitiveGraphStepBindingRows :: PrimitiveGraphStep -> [Text]
primitiveGraphStepBindingRows = \case
  PrimitiveEmpty ->
    []
  PrimitiveNode _node _entries _exits ->
    []
  PrimitiveBindingRef binding ->
    [binding]
  PrimitiveOverlay _leftNodes _rightNodes _leftBindings _rightBindings ->
    []
  PrimitiveConnect _leftExits _rightEntries _matchedPairs _unmatchedLeftExits _unmatchedRightEntries ->
    []

primitiveGraphStepEntryKeys :: PrimitiveGraphStep -> [(CircuitNodeRef, Text, Text)]
primitiveGraphStepEntryKeys = \case
  PrimitiveEmpty ->
    []
  PrimitiveNode _node entries _exits ->
    fmap admissionBoundaryKey entries
  PrimitiveBindingRef _binding ->
    []
  PrimitiveOverlay _leftNodes _rightNodes _leftBindings _rightBindings ->
    []
  PrimitiveConnect _leftExits _rightEntries _matchedPairs _unmatchedLeftExits _unmatchedRightEntries ->
    []

primitiveGraphStepExitKeys :: PrimitiveGraphStep -> [(CircuitNodeRef, Text, Text)]
primitiveGraphStepExitKeys = \case
  PrimitiveEmpty ->
    []
  PrimitiveNode _node _entries exits ->
    fmap admissionBoundaryKey exits
  PrimitiveBindingRef _binding ->
    []
  PrimitiveOverlay _leftNodes _rightNodes _leftBindings _rightBindings ->
    []
  PrimitiveConnect _leftExits _rightEntries _matchedPairs _unmatchedLeftExits _unmatchedRightEntries ->
    []

primitiveGraphStepConsumedEntryKeys :: PrimitiveGraphStep -> [(CircuitNodeRef, Text, Text)]
primitiveGraphStepConsumedEntryKeys = \case
  PrimitiveEmpty ->
    []
  PrimitiveNode _node _entries _exits ->
    []
  PrimitiveBindingRef _binding ->
    []
  PrimitiveOverlay _leftNodes _rightNodes _leftBindings _rightBindings ->
    []
  PrimitiveConnect _leftExits _rightEntries matchedPairs _unmatchedLeftExits _unmatchedRightEntries ->
    fmap admissionConnectionToKey matchedPairs

primitiveGraphStepConsumedExitKeys :: PrimitiveGraphStep -> [(CircuitNodeRef, Text, Text)]
primitiveGraphStepConsumedExitKeys = \case
  PrimitiveEmpty ->
    []
  PrimitiveNode _node _entries _exits ->
    []
  PrimitiveBindingRef _binding ->
    []
  PrimitiveOverlay _leftNodes _rightNodes _leftBindings _rightBindings ->
    []
  PrimitiveConnect _leftExits _rightEntries matchedPairs _unmatchedLeftExits _unmatchedRightEntries ->
    fmap admissionConnectionFromKey matchedPairs

primitiveGraphStepSelectInternalExitKeys
  :: [SelectAdmissionArtifact] -> PrimitiveGraphStep -> [(CircuitNodeRef, Text, Text)]
primitiveGraphStepSelectInternalExitKeys selectAdmissions = \case
  PrimitiveEmpty ->
    []
  PrimitiveNode node _entries exits ->
    let nodeSelectAdmissions =
          filter ((== node) . selectAdmissionConditionNode) selectAdmissions
        selectInternalForNode exit =
          any (`selectInternalChoiceExit` exit) nodeSelectAdmissions
     in if null nodeSelectAdmissions
          then []
          else fmap admissionBoundaryKey (filter selectInternalForNode exits)
  PrimitiveBindingRef _binding ->
    []
  PrimitiveOverlay _leftNodes _rightNodes _leftBindings _rightBindings ->
    []
  PrimitiveConnect _leftExits _rightEntries _matchedPairs _unmatchedLeftExits _unmatchedRightEntries ->
    []

selectInternalChoiceExit :: SelectAdmissionArtifact -> AdmissionBoundaryPort -> Bool
selectInternalChoiceExit selectAdmission exit =
  admissionBoundaryExclusiveGroupOwnedBy selectAdmission.selectAdmissionConditionNode exit
    && any
      (\variant -> admissionBoundariesCompatible variant.selectVariantPort exit)
      selectAdmission.selectAdmissionVariants

admissionBoundaryExclusiveGroupOwnedBy :: CircuitNodeRef -> AdmissionBoundaryPort -> Bool
admissionBoundaryExclusiveGroupOwnedBy node boundary =
  case boundary.admissionBoundaryExclusiveGroup of
    Nothing ->
      False
    Just (owner, _index) ->
      owner == node

rawConnectionFromAdmissionConnection :: AdmissionConnection -> Connection
rawConnectionFromAdmissionConnection connection =
  Connection
    { connectionFrom =
        endpointFromAdmissionBoundary connection.admissionConnectionFrom
    , connectionTo =
        endpointFromAdmissionBoundary connection.admissionConnectionTo
    }

endpointFromAdmissionBoundary :: AdmissionBoundaryPort -> EndpointRef
endpointFromAdmissionBoundary boundary =
  EndpointRef
    { endpointNodeRef = boundary.admissionBoundaryNode
    , endpointPortName = Just boundary.admissionBoundaryPort
    }

primitiveGraphStepDomainClosed
  :: Set.Set CircuitNodeRef -> Set.Set Text -> PrimitiveGraphStep -> Bool
primitiveGraphStepDomainClosed nodes bindingRefs = \case
  PrimitiveEmpty ->
    True
  PrimitiveNode node entries exits ->
    node `Set.member` nodes
      && all (admissionBoundaryInNodes nodes) entries
      && all (admissionBoundaryInNodes nodes) exits
  PrimitiveBindingRef binding ->
    binding `Set.member` bindingRefs
  PrimitiveOverlay leftNodes rightNodes leftBindings rightBindings ->
    all (`Set.member` nodes) leftNodes
      && all (`Set.member` nodes) rightNodes
      && all (`Set.member` bindingRefs) leftBindings
      && all (`Set.member` bindingRefs) rightBindings
  PrimitiveConnect leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ->
    all (admissionBoundaryInNodes nodes) leftExits
      && all (admissionBoundaryInNodes nodes) rightEntries
      && all (admissionConnectionInNodes nodes) matchedPairs
      && all (admissionBoundaryInNodes nodes) unmatchedLeftExits
      && all (admissionBoundaryInNodes nodes) unmatchedRightEntries

generatedFormArtifactDomainClosed :: Set.Set CircuitNodeRef -> GeneratedFormArtifact -> Bool
generatedFormArtifactDomainClosed nodes generated =
  all generatedChildDomainClosed generated.generatedFormUsedChildren
  where
    generatedChildDomainClosed child =
      generatedChildNode child `Set.member` nodes
        && all (admissionBoundaryInNodes nodes) child.generatedChildOutputs
        && all (admissionBoundaryInNodes nodes) child.generatedChildInputs

phantomAdapterArtifactDomainClosed :: Set.Set CircuitNodeRef -> PhantomAdapterArtifact -> Bool
phantomAdapterArtifactDomainClosed nodes phantom =
  phantom.phantomAdapterNode `Set.member` nodes
    && admissionBoundaryInNodes nodes phantom.phantomAdapterSingular
    && all (admissionBoundaryInNodes nodes) phantom.phantomAdapterMulti
    && all (admissionConnectionInNodes nodes) phantom.phantomAdapterLeftBulk
    && all (admissionConnectionInNodes nodes) phantom.phantomAdapterRightBulk

selectAdmissionArtifactDomainClosed :: Set.Set CircuitNodeRef -> SelectAdmissionArtifact -> Bool
selectAdmissionArtifactDomainClosed nodes selectAdmission =
  selectAdmission.selectAdmissionOwner `Set.member` nodes
    && selectAdmission.selectAdmissionConditionNode `Set.member` nodes
    && all
      (admissionBoundaryInNodes nodes . selectVariantPort)
      selectAdmission.selectAdmissionVariants

admissionBoundaryInNodes :: Set.Set CircuitNodeRef -> AdmissionBoundaryPort -> Bool
admissionBoundaryInNodes nodes boundary =
  admissionBoundaryNode boundary `Set.member` nodes
    && maybe
      True
      ((`Set.member` nodes) . fst)
      boundary.admissionBoundaryExclusiveGroup

admissionConnectionInNodes :: Set.Set CircuitNodeRef -> AdmissionConnection -> Bool
admissionConnectionInNodes nodes connection =
  admissionBoundaryInNodes nodes connection.admissionConnectionFrom
    && admissionBoundaryInNodes nodes connection.admissionConnectionTo

primitiveGraphStepValid :: PrimitiveGraphStep -> Bool
primitiveGraphStepValid = \case
  PrimitiveEmpty ->
    True
  PrimitiveNode node entries exits ->
    circuitNodeRefValid node
      && all admissionBoundaryPortValid entries
      && all admissionBoundaryPortValid exits
      && all ((== node) . admissionBoundaryNode) entries
      && all ((== node) . admissionBoundaryNode) exits
      && unique (fmap admissionBoundaryKey entries)
      && unique (fmap admissionBoundaryKey exits)
  PrimitiveBindingRef binding ->
    nonEmptyText binding
  PrimitiveOverlay leftNodes rightNodes leftBindings rightBindings ->
    all circuitNodeRefValid leftNodes
      && all circuitNodeRefValid rightNodes
      && all nonEmptyText leftBindings
      && all nonEmptyText rightBindings
      && primitiveOverlayUnique leftNodes rightNodes leftBindings rightBindings
      && primitiveOverlayDisjoint leftNodes rightNodes leftBindings rightBindings
  PrimitiveConnect leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries ->
    all admissionBoundaryPortValid leftExits
      && all admissionBoundaryPortValid rightEntries
      && all admissionConnectionValid matchedPairs
      && all admissionBoundaryPortValid unmatchedLeftExits
      && all admissionBoundaryPortValid unmatchedRightEntries
      && unique leftExitKeys
      && unique rightEntryKeys
      && all matchedPairInFrontiers matchedPairs
      && all (`elem` leftExits) unmatchedLeftExits
      && all (`elem` rightEntries) unmatchedRightEntries
      && unique (fmap admissionConnectionFromKey matchedPairs)
      && unique (fmap admissionConnectionToKey matchedPairs)
      && connectMatchesAllCompatiblePairs leftExits rightEntries matchedPairs
      && List.sort
        (fmap admissionConnectionFromKey matchedPairs <> fmap admissionBoundaryKey unmatchedLeftExits)
        == List.sort leftExitKeys
      && List.sort
        (fmap admissionConnectionToKey matchedPairs <> fmap admissionBoundaryKey unmatchedRightEntries)
        == List.sort rightEntryKeys
    where
      leftExitKeys =
        fmap admissionBoundaryKey leftExits

      rightEntryKeys =
        fmap admissionBoundaryKey rightEntries

      matchedPairInFrontiers connection =
        admissionConnectionFrom connection `elem` leftExits
          && admissionConnectionTo connection `elem` rightEntries

connectMatchesAllCompatiblePairs
  :: [AdmissionBoundaryPort] -> [AdmissionBoundaryPort] -> [AdmissionConnection] -> Bool
connectMatchesAllCompatiblePairs leftExits rightEntries matchedPairs =
  all
    compatiblePairMatched
    [(leftExit, rightEntry) | leftExit <- leftExits, rightEntry <- rightEntries]
  where
    matchedSet =
      Set.fromList
        [ (admissionConnectionFrom connection, admissionConnectionTo connection)
        | connection <- matchedPairs
        ]

    compatiblePairMatched (leftExit, rightEntry) =
      not (admissionBoundariesCompatible leftExit rightEntry)
        || (leftExit, rightEntry) `Set.member` matchedSet

primitiveOverlayDisjoint :: [CircuitNodeRef] -> [CircuitNodeRef] -> [Text] -> [Text] -> Bool
primitiveOverlayDisjoint leftNodes rightNodes leftBindings rightBindings =
  Set.null (Set.intersection (Set.fromList leftNodes) (Set.fromList rightNodes))
    && Set.null (Set.intersection (Set.fromList leftBindings) (Set.fromList rightBindings))

primitiveOverlayUnique :: [CircuitNodeRef] -> [CircuitNodeRef] -> [Text] -> [Text] -> Bool
primitiveOverlayUnique leftNodes rightNodes leftBindings rightBindings =
  unique leftNodes
    && unique rightNodes
    && unique leftBindings
    && unique rightBindings

type EndpointKey = (CircuitNodeRef, Text)

admissionBoundaryEndpointKey :: AdmissionBoundaryPort -> EndpointKey
admissionBoundaryEndpointKey boundary =
  (admissionBoundaryNode boundary, admissionBoundaryPort boundary)

endpointRefKey :: EndpointRef -> EndpointKey
endpointRefKey ref =
  (ref.endpointNodeRef, fromMaybe "" ref.endpointPortName)

admissionBoundaryKey :: AdmissionBoundaryPort -> (CircuitNodeRef, Text, Text)
admissionBoundaryKey boundary =
  ( admissionBoundaryNode boundary
  , admissionBoundaryPort boundary
  , admissionBoundaryContract boundary
  )

admissionBoundaryCompatibilityShape :: AdmissionBoundaryPort -> (AdmissionPortLabel, Text)
admissionBoundaryCompatibilityShape boundary =
  (admissionBoundaryLabel boundary, admissionBoundaryContract boundary)

admissionBoundaryOutputShape :: AdmissionBoundaryPort -> (AdmissionPortLabel, Text, Maybe Natural)
admissionBoundaryOutputShape boundary =
  ( admissionBoundaryLabel boundary
  , admissionBoundaryContract boundary
  , fmap snd boundary.admissionBoundaryExclusiveGroup
  )

admissionBoundaryIdentityOutputShape
  :: AdmissionBoundaryPort -> (AdmissionPortLabel, Text, Maybe Natural)
admissionBoundaryIdentityOutputShape boundary =
  (admissionBoundaryLabel boundary, admissionBoundaryContract boundary, Nothing)

admissionConnectionFromKey :: AdmissionConnection -> (CircuitNodeRef, Text, Text)
admissionConnectionFromKey =
  admissionBoundaryKey . admissionConnectionFrom

admissionConnectionToKey :: AdmissionConnection -> (CircuitNodeRef, Text, Text)
admissionConnectionToKey =
  admissionBoundaryKey . admissionConnectionTo

admissionBoundaryPortValid :: AdmissionBoundaryPort -> Bool
admissionBoundaryPortValid boundary =
  circuitNodeRefValid boundary.admissionBoundaryNode
    && nonEmptyText boundary.admissionBoundaryPort
    && nonEmptyText boundary.admissionBoundaryContract
    && admissionPortLabelValid boundary.admissionBoundaryLabel
    && maybe
      True
      ( \(owner, _index) ->
          owner == boundary.admissionBoundaryNode
            && circuitNodeRefValid owner
      )
      boundary.admissionBoundaryExclusiveGroup

admissionPortLabelValid :: AdmissionPortLabel -> Bool
admissionPortLabelValid = \case
  AdmissionNoLabel ->
    True
  AdmissionLabel label ->
    nonEmptyText label

admissionConnectionValid :: AdmissionConnection -> Bool
admissionConnectionValid connection =
  admissionBoundaryPortValid connection.admissionConnectionFrom
    && admissionBoundaryPortValid connection.admissionConnectionTo
    && admissionConnectionBoundaryCompatible connection

admissionConnectionBoundaryCompatible :: AdmissionConnection -> Bool
admissionConnectionBoundaryCompatible connection =
  admissionBoundariesCompatible connection.admissionConnectionFrom connection.admissionConnectionTo

admissionBoundariesCompatible :: AdmissionBoundaryPort -> AdmissionBoundaryPort -> Bool
admissionBoundariesCompatible fromBoundary toBoundary =
  admissionBoundaryLabel fromBoundary == admissionBoundaryLabel toBoundary
    && admissionBoundaryContract fromBoundary == admissionBoundaryContract toBoundary

rawConnectionValid :: Connection -> Bool
rawConnectionValid connection =
  endpointRefValid connection.connectionFrom
    && endpointRefValid connection.connectionTo

endpointRefValid :: EndpointRef -> Bool
endpointRefValid endpoint =
  circuitNodeRefValid endpoint.endpointNodeRef
    && maybe True nonEmptyText endpoint.endpointPortName

circuitNodeRefValid :: CircuitNodeRef -> Bool
circuitNodeRefValid node =
  nonEmptyText node.unCircuitNodeRef

nonEmptyText :: Text -> Bool
nonEmptyText =
  not . T.null

unique :: Ord a => [a] -> Bool
unique values =
  Set.size (Set.fromList values) == length values

generatedFormArtifactValid :: GeneratedFormArtifact -> Bool
generatedFormArtifactValid generated =
  nonEmptyText generated.generatedFormKindName
    && nonEmptyText generated.generatedFormBinding
    && all generatedChildSourceArtifactValid generated.generatedFormSourceChildren
    && all generatedChildArtifactValid generated.generatedFormUsedChildren
    && generatedFormChildrenOwnedByBinding generated
    && generatedFormKindShapeMatches generated
    && all usedChildBacked generated.generatedFormUsedChildren
    && unique sourceKeys
    && unique usedKeys
    && all sourceChildValueValid generated.generatedFormSourceChildren
  where
    sourceKeys =
      [ (source.generatedSourceChildNode, source.generatedSourceChildLabel)
      | source <- generated.generatedFormSourceChildren
      ]

    usedKeys =
      [ (child.generatedChildNode, child.generatedChildLabel)
      | child <- generated.generatedFormUsedChildren
      ]

    sourceKeySet =
      Set.fromList sourceKeys

    usedChildBacked child =
      (child.generatedChildNode, child.generatedChildLabel) `Set.member` sourceKeySet

    sourceChildValueValid source =
      maybe True admissionStaticValueValid source.generatedSourceChildValue

generatedFormChildrenOwnedByBinding :: GeneratedFormArtifact -> Bool
generatedFormChildrenOwnedByBinding generated =
  all sourceChildOwnedByBinding generated.generatedFormSourceChildren
    && all usedChildOwnedByBinding generated.generatedFormUsedChildren
  where
    sourceChildOwnedByBinding source =
      generatedSourceChildNode source
        == generatedChildNodeFor
          generated.generatedFormBinding
          source.generatedSourceChildLabel

    usedChildOwnedByBinding child =
      generatedChildNode child
        == generatedChildNodeFor
          generated.generatedFormBinding
          child.generatedChildLabel

generatedChildNodeFor :: Text -> Text -> CircuitNodeRef
generatedChildNodeFor binding label =
  CircuitNodeRef (binding <> "_" <> label)

generatedFormKindShapeMatches :: GeneratedFormArtifact -> Bool
generatedFormKindShapeMatches generated =
  case generated.generatedFormKind of
    GeneratedMake ->
      generatedMakeLabelsCanonical generated
        && all generatedSourceChildValueEmpty generated.generatedFormSourceChildren
    GeneratedMakeEach ->
      True

generatedSourceChildValueEmpty :: GeneratedChildSourceArtifact -> Bool
generatedSourceChildValueEmpty source =
  case source.generatedSourceChildValue of
    Nothing ->
      True
    Just _value ->
      False

generatedMakeLabelsCanonical :: GeneratedFormArtifact -> Bool
generatedMakeLabelsCanonical generated =
  fmap generatedSourceChildLabel generated.generatedFormSourceChildren
    == fmap (T.pack . show) [0 .. length generated.generatedFormSourceChildren - 1]

generatedChildSourceArtifactValid :: GeneratedChildSourceArtifact -> Bool
generatedChildSourceArtifactValid source =
  circuitNodeRefValid source.generatedSourceChildNode
    && nonEmptyText source.generatedSourceChildLabel
    && maybe True admissionStaticValueValid source.generatedSourceChildValue

generatedChildArtifactValid :: GeneratedChildArtifact -> Bool
generatedChildArtifactValid child =
  circuitNodeRefValid child.generatedChildNode
    && nonEmptyText child.generatedChildLabel
    && all generatedOutputOwnedByChild child.generatedChildOutputs
    && all generatedInputOwnedByChild child.generatedChildInputs
    && unique (fmap admissionBoundaryKey child.generatedChildOutputs)
    && unique (fmap admissionBoundaryKey child.generatedChildInputs)
    && all admissionBoundaryPortValid child.generatedChildOutputs
    && all admissionBoundaryPortValid child.generatedChildInputs
  where
    generatedOutputOwnedByChild output =
      admissionBoundaryNode output == child.generatedChildNode

    generatedInputOwnedByChild input =
      admissionBoundaryNode input == child.generatedChildNode

admissionStaticValueValid :: AdmissionStaticValue -> Bool
admissionStaticValueValid = \case
  AdmissionStaticString _text ->
    True
  AdmissionStaticBool _boolValue ->
    True
  AdmissionStaticNat _natValue ->
    True
  AdmissionStaticList values ->
    all admissionStaticValueValid values
  AdmissionStaticRecord fields ->
    unique (fmap admissionStaticFieldLabel fields)
      && all admissionStaticFieldValid fields

admissionStaticFieldValid :: AdmissionStaticField -> Bool
admissionStaticFieldValid field =
  nonEmptyText field.admissionStaticFieldLabel
    && admissionStaticValueValid field.admissionStaticFieldValue

phantomAdapterArtifactValid :: PhantomAdapterArtifact -> Bool
phantomAdapterArtifactValid phantom =
  productShapeArtifactValid phantom.phantomAdapterProductShape
    && phantomAdapterRowsValid phantom
    && phantomAdapterSingularContractMatchesProduct phantom
    && fromIntegral (length phantom.phantomAdapterMulti)
      == productShapeArtifactArity phantom.phantomAdapterProductShape
    && productShapeArtifactMatchesMulti
      phantom.phantomAdapterProductShape
      phantom.phantomAdapterMulti
    && unique (fmap admissionBoundaryKey phantom.phantomAdapterMulti)
    && phantomAdapterIndexedMultiKeysUnique phantom
    && phantomAdapterBulkEndpointsValid phantom
    && phantomAdapterBulkEndpointPartitionValid phantom

phantomAdapterRowsValid :: PhantomAdapterArtifact -> Bool
phantomAdapterRowsValid phantom =
  circuitNodeRefValid phantom.phantomAdapterNode
    && admissionBoundaryPortValid phantom.phantomAdapterSingular
    && all admissionBoundaryPortValid phantom.phantomAdapterMulti
    && all admissionConnectionValid phantom.phantomAdapterLeftBulk
    && all admissionConnectionValid phantom.phantomAdapterRightBulk

phantomAdapterSingularContractMatchesProduct :: PhantomAdapterArtifact -> Bool
phantomAdapterSingularContractMatchesProduct phantom =
  phantom.phantomAdapterSingular.admissionBoundaryContract
    == productShapeArtifactContract phantom.phantomAdapterProductShape

phantomAdapterBulkEndpointsValid :: PhantomAdapterArtifact -> Bool
phantomAdapterBulkEndpointsValid phantom =
  case phantom.phantomAdapterDirection of
    PhantomGather ->
      all gatherLeftEndpointValid phantom.phantomAdapterLeftBulk
        && all gatherRightEndpointValid phantom.phantomAdapterRightBulk
    PhantomScatter ->
      all scatterLeftEndpointValid phantom.phantomAdapterLeftBulk
        && all scatterRightEndpointValid phantom.phantomAdapterRightBulk
  where
    gatherLeftEndpointValid connection =
      admissionConnectionFrom connection `elem` phantom.phantomAdapterMulti
        && admissionBoundaryNode (admissionConnectionTo connection) == phantom.phantomAdapterNode

    gatherRightEndpointValid connection =
      admissionBoundaryNode (admissionConnectionFrom connection) == phantom.phantomAdapterNode
        && admissionConnectionTo connection == phantom.phantomAdapterSingular

    scatterLeftEndpointValid connection =
      admissionConnectionFrom connection == phantom.phantomAdapterSingular
        && admissionBoundaryNode (admissionConnectionTo connection) == phantom.phantomAdapterNode

    scatterRightEndpointValid connection =
      admissionBoundaryNode (admissionConnectionFrom connection) == phantom.phantomAdapterNode
        && admissionConnectionTo connection `elem` phantom.phantomAdapterMulti

phantomAdapterBulkEndpointPartitionValid :: PhantomAdapterArtifact -> Bool
phantomAdapterBulkEndpointPartitionValid phantom =
  case phantom.phantomAdapterDirection of
    PhantomGather ->
      List.sort (fmap admissionConnectionFromKey phantom.phantomAdapterLeftBulk)
        == List.sort multiKeys
        && List.sort (fmap admissionConnectionToKey phantom.phantomAdapterRightBulk)
          == [singularKey]
    PhantomScatter ->
      List.sort (fmap admissionConnectionFromKey phantom.phantomAdapterLeftBulk)
        == [singularKey]
        && List.sort (fmap admissionConnectionToKey phantom.phantomAdapterRightBulk)
          == List.sort multiKeys
  where
    multiKeys =
      fmap admissionBoundaryKey phantom.phantomAdapterMulti

    singularKey =
      admissionBoundaryKey phantom.phantomAdapterSingular

phantomAdapterIndexedMultiKeysUnique :: PhantomAdapterArtifact -> Bool
phantomAdapterIndexedMultiKeysUnique phantom =
  case phantom.phantomAdapterProductShape of
    ProductRecord _contract _fields ->
      True
    ProductIndexed _elementContract _count ->
      unique (fmap admissionBoundaryCompatibilityShape phantom.phantomAdapterMulti)

productShapeArtifactArity :: ProductShapeArtifact -> Natural
productShapeArtifactArity = \case
  ProductRecord _contract fields ->
    fromIntegral (length fields)
  ProductIndexed _elementContract count ->
    count

productShapeArtifactContract :: ProductShapeArtifact -> Text
productShapeArtifactContract = \case
  ProductRecord contract _fields ->
    contract
  ProductIndexed elementContract count ->
    boundedIndexedContractName elementContract count

productShapeArtifactValid :: ProductShapeArtifact -> Bool
productShapeArtifactValid = \case
  ProductRecord contract fields ->
    nonEmptyText contract
      && unique (fmap fst fields)
      && all (\(label, fieldContract) -> nonEmptyText label && nonEmptyText fieldContract) fields
  ProductIndexed elementContract _count ->
    nonEmptyText elementContract
      && not (indexedProductElementProductLike elementContract)

indexedProductElementProductLike :: Text -> Bool
indexedProductElementProductLike =
  T.isPrefixOf "["

productShapeArtifactMatchesMulti :: ProductShapeArtifact -> [AdmissionBoundaryPort] -> Bool
productShapeArtifactMatchesMulti productShape multi =
  case productShape of
    ProductRecord _contract fields ->
      length observedFields == length multi
        && List.sort observedFields == List.sort fields
    ProductIndexed elementContract _count ->
      all ((== elementContract) . admissionBoundaryContract) multi
  where
    observedFields =
      [ (label, boundary.admissionBoundaryContract)
      | boundary <- multi
      , AdmissionLabel label <- [boundary.admissionBoundaryLabel]
      ]

selectAdmissionArtifactValid :: SelectAdmissionArtifact -> Bool
selectAdmissionArtifactValid selectAdmission =
  selectAdmission.selectAdmissionOwner == selectAdmission.selectAdmissionConditionNode
    && circuitNodeRefValid selectAdmission.selectAdmissionOwner
    && circuitNodeRefValid selectAdmission.selectAdmissionConditionNode
    && all selectVariantArtifactValid selectAdmission.selectAdmissionVariants
    && all selectArmAdmissionArtifactValid selectAdmission.selectAdmissionArms
    && all
      (selectArmResolutionSound selectAdmission.selectAdmissionVariants)
      selectAdmission.selectAdmissionArms
    && unique variantKeys
    && length selectAdmission.selectAdmissionVariants >= 2
    && selectVariantsShareExclusiveGroup selectAdmission.selectAdmissionVariants
    && unique armCanonicalKeys
    && unique armSourceIndexes
    && armSourceIndexes == canonicalArmSourceIndexes
    && List.sort armCanonicalKeys == List.sort variantKeys
  where
    variantKeys =
      fmap selectVariantKey selectAdmission.selectAdmissionVariants

    armCanonicalKeys =
      fmap selectArmCanonicalKey selectAdmission.selectAdmissionArms

    armSourceIndexes =
      fmap selectArmSourceIndex selectAdmission.selectAdmissionArms

    canonicalArmSourceIndexes =
      fmap fromIntegral ([0 .. length selectAdmission.selectAdmissionArms - 1] :: [Int])

selectVariantsShareExclusiveGroup :: [SelectVariantArtifact] -> Bool
selectVariantsShareExclusiveGroup = \case
  [] ->
    False
  variant : variants ->
    case variant.selectVariantPort.admissionBoundaryExclusiveGroup of
      Nothing ->
        False
      Just groupId ->
        all
          ((== Just groupId) . admissionBoundaryExclusiveGroup . selectVariantPort)
          variants

selectVariantArtifactValid :: SelectVariantArtifact -> Bool
selectVariantArtifactValid variant =
  nonEmptyText variant.selectVariantKey
    && admissionBoundaryPortValid variant.selectVariantPort
    && selectVariantKeyCanonical variant

selectVariantKeyCanonical :: SelectVariantArtifact -> Bool
selectVariantKeyCanonical variant =
  variant.selectVariantKey == admissionBoundarySelectKey variant.selectVariantPort

admissionBoundarySelectKey :: AdmissionBoundaryPort -> Text
admissionBoundarySelectKey boundary =
  case boundary.admissionBoundaryLabel of
    AdmissionLabel label ->
      label
    AdmissionNoLabel ->
      boundary.admissionBoundaryContract

selectArmAdmissionArtifactValid :: SelectArmAdmissionArtifact -> Bool
selectArmAdmissionArtifactValid arm =
  nonEmptyText arm.selectArmSourceKey
    && nonEmptyText arm.selectArmCanonicalKey
    && all bodyEntryClosed arm.selectArmBodyEntries
    && all bodyExitClosed arm.selectArmBodyExits
    && unique arm.selectArmBodyNodes
    && unique (fmap admissionBoundaryKey arm.selectArmBodyEntries)
    && unique (fmap admissionBoundaryKey arm.selectArmBodyExits)
    && all circuitNodeRefValid arm.selectArmBodyNodes
    && all admissionBoundaryPortValid arm.selectArmBodyEntries
    && all admissionBoundaryPortValid arm.selectArmBodyExits
  where
    bodyNodes =
      Set.fromList arm.selectArmBodyNodes

    bodyEntryClosed =
      admissionBoundaryInNodes bodyNodes

    bodyExitClosed =
      admissionBoundaryInNodes bodyNodes

selectArmResolutionSound :: [SelectVariantArtifact] -> SelectArmAdmissionArtifact -> Bool
selectArmResolutionSound variants arm =
  case arm.selectArmResolutionMode of
    SelectResolvedByLabel ->
      arm.selectArmSourceKey == arm.selectArmCanonicalKey
        && any labelTargetsCanonical variants
    SelectResolvedByContract ->
      not (any labelMatchesSource variants)
        && contractMatchedKeys == [arm.selectArmCanonicalKey]
  where
    labelMatchesSource variant =
      admissionBoundaryLabel variant.selectVariantPort
        == AdmissionLabel arm.selectArmSourceKey

    labelTargetsCanonical variant =
      selectVariantKey variant == arm.selectArmCanonicalKey
        && admissionBoundaryLabel variant.selectVariantPort
          == AdmissionLabel arm.selectArmSourceKey

    contractMatchedKeys =
      [ selectVariantKey variant
      | variant <- variants
      , admissionBoundaryContract variant.selectVariantPort == arm.selectArmSourceKey
      ]

wireAdmissionMetadataKey :: Text
wireAdmissionMetadataKey = "wireAdmission"

wireAdmissionMetadataValue :: WireAdmissionArtifact -> Value
wireAdmissionMetadataValue = Aeson.toJSON
