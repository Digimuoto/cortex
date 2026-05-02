{
  agents ?
    builtins.getFlake
    "github:Digimuoto/agents/88629e29bdc69d14bb9f295c55ba3e4e0e7f62d5",
  nixpkgs ? builtins.getFlake "github:NixOS/nixpkgs/nixos-unstable",
  pkgs ? nixpkgs.legacyPackages.${system},
  system ? builtins.currentSystem,
}: let
  localSkills = import ./agent-overlays.nix {inherit pkgs;};
in
  agents.lib.${system}.mkProjectAgentRoot {
    rootContext = ''
      # Cortex Agent Context

      Cortex is a standalone durable runtime substrate. `Logos` is the downstream reasoning
      library built on Cortex; it depends on Cortex, not the other way round.

      This file is only the prompt overlay. Prefer canonical docs for detail:

      - `docs/Architecture/` - substrate map and layer boundaries.
      - `docs/ADRs/` - accepted design decisions; ADRs are append-only.
      - `docs/Reference/` - public Wire, Pulse, rewrite, and development contracts.
      - `docs/Consumers/` - downstream integration examples only, never the Cortex frame.

      Repository shape:

      - `src/Cortex/` is the main library. Public roots are `Cortex.Algebra`, `Cortex.Wire`,
        `Cortex.Pulse`, `Cortex.Capability`, and `Cortex.Artifact`.
      - Public upstream `Digimuoto/haskell-platform` provides runtime support through the
        `haskell-platform-src` flake input.
      - Downstream `Logos` owns reasoning-library code and consumes Cortex as a separate package.
      - `app/cortex-pulse/` is the substrate shell executable.
      - `editors/tree-sitter-wire/` is the Wire grammar used by docs and editors.
      - `theory/` is the Lean proof track.
      - `docs/` is canonical Cortex documentation. Keep product docs out.

      Use `just` for repo commands; builds go through Nix. Do not invoke `cabal` or `ghc`
      directly. Common checks:

      - `just build`
      - `just build-pulse`
      - `just test`
      - `just fmt`
      - `just fmt-check`
      - `just lint`
      - `just docs-check`
      - `just check`
      - `just lean-check`
      - `just update-materialized` after Cabal input changes

      GitHub Issues and Pull Requests are the active tracker. Do not introduce Linear or
      downstream issue IDs into Haskell modules, tests, Haddock, comments, or canonical docs.

      Commits must be signed and signed off with `git commit -s -S`; never add AI-tool authorship
      or `Co-authored-by` trailers. Before publishing, run:

      - `just check-commit-provenance origin/main..HEAD`

      `main` is fast-forward only. Ship reviewed PRs with `just integrate-pr <pr-or-branch>`, not
      GitHub merge, squash, or rebase buttons. Use `git push --force-with-lease` only for deliberate
      feature-branch rewrites; never raw `--force`.

      Haskell principles:

      - Prefer distinct domain types and smart constructors over aliases or loose primitives.
      - Keep decision logic pure; let thin effectful interpreters execute it.
      - Pattern match exhaustively on owned ADTs; do not wildcard them.
      - Use named records for swap-risk parameters or long argument lists.
      - Return values instead of continuation callbacks when a caller can interpret the result.
      - Every database call needs an error path; no silent ignored transaction results.
      - Comments explain non-obvious why, not obvious mechanics.

      Non-goals: no downstream product code, no frontend or REST server, and no consumer-specific
      docs in Cortex canon unless the page is explicitly about downstream integration examples.

      Cortex flake evaluation does not require access to downstream consumer repositories.

      Project-specific skills remain local for Cortex-only surfaces: Haskell style, Wire source
      style, Lean proof style, theorem attack, architecture, document review, and research
      synthesis.
    '';

    inherit localSkills;
  }
