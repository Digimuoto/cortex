# Platform Layer Context

The `src-platform/Platform/` directory is the runtime substrate layer
below `Cortex.*`. It contains reusable infrastructure and low-level
helpers that Cortex and downstream consumers may depend on.

Design intent:

- `Platform.*` is for domain-neutral infrastructure and low-level
  helpers.
- `Platform.*` must not import downstream product modules.
- `Platform.*` should avoid importing `Cortex.*`; if a dependency points
  upward, the boundary is wrong.
- Keep APIs stable and explicit. Do not widen shim or re-export
  surfaces casually.

Current shared scope:

| Module | Purpose |
| --- | --- |
| `Platform.Database` | Hasql pool, sessions, transactions, Rel8TH, encode combinators |
| `Platform.Observability` | Structured logging, tracing, subsystem emitters, WAI middleware |
| `Platform.DurableTask.*` | Cron, scheduling, run types, task pools, workflow skeleton |
| `Platform.Error` | Typed error model (`AppError`), client-safe messages |
| `Platform.Error.Servant` | HTTP status mapping, convenience constructors |
| `Platform.Require` | Handler building blocks (`requireMaybe`, `requireEither`) |
| `Platform.Patch` | Optional field update combinators (`setMaybe`, `setMaybeN`) |
| `Platform.Crypto` | AES-256-GCM credential encryption at rest |
| `Platform.HTTP.Retry` | Exponential backoff, HTTP error classification |
| `Platform.Config` | Typed environment variable loading |
| `Platform.Text` | Safe text truncation |

## Dependency Rules

- Keep this layer domain-neutral.
- If code needs product entities, auth, internal APIs, or
  assistant-specific logic, it belongs above `Platform.*`.
- If code is pure runtime logic and generic enough to be reused by
  Cortex and downstream consumers, it can live here.
- Prefer small modules with explicit export lists.

## Compatibility Rules

- When moving existing infrastructure into `Platform.*`, preserve
  behavior first.
- Compatibility shims should re-export an explicit API, not `module X`
  wholesale, so future Platform changes do not silently widen public
  surfaces.

## Design Patterns

- Favor simple total helpers and typed configuration records.
- Keep error messages safe for logs by default.
- Preserve operator-visible behavior intentionally; if semantics change,
  make that explicit in code comments and PR notes.
- Prefer generic names only for genuinely generic helpers. Put text
  utilities in `Platform.Text`, not under a narrower domain namespace.

## Module Notes

- `Platform.Database` should stay a thin Hasql infrastructure layer.
- `Platform.Observability` is still compatibility-shaped today; preserve
  existing operator-visible behavior unless a focused migration changes
  it deliberately.
- `Platform.Text` is the home for generic text truncation and similar
  helpers.
- `Platform.DurableTask.Types` is the canonical home for shared run
  status, trigger source, and scheduler-facing run outcome types.
- `Platform.DurableTask.Schedule` is the shared schedule decision
  engine. Runtime-specific DB writes stay in adapters above it.

## Anti-Patterns

- Importing downstream product modules from `Platform.*`.
- Importing domain models just to avoid a small conversion boundary.
- Adding convenience re-exports that obscure where behavior really
  lives.
- Mixing temporary compatibility choices with final architecture claims.
