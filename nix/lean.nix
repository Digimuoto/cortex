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
        nativeBuildInputs = [
          cortexWireC
          pkgs.gcc
          pkgs.jq
          pkgs.llvmPackages_18.clang
          pkgs.llvmPackages_18.llvm
        ];
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
        gcc -std=c11 -ffreestanding -fno-builtin -pedantic-errors \
          -Wall -Wextra -Werror -Wconversion -Wshadow \
          -c "$emptyGenerated/program.c" -o "$TMPDIR/empty-gcc.o"

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
        gcc -std=c11 -ffreestanding -fno-builtin -pedantic-errors \
          -Wall -Wextra -Werror -Wconversion -Wshadow \
          -c "$generated/program.c" -o "$TMPDIR/program-gcc.o"
        clang --analyze -std=c11 -Wall -Wextra -Werror \
          -Wno-unused-command-line-argument "$generated/program.c"
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
        if grep -E '\.(init_array|fini_array|ctors|dtors)' "$TMPDIR/aarch64-sections"; then
          echo "generated target object contains constructor/destructor sections" >&2
          exit 1
        fi
        if grep -E '[[:space:]][A-Z]*W[A-Z]*X[A-Z]*[[:space:]]' "$TMPDIR/aarch64-sections"; then
          echo "generated target object contains a writable executable section" >&2
          exit 1
        fi

        llvm-nm --defined-only --extern-only --format=posix \
          "$TMPDIR/program-aarch64.o" | awk '{print $1}' | sort > "$TMPDIR/exports-actual"
        # Expected exports are read from program.exports.txt, which the emitter
        # writes from the same `exportedFns` list (theory/CortexWireC.lean) that
        # generates the header declarations. This is not text scraped from the
        # generated header, so it is immune to header reformatting, whitespace
        # changes, or a comment that happens to name a real function.
        sort "$generated/program.exports.txt" > "$TMPDIR/exports-expected"
        diff -u "$TMPDIR/exports-expected" "$TMPDIR/exports-actual"

        nodeCount=$(jq -r .node_count "$generated/program.manifest.json")
        edgeCount=$(jq -r .edge_count "$generated/program.manifest.json")
        llvm-size -A "$TMPDIR/program-aarch64.o" > "$TMPDIR/aarch64-sizes"
        llvm-objdump -h "$TMPDIR/program-aarch64.o" > "$TMPDIR/aarch64-section-table"
        bssHex=$(awk '$2 == ".bss" {print $3}' "$TMPDIR/aarch64-section-table")
        rodataHex=$(awk '$2 == ".rodata" {print $3}' "$TMPDIR/aarch64-section-table")
        if [ -z "$bssHex" ]; then
          echo "generated target object is missing expected .bss storage" >&2
          exit 1
        fi
        # Unlike .bss (node_status/output_handle/frontier_snapshot are always
        # emitted, since every program has at least the Nat.max 1 nodeCount
        # storage floor), .rodata can legitimately be absent from the object:
        # for small topologies the compiler constant-folds the tiny static
        # const arrays (predecessor_offsets/predecessor_nodes/topological_order)
        # away entirely, so a missing section is not itself a regression signal
        # here — only growth past rodataBound below is.
        rodataHex=''${rodataHex:-0}
        bssSize=$((0x$bssHex))
        rodataSize=$((0x$rodataHex))
        # renderSource (theory/CortexWireC.lean) sizes every per-node array off
        # storageCount = max(1, nodeCount), not raw nodeCount, so the bound must
        # use that same floor. .bss holds node_status + frontier_snapshot (uint8
        # each) and output_handle (uint64) per storage slot (~10 bytes/node
        # before alignment); .rodata holds predecessor_offsets + topological_order
        # (uint32 each) per storage slot (~8 bytes/node) plus predecessor_nodes
        # (uint32) per edge slot (~4 bytes/edge). The multipliers below keep
        # headroom over those measured widths for alignment padding and small
        # future additions.
        storageCount=$((nodeCount > 0 ? nodeCount : 1))
        edgeStorage=$((edgeCount > 0 ? edgeCount : 1))
        bssBound=$((12 * storageCount + 64))
        rodataBound=$((8 * storageCount + 4 * edgeStorage + 64))
        if [ "$bssSize" -gt "$bssBound" ]; then
          echo "generated target .bss exceeds manifest-derived bound: $bssSize > $bssBound" >&2
          exit 1
        fi
        if [ "$rodataSize" -gt "$rodataBound" ]; then
          echo "generated target .rodata exceeds manifest-derived bound: $rodataSize > $rodataBound" >&2
          exit 1
        fi

        clang -std=c11 -Wall -Wextra -Werror \
          -I "$generated" "$generated/program.c" \
          ${../test/fixtures/wire/static-program-v1/two-node-harness.c} \
          -o "$TMPDIR/two-node-harness"
        "$TMPDIR/two-node-harness" s
        "$TMPDIR/two-node-harness" f

        gcc -std=c11 -pedantic-errors -Wall -Wextra -Werror -Wconversion -Wshadow \
          -I "$generated" "$generated/program.c" \
          ${../test/fixtures/wire/static-program-v1/two-node-harness.c} \
          -o "$TMPDIR/two-node-harness-gcc"
        "$TMPDIR/two-node-harness-gcc" s
        "$TMPDIR/two-node-harness-gcc" f

        clang -std=c11 -Wall -Wextra -Werror \
          -fsanitize=address,undefined,bounds -fno-omit-frame-pointer \
          -I "$generated" "$generated/program.c" \
          ${../test/fixtures/wire/static-program-v1/two-node-harness.c} \
          -o "$TMPDIR/two-node-harness-sanitized"
        ASAN_OPTIONS=detect_leaks=0 "$TMPDIR/two-node-harness-sanitized" s
        ASAN_OPTIONS=detect_leaks=0 "$TMPDIR/two-node-harness-sanitized" f

        generatedAgain="$TMPDIR/generated-again"
        cortex-wire-c ${../test/fixtures/wire/static-program-v1/two-node.json} "$generatedAgain"
        diff -ru "$generated" "$generatedAgain"
        clang -target aarch64-none-elf -std=c11 -ffreestanding -fno-builtin \
          -Wall -Wextra -Werror -Wno-unused-command-line-argument \
          -c "$generatedAgain/program.c" -o "$TMPDIR/program-aarch64-again.o"
        cmp "$TMPDIR/program-aarch64.o" "$TMPDIR/program-aarch64-again.o"

        inputSha=$(sha256sum ${../test/fixtures/wire/static-program-v1/two-node.json} | cut -d ' ' -f1)
        emitterSha=$(sha256sum ${../theory/CortexWireC.lean} | cut -d ' ' -f1)
        sourceSha=$(sha256sum "$generated/program.c" | cut -d ' ' -f1)
        headerSha=$(sha256sum "$generated/program.h" | cut -d ' ' -f1)
        manifestSha=$(sha256sum "$generated/program.manifest.json" | cut -d ' ' -f1)
        objectSha=$(sha256sum "$TMPDIR/program-aarch64.o" | cut -d ' ' -f1)
        clangVersion=$(clang --version | sed -n '1p')
        gccVersion=$(gcc --version | sed -n '1p')
        jq -n \
          --arg schema "cortex.cfat-evidence/v1" \
          --arg profile "cortex.wire.static-program/v1" \
          --arg lifecycle "cortex.wire.static-c-lifecycle/v1" \
          --arg input_sha256 "$inputSha" \
          --arg emitter_sha256 "$emitterSha" \
          --arg source_sha256 "$sourceSha" \
          --arg header_sha256 "$headerSha" \
          --arg manifest_sha256 "$manifestSha" \
          --arg object_sha256 "$objectSha" \
          --arg clang "$clangVersion" \
          --arg gcc "$gccVersion" \
          --argjson node_count "$nodeCount" \
          --argjson edge_count "$edgeCount" \
          --argjson bss_bytes "$bssSize" \
          --argjson bss_bound_bytes "$bssBound" \
          --argjson rodata_bytes "$rodataSize" \
          --argjson rodata_bound_bytes "$rodataBound" \
          '{
            schema: $schema,
            profile: $profile,
            lifecycle_semantics: $lifecycle,
            input: {sha256: $input_sha256, node_count: $node_count, edge_count: $edge_count},
            sources: {emitter_sha256: $emitter_sha256},
            generated: {
              source_sha256: $source_sha256,
              header_sha256: $header_sha256,
              manifest_sha256: $manifest_sha256,
              aarch64_object_sha256: $object_sha256
            },
            compilers: {clang: $clang, gcc: $gcc},
            storage: {
              bss_bytes: $bss_bytes,
              bss_bound_bytes: $bss_bound_bytes,
              rodata_bytes: $rodata_bytes,
              rodata_bound_bytes: $rodata_bound_bytes
            },
            gates: {
              invalid_inputs_rejected: true,
              clang_host: true,
              clang_aarch64_freestanding: true,
              gcc_host_strict: true,
              clang_static_analyzer: true,
              asan_ubsan_bounds: true,
              no_undefined_symbols: true,
              no_tls_or_constructors: true,
              no_writable_executable_sections: true,
              export_allowlist_exact: true,
              manifest_storage_bounds: true,
              source_reproducible: true,
              aarch64_object_reproducible: true
            }
          }' > "$TMPDIR/smoke-evidence.json"

        mkdir -p "$out"
        cp "$generated/program.c" "$generated/program.h" \
          "$generated/program.manifest.json" "$generated/program.exports.txt" \
          "$TMPDIR/program-aarch64.o" \
          "$TMPDIR/aarch64-sections" "$TMPDIR/aarch64-sizes" \
          "$TMPDIR/aarch64-section-table" \
          "$TMPDIR/exports-actual" \
          "$TMPDIR/smoke-evidence.json" "$out/"
      '';
    # ADR 0091 differential: the Haskell GraphRuntime reference driver, the Lean
    # reference interpreter, and generated freestanding C compiled by Clang and
    # GCC must agree byte-for-byte over exhaustive small DAGs plus deterministic,
    # replayable larger representatives and their lifecycle scenarios. This gates
    # the unverified topological C drive loop against both semantic models.
    cortexWireDifferential =
      pkgs.runCommand "cortex-wire-differential" {
        nativeBuildInputs = [
          config.packages.wire
          cortexWireC
          cortexWireDiff
          pkgs.gcc
          pkgs.jq
          pkgs.llvmPackages_18.clang
        ];
      } ''
        corpus="$TMPDIR/corpus"
        wire differential emit "$corpus"

        # Coverage summary — no silent truncation of the corpus.
        topologies=$(jq -r '.topology_count' "$corpus/index.json")
        scenarios=$(jq -r '.scenario_count' "$corpus/index.json")
        exhaustiveMax=$(jq -r '.coverage.exhaustive_dag_node_count_max' "$corpus/index.json")
        representativeMax=$(jq -r '.coverage.representative_node_count_max' "$corpus/index.json")
        deterministicSeeds=$(jq -c '.coverage.deterministic_seeds' "$corpus/index.json")
        if [ "$exhaustiveMax" = "null" ] || [ "$representativeMax" = "null" ] \
          || [ "$deterministicSeeds" = "null" ]; then
          echo "corpus index.json is missing expected coverage metadata" >&2
          exit 1
        fi
        echo "differential corpus: $topologies topologies, $scenarios scenarios"
        echo "coverage: exhaustive DAGs for n<=$exhaustiveMax;" \
          "named and seeded representatives through n=$representativeMax;" \
          "seeds=$deterministicSeeds"

        # Lean reference interpreter over the shared corpus.
        cortex-wire-diff "$corpus"

        # Generated C: compile one program per topology and replay its scenarios.
        : > "$corpus/c-traces.txt"
        : > "$corpus/gcc-traces.txt"
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

          gcc -std=c11 -pedantic-errors -Wall -Wextra -Werror \
            -Wconversion -Wshadow -I "$topo/gen" "$topo/gen/program.c" \
            ${../test/fixtures/wire/static-program-v1/differential-harness.c} \
            -o "$topo/gcc-harness"
          while IFS= read -r line; do
            [ -z "$line" ] && continue
            "$topo/gcc-harness" "$line" >> "$corpus/gcc-traces.txt"
          done < "$topo/scenarios.txt"
        done

        sort "$corpus/haskell-traces.txt" > "$TMPDIR/haskell.sorted"
        sort "$corpus/lean-traces.txt" > "$TMPDIR/lean.sorted"
        sort "$corpus/c-traces.txt" > "$TMPDIR/c.sorted"
        sort "$corpus/gcc-traces.txt" > "$TMPDIR/gcc.sorted"

        if ! diff -u "$TMPDIR/haskell.sorted" "$TMPDIR/lean.sorted"; then
          echo "Haskell GraphRuntime and Lean interpreter traces diverge" >&2
          exit 1
        fi
        if ! diff -u "$TMPDIR/haskell.sorted" "$TMPDIR/c.sorted"; then
          echo "Haskell GraphRuntime and clang-compiled C traces diverge" >&2
          exit 1
        fi
        if ! diff -u "$TMPDIR/haskell.sorted" "$TMPDIR/gcc.sorted"; then
          echo "Haskell GraphRuntime and GCC-compiled C traces diverge" >&2
          exit 1
        fi

        emitted=$(wc -l < "$corpus/c-traces.txt")
        if [ "$emitted" -ne "$scenarios" ]; then
          echo "expected $scenarios C traces, got $emitted" >&2
          exit 1
        fi
        gccEmitted=$(wc -l < "$corpus/gcc-traces.txt")
        if [ "$gccEmitted" -ne "$scenarios" ]; then
          echo "expected $scenarios GCC C traces, got $gccEmitted" >&2
          exit 1
        fi

        # The three trace-equality diffs above pass trivially if a topology
        # simply has nothing to disagree on, so exactly-once cancellation needs
        # its own presence check: confirm the corpus actually contains the
        # post-terminal-failure scenario that exercises it (see the "adversarial"
        # scenarios in src/Cortex/Wire/StaticDifferential.hs).
        cancellationScenarios=$(grep -cE -- '^[^[:space:]]*-adversarial-post-terminal[[:space:]]' \
          "$corpus/scenarios-all.txt" || true)
        if [ -z "$cancellationScenarios" ] || [ "$cancellationScenarios" -lt 1 ]; then
          echo "differential corpus is missing the exactly-once-cancellation" \
            "(adversarial-post-terminal) scenario" >&2
          exit 1
        fi

        corpusIndexSha=$(sha256sum "$corpus/index.json" | cut -d ' ' -f1)
        haskellTraceSha=$(sha256sum "$corpus/haskell-traces.txt" | cut -d ' ' -f1)
        leanTraceSha=$(sha256sum "$corpus/lean-traces.txt" | cut -d ' ' -f1)
        clangTraceSha=$(sha256sum "$corpus/c-traces.txt" | cut -d ' ' -f1)
        gccTraceSha=$(sha256sum "$corpus/gcc-traces.txt" | cut -d ' ' -f1)
        corpusSourceSha=$(sha256sum ${../src/Cortex/Wire/StaticDifferential.hs} | cut -d ' ' -f1)
        leanSourceSha=$(sha256sum ${../theory/CortexWireDiff.lean} | cut -d ' ' -f1)
        harnessSourceSha=$(sha256sum \
          ${../test/fixtures/wire/static-program-v1/differential-harness.c} | cut -d ' ' -f1)
        clangVersion=$(clang --version | sed -n '1p')
        gccVersion=$(gcc --version | sed -n '1p')
        jq -n \
          --arg schema "cortex.cfat-differential-evidence/v1" \
          --arg coverage "all DAGs for n <= 3 plus named and deterministic larger representatives" \
          --arg index_sha256 "$corpusIndexSha" \
          --arg haskell_sha256 "$haskellTraceSha" \
          --arg lean_sha256 "$leanTraceSha" \
          --arg clang_sha256 "$clangTraceSha" \
          --arg gcc_sha256 "$gccTraceSha" \
          --arg corpus_source_sha256 "$corpusSourceSha" \
          --arg lean_source_sha256 "$leanSourceSha" \
          --arg harness_source_sha256 "$harnessSourceSha" \
          --arg clang "$clangVersion" \
          --arg gcc "$gccVersion" \
          --argjson topology_count "$topologies" \
          --argjson scenario_count "$scenarios" \
          --argjson exhaustive_dag_node_count_max "$exhaustiveMax" \
          --argjson representative_node_count_max "$representativeMax" \
          --argjson deterministic_seeds "$deterministicSeeds" \
          '{
            schema: $schema,
            coverage: $coverage,
            coverage_bounds: {
              exhaustive_dag_node_count_max: $exhaustive_dag_node_count_max,
              representative_node_count_max: $representative_node_count_max,
              deterministic_seeds: $deterministic_seeds,
              replayable: true
            },
            topology_count: $topology_count,
            scenario_count: $scenario_count,
            sources: {
              corpus_sha256: $corpus_source_sha256,
              lean_interpreter_sha256: $lean_source_sha256,
              c_harness_sha256: $harness_source_sha256
            },
            artifacts: {
              index_sha256: $index_sha256,
              haskell_traces_sha256: $haskell_sha256,
              lean_traces_sha256: $lean_sha256,
              clang_c_traces_sha256: $clang_sha256,
              gcc_c_traces_sha256: $gcc_sha256
            },
            compilers: {clang: $clang, gcc: $gcc},
            gates: {
              haskell_lean_equal: true,
              haskell_clang_c_equal: true,
              haskell_gcc_c_equal: true,
              exactly_once_cancellation_checked: true
            }
          }' > "$corpus/differential-evidence.json"

        mkdir -p "$out"
        cp "$corpus/index.json" "$corpus/haskell-traces.txt" \
          "$corpus/lean-traces.txt" "$corpus/c-traces.txt" \
          "$corpus/gcc-traces.txt" "$corpus/differential-evidence.json" "$out/"
        echo "Haskell/Lean/clang-C/GCC-C agreement over $scenarios scenarios" > "$out/status.txt"
      '';
    cortexWireAssurance =
      pkgs.runCommand "cortex-wire-cfat-1-assurance" {
        nativeBuildInputs = [pkgs.jq];
      } ''
        jq -n \
          --arg schema "cortex.cfat-assurance/v1" \
          --arg theory_store_path "${cortexTheory}" \
          --arg compiler_store_path "${cortexWireC}" \
          --arg smoke_store_path "${cortexWireCSmoke}" \
          --arg differential_store_path "${cortexWireDifferential}" \
          --slurpfile smoke ${cortexWireCSmoke}/smoke-evidence.json \
          --slurpfile differential ${cortexWireDifferential}/differential-evidence.json \
          '{
            schema: $schema,
            classification: {
              theory: "machine-checked Lean proofs for the existing StaticC local operators",
              differential: "exhaustively checked to the recorded bounded topology corpus",
              c_hygiene: "compiled, instrumented, reproducibility-checked, and object-audited",
              assumed: [
                "whole-drive refinement to StaticC",
                "Haskell lowering exactness beyond tested correspondence",
                "C compiler semantic preservation",
                "assembler, linker, loader, OS, adapter effects, devices, and hardware"
              ]
            },
            nix_store_paths: {
              theory: $theory_store_path,
              compiler: $compiler_store_path,
              smoke: $smoke_store_path,
              differential: $differential_store_path
            },
            smoke: $smoke[0],
            differential: $differential[0],
            gates: {
              theory_build: true,
              compiler_build: true,
              smoke_and_object_assurance:
                (($smoke[0].gates | length) > 0 and ($smoke[0].gates | to_entries | all(.value == true))),
              bounded_multi_implementation_differential:
                (($differential[0].gates | length) > 0
                  and ($differential[0].gates | to_entries | all(.value == true)))
            }
          }' > "$TMPDIR/evidence.json"
        mkdir -p "$out"
        cp "$TMPDIR/evidence.json" "$out/"
      '';
  in {
    packages.cortex-theory = cortexTheory;
    packages.cortex-wire-c = cortexWireC;
    packages.cortex-wire-diff = cortexWireDiff;

    checks.cortex-theory = cortexTheory;
    checks.cortex-wire-c = cortexWireC;
    checks.cortex-wire-c-smoke = cortexWireCSmoke;
    checks.cortex-wire-differential = cortexWireDifferential;
    checks.cortex-wire-cfat-1-assurance = cortexWireAssurance;
  };
}
