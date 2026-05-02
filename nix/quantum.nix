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
  in {
    packages = {
      wire-quantum-qiskit = wire-quantum-qiskit;
    };

    apps = {
      wire-quantum-qiskit = {
        type = "app";
        program = "${wire-quantum-qiskit}/bin/wire-quantum-qiskit";
        meta.description = "Run Wire quantum examples through a local Qiskit Aer simulator";
      };
    };
  };
}
