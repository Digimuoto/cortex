# Cortex documentation site — served at the repo root (/).
#
# Outputs: packages.docs-site, apps.docs-{dev,preview}.
{
  perSystem = {config, ...}: {
    docsSite = {
      enable = true;

      # The Cortex research wiki: architecture, ADRs, reference specs,
      # publications, research notes. This is the sole site in this repo,
      # so it sits at routeBase "/".
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

        navigation = {
          # Drop the auto-generated "Overview" eyebrow; the root index,
          # glossary, taxonomy, and map.md read better as a flush list.
          rootSectionLabel = null;

          # Keep top-level IA semantic instead of relying on alphabetical
          # folder order. Nested sections mostly carry their own numbered or
          # frontmatter order.
          topLevelOrder = [
            "Architecture"
            "Reference"
            "ADRs"
            "Consumers"
            "Publications"
            "Roadmap"
            "Research-notes"
            "Experiments"
          ];
        };

        languages.wire = {
          grammarSrc = ../editors/tree-sitter-wire;
        };

        lean4.theoryDir = "theory";

        haskell.packages.cortex = {
          packageDir = ".";
          packageName = "cortex";
          modulePrefixes = ["Cortex"];
          title = "Cortex Haskell API";
          description = "Generated Haddock documentation for the Cortex Haskell package.";
        };

        typst.manuscripts = {
          paper1.dir = "Publications/Paper-1-staged-reduction/typst";
          paper2.dir = "Publications/Paper-2-algebraic-foundations/typst";
          paper3.dir = "Publications/Paper-3-graph-substitution-semantics/typst";
          paper4.dir = "Publications/Paper-4-wire-language/typst";
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
