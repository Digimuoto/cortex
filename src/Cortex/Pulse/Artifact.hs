{- |
Module      : Cortex.Pulse.Artifact
Description : Typed surface and stock binder for the content-addressed artifact store (ADR 0089).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

The Pulse-owned store for values a running graph durably emits: content rows
are immutable and keyed by 'artifactAddress' — SHA-256 over the canonical
UTF-8 encoding of the typed envelope @{contract, mediaType, payloadKind,
value}@ — and provenance rows link each content row to the run and node that
emitted it. Distinct from ADR 0006's compiled-workflow artifact
('Cortex.Wire.Circuit.Artifact', the circuit-as-artifact boundary): this
module stores values a workflow emits, not the workflow itself.

'bindPulseArtifactBoundary' is the stock, strictly opt-in interpreter for the
ADR 0071 artifact-emission boundary: the default binder still rejects artifact
boundaries, kind and target stay opaque, and a host that wants its own store
injects its own binder exactly as before. Cortex offers one injectable target;
it does not enumerate kinds, validate targets, or interpret referenced content
(ADR 0085 names resolved-content validation as a follow-up at this boundary).
-}
module Cortex.Pulse.Artifact
  ( ArtifactHash (..)
  , artifactAddress
  , pulseArtifactRefValue
  , bindPulseArtifactBoundary
  , ArtifactPut (..)
  , ArtifactRecord (..)
  , ArtifactForRun (..)
  , putArtifact
  , getArtifact
  , listArtifactsForRun
  )
where

import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID

import Cortex.Pulse.Database (Pool, runTransaction)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Plan
  ( StageContext (..)
  , StageDefinition
  , StageReplaySafety (..)
  , StageResult (..)
  )
import Cortex.Pulse.Query.Artifact
  ( ArtifactForRun (..)
  , ArtifactPut (..)
  , ArtifactRecord (..)
  , getArtifact
  , listArtifactsForRun
  , putArtifact
  )
import Cortex.Wire.Circuit.IR (CircuitArtifactBoundary (..))
import Cortex.Wire.Circuit.Lowering (CircuitLoweringError, artifactStage)
import Cortex.Wire.Pure (canonicalJson)
import Cortex.Wire.Value
  ( WirePayloadKind (..)
  , WireValue (..)
  , mkWireValue
  , renderWirePayloadKind
  , wirePayloadKindMediaType
  )

{- | A rendered content address: @sha256:\<64 hex\>@. The address covers the
typed envelope, not just the payload value, so every @pulse.artifacts@ column
is a pure function of the hash.
-}
newtype ArtifactHash = ArtifactHash {unArtifactHash :: Text}
  deriving stock (Eq, Ord, Show)

{- | Compute the canonical content address of a typed payload:
@sha256:@ followed by the lowercase hex SHA-256 of the canonical UTF-8
encoding ('Cortex.Wire.Pure.canonicalJson' — recursively key-sorted objects,
canonical numbers) of the envelope

> { "contract": <string|null>, "mediaType": <string>,
>   "payloadKind": <string>, "value": <payload> }

Including the typing fields means two emissions that disagree about contract,
media type, or payload kind get distinct addresses — @ON CONFLICT DO NOTHING@
can never keep first-writer metadata a second writer disagreed with. The exact
hashed shape is pinned by ADR 0089 and the schema reference; changing it is a
new address scheme, not an edit.
-}
artifactAddress :: Maybe Text -> WirePayloadKind -> Text -> Aeson.Value -> ArtifactHash
artifactAddress contract payloadKind mediaType payload =
  let envelope =
        Aeson.object
          [ "contract" .= contract
          , "mediaType" .= mediaType
          , "payloadKind" .= renderWirePayloadKind payloadKind
          , "value" .= payload
          ]
      digest = hash (TE.encodeUtf8 (canonicalJson envelope)) :: Digest SHA256
   in ArtifactHash ("sha256:" <> T.pack (show digest))

{- | The suggested @artifact_ref@ reference object for a stored artifact.
Substrate validation of @artifact_ref@ payloads stays structural ("a JSON
object"); this shape is a documented convention that a downstream contract may
pin with an ADR 0085 schema. Deliberately free of timestamps and nonces so a
replayed emission produces a byte-identical reference.
-}
pulseArtifactRefValue :: ArtifactPut -> Aeson.Value
pulseArtifactRefValue put =
  Aeson.object
    [ "artifactHash" .= put.apHash
    , "store" .= ("pulse.artifacts" :: Text)
    , "kind" .= put.apKind
    , "runId" .= UUID.toText put.apRunId
    , "nodeId" .= put.apNodeId
    , "mediaType" .= put.apMediaType
    , "contract" .= put.apContract
    ]

{- | Stock Pulse-backed interpreter for a 'CircuitArtifactBoundary': persist the
stage input to the content-addressed store and complete with an @artifact_ref@
envelope carrying the address. Opt-in only — inject it through
'Cortex.Wire.Circuit.Lowering.committedVariantBinderWith' (or a custom binder);
the default binder keeps rejecting artifact boundaries.

Input selection follows the 'Cortex.Pulse.Plan.liftChainAction' convention
(single input: that value; none: @Null@; several: the input map). An input that
decodes as a 'WireValue' contributes its contract, payload kind, and media
type to the content typing, and its inner value becomes the stored payload;
any other input is stored as an untyped @json@ payload. The boundary's opaque
kind and target are recorded on the provenance row and interpreted by nothing.

Replay safety is 'SafeToReplay' by content addressing: the same input yields
the same address, both store writes are conflict-free upserts, and the
completed reference is a deterministic function of the input — re-running the
stage on resume cannot duplicate rows or change its output. A store failure
fails the stage with the typed @artifact_store_failure@ reason (every database
call has an error path), never a silent success.
-}
bindPulseArtifactBoundary
  :: Pool
  -> CircuitArtifactBoundary
  -> Either CircuitLoweringError (StageDefinition NodeId)
bindPulseArtifactBoundary pool boundary =
  Right . artifactStage boundary SafeToReplay $ \ctx -> do
    let input = case Map.elems ctx.scInputs of
          [v] -> v
          [] -> Aeson.Null
          _ -> Aeson.toJSON ctx.scInputs
        (contract, payloadKind, payload) = case Aeson.fromJSON input :: Aeson.Result WireValue of
          Aeson.Success wireValue ->
            ( Just wireValue.wireValueContract
            , wireValue.wireValuePayloadKind
            , wireValue.wireValueValue
            )
          Aeson.Error _ -> (Nothing, WirePayloadJson, input)
        mediaType = wirePayloadKindMediaType payloadKind
        ArtifactHash address = artifactAddress contract payloadKind mediaType payload
        put =
          ArtifactPut
            { apHash = address
            , apPayload = payload
            , apContract = contract
            , apPayloadKind = renderWirePayloadKind payloadKind
            , apMediaType = mediaType
            , apByteSize = fromIntegral (BS.length (TE.encodeUtf8 (canonicalJson payload)))
            , apRunId = ctx.scRunId
            , apNodeId = unNodeId ctx.scNodeId
            , apKind = boundary.circuitArtifactKind
            , apTarget = artifactTargetText boundary
            }
    stored <- runTransaction pool (putArtifact put)
    case stored of
      Left err ->
        pure (StageFail "artifact_store_failure" (T.pack err))
      Right () ->
        pure
          ( StageComplete
              ( Aeson.toJSON
                  ( mkWireValue
                      "artifact_ref"
                      WirePayloadArtifactRef
                      (Just (unNodeId ctx.scNodeId))
                      (pulseArtifactRefValue put)
                  )
              )
          )

{- | Render the boundary's opaque @to@ target for the provenance row, when the
compiled metadata carries one. The target is recorded verbatim and never
interpreted (ADR 0071).
-}
artifactTargetText :: CircuitArtifactBoundary -> Maybe Text
artifactTargetText boundary =
  case boundary.circuitArtifactMetadata of
    Aeson.Object fields ->
      case Aeson.fromJSON (Aeson.Object fields) of
        Aeson.Success (ArtifactMetadataTarget target) -> target
        Aeson.Error _ -> Nothing
    _ -> Nothing

newtype ArtifactMetadataTarget = ArtifactMetadataTarget (Maybe Text)

instance Aeson.FromJSON ArtifactMetadataTarget where
  parseJSON = Aeson.withObject "ArtifactMetadataTarget" $ \fields ->
    ArtifactMetadataTarget <$> fields Aeson..:? "to"
