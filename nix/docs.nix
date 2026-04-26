# Cortex documentation site — served at the repo root (/).
#
# Outputs: packages.docs-site, apps.docs-{dev,preview}.
{
  perSystem = {...}: {
    docsSite = {
      enable = true;

      # The Cortex research wiki: architecture, ADRs, reference specs,
      # publications, research notes. This is the sole site in this repo;
      # it sits at routeBase "/" (not "/cortex" as in the Portman monorepo).
      sites.default = {
        contentDir = ../docs;
        theme = "cortex-light";

        # Templates are authoring skeletons with placeholder frontmatter
        # that intentionally fails the content schema. Exclude them.
        excludePaths = ["Templates"];

        site = {
          title = "Cortex";
          tagline = "Research wiki";
          description = "Cortex engineering specifications, ADRs, research notes, and publications";
          publicBaseUrl = "https://crispy-barnacle-j1kepz8.pages.github.io";
          routeBase = "/";
        };

        repo = {
          repoUrl = "https://github.com/Digimuoto/cortex";
        };

        # Drop the auto-generated "Overview" eyebrow; the root index,
        # glossary, taxonomy, and map.md read better as a flush list.
        navigation.rootSectionLabel = null;

        # NOTE: Wire grammar registration is currently disabled because
        # repo-docs' WASM compilation step downloads wasi-sdk from the
        # network mid-build, which the nix build sandbox blocks. Re-enable
        # once repo-docs ships a sandbox-friendly path (e.g. wasi-sdk
        # provided as a fixed-output derivation or pre-bundled binary).
        # languages.wire = {
        #   grammarSrc = ../editors/tree-sitter-wire;
        # };
      };
    };
  };
}
