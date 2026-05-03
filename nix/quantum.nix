{...}: {
  perSystem = {
    config,
    pkgs,
    ...
  }: let
    qiskitPython =
      pkgs.python313.withPackages
      (ps: [
        ps.qiskit
        ps.qiskit-aer
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

    wire-quantum-eraser = pkgs.writeShellApplication {
      name = "wire-quantum-eraser";
      text = ''
        set -euo pipefail
        wire_file="examples/wire/quantum-eraser-round.wire"
        if [ "$#" -gt 0 ] && [ -f "$1" ]; then
          wire_file="$1"
          shift
        fi
        exec ${wire-quantum-qiskit}/bin/wire-quantum-qiskit "$wire_file" "$@"
      '';
    };
  in {
    packages = {
      wire-quantum-qiskit = wire-quantum-qiskit;
      wire-quantum-ibm-rest = wire-quantum-ibm-rest;
      wire-quantum-ipea = wire-quantum-ipea;
      wire-quantum-eraser = wire-quantum-eraser;
    };

    apps = {
      wire-quantum-qiskit = {
        type = "app";
        program = "${wire-quantum-qiskit}/bin/wire-quantum-qiskit";
        meta.description = "Run Wire quantum examples through a local Qiskit Aer simulator";
      };
      wire-quantum-ibm-rest = {
        type = "app";
        program = "${wire-quantum-ibm-rest}/bin/wire-quantum-ibm-rest";
        meta.description = "Submit Wire quantum examples to IBM Quantum Runtime REST";
      };
      wire-quantum-ipea = {
        type = "app";
        program = "${wire-quantum-ipea}/bin/wire-quantum-ipea";
        meta.description = "Run iterative phase estimation as composed Wire quantum rounds";
      };
      wire-quantum-eraser = {
        type = "app";
        program = "${wire-quantum-eraser}/bin/wire-quantum-eraser";
        meta.description = "Run the checked-in delayed-choice quantum eraser Wire circuit";
      };
    };
  };
}
