{
  provider,
  agents ?
    builtins.getFlake
    "github:Digimuoto/agents/88629e29bdc69d14bb9f295c55ba3e4e0e7f62d5",
  nixpkgs ? builtins.getFlake "github:NixOS/nixpkgs/nixos-unstable",
  system ? builtins.currentSystem,
}: let
  pkgs = nixpkgs.legacyPackages.${system};
  projectAgents = import ./agent-root.nix {inherit agents pkgs system;};
  agentEnv = agents.lib.${system}.mkProjectAgentEnv projectAgents;
  runtimePath = pkgs.lib.makeBinPath [
    pkgs.coreutils
    pkgs.gawk
    pkgs.git
  ];
  linkProvider = pkgs.lib.getExe agents.packages.${system}.link-provider;
in
  pkgs.writeShellScriptBin "agent-link-${provider}" ''
    export PATH=${runtimePath}:$PATH
    export AGENTS_SHARED_ROOT=${agents.outPath}
    export AGENTS_CONTEXT_PATH=${agentEnv.AGENTS_CONTEXT_PATH}
    export AGENTS_CONTEXT_MOUNTS_FILE=${agentEnv.AGENTS_CONTEXT_MOUNTS_FILE}
    export AGENTS_LOCAL_SKILLS_DIR=${agentEnv.AGENTS_LOCAL_SKILLS_DIR}
    export AGENTS_LOCAL_ARCHETYPES_DIR=${agentEnv.AGENTS_LOCAL_ARCHETYPES_DIR}
    exec ${linkProvider} ${provider} "$@"
  ''
