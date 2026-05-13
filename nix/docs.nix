# Cortex documentation site — deployed as a GitHub Pages project site.
#
# Outputs: packages.docs-site, apps.docs-{dev,preview}.
{
  perSystem = {
    config,
    pkgs,
    ...
  }: {
    docsSite = {
      enable = true;

      # The Cortex research wiki: architecture, ADRs, reference specs,
      # publications, research notes. GitHub Pages serves the repository
      # artifact under /cortex, so generated routes and asset URLs must
      # carry that route base even though the docs source tree is flat.
      sites.default = {
        contentDir = ../docs;
        theme = "cortex-light";
        themeModes = {
          light = "cortex-light";
          dark = "cortex-slate-darker";
        };

        # Templates are authoring skeletons with placeholder frontmatter
        # that intentionally fails the content schema. Exclude them.
        excludePaths = ["Templates"];

        site = {
          title = "Cortex";
          tagline = "Research wiki";
          description = "Cortex engineering specifications, ADRs, research notes, and publications";
          publicBaseUrl = "https://digimuoto.github.io/cortex";
          routeBase = "/cortex";
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
            "Usage"
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
          paper6.dir = "Publications/Paper-6-executable-diagrams/typst";
        };
      };
    };

    packages.paper6-executable-diagrams-renderings = pkgs.stdenvNoCC.mkDerivation {
      pname = "paper6-executable-diagrams-renderings";
      version = "2026-05-08";
      src = ../.;
      nativeBuildInputs = [pkgs.typst];
      dontConfigure = true;
      dontFixup = true;
      buildPhase = ''
        runHook preBuild
        typst compile --root "$PWD" \
          docs/Publications/Paper-6-executable-diagrams/typst/manuscript.typ \
          paper6-executable-diagrams.pdf
        typst compile --root "$PWD" \
          docs/Publications/Paper-6-executable-diagrams/Figures/executable-diagram-layers.typ \
          executable-diagram-layers.pdf
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        cp paper6-executable-diagrams.pdf "$out/"
        cp executable-diagram-layers.pdf "$out/"
        runHook postInstall
      '';
    };

    packages.papers-renderings = pkgs.symlinkJoin {
      name = "cortex-paper-renderings";
      paths = [
        config.packages.paper6-executable-diagrams-renderings
      ];
    };

    packages.docs-site = config.packages.default-site;

    apps = {
      docs-dev = config.apps.default-dev;
      docs-preview = config.apps.default-preview;
    };
  };
}
