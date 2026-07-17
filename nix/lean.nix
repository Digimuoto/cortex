{
  perSystem = {
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
  in {
    packages.cortex-theory = cortexTheory;
    packages.cortex-wire-c = cortexWireC;

    checks.cortex-theory = cortexTheory;
    checks.cortex-wire-c = cortexWireC;
    checks.cortex-wire-c-smoke = cortexWireCSmoke;
  };
}
