{- |
Module      : Cortex.Pulse.Query.ExternalCall
Description : Durable external-call attempt record CRUD (ADR 0059 §3).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The external-call attempt record is the Pulse-owned durable home for a
@submit_park_resume@ external call's @{idempotency key, frozen fused plan, job
handle, completion signal}@, keyed by @(run, node, runtime binding, frontier)@
(ADR 0059 §3). ADR 0058 settlement commits only graph state, signal wait rows, and
run status, so executor metadata lives here, not on the signal rows.

The crash-safe protocol is: reserve (before provider submit), persist the handle
(after submit, before suspend), then settle on completion. Reserve is idempotent on
the key so recovery re-entry never creates a duplicate provider task. Provider
fields are opaque JSON; Pulse does not interpret the backend.
-}
module Cortex.Pulse.Query.ExternalCall
  ( ExternalCallAttemptKey (..)
  , ExternalCallAttemptStatus (..)
  , externalCallStatusText
  , parseExternalCallStatus
  , ExternalCallAttempt (..)
  , reserveExternalCallAttempt
  , persistExternalCallHandle
  , settleExternalCallAttempt
  , failExternalCallAttempt
  , loadExternalCallAttempt
  )
where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Hasql.Decoders qualified as D
import Hasql.Statement (Statement (..))
import Hasql.Transaction (Transaction)
import Hasql.Transaction qualified as Tx

import Platform.Database.Encode qualified as Enc

{- | Identity of an external-call attempt: the realize stage's node within a run,
the runtime binding that owns it, and the canonical frontier hash.
-}
data ExternalCallAttemptKey = ExternalCallAttemptKey
  { ecaRunId :: !UUID
  , ecaNodeId :: !Text
  , ecaRuntimeBindingId :: !Text
  , ecaFrontierId :: !Text
  }
  deriving stock (Eq, Show)

data ExternalCallAttemptStatus
  = AttemptReserved
  | AttemptSubmitted
  | AttemptSettled
  | AttemptFailed
  deriving stock (Eq, Show)

externalCallStatusText :: ExternalCallAttemptStatus -> Text
externalCallStatusText = \case
  AttemptReserved -> "reserved"
  AttemptSubmitted -> "submitted"
  AttemptSettled -> "settled"
  AttemptFailed -> "failed"

parseExternalCallStatus :: Text -> Maybe ExternalCallAttemptStatus
parseExternalCallStatus = \case
  "reserved" -> Just AttemptReserved
  "submitted" -> Just AttemptSubmitted
  "settled" -> Just AttemptSettled
  "failed" -> Just AttemptFailed
  _ -> Nothing

data ExternalCallAttempt = ExternalCallAttempt
  { ecaKey :: !ExternalCallAttemptKey
  , ecaIdempotencyKey :: !Text
  , ecaFrozenPlan :: !Aeson.Value
  , ecaJobHandle :: !(Maybe Aeson.Value)
  , ecaSignalName :: !(Maybe Text)
  , ecaStatus :: !Text
  }
  deriving stock (Eq, Show)

{- | Reserve the attempt before provider submission. Idempotent on the key: a
recovery re-entry with the same key is a no-op (@ON CONFLICT DO NOTHING@), so the
frozen plan and idempotency key written on first reservation are authoritative.
-}
reserveExternalCallAttempt
  :: ExternalCallAttemptKey -> Text -> Aeson.Value -> UTCTime -> Transaction ()
reserveExternalCallAttempt key idempotencyKey frozenPlan now =
  Tx.statement
    ( key.ecaRunId
    , key.ecaNodeId
    , key.ecaRuntimeBindingId
    , key.ecaFrontierId
    , idempotencyKey
    , frozenPlan
    , now
    )
    $ Statement
      "INSERT INTO pulse.external_call_attempts \
      \(run_id, node_id, runtime_binding_id, frontier_id, idempotency_key, frozen_plan, status, created_at) \
      \VALUES ($1, $2, $3, $4, $5, $6, 'reserved', $7) \
      \ON CONFLICT (run_id, node_id, runtime_binding_id, frontier_id) DO NOTHING"
      ( Enc.encode7
          ((\(a, _, _, _, _, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _, _, _, _, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c, _, _, _, _) -> c), Enc.nonNullable Enc.text)
          ((\(_, _, _, d, _, _, _) -> d), Enc.nonNullable Enc.text)
          ((\(_, _, _, _, e, _, _) -> e), Enc.nonNullable Enc.text)
          ((\(_, _, _, _, _, f, _) -> f), Enc.nonNullable Enc.jsonb)
          ((\(_, _, _, _, _, _, g) -> g), Enc.nonNullable Enc.timestamptz)
      )
      D.noResult
      False

{- | Persist the provider job handle and completion signal name, marking the attempt
submitted. Called after provider submit, before the stage returns @StageSuspend@.
-}
persistExternalCallHandle
  :: ExternalCallAttemptKey -> Aeson.Value -> Text -> UTCTime -> Transaction ()
persistExternalCallHandle key jobHandle signalName now =
  Tx.statement
    ( jobHandle
    , signalName
    , now
    , key.ecaRunId
    , key.ecaNodeId
    , key.ecaRuntimeBindingId
    , key.ecaFrontierId
    )
    $ Statement
      "UPDATE pulse.external_call_attempts \
      \SET job_handle = $1, signal_name = $2, status = 'submitted', submitted_at = $3 \
      \WHERE run_id = $4 AND node_id = $5 AND runtime_binding_id = $6 AND frontier_id = $7"
      ( Enc.encode7
          ((\(a, _, _, _, _, _, _) -> a), Enc.nonNullable Enc.jsonb)
          ((\(_, b, _, _, _, _, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c, _, _, _, _) -> c), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, _, d, _, _, _) -> d), Enc.nonNullable Enc.uuid)
          ((\(_, _, _, _, e, _, _) -> e), Enc.nonNullable Enc.text)
          ((\(_, _, _, _, _, f, _) -> f), Enc.nonNullable Enc.text)
          ((\(_, _, _, _, _, _, g) -> g), Enc.nonNullable Enc.text)
      )
      D.noResult
      False

settleExternalCallAttempt :: ExternalCallAttemptKey -> UTCTime -> Transaction ()
settleExternalCallAttempt = updateStatus "settled"

failExternalCallAttempt :: ExternalCallAttemptKey -> UTCTime -> Transaction ()
failExternalCallAttempt = updateStatus "failed"

updateStatus :: Text -> ExternalCallAttemptKey -> UTCTime -> Transaction ()
updateStatus status key now =
  Tx.statement
    (status, now, key.ecaRunId, key.ecaNodeId, key.ecaRuntimeBindingId, key.ecaFrontierId)
    $ Statement
      "UPDATE pulse.external_call_attempts \
      \SET status = $1, settled_at = $2 \
      \WHERE run_id = $3 AND node_id = $4 AND runtime_binding_id = $5 AND frontier_id = $6"
      ( Enc.encode6
          ((\(a, _, _, _, _, _) -> a), Enc.nonNullable Enc.text)
          ((\(_, b, _, _, _, _) -> b), Enc.nonNullable Enc.timestamptz)
          ((\(_, _, c, _, _, _) -> c), Enc.nonNullable Enc.uuid)
          ((\(_, _, _, d, _, _) -> d), Enc.nonNullable Enc.text)
          ((\(_, _, _, _, e, _) -> e), Enc.nonNullable Enc.text)
          ((\(_, _, _, _, _, f) -> f), Enc.nonNullable Enc.text)
      )
      D.noResult
      False

loadExternalCallAttempt :: ExternalCallAttemptKey -> Transaction (Maybe ExternalCallAttempt)
loadExternalCallAttempt key =
  Tx.statement
    (key.ecaRunId, key.ecaNodeId, key.ecaRuntimeBindingId, key.ecaFrontierId)
    $ Statement
      "SELECT idempotency_key, frozen_plan, job_handle, signal_name, status \
      \FROM pulse.external_call_attempts \
      \WHERE run_id = $1 AND node_id = $2 AND runtime_binding_id = $3 AND frontier_id = $4"
      ( Enc.encode4
          ((\(a, _, _, _) -> a), Enc.nonNullable Enc.uuid)
          ((\(_, b, _, _) -> b), Enc.nonNullable Enc.text)
          ((\(_, _, c, _) -> c), Enc.nonNullable Enc.text)
          ((\(_, _, _, d) -> d), Enc.nonNullable Enc.text)
      )
      (D.rowMaybe row)
      False
  where
    row =
      ExternalCallAttempt key
        <$> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.jsonb)
        <*> D.column (D.nullable D.jsonb)
        <*> D.column (D.nullable D.text)
        <*> D.column (D.nonNullable D.text)
