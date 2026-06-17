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

    wire-quantum-qec-repetition = pkgs.writeShellApplication {
      name = "wire-quantum-qec-repetition";
      text = ''
        set -euo pipefail
        if [ "$#" -ne 1 ] || [ "$1" != "--confirm-hardware" ]; then
          echo "usage: wire-quantum-qec-repetition --confirm-hardware" >&2
          echo "runs four selected QEC repetition-code circuit graphs as IBM Runtime REST hardware jobs" >&2
          exit 64
        fi
        export PATH="${wire-quantum-ibm-rest}/bin:$PATH"
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
        export PATH="${wire-quantum-ibm-rest}/bin:$PATH"
        exec ${config.packages.wire}/bin/wire run examples/wire/quantum-eraser-experiment.wire
      '';
    };
  in {
    packages =
      {
        wire-quantum-ibm-rest = wire-quantum-ibm-rest;
        wire-quantum-eraser = wire-quantum-eraser;
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
        wire-quantum-eraser = {
          type = "app";
          program = "${wire-quantum-eraser}/bin/wire-quantum-eraser";
          meta.description = "Run the delayed-choice quantum eraser Wire sweep on IBM Runtime REST hardware";
        };
        wire-quantum-qec-repetition = {
          type = "app";
          program = "${wire-quantum-qec-repetition}/bin/wire-quantum-qec-repetition";
          meta.description = "Run the distance-3 repetition-code QEC workbench on IBM Runtime REST hardware";
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
