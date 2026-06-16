-- Test-only support schema (NOT part of the Pulse substrate).
--
-- The Pulse executor/scheduler tests scope some runs to a user and use
-- `insertTestUser`, which writes to a `users` table owned downstream. Cortex
-- does not own `users`; this minimal stand-in lets the user-scoped tests run
-- against the cortex-owned Pulse fixture without pulling in downstream schema.
-- pulse.runs.user_id is intentionally FK-free in the fixture, so this table is
-- only needed by tests that insert users directly.

CREATE TABLE IF NOT EXISTS users (
    user_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username      TEXT NOT NULL,
    email         TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
