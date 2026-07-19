{- |
Module      : Cortex.Capability.Catalog.AdmissionProjection
Description : ADR 0053 admission projection — the inert public surface of an executor.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The admission projection is the compile-time, authority-free description of an
executor that Wire and Capability check against (ADR 0053): identity, a projection
version, a content digest, typed ports, a config schema reference, declared
requirement slots, and the replay / isolation / effect / await-strategy metadata
the runtime binding later honours. It carries no runnable action and no credentials.

The registry invariant is @(executor id, projection version)@ uniquely identifies
projection content; two manifests claiming the same pair must agree on the digest.

JSON is hand-written because the reused Wire port types do not round-trip through
their derived instances; the digest is taken over a canonical field tuple so it is
stable regardless of JSON object ordering (mirrors 'Cortex.Pulse.Materialization.computeTopologyHash').
-}
module Cortex.Capability.Catalog.AdmissionProjection
  ( AdmissionProjection (..)
  , ProjectionVersion (..)
  , ContentDigest (..)
  , ConfigSchemaRef (..)
  , ArgumentShapeRef (..)
  , RequirementSlot (..)
  , currentProjectionVersion
  , apArgumentShapeRef
  , admissionProjectionWithArgumentShapeRef
  , rsArgumentSelector
  , admissionProjectionDigest
  , encodeWirePorts
  , decodeWirePorts
  )
where

import Control.Monad (when)
import Crypto.Hash (SHA256, hashlazy)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Parser)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

import Cortex.Capability.Catalog.AwaitStrategy
  ( AwaitStrategy
  , IsolationExpectation
  , ReplayClass
  )
import Cortex.Wire.AST
  ( WireInputCardinality (..)
  , WireInputPort (..)
  , WireOutputPort (..)
  , WirePorts (..)
  )
import Cortex.Wire.Executor
  ( WireExecutorEffect (..)
  , WireExecutorId (..)
  )

newtype ProjectionVersion = ProjectionVersion {unProjectionVersion :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

newtype ContentDigest = ContentDigest {unContentDigest :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

{- | A reference to the executor's config schema (digest or named decoder), never
the config itself (ADR 0053 keeps config data pure and out of the projection).
-}
data ConfigSchemaRef
  = ConfigSchemaNone
  | ConfigSchemaDigest ContentDigest
  | ConfigSchemaName Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

{- | Canonical name for the schema/decoder reference at the one-record ingress
boundary. The config-named representation remains stored for v1 callers.
-}
data ArgumentShapeRef
  = ArgumentShapeNone
  | ArgumentShapeDigest ContentDigest
  | ArgumentShapeName Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

currentProjectionVersion :: ProjectionVersion
currentProjectionVersion = ProjectionVersion "2"

argumentShapeRefFromConfig :: ConfigSchemaRef -> ArgumentShapeRef
argumentShapeRefFromConfig = \case
  ConfigSchemaNone -> ArgumentShapeNone
  ConfigSchemaDigest digest -> ArgumentShapeDigest digest
  ConfigSchemaName name -> ArgumentShapeName name

configSchemaRefFromArgument :: ArgumentShapeRef -> ConfigSchemaRef
configSchemaRefFromArgument = \case
  ArgumentShapeNone -> ConfigSchemaNone
  ArgumentShapeDigest digest -> ConfigSchemaDigest digest
  ArgumentShapeName name -> ConfigSchemaName name

{- | A declared requirement the binding layer must satisfy: a capability kind, the
local binding name the host resolves, an optional config selector path, and the
required permission class. Inert — declaring a requirement does not grant it.
-}
data RequirementSlot = RequirementSlot
  { rsCapabilityKind :: !Text
  , rsBindingName :: !Text
  , rsConfigSelector :: !(Maybe Text)
  , rsPermissionClass :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

rsArgumentSelector :: RequirementSlot -> Maybe Text
rsArgumentSelector = rsConfigSelector

data AdmissionProjection = AdmissionProjection
  { apExecutorId :: !WireExecutorId
  , apProjectionVersion :: !ProjectionVersion
  , apPorts :: !WirePorts
  , apConfigSchemaRef :: !ConfigSchemaRef
  , apRequirementSlots :: ![RequirementSlot]
  , apReplayClass :: !ReplayClass
  , apIsolationExpectation :: !IsolationExpectation
  , apEffect :: !WireExecutorEffect
  , apAwaitStrategy :: !AwaitStrategy
  }
  deriving stock (Eq, Show, Generic)

apArgumentShapeRef :: AdmissionProjection -> ArgumentShapeRef
apArgumentShapeRef = argumentShapeRefFromConfig . apConfigSchemaRef

admissionProjectionWithArgumentShapeRef
  :: ArgumentShapeRef -> AdmissionProjection -> AdmissionProjection
admissionProjectionWithArgumentShapeRef shapeRef projection =
  projection
    { apProjectionVersion = currentProjectionVersion
    , apConfigSchemaRef = configSchemaRefFromArgument shapeRef
    }

instance ToJSON AdmissionProjection where
  toJSON p =
    object
      ( [ "executorId" .= unWireExecutorId (apExecutorId p)
        , "projectionVersion" .= apProjectionVersion p
        , "ports" .= encodeWirePorts (apPorts p)
        , "requirementSlots" .= apRequirementSlots p
        , "replayClass" .= apReplayClass p
        , "isolationExpectation" .= apIsolationExpectation p
        , "effect" .= effectText (apEffect p)
        , "awaitStrategy" .= apAwaitStrategy p
        ]
          <> if apProjectionVersion p == currentProjectionVersion
            then ["argumentShapeRef" .= apArgumentShapeRef p]
            else ["configSchemaRef" .= apConfigSchemaRef p]
      )

instance FromJSON AdmissionProjection where
  parseJSON = withObject "AdmissionProjection" $ \o -> do
    version <- o .: "projectionVersion"
    legacyRef <- o .:? "configSchemaRef"
    argumentRef <- o .:? "argumentShapeRef"
    when (isJust legacyRef && isJust argumentRef) $
      fail "admission projection cannot define both configSchemaRef and argumentShapeRef"
    storedRef <-
      case version of
        ProjectionVersion "2" ->
          maybe
            (fail "version 2 admission projection is missing argumentShapeRef")
            (pure . configSchemaRefFromArgument)
            argumentRef
        ProjectionVersion "1" ->
          maybe (fail "version 1 admission projection is missing configSchemaRef") pure legacyRef
        ProjectionVersion unknown ->
          fail ("unsupported admission projection version " <> T.unpack unknown)
    AdmissionProjection . WireExecutorId
      <$> o .: "executorId"
      <*> pure version
      <*> (o .: "ports" >>= decodeWirePorts)
      <*> pure storedRef
      <*> o .:? "requirementSlots" .!= []
      <*> o .: "replayClass"
      <*> o .: "isolationExpectation"
      <*> (o .: "effect" >>= parseEffect)
      <*> o .: "awaitStrategy"

{- | Deterministic content digest over the projection's defining fields. Taken over
a canonical tuple (not the JSON object) so object key ordering cannot perturb it.
-}
admissionProjectionDigest :: AdmissionProjection -> ContentDigest
admissionProjectionDigest p =
  let canonical =
        Aeson.encode
          ( unWireExecutorId (apExecutorId p)
          , unProjectionVersion (apProjectionVersion p)
          , canonicalPorts (apPorts p)
          , if apProjectionVersion p == currentProjectionVersion
              then toJSON (apArgumentShapeRef p)
              else toJSON (apConfigSchemaRef p)
          , toJSON (apRequirementSlots p)
          , toJSON (apReplayClass p)
          , toJSON (apIsolationExpectation p)
          , effectText (apEffect p)
          , toJSON (apAwaitStrategy p)
          )
      digest = hashlazy @SHA256 canonical
   in ContentDigest (T.pack (show digest))

-- Canonical, order-stable encoding of ports for the digest: sorted association
-- lists rather than a map/object.
canonicalPorts :: WirePorts -> Aeson.Value
canonicalPorts ports =
  toJSON
    ( [ (name, p.wireInputPortAccepts, cardinalityText p.wireInputPortCardinality, p.wireInputPortRequired)
      | (name, p) <- Map.toAscList ports.wirePortsInputs
      ]
    , [ (name, p.wireOutputPortContract)
      | (name, p) <- Map.toAscList ports.wirePortsOutputs
      ]
    )

{- | Encode ports in the shape 'FromJSON' 'WirePorts' reads (object form with
@inputs@/@outputs@ maps and @accepts@/@cardinality@/@required@/@contract@ fields).
-}
encodeWirePorts :: WirePorts -> Aeson.Value
encodeWirePorts ports =
  object
    [ "inputs"
        .= object
          [ Key.fromText name
              .= object
                [ "accepts" .= p.wireInputPortAccepts
                , "cardinality" .= cardinalityText p.wireInputPortCardinality
                , "required" .= p.wireInputPortRequired
                ]
          | (name, p) <- Map.toList ports.wirePortsInputs
          ]
    , "outputs"
        .= object
          [ Key.fromText name .= object ["contract" .= p.wireOutputPortContract]
          | (name, p) <- Map.toList ports.wirePortsOutputs
          ]
    ]

decodeWirePorts :: Aeson.Value -> Parser WirePorts
decodeWirePorts = parseJSON

cardinalityText :: WireInputCardinality -> Text
cardinalityText = \case
  WireInputCardinalityOne -> "one"
  WireInputCardinalityMany -> "many"

effectText :: WireExecutorEffect -> Text
effectText = \case
  WireExecutorPure -> "pure"
  WireExecutorModel -> "model"
  WireExecutorHostEffect -> "host_effect"
  WireExecutorImpure -> "impure"

parseEffect :: Text -> Parser WireExecutorEffect
parseEffect = \case
  "pure" -> pure WireExecutorPure
  "model" -> pure WireExecutorModel
  "host_effect" -> pure WireExecutorHostEffect
  "impure" -> pure WireExecutorImpure
  other -> fail ("unknown executor effect: " <> T.unpack other)
