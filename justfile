# Cortex — durable runtime substrate
# ============================================================
#
# Type `just` or `just --list` to see all commands.
# All builds flow through Nix; do not run cabal / ghc directly.

default:
    @just --list

help: default

# ============================================================================
# BUILD & TEST
# ============================================================================

# Build the Cortex library
build:
    @echo "🔨 Building cortex library..."
    nix build .#cortex

# Build the cortex-pulse executable
build-pulse:
    @echo "🔨 Building cortex-pulse..."
    nix build .#cortex-pulse

# Build the Wire CLI executable
build-wire:
    @echo "🔨 Building wire..."
    nix build .#wire

# Run opt-in Criterion benchmarks for Wire pure evaluation
bench-pure-wire *ARGS:
    @echo "📈 Running pure Wire benchmarks..."
    nix run .#pure-wire-bench {{ ARGS }}

# Run opt-in Criterion benchmarks for hosted Circuit JSONL protocol overhead.
# Informational only: this target deliberately has no timing threshold.
bench-hosted-protocol *ARGS:
    @echo "📈 Running hosted Circuit protocol benchmarks..."
    nix run .#hosted-protocol-bench {{ ARGS }}

# Run the cortex-test suite (hspec-discover)
# Differential parse: megaparsec vs tree-sitter over the Wire corpus
wire-grammar-diff:
    @echo "🔀 Comparing Wire grammars over the corpus..."
    scripts/wire-grammar-diff

# Regenerate Lean fixtures for emitted Wire admission artifacts
wire-lean-fixtures:
    @echo "🧬 Regenerating emitted Lean artifact fixtures..."
    nix run .#wire -- lean-fixtures theory/Cortex/Wire/AdmissionArtifact/Emitted

test:
    @echo "🧪 Running cortex tests..."
    nix run .#cortex-tests

# Run tests matching a pattern
test-match PATTERN:
    @echo "🧪 Running tests matching '{{ PATTERN }}'..."
    nix run .#cortex-tests -- -m '{{ PATTERN }}'

# Run flake checks (format + build + test)
check:
    @echo "🔍 Running flake checks..."
    nix flake check --print-build-logs
    @echo "✅ All checks passed"

# Full dev cycle: fmt → check → build
dev: fmt check build
    @echo "✅ Development cycle completed"

# ============================================================================
# CODE QUALITY
# ============================================================================

# Format all code (Haskell, Nix)
fmt:
    @echo "🎨 Formatting..."
    nix fmt

# Check formatting without mutating files
fmt-check:
    @echo "🎨 Checking formatting..."
    nix run .#_check-format

# Run HLint on Haskell files
lint:
    @echo "🔍 Running HLint..."
    nix run .#lint-haskell

# Run strict Lean theory lint checks
lean-lint:
    @echo "🔍 Running Lean lint..."
    nix run .#lean-lint

# Run strict Markdown/docs lint checks
docs-lint:
    @echo "🔍 Running docs lint..."
    nix run .#docs-lint

# Run strict Wire source style checks
wire-style-check:
    @echo "🔍 Running Wire style checks..."
    nix run .#check-wire-style

# Parse and highlight Wire fences embedded in Markdown docs
doc-wire-examples:
    @echo "🔍 Checking docs Wire examples..."
    nix run .#check-doc-wire-examples

# Build and validate the runtime-bounded iteration Wire provisioning example
runtime-iteration-wire-example:
    @echo "🔍 Checking runtime iteration Wire example..."
    nix run .#check-runtime-iteration-wire-example

# ============================================================================
# DOCUMENTATION SITE
# ============================================================================

# Build documentation site (static output via repo-docs)
docs-build:
    nix build .#docs-site

# Validate documentation by attempting a full site build (frontmatter + links)
docs-check: docs-build

# Run documentation dev server (HOST=127.0.0.1 PORT=4321 by default)
docs-dev:
    nix run .#docs-dev

# Build and preview documentation site (HOST=127.0.0.1 PORT=4322 by default)
docs-preview:
    nix run .#docs-preview

# ============================================================================
# PAPERS
# ============================================================================

# Build all Nix-rendered paper PDFs
papers-build:
    @echo "📄 Building paper PDFs..."
    nix build .#papers-renderings --out-link result-papers

# Build the main paper PDF and copy it into the directory where just was invoked
paper-generate PDF="paper6-executable-diagrams.pdf":
    #!/usr/bin/env bash
    set -euo pipefail

    out="$(nix build .#papers-renderings --no-link --print-out-paths)"
    pdf="$out/{{ PDF }}"
    dest="{{ invocation_directory() }}"

    if [[ ! -e "$pdf" ]]; then
      echo "paper PDF not found: {{ PDF }}" >&2
      echo "available PDFs:" >&2
      find "$out" -maxdepth 1 -name '*.pdf' | sort | while IFS= read -r candidate; do
        printf '  %s\n' "$(basename "$candidate")" >&2
      done
      exit 1
    fi

    cp -f "$pdf" "$dest/"
    printf 'generated %s\n' "$dest/$(basename "$pdf")"

# Build paper PDFs and open one with zathura from the Nix dev shell
papers-open PDF="paper6-executable-diagrams.pdf":
    #!/usr/bin/env bash
    set -euo pipefail

    out="$(nix build .#papers-renderings --no-link --print-out-paths)"
    pdf="$out/{{ PDF }}"

    if [[ ! -e "$pdf" ]]; then
      echo "paper PDF not found: {{ PDF }}" >&2
      echo "available PDFs:" >&2
      find "$out" -maxdepth 1 -name '*.pdf' | sort | while IFS= read -r candidate; do
        printf '  %s\n' "$(basename "$candidate")" >&2
      done
      exit 1
    fi

    exec nix develop -c zathura "$pdf"

# ============================================================================
# LEAN 4 THEORY (theory/)
# ============================================================================

# Build the Lean 4 mechanization (axioms + sorry-shaped scaffold for now)
lean-build:
    @echo "🔨 Building Cortex theory (Lean 4)..."
    cd theory && lake build

# Build the Lean theory through the flake surface used by CI and hooks
lean-check:
    @echo "🔍 Checking Cortex theory through Nix..."
    nix run .#_check-theory

# Model-check the Pulse and Wire hosted protocols (TLC) through the flake surface
tla-check:
    @echo "🔍 Model-checking the Pulse and Wire hosted protocols (TLC)..."
    nix run .#_check-tla

# Run the test suite against an ephemeral Postgres with the Pulse schema fixture.
# Without this, DB-backed Pulse tests skip themselves (PGHOST unset). Extra args
# pass through to hspec, e.g. `just test-db -m "run-terminal"`.
test-db *ARGS:
    @echo "🧪 Running tests against an ephemeral Pulse test database..."
    nix shell nixpkgs#postgresql -c scripts/with-test-db.sh nix run .#cortex-tests -- {{ ARGS }}

# Verify that the curated full schema is unchanged by replaying every migration
# and that its recorded migration head is current.
schema-drift-check:
    @echo "🗄️  Checking Pulse schema dump against migrations..."
    nix build .#pulse-schema-drift

# Build and run the smoke executable
lean-run: lean-build
    cd theory && ./.lake/build/bin/cortex-theory

# Build the executable target explicitly (Lake doesn't build exes by default)
lean-build-exe:
    cd theory && lake build cortex-theory

# Update the lake manifest (after editing lakefile.lean)
lean-update:
    cd theory && lake update

# Wipe Lake's build cache. Useful when toolchain changes.
lean-clean:
    rm -rf theory/.lake/build

# ============================================================================
# UTILITIES
# ============================================================================

# Update flake dependencies
update:
    @echo "🔄 Updating dependencies..."
    nix flake update

# Run the full CI-aligned local check surface
ci-check:
    @echo "🚀 Running CI-aligned checks..."
    nix run .#_ci-check

# Check commit signatures, signoffs, and authorship for a revision range
check-commit-provenance RANGE="origin/main..HEAD":
    scripts/check-commit-provenance "{{ RANGE }}"

# Check a branch name against the naming policy (default: current branch)
check-branch-name BRANCH="":
    scripts/check-branch-name "{{ BRANCH }}"

# Check that GitHub merge settings cannot manufacture squash/merge commits
check-github-merge-policy:
    nix develop -c scripts/check-github-merge-policy

# Build a deterministic review bundle for an inclusive commit range
review-commits RANGE *ARGS:
    scripts/review-commits "{{ RANGE }}" {{ ARGS }}

# Fast-forward main to an already reviewed and signed branch or PR number
integrate-pr TARGET:
    scripts/integrate-pr "{{ TARGET }}"

# Regenerate haskell.nix materialized plans (after editing cortex.cabal)
update-materialized:
    nix run .#update-materialized

# Show flake outputs
show:
    nix flake show

_agent-link PROVIDER:
    agent_link="$(nix build --builders '' --impure --no-link --print-out-paths --expr 'import ./nix/agent-link.nix { provider = "{{ PROVIDER }}"; }')" && "$agent_link/bin/agent-link-{{ PROVIDER }}"

# Link repo-local agent context and skills for Codex
agent-link-codex:
    just _agent-link codex

# Link repo-local agent context and skills for Claude
agent-link-claude:
    just _agent-link claude

# Link repo-local agent context and skills for OpenCode
agent-link-opencode:
    just _agent-link opencode

# Start Nix REPL
repl:
    nix repl -f flake:nixpkgs

# Enter development shell
shell:
    nix develop
