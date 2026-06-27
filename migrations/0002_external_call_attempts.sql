-- Cortex Pulse forward migration 0002: external_call_attempts (ADR 0059 §3)
--
-- The Pulse-owned durable home for a submit/park/resume external call's executor
-- metadata: {idempotency key, frozen fused plan, provider job handle, reserved
-- external-call: wake signal name, typed failure reason}, keyed by
-- (run id, node id, runtime binding id, frontier id). ADR 0058 suspend settlement
-- commits only graph state, signal wait rows, and run status, so this record --
-- not the signal rows -- anchors crash-safe idempotency. Reserve is idempotent on
-- the unique key, so recovery re-entry never creates a duplicate provider task.
--
-- This migration is idempotent and safe to re-run. The table predates the in-repo
-- migration ledger (it shipped in the generated test dump), so a deployed database
-- may already have it without the run_id foreign key or the failure_reason column;
-- the ALTER guards below bring such a database to the current shape.
--
-- NOTE: this repository has no in-repo migration runner; the `pulse` schema is
-- applied out of band (the test fixture test/sql/pulse-schema.sql is a generated
-- dump). Apply this file to deployed databases through the same deployment /
-- schema pipeline that provisions the pulse schema, before rolling out the code
-- that writes or reads pulse.external_call_attempts.

CREATE TABLE IF NOT EXISTS pulse.external_call_attempts (
    attempt_id bigserial PRIMARY KEY,
    run_id uuid NOT NULL,
    node_id text NOT NULL,
    runtime_binding_id text NOT NULL,
    frontier_id text NOT NULL,
    idempotency_key text NOT NULL,
    frozen_plan jsonb NOT NULL,
    job_handle jsonb,
    signal_name text,
    status text DEFAULT 'reserved'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    submitted_at timestamp with time zone,
    settled_at timestamp with time zone,
    failure_reason text
);

-- Durable typed failure reason (ADR 0059): reproduced on resume so a crash between
-- storeFail and the node-completion graph write never loses the typed reason.
ALTER TABLE pulse.external_call_attempts
  ADD COLUMN IF NOT EXISTS failure_reason text;

-- One attempt per (run, node, runtime binding, frontier): the reserve dedup anchor.
CREATE UNIQUE INDEX IF NOT EXISTS idx_pulse_external_call_attempts_key
    ON pulse.external_call_attempts USING btree (run_id, node_id, runtime_binding_id, frontier_id);

-- Attempt rows are owned by their run; cascade cleanup on run deletion, matching
-- the sibling per-run Pulse tables (graph_state, graph_rewrites).
--
-- A database that had this table without the FK may hold orphan rows whose run was
-- already deleted (no cascade removed them). ADD CONSTRAINT validates existing data
-- and would raise foreign_key_violation on those rows -- which the duplicate_object
-- handler below does NOT catch -- aborting this "idempotent and safe to re-run"
-- migration. Delete the orphans first: they are exactly the rows the cascade would
-- have removed, and the DELETE is a no-op when there are none.
DELETE FROM pulse.external_call_attempts a
  WHERE NOT EXISTS (SELECT 1 FROM pulse.runs r WHERE r.run_id = a.run_id);

DO $$
BEGIN
  ALTER TABLE pulse.external_call_attempts
    ADD CONSTRAINT external_call_attempts_run_id_fkey
    FOREIGN KEY (run_id) REFERENCES pulse.runs(run_id) ON DELETE CASCADE;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END
$$;
