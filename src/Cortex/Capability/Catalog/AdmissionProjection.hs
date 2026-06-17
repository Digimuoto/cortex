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
  , RequirementSlot (..)
  , admissionProjectionDigest
  , encodeWirePorts
  , decodeWirePorts
  )
where

import Crypto.Hash (SHA256, hashlazy)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Parser)
import Data.Map.Strict qualified as Map
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

instance ToJSON AdmissionProjection where
  toJSON p =
    object
      [ "executorId" .= unWireExecutorId (apExecutorId p)
      , "projectionVersion" .= apProjectionVersion p
      , "ports" .= encodeWirePorts (apPorts p)
      , "configSchemaRef" .= apConfigSchemaRef p
      , "requirementSlots" .= apRequirementSlots p
      , "replayClass" .= apReplayClass p
      , "isolationExpectation" .= apIsolationExpectation p
      , "effect" .= effectText (apEffect p)
      , "awaitStrategy" .= apAwaitStrategy p
      ]

instance FromJSON AdmissionProjection where
  parseJSON = withObject "AdmissionProjection" $ \o ->
    AdmissionProjection . WireExecutorId
      <$> o .: "executorId"
      <*> o .: "projectionVersion"
      <*> (o .: "ports" >>= decodeWirePorts)
      <*> o .: "configSchemaRef"
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
          , toJSON (apConfigSchemaRef p)
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
