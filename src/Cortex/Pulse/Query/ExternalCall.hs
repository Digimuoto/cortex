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
  , externalCallStatusIsTerminal
  , externalCallSignalSuffix
  , ExternalCallAttempt (..)
  , reserveExternalCallAttempt
  , persistExternalCallHandle
  , settleExternalCallAttempt
  , failExternalCallAttempt
  , loadExternalCallAttempt
  , listSubmittedExternalCallAttempts
  )
where

import Crypto.Hash (SHA256, hashlazy)
import Data.Aeson qualified as Aeson
import Data.Int (Int32)
import Data.Text (Text)
import Data.Text qualified as T
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

{- | Whether a stored attempt status is terminal (a settled success or a typed
failure). Routed through the typed 'ExternalCallAttemptStatus' so adding a new status
forces a classification here, rather than a raw @elem ["settled", "failed"]@ string
check that would silently treat a new status as non-terminal.
-}
externalCallStatusIsTerminal :: Text -> Bool
externalCallStatusIsTerminal status =
  case parseExternalCallStatus status of
    Just AttemptSettled -> True
    Just AttemptFailed -> True
    Just AttemptReserved -> False
    Just AttemptSubmitted -> False
    Nothing -> False

{- | The opaque suffix for the reserved @external-call:@ wake of this attempt
(combine with 'Cortex.Pulse.Signal.externalCallSignalName'). A SHA-256 digest of
the non-run key components @(node, runtime binding, frontier)@: the run is already
scoped by delivery, and the wait row's pending-uniqueness is @(run_id, signal_name)@,
so the digest only needs to resolve exactly one parked attempt within the run. It is
deterministic, so the runtime re-derives the same name across replays.
-}
externalCallSignalSuffix :: ExternalCallAttemptKey -> Text
externalCallSignalSuffix key =
  T.pack
    ( show
        ( hashlazy @SHA256
            (Aeson.encode (ecaNodeId key, ecaRuntimeBindingId key, ecaFrontierId key))
        )
    )

data ExternalCallAttempt = ExternalCallAttempt
  { ecaKey :: !ExternalCallAttemptKey
  , ecaIdempotencyKey :: !Text
  , ecaFrozenPlan :: !Aeson.Value
  , ecaJobHandle :: !(Maybe Aeson.Value)
  , ecaSignalName :: !(Maybe Text)
  , ecaStatus :: !Text
  , ecaFailureReason :: !(Maybe Text)
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

{- | Mark the attempt failed and persist the typed reason. The reason is read back
on resume so a crash between this write and the node-failure graph write reproduces
the same typed failure rather than losing it (ADR 0059 failure durability).

Terminal states are immutable: the @status NOT IN ('settled', 'failed')@ guard stops
a late or duplicate resume fetch from downgrading an already-'settled' success to
'failed', so a misbehaving or transiently-unavailable provider cannot corrupt the
durable record.
-}
failExternalCallAttempt :: ExternalCallAttemptKey -> Text -> UTCTime -> Transaction ()
failExternalCallAttempt key reason now =
  Tx.statement
    (reason, now, key.ecaRunId, key.ecaNodeId, key.ecaRuntimeBindingId, key.ecaFrontierId)
    $ Statement
      "UPDATE pulse.external_call_attempts \
      \SET status = 'failed', failure_reason = $1, settled_at = $2 \
      \WHERE run_id = $3 AND node_id = $4 AND runtime_binding_id = $5 AND frontier_id = $6 \
      \  AND status NOT IN ('settled', 'failed')"
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

{- | Set a non-terminal attempt's status. Terminal states ('settled'/'failed') are
immutable, so the @status NOT IN ('settled', 'failed')@ guard makes a re-settle a
no-op and blocks a settled<->failed flip on a crash-recovery re-fetch (ADR 0059).
-}
updateStatus :: Text -> ExternalCallAttemptKey -> UTCTime -> Transaction ()
updateStatus status key now =
  Tx.statement
    (status, now, key.ecaRunId, key.ecaNodeId, key.ecaRuntimeBindingId, key.ecaFrontierId)
    $ Statement
      "UPDATE pulse.external_call_attempts \
      \SET status = $1, settled_at = $2 \
      \WHERE run_id = $3 AND node_id = $4 AND runtime_binding_id = $5 AND frontier_id = $6 \
      \  AND status NOT IN ('settled', 'failed')"
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
      "SELECT idempotency_key, frozen_plan, job_handle, signal_name, status, failure_reason \
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
        <*> D.column (D.nullable D.text)

{- | A bounded batch of external-call attempts currently @submitted@ (a provider job
is in flight) whose run is still live (pending/running/waiting), oldest first. For a
DB-wide provider-completion watcher that has no single run to scope by: it polls for
terminal provider jobs and delivers the trusted external-call wake
('Cortex.Pulse.Query.deliverExternalCallSignal').

@batchLimit@ bounds the rows returned per poll so the watcher's working set does not
grow with the backlog. The run-liveness filter drops a terminal run's orphaned
@submitted@ attempt: a terminal run can never be woken back to pending, so polling it
forever would be wasted work and the row would never leave the result set.
-}
listSubmittedExternalCallAttempts :: Int32 -> Transaction [ExternalCallAttempt]
listSubmittedExternalCallAttempts batchLimit =
  Tx.statement batchLimit $
    Statement
      "SELECT a.run_id, a.node_id, a.runtime_binding_id, a.frontier_id, \
      \       a.idempotency_key, a.frozen_plan, a.job_handle, a.signal_name, a.status, a.failure_reason \
      \FROM pulse.external_call_attempts a \
      \JOIN pulse.runs r ON r.run_id = a.run_id \
      \WHERE a.status = 'submitted' \
      \  AND r.status IN ('pending'::pulse.run_status, 'running'::pulse.run_status, 'waiting'::pulse.run_status) \
      \ORDER BY a.attempt_id \
      \LIMIT $1"
      (Enc.encode1 (Prelude.id, Enc.nonNullable Enc.int4))
      (D.rowList listRow)
      True
  where
    listRow =
      ExternalCallAttempt
        <$> keyRow
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.jsonb)
        <*> D.column (D.nullable D.jsonb)
        <*> D.column (D.nullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nullable D.text)
    keyRow =
      ExternalCallAttemptKey
        <$> D.column (D.nonNullable D.uuid)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
        <*> D.column (D.nonNullable D.text)
