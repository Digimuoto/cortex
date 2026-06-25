#!/usr/bin/env bash
#
# Build the Wire-authored loop kernel and write the host-side Pulse loop
# registration sketch for the paginated-ingest example.
#
# This script is intentionally not a durable runner. The stock `wire` command in
# this repository can compile Wire source and run small fixed-topology local
# programs, but it does not submit a durable Pulse run or install a LoopPolicy.
# Runtime-bounded self-append is provisioned by the host/Pulse binding that
# consumes the compiled kernel artifact.
#
# The useful work this script performs is:
#
#   1. compile page-kernel.wire with the real `wire build` command;
#   2. write the loop policy metadata the downstream host must pair with that
#      compiled kernel when building a StagePlan;
#   3. print the exact runtime handoff so the example does not hide the loop
#      inside the executor.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
OUT_DIR="${1:-"$HERE/build"}"
KERNEL_WIRE="$HERE/page-kernel.wire"
COMPILED_KERNEL="$OUT_DIR/page-kernel.compiled.json"
LOOP_REGISTRATION="$OUT_DIR/loop-registration.sketch.json"

mkdir -p "$OUT_DIR"

cd "$REPO_ROOT"

# This is the only part the stock Wire CLI owns today: parse/elaborate/compile
# the open kernel fragment into an inspectable CompiledCircuit JSON artifact.
#
# CI passes WIRE_BIN so this check does not need recursive Nix. Humans can run
# the script directly and use the default `nix run .#wire` path.
if [[ -n "${WIRE_BIN:-}" ]]; then
  "$WIRE_BIN" build "$KERNEL_WIRE" >"$COMPILED_KERNEL"
else
  nix run .#wire -- build "$KERNEL_WIRE" >"$COMPILED_KERNEL"
fi

# This JSON is a readable handoff artifact, not an API consumed by Cortex today.
# The corresponding Haskell values are LoopPolicy, LoopRegistration, and
# StagePlan.spLoopRegistrations. The DB-backed tests in ExecutorSpec construct
# those values directly.
cat >"$LOOP_REGISTRATION" <<'JSON'
{
  "kind": "runtime-bounded-iteration-registration-sketch",
  "status": "documentation-only",
  "wireKernelArtifact": "page-kernel.compiled.json",
  "kernelNode": "page_kernel",
  "stageTemplateId": "loop_kernel_paginated_ingest",
  "namespaceRoot": "ingest_loop",
  "frontierWitness": {
    "version": "FrontierWitnessV1",
    "token": "paginated-ingest-state-v1",
    "loopStateRole": "state"
  },
  "policy": {
    "maxIterations": 100,
    "rewriteInteraction": "LoopKernelRewriteClosed",
    "admissionMode": "witnessed",
    "stepRewrite": "AppendAfter"
  },
  "runtimeHandoff": {
    "seedNodeId": "ingest_loop:iter_0:page_kernel",
    "continueOutput": "state",
    "terminalOutput": "terminal",
    "nextNodeIdPattern": "ingest_loop:iter_<i+1>:page_kernel"
  }
}
JSON

cat <<EOF
Built runtime-bounded paginated-ingest kernel artifacts:

  compiled kernel:   $COMPILED_KERNEL
  registration note: $LOOP_REGISTRATION

What happens next in a real host binding:

  1. Lower the compiled page_kernel circuit to a Pulse StageDefinition.
  2. Bind @ingest.fetch_page to host code.
  3. Register StageTemplateId loop_kernel_paginated_ingest in
     StagePlan.spLoopRegistrations with the policy sketched above.
  4. Seed the first node as ingest_loop:iter_0:page_kernel.
  5. On a non-terminal state result, the host action returns StageLoopStep with
     AppendAfter ingest_loop:iter_i:page_kernel ingest_loop:iter_<i+1>:page_kernel.
  6. Pulse verifies the witness, namespace, kernel digest, and effective bound
     before admitting that append gas-neutral.

The loop is therefore not a recursive Wire definition and not authority hidden
inside @ingest.fetch_page. The executor chooses terminal vs continuation data;
Pulse owns whether another kernel instance may be materialized.
EOF
