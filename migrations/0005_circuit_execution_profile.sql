-- Cortex Pulse forward migration 0005: compiled-circuit execution profiles
-- and hosted engine checkpoint sequencing.
--
-- Existing non-compiled and pre-profile runs remain all-NULL. A compiled run
-- freezes either the graph-runtime profile or the hosted x86_64 Linux profile;
-- the consistency constraint prevents half-written identity records. Hosted
-- snapshots continue to use graph_state.node_statuses/node_outputs as the sole
-- recovery state and add only the acknowledged engine checkpoint sequence.
--
-- Idempotent and safe to re-run. Existing rows need no backfill.

ALTER TABLE pulse.runs
    ADD COLUMN IF NOT EXISTS execution_backend text,
    ADD COLUMN IF NOT EXISTS program_identity text,
    ADD COLUMN IF NOT EXISTS artifact_digest text,
    ADD COLUMN IF NOT EXISTS protocol_version text;

ALTER TABLE pulse.graph_state
    ADD COLUMN IF NOT EXISTS hosted_checkpoint_sequence bigint;

DO $$
BEGIN
  ALTER TABLE ONLY pulse.runs
    ADD CONSTRAINT pulse_runs_execution_profile_consistent CHECK (
      (
        execution_backend IS NULL
        AND program_identity IS NULL
        AND artifact_digest IS NULL
        AND protocol_version IS NULL
      )
      OR (
        execution_backend = 'pulse_graph_runtime_v1'
        AND program_identity IS NOT NULL
        AND artifact_digest IS NULL
        AND protocol_version IS NULL
      )
      OR (
        execution_backend = 'hosted_x86_64_linux_v1'
        AND program_identity IS NOT NULL
        AND artifact_digest ~ '^[0-9a-f]{64}$'
        AND protocol_version IS NOT NULL
        AND protocol_version <> ''
      )
    );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
  ALTER TABLE ONLY pulse.graph_state
    ADD CONSTRAINT pulse_graph_state_hosted_checkpoint_positive CHECK (
      hosted_checkpoint_sequence IS NULL OR hosted_checkpoint_sequence > 0
    );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END
$$;
