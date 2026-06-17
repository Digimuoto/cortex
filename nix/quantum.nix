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

    wire-quantum-qiskit = pkgs.writeShellApplication {
      name = "wire-quantum-qiskit";
      text = ''
        set -euo pipefail
        exec ${qiskitPython}/bin/python ${../scripts/wire-quantum-qiskit.py} \
          --wire-bin ${config.packages.wire}/bin/wire \
          "$@"
      '';
    };

    wire-quantum-ibm-rest = pkgs.writeShellApplication {
      name = "wire-quantum-ibm-rest";
      text = ''
        set -euo pipefail
        scripts_dir="${../scripts}"
        exec ${pkgs.python313}/bin/python "$scripts_dir/wire-quantum-ibm-rest.py" \
          --wire-bin ${config.packages.wire}/bin/wire \
          "$@"
      '';
    };

    wire-quantum-braket = pkgs.writeShellApplication {
      name = "wire-quantum-braket";
      text = ''
        set -euo pipefail
        scripts_dir="${../scripts}"
        exec ${pkgs.python313}/bin/python "$scripts_dir/wire-quantum-braket.py" \
          --wire-bin ${config.packages.wire}/bin/wire \
          --aws-bin ${pkgs.awscli2}/bin/aws \
          "$@"
      '';
    };

    wire-quantum-runner-ibm = pkgs.writeShellApplication {
      name = "wire-quantum-runner";
      text = ''
        set -euo pipefail
        exec ${wire-quantum-ibm-rest}/bin/wire-quantum-ibm-rest "$@"
      '';
    };

    wire-quantum-runner-braket = pkgs.writeShellApplication {
      name = "wire-quantum-runner";
      text = ''
        set -euo pipefail
        exec ${wire-quantum-braket}/bin/wire-quantum-braket "$@"
      '';
    };

    wire-quantum-ipea = pkgs.writeShellApplication {
      name = "wire-quantum-ipea";
      text = ''
        set -euo pipefail
        scripts_dir="${../scripts}"
        exec ${qiskitPython}/bin/python "$scripts_dir/wire-quantum-ipea.py" \
          --wire-bin ${config.packages.wire}/bin/wire \
          "$@"
      '';
    };

    wire-quantum-ipea-braket = pkgs.writeShellApplication {
      name = "wire-quantum-ipea-braket";
      text = ''
        set -euo pipefail
        scripts_dir="${../scripts}"
        exec ${pkgs.python313}/bin/python "$scripts_dir/wire-quantum-ipea.py" \
          --wire-bin ${config.packages.wire}/bin/wire \
          --aws-bin ${pkgs.awscli2}/bin/aws \
          --hardware \
          --provider braket \
          "$@"
      '';
    };

    wire-quantum-qec-repetition = pkgs.writeShellApplication {
      name = "wire-quantum-qec-repetition";
      text = ''
        set -euo pipefail
        if [ "$#" -ne 1 ] || [ "$1" != "--confirm-hardware" ]; then
          echo "usage: wire-quantum-qec-repetition --confirm-hardware" >&2
          echo "runs four selected QEC repetition-code circuit graphs as IBM Runtime REST hardware jobs" >&2
          exit 64
        fi
        export PATH="${wire-quantum-runner-ibm}/bin:${wire-quantum-ibm-rest}/bin:$PATH"
        exec ${config.packages.wire}/bin/wire run examples/wire/qec-repetition-code-forced-errors.wire
      '';
    };

    wire-quantum-qec-repetition-braket = pkgs.writeShellApplication {
      name = "wire-quantum-qec-repetition-braket";
      text = ''
        set -euo pipefail
        if [ "$#" -ne 1 ] || [ "$1" != "--confirm-hardware" ]; then
          echo "usage: wire-quantum-qec-repetition-braket --confirm-hardware" >&2
          echo "runs four selected QEC repetition-code circuit graphs as Amazon Braket tasks" >&2
          exit 64
        fi
        export PATH="${wire-quantum-runner-braket}/bin:${wire-quantum-braket}/bin:$PATH"
        exec ${config.packages.wire}/bin/wire run examples/wire/qec-repetition-code-forced-errors.wire
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
        export PATH="${wire-quantum-runner-ibm}/bin:${wire-quantum-ibm-rest}/bin:$PATH"
        exec ${config.packages.wire}/bin/wire run examples/wire/quantum-eraser-experiment.wire
      '';
    };

    wire-quantum-eraser-braket = pkgs.writeShellApplication {
      name = "wire-quantum-eraser-braket";
      text = ''
        set -euo pipefail
        if [ "$#" -ne 1 ] || [ "$1" != "--confirm-hardware" ]; then
          echo "usage: wire-quantum-eraser-braket --confirm-hardware" >&2
          echo "runs nine selected circuit graphs from examples/wire/quantum-eraser-experiment.wire as Amazon Braket tasks" >&2
          exit 64
        fi
        export PATH="${wire-quantum-runner-braket}/bin:${wire-quantum-braket}/bin:$PATH"
        exec ${config.packages.wire}/bin/wire run examples/wire/quantum-eraser-experiment.wire
      '';
    };
  in {
    packages =
      {
        wire-quantum-braket = wire-quantum-braket;
        wire-quantum-ibm-rest = wire-quantum-ibm-rest;
        wire-quantum-eraser-braket = wire-quantum-eraser-braket;
        wire-quantum-eraser = wire-quantum-eraser;
        wire-quantum-ipea-braket = wire-quantum-ipea-braket;
        wire-quantum-qec-repetition-braket = wire-quantum-qec-repetition-braket;
        wire-quantum-qec-repetition = wire-quantum-qec-repetition;
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
          meta.description = "Submit Wire quantum examples to Amazon Braket OpenQASM";
        };
        wire-quantum-eraser = {
          type = "app";
          program = "${wire-quantum-eraser}/bin/wire-quantum-eraser";
          meta.description = "Run the delayed-choice quantum eraser Wire sweep on IBM Runtime REST hardware";
        };
        wire-quantum-eraser-braket = {
          type = "app";
          program = "${wire-quantum-eraser-braket}/bin/wire-quantum-eraser-braket";
          meta.description = "Run the delayed-choice quantum eraser Wire sweep on Amazon Braket";
        };
        wire-quantum-ipea-braket = {
          type = "app";
          program = "${wire-quantum-ipea-braket}/bin/wire-quantum-ipea-braket";
          meta.description = "Run iterative phase estimation as Amazon Braket tasks";
        };
        wire-quantum-qec-repetition = {
          type = "app";
          program = "${wire-quantum-qec-repetition}/bin/wire-quantum-qec-repetition";
          meta.description = "Run the distance-3 repetition-code QEC workbench on IBM Runtime REST hardware";
        };
        wire-quantum-qec-repetition-braket = {
          type = "app";
          program = "${wire-quantum-qec-repetition-braket}/bin/wire-quantum-qec-repetition-braket";
          meta.description = "Run the distance-3 repetition-code QEC workbench on Amazon Braket";
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
