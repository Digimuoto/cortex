{lib, ...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    qiskitAer = pkgs.python313Packages.qiskit-aer;
    qiskitSupported = !(qiskitAer.meta.broken or false);

    qiskitPython =
      pkgs.python313.withPackages
      (ps: [
        ps.qiskit
        qiskitAer
      ]);

    # The wire CLI defaults to Cortex's standard namespaces only (ADR 0060): the
    # quantum showcase packages are opt-in. These runners therefore select the
    # in-tree quantum manifests explicitly via CORTEX_WIRE_PACKAGE_MANIFESTS so
    # `use quantum.*` resolves regardless of the working directory.
    quantumWirePackages = lib.concatStringsSep ":" [
      "${../extensions/quantum/packages/quantum-core/cortex.toml}"
      "${../extensions/quantum/packages/quantum-qec/cortex.toml}"
      "${../extensions/quantum/packages/quantum-braket/cortex.toml}"
    ];

    wire-quantum-qiskit = pkgs.writeShellApplication {
      name = "wire-quantum-qiskit";
      text = ''
        set -euo pipefail
        export CORTEX_WIRE_PACKAGE_MANIFESTS="${quantumWirePackages}"
        exec ${qiskitPython}/bin/python ${../scripts/wire-quantum-qiskit.py} \
          --wire-bin ${config.packages.wire}/bin/wire \
          "$@"
      '';
    };

    wire-quantum-ibm-rest = pkgs.writeShellApplication {
      name = "wire-quantum-ibm-rest";
      text = ''
        set -euo pipefail
        export CORTEX_WIRE_PACKAGE_MANIFESTS="${quantumWirePackages}"
        scripts_dir="${../scripts}"
        exec ${pkgs.python313}/bin/python "$scripts_dir/wire-quantum-ibm-rest.py" \
          --wire-bin ${config.packages.wire}/bin/wire \
          "$@"
      '';
    };

    # Native Wire -> Amazon Braket runner: a Haskell extension binary that compiles
    # the selected graph, lowers its @quantum.realize frontier, and submits OpenQASM
    # to Braket. The AWS CLI path is handed over via CORTEX_AWS_BIN; no Python.
    wire-quantum-braket = pkgs.writeShellApplication {
      name = "wire-quantum-braket";
      text = ''
        set -euo pipefail
        export CORTEX_WIRE_PACKAGE_MANIFESTS="${quantumWirePackages}"
        export CORTEX_AWS_BIN="${pkgs.awscli2}/bin/aws"
        exec ${config.packages.wire-quantum-braket-bin}/bin/wire-quantum-braket "$@"
      '';
    };

    wire-quantum-qec-repetition-braket = pkgs.writeShellApplication {
      name = "wire-quantum-qec-repetition-braket";
      text = ''
        set -euo pipefail
        export CORTEX_WIRE_PACKAGE_MANIFESTS="${quantumWirePackages}"
        export CORTEX_AWS_BIN="${pkgs.awscli2}/bin/aws"
        exec ${config.packages.wire-quantum-qec-repetition-braket-bin}/bin/wire-quantum-qec-repetition-braket "$@"
      '';
    };

    wire-quantum-ipea = pkgs.writeShellApplication {
      name = "wire-quantum-ipea";
      text = ''
        set -euo pipefail
        export CORTEX_WIRE_PACKAGE_MANIFESTS="${quantumWirePackages}"
        scripts_dir="${../scripts}"
        exec ${qiskitPython}/bin/python "$scripts_dir/wire-quantum-ipea.py" \
          --wire-bin ${config.packages.wire}/bin/wire \
          "$@"
      '';
    };

    wire-quantum-eraser = pkgs.writeShellApplication {
      name = "wire-quantum-eraser";
      text = ''
        set -euo pipefail
        if [ "$#" -ne 1 ] || [ "$1" != "--confirm-hardware" ]; then
          echo "usage: wire-quantum-eraser --confirm-hardware" >&2
          echo "runs nine selected circuit graphs from examples/wire/quantum-eraser-experiment.wire as IBM Runtime REST hardware jobs" >&2
          exit 64
        fi
        export PATH="${wire-quantum-ibm-rest}/bin:$PATH"
        export CORTEX_WIRE_PACKAGE_MANIFESTS="${quantumWirePackages}"
        exec ${config.packages.wire}/bin/wire run examples/wire/quantum-eraser-experiment.wire
      '';
    };
  in {
    packages =
      {
        wire-quantum-braket = wire-quantum-braket;
        wire-quantum-qec-repetition-braket = wire-quantum-qec-repetition-braket;
        wire-quantum-ibm-rest = wire-quantum-ibm-rest;
        wire-quantum-eraser = wire-quantum-eraser;
      }
      // lib.optionalAttrs qiskitSupported {
        wire-quantum-qiskit = wire-quantum-qiskit;
        wire-quantum-ipea = wire-quantum-ipea;
      };

    apps =
      {
        wire-quantum-ibm-rest = {
          type = "app";
          program = "${wire-quantum-ibm-rest}/bin/wire-quantum-ibm-rest";
          meta.description = "Submit Wire quantum examples to IBM Quantum Runtime REST";
        };
        wire-quantum-braket = {
          type = "app";
          program = "${wire-quantum-braket}/bin/wire-quantum-braket";
          meta.description = "Submit native Wire quantum examples to Amazon Braket OpenQASM";
        };
        wire-quantum-qec-repetition-braket = {
          type = "app";
          program = "${wire-quantum-qec-repetition-braket}/bin/wire-quantum-qec-repetition-braket";
          meta.description = "Run the native distance-3 repetition-code QEC example on Amazon Braket";
        };
        wire-quantum-eraser = {
          type = "app";
          program = "${wire-quantum-eraser}/bin/wire-quantum-eraser";
          meta.description = "Run the delayed-choice quantum eraser Wire sweep on IBM Runtime REST hardware";
        };
      }
      // lib.optionalAttrs qiskitSupported {
        wire-quantum-qiskit = {
          type = "app";
          program = "${wire-quantum-qiskit}/bin/wire-quantum-qiskit";
          meta.description = "Run Wire quantum examples through a local Qiskit Aer simulator";
        };
        wire-quantum-ipea = {
          type = "app";
          program = "${wire-quantum-ipea}/bin/wire-quantum-ipea";
          meta.description = "Run iterative phase estimation as composed Wire quantum rounds";
        };
      };
  };
}
