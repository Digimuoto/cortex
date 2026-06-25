-- Cortex Pulse forward migration 0001: graph_rewrites.admission_mode
--
-- Adds the per-rewrite admission mode (ADR 0055 runtime-bounded iteration /
-- ADR 0056 witnessed-vs-gas admission). 'gassed' rewrites debit the run-global
-- RewriteBudget at admission; 'witnessed' rewrites (a compile-bounded
-- runtime-iteration self-append step) record cost but are gas-neutral, and
-- replay re-validates them rather than trusting the stored tag.
--
-- Idempotent and safe to re-run. Existing rows backfill to 'gassed' (the metered
-- default), so pre-existing rewrites stay on the gas-charged path.
--
-- NOTE: this repository has no in-repo migration runner; the `pulse` schema is
-- applied out of band (the test fixture test/sql/pulse-schema.sql is a generated
-- dump). Apply this file to deployed databases through the same deployment /
-- schema pipeline that provisions the pulse schema, before rolling out the code
-- that writes or reads admission_mode.

ALTER TABLE pulse.graph_rewrites
  ADD COLUMN IF NOT EXISTS admission_mode text DEFAULT 'gassed';

UPDATE pulse.graph_rewrites
  SET admission_mode = 'gassed'
  WHERE admission_mode IS NULL;

ALTER TABLE pulse.graph_rewrites
  ALTER COLUMN admission_mode SET DEFAULT 'gassed';

ALTER TABLE pulse.graph_rewrites
  ALTER COLUMN admission_mode SET NOT NULL;

DO $$
BEGIN
  ALTER TABLE pulse.graph_rewrites
    ADD CONSTRAINT graph_rewrites_admission_mode_check
    CHECK (admission_mode = ANY (ARRAY['gassed'::text, 'witnessed'::text]));
EXCEPTION
  WHEN duplicate_object THEN NULL;
END
$$;
