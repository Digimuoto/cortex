# Cortex documentation site — served at the repo root (/).
#
# Outputs: packages.docs-site, apps.docs-{dev,preview}.
{
  perSystem = {config, ...}: {
    docsSite = {
      enable = true;

      # The Cortex research wiki: architecture, ADRs, reference specs,
      # publications, research notes. This is the sole site in this repo;
      # it sits at routeBase "/" (not "/cortex" as in the Portman monorepo).
      sites.default = {
        contentDir = ../docs;
        theme = "cortex-light";
        themeModes = {
          light = "cortex-light";
          dark = "cortex-slate";
        };

        # Templates are authoring skeletons with placeholder frontmatter
        # that intentionally fails the content schema. Exclude them.
        excludePaths = ["Templates"];

        site = {
          title = "Cortex";
          tagline = "Research wiki";
          description = "Cortex engineering specifications, ADRs, research notes, and publications";
          publicBaseUrl = "https://digimuoto.github.io/cortex";
          routeBase = "/";
        };

        repo = {
          repoUrl = "https://github.com/Digimuoto/cortex";
        };

        # Drop the auto-generated "Overview" eyebrow; the root index,
        # glossary, taxonomy, and map.md read better as a flush list.
        navigation.rootSectionLabel = null;

        languages.wire = {
          grammarSrc = ../editors/tree-sitter-wire;
        };
      };
    };

    packages.docs-site = config.packages.default-site;

    apps = {
      docs-dev = config.apps.default-dev;
      docs-preview = config.apps.default-preview;
    };
  };
}
