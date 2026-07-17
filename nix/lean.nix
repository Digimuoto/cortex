{
  perSystem = {
    config,
    lib,
    pkgs,
    ...
  }: let
    leanDependencies = with pkgs.leanPackages; [
      batteries
      aesop
      Qq
      proofwidgets
      plausible
      LeanSearchClient
      importGraph
      Cli
    ];
    commonLakePackage = {
      version = "0.1.0";
      src = ../theory;
      leanPackageName = "cortex-theory";
      lakeHash = "sha256-wZ0y94pkNWerPhDPTIZByZ7Yu3f2OGy+/1/ioDEg8Lg=";
      leanDeps = leanDependencies;
    };
    cortexTheory = pkgs.leanPackages.buildLakePackage (commonLakePackage
      // {
        pname = "cortex-theory";

        # Build the proof surface through Nix. The host compiler intentionally
        # imports only Lean core, keeping its native closure independent from
        # the Mathlib-backed proof model.
        buildTargets = ["Cortex"];

        meta = {
          description = "Lean 4 mechanization of the Cortex substrate";
        };
      });
    cortexWireC = pkgs.leanPackages.buildLakePackage (commonLakePackage
      // {
        pname = "cortex-wire-c";
        buildTargets = ["cortex-wire-c"];

        meta = {
          description = "Host-side validator and freestanding C emitter for static Wire programs";
          mainProgram = "cortex-wire-c";
        };
      });
    cortexWireDiff = pkgs.leanPackages.buildLakePackage (commonLakePackage
      // {
        pname = "cortex-wire-diff";
        buildTargets = ["cortex-wire-diff"];

        meta = {
          description = "Lean reference interpreter for the static Wire C differential suite";
          mainProgram = "cortex-wire-diff";
        };
      });
    cortexWireCSmoke =
      pkgs.runCommand "cortex-wire-c-smoke" {
        nativeBuildInputs = [cortexWireC pkgs.jq pkgs.llvmPackages_18.clang pkgs.llvmPackages_18.llvm];
      } ''
        generated="$TMPDIR/generated"
        cortex-wire-c ${../test/fixtures/wire/static-program-v1/two-node.json} "$generated"
        jq -e . "$generated/program.manifest.json" >/dev/null

        emptyArtifact="$TMPDIR/empty.json"
        jq '.program_identity = "empty" | .nodes = [] | .edges = []' \
          ${../test/fixtures/wire/static-program-v1/two-node.json} > "$emptyArtifact"
        emptyGenerated="$TMPDIR/empty-generated"
        cortex-wire-c "$emptyArtifact" "$emptyGenerated"
        clang -std=c11 -ffreestanding -fno-builtin -Wall -Wextra -Werror \
          -c "$emptyGenerated/program.c" -o "$TMPDIR/empty-host.o"
        clang -target aarch64-none-elf -std=c11 -ffreestanding -fno-builtin \
          -Wall -Wextra -Werror -Wno-unused-command-line-argument \
          -c "$emptyGenerated/program.c" -o "$TMPDIR/empty-aarch64.o"

        expectRejected() {
          name="$1"
          artifact="$2"
          if cortex-wire-c "$artifact" "$TMPDIR/rejected-$name"; then
            echo "cortex-wire-c accepted invalid $name artifact" >&2
            exit 1
          fi
        }

        duplicateEdge="$TMPDIR/duplicate-edge.json"
        jq '.edges += [.edges[0]]' \
          ${../test/fixtures/wire/static-program-v1/two-node.json} > "$duplicateEdge"
        expectRejected duplicate-edge "$duplicateEdge"

        invalidEndpoint="$TMPDIR/invalid-endpoint.json"
        jq '.edges[0].to = 2' \
          ${../test/fixtures/wire/static-program-v1/two-node.json} > "$invalidEndpoint"
        expectRejected invalid-endpoint "$invalidEndpoint"

        cycle="$TMPDIR/cycle.json"
        jq '.edges += [{"from": 1, "to": 0}]' \
          ${../test/fixtures/wire/static-program-v1/two-node.json} > "$cycle"
        expectRejected cycle "$cycle"

        noncanonicalNode="$TMPDIR/noncanonical-node.json"
        jq '.nodes[1].id = 2' \
          ${../test/fixtures/wire/static-program-v1/two-node.json} > "$noncanonicalNode"
        expectRejected noncanonical-node "$noncanonicalNode"

        overflow="$TMPDIR/overflow.json"
        jq '.nodes[1].id = 4294967296' \
          ${../test/fixtures/wire/static-program-v1/two-node.json} > "$overflow"
        expectRejected overflow "$overflow"

        delayedPure="$TMPDIR/delayed-pure.json"
        jq '.nodes[0].executor = "pure"' \
          ${../test/fixtures/wire/static-program-v1/two-node.json} > "$delayedPure"
        expectRejected delayed-pure "$delayedPure"

        clang -std=c11 -ffreestanding -fno-builtin -Wall -Wextra -Werror \
          -c "$generated/program.c" -o "$TMPDIR/program-host.o"
        llvm-nm --undefined-only "$TMPDIR/program-host.o" > "$TMPDIR/host-undefined"
        test ! -s "$TMPDIR/host-undefined"

        clang -target aarch64-none-elf -std=c11 -ffreestanding -fno-builtin \
          -Wall -Wextra -Werror -Wno-unused-command-line-argument \
          -c "$generated/program.c" -o "$TMPDIR/program-aarch64.o"
        llvm-nm --undefined-only "$TMPDIR/program-aarch64.o" > "$TMPDIR/aarch64-undefined"
        test ! -s "$TMPDIR/aarch64-undefined"
        llvm-readelf -S "$TMPDIR/program-aarch64.o" > "$TMPDIR/aarch64-sections"
        if grep -E '\.(tdata|tbss)' "$TMPDIR/aarch64-sections"; then
          echo "generated target object contains TLS sections" >&2
          exit 1
        fi

        clang -std=c11 -Wall -Wextra -Werror \
          -I "$generated" "$generated/program.c" \
          ${../test/fixtures/wire/static-program-v1/two-node-harness.c} \
          -o "$TMPDIR/two-node-harness"
        "$TMPDIR/two-node-harness" s
        "$TMPDIR/two-node-harness" f

        mkdir -p "$out"
        cp "$generated/program.c" "$generated/program.h" \
          "$generated/program.manifest.json" "$out/"
      '';
    # ADR 0091 three-way differential: the Haskell GraphRuntime reference driver,
    # the Lean reference interpreter, and the generated freestanding C must agree
    # byte-for-byte on the whole scenario corpus (exhaustive DAGs for n <= 3 plus
    # named four-node shapes, each with lifecycle and adversarial completion
    # scenarios). This gates the unverified topological C drive loop against both
    # semantic models.
    cortexWireDifferential =
      pkgs.runCommand "cortex-wire-differential" {
        nativeBuildInputs = [
          config.packages.wire
          cortexWireC
          cortexWireDiff
          pkgs.jq
          pkgs.llvmPackages_18.clang
        ];
      } ''
        corpus="$TMPDIR/corpus"
        wire differential emit "$corpus"

        # Coverage summary — no silent truncation of the corpus.
        topologies=$(jq -r '.topology_count' "$corpus/index.json")
        scenarios=$(jq -r '.scenario_count' "$corpus/index.json")
        echo "differential corpus: $topologies topologies, $scenarios scenarios"
        echo "coverage: exhaustive DAGs for n<=3 plus named four-node shapes" \
          "(chain, diamond, fan-out, fan-in, independent frontier)"

        # Lean reference interpreter over the shared corpus.
        cortex-wire-diff "$corpus"

        # Generated C: compile one program per topology and replay its scenarios.
        : > "$corpus/c-traces.txt"
        for topo in "$corpus"/topologies/*/; do
          name=$(basename "$topo")
          cortex-wire-c "$topo/artifact.json" "$topo/gen"
          clang -std=c11 -Wall -Wextra -Werror \
            -I "$topo/gen" "$topo/gen/program.c" \
            ${../test/fixtures/wire/static-program-v1/differential-harness.c} \
            -o "$topo/harness"
          while IFS= read -r line; do
            [ -z "$line" ] && continue
            "$topo/harness" "$line" >> "$corpus/c-traces.txt"
          done < "$topo/scenarios.txt"
        done

        sort "$corpus/haskell-traces.txt" > "$TMPDIR/haskell.sorted"
        sort "$corpus/lean-traces.txt" > "$TMPDIR/lean.sorted"
        sort "$corpus/c-traces.txt" > "$TMPDIR/c.sorted"

        if ! diff -u "$TMPDIR/haskell.sorted" "$TMPDIR/lean.sorted"; then
          echo "Haskell GraphRuntime and Lean interpreter traces diverge" >&2
          exit 1
        fi
        if ! diff -u "$TMPDIR/haskell.sorted" "$TMPDIR/c.sorted"; then
          echo "Haskell GraphRuntime and generated C traces diverge" >&2
          exit 1
        fi

        emitted=$(wc -l < "$corpus/c-traces.txt")
        if [ "$emitted" -ne "$scenarios" ]; then
          echo "expected $scenarios C traces, got $emitted" >&2
          exit 1
        fi

        mkdir -p "$out"
        cp "$corpus/index.json" "$corpus/haskell-traces.txt" "$out/"
        echo "three-way differential agreement over $scenarios scenarios" > "$out/status.txt"
      '';
  in {
    packages.cortex-theory = cortexTheory;
    packages.cortex-wire-c = cortexWireC;
    packages.cortex-wire-diff = cortexWireDiff;

    checks.cortex-theory = cortexTheory;
    checks.cortex-wire-c = cortexWireC;
    checks.cortex-wire-c-smoke = cortexWireCSmoke;
    checks.cortex-wire-differential = cortexWireDifferential;
  };
}
