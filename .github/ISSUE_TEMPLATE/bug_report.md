---
name: Bug report
about: Something in Cortex behaves incorrectly.
title: ""
labels: bug
---

## Summary

<!-- One sentence: what is wrong. -->

## Reproduction

<!--
Minimal steps. Include the exact `just` or `nix` command, any Wire source,
and runtime input that triggers the bug. Pin commit hash if relevant.
-->

## Expected behavior

<!-- What should happen, and why. Cite the doc or ADR when possible. -->

## Actual behavior

<!-- Logs, error output, or runtime state. Trim noise. -->

## Environment

- Cortex commit: `<hash>`
- Build surface: `just build` / `just test` / `just lean-check` / other
- OS / Nix channel: `<value>`

## Component

<!--
Optional. If the bug is contained to one substrate layer, name it so the
right component label can be applied: pulse | wire | memory | other.
-->
