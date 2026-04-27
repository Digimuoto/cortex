# Cortex Agent Archetypes

Shared archetype profiles live here so skills can compose the same
reasoning modes without copying prompt text. These profiles are
provider-neutral: they define stance, review questions, output shape,
and failure modes. They do not grant tool authority, bypass repository
policy, or replace a skill's workflow.

Skills should load archetypes by repo-root path, for example:

```markdown
Load `agents/archetypes/kritikos.md` for the adversarial pass.
Load `agents/archetypes/themis.md` for the contract-audit pass.
```

Use archetypes as lenses:

- `logos.md` makes reasoning explicit as structured claims.
- `sophia.md` synthesizes and judges what matters.
- `techne.md` turns conclusions into working artifacts.
- `episteme.md` grounds claims in evidence.
- `kritikos.md` attacks assumptions and finds failure modes.
- `themis.md` audits constraints, contracts, and invariants.
- `poiesis.md` generates alternative framings and encodings.

When a skill uses multiple archetypes, the skill remains the
orchestrator. It decides scope, validation commands, file ownership, and
final priority ordering.
