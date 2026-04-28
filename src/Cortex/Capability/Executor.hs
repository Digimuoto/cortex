-- | Authority-bearing executor registration boundary.
--
-- The concrete 'ExecutorSpec' and registration API is intentionally deferred to
-- a later executor-design ADR. This module marks the canonical Capability home
-- for host bindings that admit tools, providers, codecs, and runnable
-- interpreters.
module Cortex.Capability.Executor () where
