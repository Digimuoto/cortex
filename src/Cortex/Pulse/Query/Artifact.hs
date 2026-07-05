{- |
Module      : Cortex.Pulse.Query.Artifact
Description : Content-addressed run-output artifact store queries (ADR 0089).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Hasql statements for the ADR 0089 artifact store: @pulse.artifacts@ holds
immutable content rows keyed by the canonical content address, and
@pulse.artifact_provenance@ links each content row to the run and node that
emitted it. Both writes upsert with @ON CONFLICT DO NOTHING@ — the address is a
pure function of every content column, so a conflicting insert is by
construction identical to the stored row, and a retried put of the same
@(run, node, content)@ triple is a no-op. Content rows carry no run FK and are
never deleted by Cortex; provenance rows cascade with their run. The typed
surface ('Cortex.Pulse.Artifact') owns address computation; this module owns
only the SQL.
-}
module Cortex.Pulse.Query.Artifact
  ( ArtifactPut (..)
  , ArtifactRecord (..)
  , ArtifactForRun (..)
  , putArtifact
  , getArtifact
  , listArtifactsForRun
  )
where

import Data.Aeson qualified as Aeson
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Hasql.Decoders qualified as D
import Hasql.Statement (Statement (..))
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx

import Platform.Database.Encode qualified as Enc

{- | One artifact emission: the content row and the provenance link written in
one transaction. The caller (the typed surface) has already computed
@apHash@ as the canonical address of @(contract, media type, payload kind,
payload)@; this module persists what it is given.
-}
data ArtifactPut = ArtifactPut
  { apHash :: !Text
  , apPayload :: !Aeson.Value
  , apContract :: !(Maybe Text)
  , apPayloadKind :: !Text
  , apMediaType :: !Text
  , apByteSize :: !Int64
  , apRunId :: !UUID
  , apNodeId :: !Text
  , apKind :: !Text
  , apTarget :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | A stored content row, read back by address.
data ArtifactRecord = ArtifactRecord
  { arHash :: !Text
  , arPayload :: !Aeson.Value
  , arContract :: !(Maybe Text)
  , arPayloadKind :: !Text
  , arMediaType :: !Text
  , arByteSize :: !Int64
  , arCreatedAt :: !UTCTime
  }
  deriving stock (Eq, Show)

-- | A provenance row joined to its content, scoped to one run.
data ArtifactForRun = ArtifactForRun
  { afrHash :: !Text
  , afrNodeId :: !Text
  , afrKind :: !Text
  , afrTarget :: !(Maybe Text)
  , afrPayload :: !Aeson.Value
  , afrContract :: !(Maybe Text)
  , afrPayloadKind :: !Text
  , afrMediaType :: !Text
  }
  deriving stock (Eq, Show)

{- | Persist one artifact emission: content upsert plus provenance upsert in the
caller's transaction. Idempotent on the content address and on the
@(run, node, artifact_hash)@ provenance key, so replaying a 'SafeToReplay'
artifact stage cannot duplicate rows.
-}
putArtifact :: ArtifactPut -> Transaction ()
putArtifact put = do
  Tx.statement
    (put.apHash, put.apPayload, put.apContract, put.apPayloadKind, put.apMediaType, put.apByteSize)
    ( Statement
        "INSERT INTO pulse.artifacts \
        \(artifact_hash, payload, contract, payload_kind, media_type, byte_size) \
        \VALUES ($1, $2, $3, $4, $5, $6) \
        \ON CONFLICT (artifact_hash) DO NOTHING"
        ( Enc.encode6
            ((\(a, _, _, _, _, _) -> a), Enc.nonNullable Enc.text)
            ((\(_, b, _, _, _, _) -> b), Enc.nonNullable Enc.jsonb)
            ((\(_, _, c, _, _, _) -> c), Enc.nullable Enc.text)
            ((\(_, _, _, d, _, _) -> d), Enc.nonNullable Enc.text)
            ((\(_, _, _, _, e, _) -> e), Enc.nonNullable Enc.text)
            ((\(_, _, _, _, _, f) -> f), Enc.nonNullable Enc.int8)
        )
        D.noResult
        False
    )
  Tx.statement
    (put.apHash, put.apRunId, put.apNodeId, put.apKind, put.apTarget)
    ( Statement
        "INSERT INTO pulse.artifact_provenance \
        \(artifact_hash, run_id, node_id, kind, target) \
        \VALUES ($1, $2, $3, $4, $5) \
        \ON CONFLICT (run_id, node_id, artifact_hash) DO NOTHING"
        ( Enc.encode5
            ((\(a, _, _, _, _) -> a), Enc.nonNullable Enc.text)
            ((\(_, b, _, _, _) -> b), Enc.nonNullable Enc.uuid)
            ((\(_, _, c, _, _) -> c), Enc.nonNullable Enc.text)
            ((\(_, _, _, d, _) -> d), Enc.nonNullable Enc.text)
            ((\(_, _, _, _, e) -> e), Enc.nullable Enc.text)
        )
        D.noResult
        False
    )

-- | Read a content row by its address.
getArtifact :: Text -> Transaction (Maybe ArtifactRecord)
getArtifact hash =
  Tx.statement hash $
    Statement
      "SELECT artifact_hash, payload, contract, payload_kind, media_type, byte_size, created_at \
      \FROM pulse.artifacts \
      \WHERE artifact_hash = $1"
      (Enc.encode1 (id, Enc.nonNullable Enc.text))
      ( D.rowMaybe $
          ArtifactRecord
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.jsonb)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.timestamptz)
      )
      False

-- | List a run's emitted artifacts: provenance rows joined to their content.
listArtifactsForRun :: UUID -> Transaction [ArtifactForRun]
listArtifactsForRun runId =
  Tx.statement runId $
    Statement
      "SELECT p.artifact_hash, p.node_id, p.kind, p.target, \
      \a.payload, a.contract, a.payload_kind, a.media_type \
      \FROM pulse.artifact_provenance p \
      \INNER JOIN pulse.artifacts a ON a.artifact_hash = p.artifact_hash \
      \WHERE p.run_id = $1 \
      \ORDER BY p.provenance_id ASC"
      (Enc.encode1 (id, Enc.nonNullable Enc.uuid))
      ( D.rowList $
          ArtifactForRun
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nonNullable D.jsonb)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
      )
      False
