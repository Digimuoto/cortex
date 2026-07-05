-- Cortex Pulse forward migration 0003: widen graph_rewrites.admission_mode
--
-- Adds 'external' to the admission-mode CHECK (ADR 0088 externally-driven step
-- admission). 'external' rows are gas-neutral like 'witnessed' rows, but their
-- bounding resource is a journaled durable-signal delivery per step (ADR 0082)
-- rather than a compile-witnessed finite cap. Replay re-validates external rows
-- through the same step gate as live admission; readers that predate the mode
-- decode unknown values as 'gassed' and fail closed on budget re-debit.
--
-- Idempotent and safe to re-run. Dropping and re-adding the CHECK is safe:
-- every existing value ('gassed', 'witnessed') remains admitted by the new
-- constraint.
--
-- NOTE: this repository has no in-repo migration runner; the `pulse` schema is
-- applied out of band (data/pulse-schema.sql is the curated full-schema dump a
-- fresh database is provisioned from). Apply this file to deployed databases
-- through the same deployment / schema pipeline that provisions the pulse
-- schema, before rolling out the code that writes 'external' rows.

ALTER TABLE pulse.graph_rewrites
  DROP CONSTRAINT IF EXISTS graph_rewrites_admission_mode_check;

DO $$
BEGIN
  ALTER TABLE pulse.graph_rewrites
    ADD CONSTRAINT graph_rewrites_admission_mode_check
    CHECK (admission_mode = ANY (ARRAY['gassed'::text, 'witnessed'::text, 'external'::text]));
EXCEPTION
  WHEN duplicate_object THEN NULL;
END
$$;
