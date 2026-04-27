# Pulse Runtime Correspondence

Use this reference when attacking `Cortex.Pulse.*` Lean modules. The goal
is not to model every Haskell payload, but to preserve the structural
safety obligations that the runtime relies on.

## Topology

Pulse graph topology obligations:

- `nodes` is the finite set of materialized runtime nodes.
- `edge a b = true` means `a` is a direct dependency of `b`.
- Direct-edge endpoints must be in `nodes`.
- Strict reachability should be edge-derived unless the model includes
  exactness laws tying it to edges.
- Derived reachability endpoints must remain in `nodes`.
- Acyclicity must apply to the same reachability relation used by
  readiness, frontier, and failure closure.

Attack pattern: a singleton graph with no edges and a spurious
reachability witness should not affect readiness or failure closure.

## Status And Output Ownership

Review every `NodeStatus` constructor against these questions:

- Can the runtime write an output for this status?
- Can downstream readiness consume an output from this status?
- Does recovery preserve, clear, or rewrite this status?
- Is the status terminal, propagatable, both, or neither?

The abstract model may erase payload contents, but it must not erase
payload ownership. If a status does not own a durable payload, a validity
predicate should reject `some payload` for that status.

For the current Pulse kernel, completed and rewritten statuses may own
outputs. Failed, skipped, pending, running, interrupted, and waiting
statuses should not own outputs unless a later runtime design explicitly
changes the contract and updates this reference.

## Recovered-State Validity

A recovered-state validity predicate should cover:

- No volatile `running` nodes after normalization.
- Outputs respect status ownership.
- Off-topology state is absent or normalized.
- Failure closure is complete for the topology relation.
- Ready frontier is exact for the readiness predicate.
- Any runtime-specific persisted-state corruption that the theorem
  claims to rule out.

If `GraphState` is modeled as total functions over `ν`, validity must
either range over the node subtype or include an explicit off-topology
domain predicate.

## Frontier And Readiness

Readiness/frontier obligations:

- A ready node is in `G.nodes`.
- A ready node is pending or otherwise eligible according to the runtime
  lifecycle.
- All direct dependencies that matter to readiness are topology edges.
- Skipped or failed predecessors do not contribute stale successful
  outputs.
- `readyNodes` is exact for `Ready`, not merely sound or complete in one
  direction.

## Failure Closure

Failure propagation obligations:

- Closure follows topology reachability, not an arbitrary ambient
  relation.
- Propagation does not invent failures from off-domain nodes.
- Terminal statuses that should not be overwritten remain protected.
- The closure theorem proves the named closure property rather than
  assuming it through a broad predicate.

## Recovery Normalization

Recovery obligations:

- Volatile execution marks are reset.
- Durable outputs are preserved only when their status owns them.
- Domain exactness is preserved.
- Recovery theorems establish the recovered-state validity predicate or
  explicitly state any required persistence assumptions.

## Common Pulse P1s

- Arbitrary `reaches` accepted as a DAG field without edge exactness.
- Validity accepts outputs on failed or skipped nodes.
- Well-formed recovered state omits off-topology status/output checks.
- Readiness or failure closure quantifies over ambient nodes without
  domain protection.
- A theorem claims persisted-state safety but assumes a corruption-free
  state as input.
