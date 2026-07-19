# NativePure epic review plan

This plan decomposes the replacement epic PR into deterministic, coherent review batches. Ranges are
inclusive. Run each command from the epic head; the generator reads committed objects, embeds the
current project context and repo-local review skills, and writes a content-addressable review bundle
under `.review/`.

Do not amend or rewrite the reconstructed commits when review finds a defect. Stack a signed,
signed-off conventional fix commit on the epic head. Name the affected subsystem in the subject and
record the review batch in trailers:

```text
fix(wire): preserve executor argument phase separation

Review-Range: e1269ae-f0d2e6d
Review-PRs: #388, #389
Signed-off-by: ...
```

## Review batches

- [x] `0542a4d-2da32a7` — realization foundations through NativePure admission. Historical PRs:
      [#384](https://github.com/Digimuoto/cortex/pull/384),
      [#385](https://github.com/Digimuoto/cortex/pull/385),
      [#386](https://github.com/Digimuoto/cortex/pull/386), and
      [#387](https://github.com/Digimuoto/cortex/pull/387). Focus: witnessed quotient terminology,
      native-shape bounds/layout, exclusive-sum typing, strict registry admission, crossing
      evidence, and rejection diagnostics. Command: `just review-commits 0542a4d-2da32a7`

- [x] `e1269ae-f0d2e6d` — executable Lean kernel and compatible one-record executor substrate.
      Historical PRs: [#388](https://github.com/Digimuoto/cortex/pull/388) and
      [#389](https://github.com/Digimuoto/cortex/pull/389). Focus: theorem boundary, checked-i64
      claims, static metadata versus runtime argument evaluation, `argument_shape` validation order,
      adapter equivalence, and legacy ABI preservation. Command:
      `just review-commits e1269ae-f0d2e6d`

- [ ] `54ec95f-9a8dace` — normalized realization artifacts, shared semantic C IR, and validated C11
      renderer. Historical PRs: [#390](https://github.com/Digimuoto/cortex/pull/390),
      [#391](https://github.com/Digimuoto/cortex/pull/391), and
      [#392](https://github.com/Digimuoto/cortex/pull/392). Focus: stable digests, bidirectional
      witnesses, maximal fusion, ANF/SSA typing, operational semantics, failure propagation, C
      precedence/escaping, and single-representation derivation. Command:
      `just review-commits 54ec95f-9a8dace`

- [ ] `e47de5a-7c71ed3` — StaticC v1 golden pinning and migration to the shared emitter. Historical
      PR: [#393](https://github.com/Digimuoto/cortex/pull/393). Focus: byte stability, ABI
      inventory, lifecycle behavior, scheduler semantics, and removal of whole-function string
      assembly without v1 drift. Command: `just review-commits e47de5a-7c71ed3`

- [ ] `33d002e-cfe4e79` — NativePure region C lowering and v2 checkpoint/select scheduler.
      Historical PRs: [#394](https://github.com/Digimuoto/cortex/pull/394) and
      [#395](https://github.com/Digimuoto/cortex/pull/395). Focus: layouts/padding, typed frames and
      tags, heap/authority exclusion, checked failure paths, checkpoint acknowledgement order,
      select skipping/rejoin, cancellation, and restoration. Command:
      `just review-commits 33d002e-cfe4e79`

- [ ] `4143a07-de2f825` — differential/target assurance and generated NativePure engine integration.
      Historical PRs: [#396](https://github.com/Digimuoto/cortex/pull/396) and
      [#397](https://github.com/Digimuoto/cortex/pull/397). Focus: three-way oracle independence,
      f64 scope, sanitizer and cross-target coverage, symbol/section gates, normalized-plan
      decoding, generated engine bounds, and checkpoint protocol. Command:
      `just review-commits 4143a07-de2f825`

- [ ] `10c2a0b-26cc507` — compatible Wire authoring surface and compliant epic integration policy.
      Historical PR: [#398](https://github.com/Digimuoto/cortex/pull/398). Replacement epic:
      [#400](https://github.com/Digimuoto/cortex/pull/400). Focus: dual grammar normalization,
      formatter/tree-sitter parity, metadata allowlisting, inheritance, unchanged v1 artifacts,
      linear provenance, and branch-policy enforcement. Command:
      `just review-commits 10c2a0b-26cc507`

## Review closure

For every checked batch, add a PR comment containing the bundle SHA-256, reviewer identity/model,
findings or explicit no-findings result, fix commit links, and checks run after the fixes. A batch
is not closed merely because its historical child PR merged.
