# Countermodel Patterns

Use these patterns to search for small formal models that satisfy the
current hypotheses while violating the intended claim.

## Minimal Topologies

- Empty node set with arbitrary off-domain state.
- Singleton node set with no edges.
- Two nodes with no edge but a spurious reachability relation.
- Edge endpoint outside the finite node set.
- Disconnected component that nevertheless influences readiness or
  closure.
- Cycle hidden in a derived relation but absent from direct edges.

## State Corruption

- Status exists for a node outside the topology.
- Output exists for a node outside the topology.
- A failed, skipped, pending, running, interrupted, or waiting node has
  a stale output.
- A terminal status and output disagree about ownership.
- Recovery leaves volatile state because normalization only changes one
  field.
- A validity predicate accepts a state the runtime cannot write but a
  corrupted persistence layer could load.

## Relation And Closure Gaps

- A reachability relation is transitive and irreflexive but not the
  transitive closure of edges.
- A closure predicate includes non-topology predecessors.
- A frontier predicate blocks a node because of an off-domain
  dependency.
- A failure propagation rule can fail a node because of a non-edge
  relation witness.
- A theorem proves every ready node is in the frontier but not every
  frontier node is ready, or vice versa.

## Quantifier Traps

- The theorem quantifies over all ambient nodes but only some are in the
  graph.
- A hypothesis is too far right of the colon to be reusable as an
  explicit assumption.
- An existential witness is unconstrained and can be chosen off-domain.
- A universal predicate over total functions hides the need for map
  key-domain checks.

## Encoding Mismatches

- Runtime maps are modeled as total functions without an absence
  predicate.
- Runtime constructors enforce an invariant, but Lean uses an arbitrary
  structure field.
- Runtime transition functions are partial or error-returning, but Lean
  models them as total state transforms.
- Runtime never observes a field, but Lean theorems depend on it.
- Runtime stores durable facts, but Lean erases them without preserving
  the corresponding safety obligation.

## Countermodel Report Shape

For each candidate:

```markdown
Countermodel: <short name>
Formal setup: <nodes, edges, statuses, outputs, relations>
Hypotheses satisfied: <why Lean accepts it>
Intended property violated: <runtime/prose claim that fails>
Repair direction: <derive, constrain, subtype, or add validity field>
```
