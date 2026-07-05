-- Cortex Pulse forward migration 0004: content-addressed run artifacts
--
-- Adds the ADR 0089 artifact store: pulse.artifacts holds immutable content
-- rows keyed by "sha256:<64 hex>" over the canonical UTF-8 encoding of the
-- typed envelope {contract, mediaType, payloadKind, value}; every column is a
-- pure function of the address, so writers upsert with ON CONFLICT DO NOTHING
-- and the same content is stored once across runs. pulse.artifact_provenance
-- links a content row to the run/node that emitted it, with the opaque
-- ADR 0071 kind and target recorded per emission. Provenance cascades with its
-- run; content rows are never deleted by Cortex (unreferenced rows are GC-able
-- by an operator anti-join, retention policy stays downstream).
--
-- Idempotent and safe to re-run. New tables, so no backfill is needed.
--
-- NOTE: this repository has no in-repo migration runner; the `pulse` schema is
-- applied out of band (data/pulse-schema.sql is the curated full-schema dump a
-- fresh database is provisioned from). Apply this file to deployed databases
-- through the same deployment / schema pipeline that provisions the pulse
-- schema, before rolling out the code that writes or reads artifacts.

CREATE TABLE IF NOT EXISTS pulse.artifacts (
    artifact_hash text PRIMARY KEY,
    payload jsonb NOT NULL,
    contract text,
    payload_kind text NOT NULL,
    media_type text NOT NULL,
    byte_size bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS pulse.artifact_provenance (
    provenance_id bigserial PRIMARY KEY,
    artifact_hash text NOT NULL,
    run_id uuid NOT NULL,
    node_id text NOT NULL,
    kind text NOT NULL,
    target text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_pulse_artifact_provenance_key
    ON pulse.artifact_provenance USING btree (run_id, node_id, artifact_hash);

DO $$
BEGIN
  ALTER TABLE ONLY pulse.artifact_provenance
    ADD CONSTRAINT artifact_provenance_artifact_hash_fkey
    FOREIGN KEY (artifact_hash) REFERENCES pulse.artifacts(artifact_hash);
EXCEPTION
  WHEN duplicate_object THEN NULL;
END
$$;

DO $$
BEGIN
  ALTER TABLE ONLY pulse.artifact_provenance
    ADD CONSTRAINT artifact_provenance_run_id_fkey
    FOREIGN KEY (run_id) REFERENCES pulse.runs(run_id) ON DELETE CASCADE;
EXCEPTION
  WHEN duplicate_object THEN NULL;
END
$$;
