-- Cortex Pulse forward migration 0006: preserve the durable hosted engine
-- terminal decision alongside the acknowledged checkpoint sequence.
--
-- The graph-state maps remain the authoritative recovery state. This scalar
-- prevents a crash after a terminal checkpoint and before run-row settlement
-- from reinterpreting a cancelled or failed engine snapshot as active.

ALTER TABLE pulse.graph_state
    ADD COLUMN IF NOT EXISTS hosted_terminal_state text;

DO $$
BEGIN
  ALTER TABLE ONLY pulse.graph_state
    ADD CONSTRAINT pulse_graph_state_hosted_terminal_state_valid CHECK (
      hosted_terminal_state IS NULL
      OR hosted_terminal_state IN ('active', 'completed', 'failed', 'cancelled')
    );
EXCEPTION
  WHEN duplicate_object THEN NULL;
END
$$;
