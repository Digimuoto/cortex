---
title: Cortex Style Guide
description:
  Haskell formatting, import hygiene, language pragma policy, and module documentation rules for
  Cortex contributors.
sidebar:
  label: Style
  order: 4
---

# Cortex Style Guide

## Haskell Formatting

Cortex Haskell sources are formatted with Fourmolu through `just fmt` and checked with
`just fmt-check`. Fourmolu owns import sorting and grouping:

- third-party imports first;
- `Cortex.*` imports second;
- `Platform.*` imports third;
- qualified imports use the postpositive `import Module qualified` style.

Contributors should bind the Haskell Language Server "Remove all redundant imports" code action to
format-on-save. The build still enforces unused-import failures, so the editor action is only a
short feedback loop.

## Language Pragmas

Cortex uses `GHC2024` in the `common shared-properties` stanza of `cortex.cabal`. Project-wide
extensions live in that stanza, not at the top of individual modules.

Current project defaults are:

- `DeriveAnyClass`
- `DerivingVia`
- `DuplicateRecordFields`
- `OverloadedRecordDot`
- `OverloadedStrings`
- `RecordWildCards`
- `TypeFamilies`

File-local `LANGUAGE` pragmas are allowed only for genuinely local cases checked by
`scripts/check-language-pragma-allowlist.sh`. New entries to the allowlist require review with a
specific reason why the extension should not become a project default.

Allowed file-local extensions are:

- `AllowAmbiguousTypes`
- `BlockArguments`
- `CPP`
- `MagicHash`
- `OverlappingInstances`
- `PackageImports`
- `PartialTypeSignatures`
- `StrictData`
- `TemplateHaskell`
- `UnboxedTuples`
- `UndecidableInstances`

The initial pragma inventory before centralization was:

```text
111 OverloadedStrings
 88 OverloadedRecordDot
 39 LambdaCase
 35 DerivingStrategies
 27 DeriveGeneric
 12 DeriveAnyClass
  9 ScopedTypeVariables
  6 GADTs
  4 DuplicateRecordFields
  3 GeneralizedNewtypeDeriving
  3 TypeFamilies
  2 BlockArguments
  1 ImportQualifiedPost
  1 PackageImports
  1 StrictData
  1 TemplateHaskell
  1 TupleSections
```
