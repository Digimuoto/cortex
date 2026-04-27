# Lean Theorem Attack: {target}

**Overall:** {judgment}
**Mode:** {sequential|multi-agent}
**Files reviewed:** {count}

## Findings

- [P1] {soundness or model gap} - {file}:{line}
- [P2] {contract coverage or runtime correspondence gap} - {file}:{line}

## Archetype Passes

| Pass | Result |
|---|---|
| Logos | {formal claim and theorem boundary} |
| Episteme | {evidence and runtime correspondence} |
| Kritikos | {countermodels and stress cases} |
| Themis | {contract and invariant coverage} |
| Techne | {minimal repair direction} |
| Poiesis | {alternative encodings} |
| Sophia | {priority synthesis and readiness judgment} |

## Coverage Matrix

| Runtime/prose obligation | Lean declaration | Preserved/proved by | Status |
|---|---|---|---|
| {obligation} | `{declaration}` | `{theorem}` | {covered|partial|missing} |

## Countermodels

```markdown
Countermodel: {name}
Formal setup: {nodes, edges, statuses, outputs, relations}
Hypotheses satisfied: {why Lean accepts it}
Intended property violated: {runtime/prose claim that fails}
Repair direction: {derive, constrain, subtype, or add validity field}
```

## Top Priorities

1. {most important fix}
2. {second}
3. {third}

## Validation

- {command}: {result or not run}
