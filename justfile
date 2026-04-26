# Cortex — durable runtime + structured reasoning substrate
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

# Build the platform-runtime sub-library
build-platform:
    @echo "🔨 Building platform-runtime..."
    nix build .#platform-runtime

# Run the cortex-test suite (hspec-discover)
test:
    @echo "🧪 Running cortex tests..."
    nix run .#cortex-tests

# Run tests matching a pattern
test-match PATTERN:
    @echo "🧪 Running tests matching '{{ PATTERN }}'..."
    nix develop -c cabal test cortex-test --test-option='-m' --test-option='{{ PATTERN }}'

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

# Check that GitHub merge settings cannot manufacture squash/merge commits
check-github-merge-policy:
    nix develop -c scripts/check-github-merge-policy

# Fast-forward main to an already reviewed and signed branch or PR number
integrate-pr TARGET:
    scripts/integrate-pr "{{ TARGET }}"

# Regenerate haskell.nix materialized plans (after editing cortex.cabal)
update-materialized:
    nix run .#update-materialized

# Show flake outputs
show:
    nix flake show

# Link repo-local agent context and skills for Codex
agent-link-codex:
    agents/scripts/link-provider codex

# Link repo-local agent context and skills for Claude
agent-link-claude:
    agents/scripts/link-provider claude

# Link repo-local agent context and skills for OpenCode
agent-link-opencode:
    agents/scripts/link-provider opencode

# Start Nix REPL
repl:
    nix repl -f flake:nixpkgs

# Enter development shell
shell:
    nix develop
