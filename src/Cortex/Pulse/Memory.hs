{- | Umbrella module for the graph-native topological memory (DIG-529).

Re-exports the pure sub-modules and provides IO helpers for use
inside the Pulse executor.

See @paper-drafts2/topological-memory-as-query.md@ for the design
thesis: /memory is a query, not a store/.  A stage's memory view is
a deterministic graph query over a 'PersistedGraphState' snapshot
captured at stage entry, scored by a composite of graph distance,
temporal distance, and a pluggable semantic score.

__Past / present / future.__  A wire run has three graphs:

 * __Past__ — settled nodes with materialised outputs.  This is
   memory: searchable, stable, the only thing this module exposes
   for domain queries.
 * __Present__ — the current frontier plus nodes still running or
   waiting on signals.  Live orchestration state; deliberately
   excluded from memory so there is no bleed between siblings in
   the same frontier.
 * __Future__ — not-yet-materialised descendants and latent
   rewrites.  Absent from memory by construction.

Stage-entry binding is how the past/present split is enforced at
runtime: the handle wraps one snapshot taken when the stage
attempt begins, so reads made later in the stage never observe a
sibling that settled in the meantime.
-}
module Cortex.Pulse.Memory
  ( -- * Pure types (re-exports)
    module Cortex.Pulse.Memory.Types

    -- * Pure query engine (re-exports)
  , pureQueryMemory

    -- * Handle + snapshot construction
  , newMemoryHandle
  , discardMemoryHandle
  , captureMemorySnapshot

    -- * Snapshot helpers
  , snapshotFromStateAndTimes
  )
where

import Control.Concurrent.STM (TVar, atomically, readTVar)
import Data.Map.Strict (Map)
import Data.Time (UTCTime, getCurrentTime)

import Cortex.Algebra.Graph (Relation)
import Cortex.Pulse.Materialize (PersistedGraphState (..))
import Cortex.Pulse.Memory.Query (pureQueryMemory)
import Cortex.Pulse.Memory.Types
import Cortex.Pulse.Node (NodeId)
import Cortex.Pulse.Runtime (GraphState (..))

-- ============================================================================
-- Snapshot capture
-- ============================================================================

{- | Capture a fresh 'MemorySnapshot' from the executor's TVars.

Reads all three TVars in a single STM transaction so a concurrent
rewrite admission (which writes 'tvPersistedState' and
'tvTopology' atomically) cannot interleave with the read and
produce a mixed graph/topology view.  Wall-clock is captured
outside STM via 'getCurrentTime' (it is IO-only); that only
affects the temporal score axis, not the determinism of the
graph/status/output triple.
-}
captureMemorySnapshot
  :: TVar PersistedGraphState
  -> TVar (Map NodeId UTCTime)
  -> TVar (Relation NodeId)
  -> IO MemorySnapshot
captureMemorySnapshot tvPersistedState tvNodeCompletedAt tvTopology = do
  now <- getCurrentTime
  (persistedState, completedAt, topology) <-
    atomically $
      (,,)
        <$> readTVar tvPersistedState
        <*> readTVar tvNodeCompletedAt
        <*> readTVar tvTopology
  pure (mkSnapshot now topology persistedState completedAt)

-- ============================================================================
-- Handle constructors
-- ============================================================================

{- | Wrap a 'MemorySnapshot' as a 'MemoryHandle'.

__Stage-entry binding.__  The handle is bound to the snapshot it
was constructed with.  'memorySnapshot' returns the same bound
value on every call; 'queryMemory' runs 'pureQueryMemory' against
it.  A stage that does many reads therefore observes a stable
view — no frontier-sibling settling partway through a stage can
change what memory reports.

The executor constructs a fresh handle per stage attempt from
'captureMemorySnapshot'.  See 'StageEnv.seMemoryFactory'.
-}
newMemoryHandle :: MemorySnapshot -> MemoryHandle
newMemoryHandle snap =
  MemoryHandle
    { memorySnapshot = pure snap
    , queryMemory = \origin walkSpec query ->
        pure (pureQueryMemory origin snap walkSpec query)
    }

{- | Constant no-op handle: 'queryMemory' always returns @[]@;
'memorySnapshot' returns an empty snapshot captured at call time.
Safe to place in record literals built outside IO.

Only use this when the stage under test does not touch memory.
Tests that need to observe reads should use 'newMemoryHandle' with
a non-empty snapshot.
-}
discardMemoryHandle :: MemoryHandle
discardMemoryHandle =
  MemoryHandle
    { memorySnapshot = do
        now <- getCurrentTime
        pure (emptyMemorySnapshot now mempty)
    , queryMemory = \_ _ _ -> pure []
    }

-- ============================================================================
-- Snapshot construction
-- ============================================================================

{- | Build a 'MemorySnapshot' from the executor's state.  Pure given
the inputs; the capture time is supplied by the caller.
-}
snapshotFromStateAndTimes
  :: UTCTime
  -> Relation NodeId
  -> PersistedGraphState
  -> Map NodeId UTCTime
  -> MemorySnapshot
snapshotFromStateAndTimes = mkSnapshot

mkSnapshot
  :: UTCTime
  -> Relation NodeId
  -> PersistedGraphState
  -> Map NodeId UTCTime
  -> MemorySnapshot
mkSnapshot now topology persistedState completedAt =
  MemorySnapshot
    { msTopology = topology
    , msNodeStatuses = persistedState.pgsGraphState.gsNodeStatuses
    , msNodeOutputs = persistedState.pgsGraphState.gsNodeOutputs
    , msNodeCompletedAt = completedAt
    , msCapturedAt = now
    }
