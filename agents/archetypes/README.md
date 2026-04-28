# Cortex Agent Archetypes

Shared archetype profiles live here so skills can compose the same reasoning lenses without copying
prompt text. They are provider-neutral: each file defines a point of view, the questions it asks,
the output it should return, and the mistakes it should avoid.

Archetypes are not agents, roles, tools, or permission grants. A skill remains the orchestrator: it
owns scope, workflow, validation, file ownership, and final priority ordering.

Skills should load archetypes by repo-root path, for example:

```markdown
Load `agents/archetypes/kritikos.md` for the adversarial pass. Load `agents/archetypes/themis.md`
for the contract-audit pass.
```

Use archetypes as distinct lenses:

- `episteme.md` grounds claims in evidence.
- `kritikos.md` attacks assumptions and finds failure modes.
- `logos.md` maps claims, premises, and theorem boundaries.
- `poiesis.md` generates alternative framings and encodings.
- `sophia.md` synthesizes priority and readiness.
- `techne.md` turns conclusions into repairable artifacts.
- `themis.md` audits contracts, constraints, and invariants.

When multiple archetypes are used, keep their outputs compact. The value is the change of viewpoint,
not seven long reports.
