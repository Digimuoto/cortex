{ system
  , compiler
  , flags
  , pkgs
  , hsPkgs
  , pkgconfPkgs
  , errorHandler
  , config
  , ... }:
  {
    flags = {};
    package = {
      specVersion = "3.0";
      identifier = { name = "cortex"; version = "0.1.0.0"; };
      license = "Apache-2.0";
      copyright = "2026 Digimuoto Oy";
      maintainer = "julius.koskela@digimuoto.com";
      author = "Julius Koskela";
      homepage = "";
      url = "";
      synopsis = "Durable runtime substrate for typed dataflow programs";
      description = "Cortex is a durable runtime substrate for typed-dataflow programs:\nGraph algebra, Circuit validation, Wire source language, Pulse\nexecutor, memory substrate, and capability abstractions.";
      buildType = "Simple";
      isLocal = true;
      detailLevel = "FullDetails";
      licenseFiles = [ "LICENSE" ];
      dataDir = ".";
      dataFiles = [];
      extraSrcFiles = [ "README.md" "NOTICE" ];
      extraTmpFiles = [];
      extraDocFiles = [];
    };
    components = {
      "library" = {
        depends = [
          (hsPkgs."base" or (errorHandler.buildDepError "base"))
          (hsPkgs."text" or (errorHandler.buildDepError "text"))
          (hsPkgs."bytestring" or (errorHandler.buildDepError "bytestring"))
          (hsPkgs."deepseq" or (errorHandler.buildDepError "deepseq"))
          (hsPkgs."base16-bytestring" or (errorHandler.buildDepError "base16-bytestring"))
          (hsPkgs."base64-bytestring" or (errorHandler.buildDepError "base64-bytestring"))
          (hsPkgs."uuid" or (errorHandler.buildDepError "uuid"))
          (hsPkgs."uuid-types" or (errorHandler.buildDepError "uuid-types"))
          (hsPkgs."time" or (errorHandler.buildDepError "time"))
          (hsPkgs."scientific" or (errorHandler.buildDepError "scientific"))
          (hsPkgs."containers" or (errorHandler.buildDepError "containers"))
          (hsPkgs."vector" or (errorHandler.buildDepError "vector"))
          (hsPkgs."insert-ordered-containers" or (errorHandler.buildDepError "insert-ordered-containers"))
          (hsPkgs."unordered-containers" or (errorHandler.buildDepError "unordered-containers"))
          (hsPkgs."mtl" or (errorHandler.buildDepError "mtl"))
          (hsPkgs."transformers" or (errorHandler.buildDepError "transformers"))
          (hsPkgs."exceptions" or (errorHandler.buildDepError "exceptions"))
          (hsPkgs."async" or (errorHandler.buildDepError "async"))
          (hsPkgs."stm" or (errorHandler.buildDepError "stm"))
          (hsPkgs."random" or (errorHandler.buildDepError "random"))
          (hsPkgs."unix" or (errorHandler.buildDepError "unix"))
          (hsPkgs."filepath" or (errorHandler.buildDepError "filepath"))
          (hsPkgs."directory" or (errorHandler.buildDepError "directory"))
          (hsPkgs."temporary" or (errorHandler.buildDepError "temporary"))
          (hsPkgs."process" or (errorHandler.buildDepError "process"))
          (hsPkgs."aeson" or (errorHandler.buildDepError "aeson"))
          (hsPkgs."aeson-pretty" or (errorHandler.buildDepError "aeson-pretty"))
          (hsPkgs."yaml" or (errorHandler.buildDepError "yaml"))
          (hsPkgs."rel8" or (errorHandler.buildDepError "rel8"))
          (hsPkgs."hasql" or (errorHandler.buildDepError "hasql"))
          (hsPkgs."hasql-pool" or (errorHandler.buildDepError "hasql-pool"))
          (hsPkgs."hasql-transaction" or (errorHandler.buildDepError "hasql-transaction"))
          (hsPkgs."resource-pool" or (errorHandler.buildDepError "resource-pool"))
          (hsPkgs."openapi3" or (errorHandler.buildDepError "openapi3"))
          (hsPkgs."http-types" or (errorHandler.buildDepError "http-types"))
          (hsPkgs."wai" or (errorHandler.buildDepError "wai"))
          (hsPkgs."warp" or (errorHandler.buildDepError "warp"))
          (hsPkgs."crypton" or (errorHandler.buildDepError "crypton"))
          (hsPkgs."memory" or (errorHandler.buildDepError "memory"))
          (hsPkgs."optparse-applicative" or (errorHandler.buildDepError "optparse-applicative"))
          (hsPkgs."ansi-terminal" or (errorHandler.buildDepError "ansi-terminal"))
          (hsPkgs."prettyprinter" or (errorHandler.buildDepError "prettyprinter"))
          (hsPkgs."template-haskell" or (errorHandler.buildDepError "template-haskell"))
          (hsPkgs."lens" or (errorHandler.buildDepError "lens"))
          (hsPkgs."microlens" or (errorHandler.buildDepError "microlens"))
          (hsPkgs."microlens-th" or (errorHandler.buildDepError "microlens-th"))
          (hsPkgs."fast-logger" or (errorHandler.buildDepError "fast-logger"))
          (hsPkgs."monad-logger" or (errorHandler.buildDepError "monad-logger"))
          (hsPkgs."configurator" or (errorHandler.buildDepError "configurator"))
          (hsPkgs."haskell-platform" or (errorHandler.buildDepError "haskell-platform"))
          (hsPkgs."megaparsec" or (errorHandler.buildDepError "megaparsec"))
        ];
        buildable = true;
        modules = [
          "Paths_cortex"
          "Cortex/Wire/AST"
          "Cortex/Wire/Contracts"
          "Cortex/Wire/NodeBoundary"
          "Cortex/Wire/Proposal"
          "Cortex/Wire/Runtime"
          "Cortex/Wire/Value"
          "Cortex"
          "Cortex/Algebra"
          "Cortex/Algebra/Graph"
          "Cortex/Algebra/Graph/Core"
          "Cortex/Algebra/Graph/Decompose"
          "Cortex/Algebra/Graph/Influence"
          "Cortex/Algebra/Graph/Modify"
          "Cortex/Algebra/Graph/Mokhov"
          "Cortex/Algebra/Graph/Search"
          "Cortex/Algebra/Graph/Validate"
          "Cortex/Capability"
          "Cortex/Capability/Executor"
          "Cortex/Capability/Executor/Pure"
          "Cortex/Pulse"
          "Cortex/Pulse/Attempt"
          "Cortex/Pulse/Checkpoint"
          "Cortex/Pulse/Database"
          "Cortex/Pulse/Event"
          "Cortex/Pulse/Executor"
          "Cortex/Pulse/Executor/Attempt"
          "Cortex/Pulse/Executor/Events"
          "Cortex/Pulse/Executor/Frontier"
          "Cortex/Pulse/Executor/Loop"
          "Cortex/Pulse/Executor/Outcome"
          "Cortex/Pulse/Executor/Persistence"
          "Cortex/Pulse/Executor/ReplayPolicy"
          "Cortex/Pulse/Executor/Resume"
          "Cortex/Pulse/Executor/Types"
          "Cortex/Pulse/Frontier"
          "Cortex/Pulse/GraphStateRevision"
          "Cortex/Pulse/Hydrate"
          "Cortex/Pulse/Materialize"
          "Cortex/Pulse/Outcome"
          "Cortex/Pulse/Persistence"
          "Cortex/Pulse/Replay"
          "Cortex/Pulse/Resume"
          "Cortex/Pulse/Runtime"
          "Cortex/Wire"
          "Cortex/Wire/Compile"
          "Cortex/Wire/Contract"
          "Cortex/Wire/Executor"
          "Cortex/Wire/Parser"
          "Cortex/Wire/Pure"
          "Cortex/Wire/Std"
          "Cortex/Wire/Syntax"
          "Cortex/Wire/Use"
          "Cortex/Wire/Circuit"
          "Cortex/Wire/Circuit/Artifact"
          "Cortex/Wire/Circuit/Compile"
          "Cortex/Wire/Circuit/Compiled"
          "Cortex/Wire/Circuit/Compiler"
          "Cortex/Wire/Circuit/IR"
          "Cortex/Wire/Circuit/Lower"
          "Cortex/Wire/Circuit/Lowering"
          "Cortex/Wire/Circuit/Node"
          "Cortex/Wire/Circuit/NodeKind"
          "Cortex/Pulse/GraphRuntime"
          "Cortex/Pulse/Health"
          "Cortex/Pulse/Materialization"
          "Cortex/Pulse/Memory"
          "Cortex/Pulse/Memory/Query"
          "Cortex/Pulse/Memory/Score"
          "Cortex/Pulse/Memory/Tool"
          "Cortex/Pulse/Memory/Types"
          "Cortex/Pulse/Memory/Walk"
          "Cortex/Pulse/Node"
          "Cortex/Pulse/Plan"
          "Cortex/Pulse/PlanHydration"
          "Cortex/Pulse/Query"
          "Cortex/Pulse/Rewrite"
          "Cortex/Pulse/Schema"
          "Cortex/Pulse/Signal"
          "Cortex/Pulse/Scheduler"
          "Cortex/Pulse/Types"
        ];
        hsSourceDirs = [ "src" ];
      };
      exes = {
        "cortex-pulse" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."cortex" or (errorHandler.buildDepError "cortex"))
            (hsPkgs."haskell-platform" or (errorHandler.buildDepError "haskell-platform"))
            (hsPkgs."optparse-applicative" or (errorHandler.buildDepError "optparse-applicative"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."bytestring" or (errorHandler.buildDepError "bytestring"))
            (hsPkgs."containers" or (errorHandler.buildDepError "containers"))
          ];
          buildable = true;
          hsSourceDirs = [ "app/cortex-pulse" ];
          mainPath = [ "Main.hs" ];
        };
        "wire" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."cortex" or (errorHandler.buildDepError "cortex"))
            (hsPkgs."aeson" or (errorHandler.buildDepError "aeson"))
            (hsPkgs."aeson-pretty" or (errorHandler.buildDepError "aeson-pretty"))
            (hsPkgs."async" or (errorHandler.buildDepError "async"))
            (hsPkgs."bytestring" or (errorHandler.buildDepError "bytestring"))
            (hsPkgs."containers" or (errorHandler.buildDepError "containers"))
            (hsPkgs."process" or (errorHandler.buildDepError "process"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
          ];
          buildable = true;
          hsSourceDirs = [ "app/wire" ];
          mainPath = [ "Main.hs" ];
        };
      };
      tests = {
        "cortex-test" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."cortex" or (errorHandler.buildDepError "cortex"))
            (hsPkgs."haskell-platform" or (errorHandler.buildDepError "haskell-platform"))
            (hsPkgs."hspec" or (errorHandler.buildDepError "hspec"))
            (hsPkgs."hspec-discover" or (errorHandler.buildDepError "hspec-discover"))
            (hsPkgs."HUnit" or (errorHandler.buildDepError "HUnit"))
            (hsPkgs."QuickCheck" or (errorHandler.buildDepError "QuickCheck"))
            (hsPkgs."hedgehog" or (errorHandler.buildDepError "hedgehog"))
            (hsPkgs."aeson" or (errorHandler.buildDepError "aeson"))
            (hsPkgs."aeson-qq" or (errorHandler.buildDepError "aeson-qq"))
            (hsPkgs."hasql" or (errorHandler.buildDepError "hasql"))
            (hsPkgs."hasql-pool" or (errorHandler.buildDepError "hasql-pool"))
            (hsPkgs."hasql-transaction" or (errorHandler.buildDepError "hasql-transaction"))
            (hsPkgs."rel8" or (errorHandler.buildDepError "rel8"))
            (hsPkgs."postgresql-simple" or (errorHandler.buildDepError "postgresql-simple"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."bytestring" or (errorHandler.buildDepError "bytestring"))
            (hsPkgs."time" or (errorHandler.buildDepError "time"))
            (hsPkgs."containers" or (errorHandler.buildDepError "containers"))
            (hsPkgs."uuid" or (errorHandler.buildDepError "uuid"))
            (hsPkgs."uuid-types" or (errorHandler.buildDepError "uuid-types"))
            (hsPkgs."scientific" or (errorHandler.buildDepError "scientific"))
            (hsPkgs."raw-strings-qq" or (errorHandler.buildDepError "raw-strings-qq"))
            (hsPkgs."mtl" or (errorHandler.buildDepError "mtl"))
            (hsPkgs."transformers" or (errorHandler.buildDepError "transformers"))
            (hsPkgs."filepath" or (errorHandler.buildDepError "filepath"))
            (hsPkgs."directory" or (errorHandler.buildDepError "directory"))
            (hsPkgs."stm" or (errorHandler.buildDepError "stm"))
            (hsPkgs."async" or (errorHandler.buildDepError "async"))
          ];
          build-tools = [
            (hsPkgs.pkgsBuildBuild.hspec-discover.components.exes.hspec-discover or (pkgs.pkgsBuildBuild.hspec-discover or (errorHandler.buildToolDepError "hspec-discover:hspec-discover")))
          ];
          buildable = true;
          modules = [
            "Cortex/Algebra/GraphSpec"
            "Cortex/CanonicalModuleTreeSpec"
            "Cortex/Capability/Executor/PureSpec"
            "Cortex/PublicPreludeSpec"
            "Cortex/Pulse/CheckpointSpec"
            "Cortex/Pulse/RewriteAnchorValidationSpec"
            "Cortex/Pulse/RewriteRetryHydrationSpec"
            "Cortex/Pulse/StageTemplateRegistrySpec"
            "Cortex/Pulse/Executor/EventsSpec"
            "Cortex/Pulse/ExecutorSpec"
            "Cortex/Pulse/GraphRewriteSpec"
            "Cortex/Pulse/MemoryIntegrationSpec"
            "Cortex/Pulse/MemorySpec"
            "Cortex/Pulse/MemoryToolSpec"
            "Cortex/Pulse/SchedulerSpec"
            "Cortex/Pulse/TypesSpec"
            "Cortex/TestSupport/Database"
            "Cortex/Wire/Circuit/CompilerSpec"
            "Cortex/Wire/Circuit/IRSpec"
            "Cortex/Wire/CompileSpec"
            "Cortex/Wire/ParserSpec"
            "Cortex/Wire/PureSpec"
            "Cortex/Wire/RuntimeSpec"
          ];
          hsSourceDirs = [ "test" ];
          mainPath = [ "Spec.hs" ];
        };
      };
      benchmarks = {
        "pure-wire-bench" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."cortex" or (errorHandler.buildDepError "cortex"))
            (hsPkgs."aeson" or (errorHandler.buildDepError "aeson"))
            (hsPkgs."containers" or (errorHandler.buildDepError "containers"))
            (hsPkgs."criterion" or (errorHandler.buildDepError "criterion"))
            (hsPkgs."deepseq" or (errorHandler.buildDepError "deepseq"))
            (hsPkgs."scientific" or (errorHandler.buildDepError "scientific"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."vector" or (errorHandler.buildDepError "vector"))
          ];
          buildable = true;
          hsSourceDirs = [ "bench/pure-wire" ];
        };
      };
    };
  } // rec { src = pkgs.lib.mkDefault ../.; }