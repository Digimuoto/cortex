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
      maintainer = "julius@koskela.dev";
      author = "Julius Koskela";
      homepage = "";
      url = "";
      synopsis = "Durable AI runtime + structured reasoning substrate";
      description = "Cortex is a durable runtime substrate for typed-dataflow programs:\nGraph algebra, Circuit validation, Wire source language, Pulse\nexecutor, memory substrate, and capability abstractions. A structured\nreasoning library (Cortex.Nous) sits on top of the substrate and\ndepends on it, not the other way round (ADR 0015).";
      buildType = "Simple";
      isLocal = true;
      detailLevel = "FullDetails";
      licenseFiles = [ "LICENSE" ];
      dataDir = ".";
      dataFiles = [ "config/cortex/memory-ranking.yaml" ];
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
          (hsPkgs."retry" or (errorHandler.buildDepError "retry"))
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
          (hsPkgs."servant-server" or (errorHandler.buildDepError "servant-server"))
          (hsPkgs."servant-client-core" or (errorHandler.buildDepError "servant-client-core"))
          (hsPkgs."openapi3" or (errorHandler.buildDepError "openapi3"))
          (hsPkgs."http-client" or (errorHandler.buildDepError "http-client"))
          (hsPkgs."http-client-tls" or (errorHandler.buildDepError "http-client-tls"))
          (hsPkgs."http-api-data" or (errorHandler.buildDepError "http-api-data"))
          (hsPkgs."http-types" or (errorHandler.buildDepError "http-types"))
          (hsPkgs."case-insensitive" or (errorHandler.buildDepError "case-insensitive"))
          (hsPkgs."wai" or (errorHandler.buildDepError "wai"))
          (hsPkgs."warp" or (errorHandler.buildDepError "warp"))
          (hsPkgs."crypton" or (errorHandler.buildDepError "crypton"))
          (hsPkgs."memory" or (errorHandler.buildDepError "memory"))
          (hsPkgs."safe-money" or (errorHandler.buildDepError "safe-money"))
          (hsPkgs."safe-money-aeson" or (errorHandler.buildDepError "safe-money-aeson"))
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
          (hsPkgs."cmark-gfm" or (errorHandler.buildDepError "cmark-gfm"))
          (hsPkgs."cortex".components.sublibs.platform-runtime or (errorHandler.buildDepError "cortex:platform-runtime"))
          (hsPkgs."megaparsec" or (errorHandler.buildDepError "megaparsec"))
        ];
        buildable = true;
        modules = [
          "Paths_cortex"
          "Cortex/Nous/Types"
          "Cortex/Wire/AST"
          "Cortex/Wire/Contracts"
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
          "Cortex/Artifact"
          "Cortex/Artifact/Host"
          "Cortex/Artifact/IR"
          "Cortex/Artifact/Metadata"
          "Cortex/Capability"
          "Cortex/Capability/Executor"
          "Cortex/Capability/Model"
          "Cortex/Capability/Model/Client"
          "Cortex/Capability/Model/Message"
          "Cortex/Capability/Model/Output"
          "Cortex/Capability/Model/Types"
          "Cortex/Capability/Provider"
          "Cortex/Capability/Provider/OpenRouter"
          "Cortex/Capability/Provider/OpenRouter/Client"
          "Cortex/Capability/Provider/OpenRouter/Embedding"
          "Cortex/Capability/Provider/OpenRouter/Wire"
          "Cortex/Capability/StructuredOutput"
          "Cortex/Capability/Tool"
          "Cortex/Capability/Tool/Definition"
          "Cortex/Capability/Tool/Record"
          "Cortex/Nous"
          "Cortex/Nous/Archetypes"
          "Cortex/Nous/Archetypes/Episteme"
          "Cortex/Nous/Archetypes/Episteme/Activation"
          "Cortex/Nous/Archetypes/Kritikos"
          "Cortex/Nous/Archetypes/Kritikos/Activation"
          "Cortex/Nous/Archetypes/Logos"
          "Cortex/Nous/Archetypes/Logos/Activation"
          "Cortex/Nous/Archetypes/Poiesis"
          "Cortex/Nous/Archetypes/Poiesis/Activation"
          "Cortex/Nous/Archetypes/Sophia"
          "Cortex/Nous/Archetypes/Sophia/Activation"
          "Cortex/Nous/Archetypes/Techne"
          "Cortex/Nous/Archetypes/Techne/Activation"
          "Cortex/Nous/Archetypes/Themis"
          "Cortex/Nous/Archetypes/Themis/Activation"
          "Cortex/Nous/Memory"
          "Cortex/Nous/Memory/Candidate"
          "Cortex/Nous/Memory/Candidates"
          "Cortex/Nous/Memory/Compact"
          "Cortex/Nous/Memory/Conflict"
          "Cortex/Nous/Memory/Document"
          "Cortex/Nous/Memory/Host"
          "Cortex/Nous/Memory/Pack"
          "Cortex/Nous/Memory/Query"
          "Cortex/Nous/Memory/Rank"
          "Cortex/Nous/Memory/Retrieve"
          "Cortex/Nous/Memory/Source"
          "Cortex/Nous/Memory/Types"
          "Cortex/Nous/Patterns/DeepReport"
          "Cortex/Nous/Patterns/DeepReport/Contracts"
          "Cortex/Nous/Patterns/DeepReport/Gather"
          "Cortex/Nous/Patterns/DeepReport/LegacyReportTask"
          "Cortex/Nous/Patterns/DeepReport/Section"
          "Cortex/Nous/Patterns/DeepReport/Section/Runtime"
          "Cortex/Nous/Patterns/PlanReview"
          "Cortex/Nous/Thought"
          "Cortex/Nous/Thought/Event"
          "Cortex/Nous/Thought/Frame"
          "Cortex/Nous/Thought/Host"
          "Cortex/Nous/Thought/Policy"
          "Cortex/Nous/Thought/Runtime"
          "Cortex/Nous/Thought/Stage"
          "Cortex/Nous/Thought/StructuredOutput"
          "Cortex/Nous/Thought/ToolHost"
          "Cortex/Nous/Thought/ToolLoop"
          "Cortex/Pulse"
          "Cortex/Pulse/Attempt"
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
          "Cortex/Wire/Syntax"
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
      sublibs = {
        "platform-runtime" = {
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
            (hsPkgs."retry" or (errorHandler.buildDepError "retry"))
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
            (hsPkgs."servant-server" or (errorHandler.buildDepError "servant-server"))
            (hsPkgs."servant-client-core" or (errorHandler.buildDepError "servant-client-core"))
            (hsPkgs."openapi3" or (errorHandler.buildDepError "openapi3"))
            (hsPkgs."http-client" or (errorHandler.buildDepError "http-client"))
            (hsPkgs."http-client-tls" or (errorHandler.buildDepError "http-client-tls"))
            (hsPkgs."http-api-data" or (errorHandler.buildDepError "http-api-data"))
            (hsPkgs."http-types" or (errorHandler.buildDepError "http-types"))
            (hsPkgs."case-insensitive" or (errorHandler.buildDepError "case-insensitive"))
            (hsPkgs."wai" or (errorHandler.buildDepError "wai"))
            (hsPkgs."warp" or (errorHandler.buildDepError "warp"))
            (hsPkgs."crypton" or (errorHandler.buildDepError "crypton"))
            (hsPkgs."memory" or (errorHandler.buildDepError "memory"))
            (hsPkgs."safe-money" or (errorHandler.buildDepError "safe-money"))
            (hsPkgs."safe-money-aeson" or (errorHandler.buildDepError "safe-money-aeson"))
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
            (hsPkgs."cmark-gfm" or (errorHandler.buildDepError "cmark-gfm"))
          ];
          buildable = true;
          modules = [
            "Platform"
            "Platform/Database"
            "Platform/Database/Encode"
            "Platform/Database/Rel8TH"
            "Platform/Observability"
            "Platform/Observability/Context"
            "Platform/Observability/Emit"
            "Platform/Observability/Fields"
            "Platform/Observability/Redaction"
            "Platform/Observability/Runtime"
            "Platform/Observability/Store"
            "Platform/Observability/Types"
            "Platform/Observability/Wai"
            "Platform/DurableTask/Cron"
            "Platform/DurableTask/Checkpoint"
            "Platform/DurableTask/Error"
            "Platform/DurableTask/Polling"
            "Platform/DurableTask/Pool"
            "Platform/DurableTask/Types"
            "Platform/DurableTask/Schedule"
            "Platform/DurableTask/Workflow"
            "Platform/Serde"
            "Platform/Serde/Json"
            "Platform/Serde/Json/Object"
            "Platform/Serde/Json/Preview"
            "Platform/Serde/Json/Text"
            "Platform/Text"
            "Platform/Config"
            "Platform/Crypto"
            "Platform/Error"
            "Platform/Error/Servant"
            "Platform/HTTP/Retry"
            "Platform/Patch"
            "Platform/Require"
          ];
          hsSourceDirs = [ "src-platform" ];
        };
      };
      exes = {
        "cortex-pulse" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."cortex" or (errorHandler.buildDepError "cortex"))
            (hsPkgs."cortex".components.sublibs.platform-runtime or (errorHandler.buildDepError "cortex:platform-runtime"))
            (hsPkgs."optparse-applicative" or (errorHandler.buildDepError "optparse-applicative"))
            (hsPkgs."text" or (errorHandler.buildDepError "text"))
            (hsPkgs."bytestring" or (errorHandler.buildDepError "bytestring"))
            (hsPkgs."containers" or (errorHandler.buildDepError "containers"))
          ];
          buildable = true;
          hsSourceDirs = [ "app/cortex-pulse" ];
          mainPath = [ "Main.hs" ];
        };
      };
      tests = {
        "cortex-test" = {
          depends = [
            (hsPkgs."base" or (errorHandler.buildDepError "base"))
            (hsPkgs."cortex" or (errorHandler.buildDepError "cortex"))
            (hsPkgs."cortex".components.sublibs.platform-runtime or (errorHandler.buildDepError "cortex:platform-runtime"))
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
            "Cortex/Artifact/IRSpec"
            "Cortex/CanonicalModuleTreeSpec"
            "Cortex/Capability/Provider/OpenRouterSpec"
            "Cortex/Capability/StructuredOutputSpec"
            "Cortex/Nous/Memory/CandidatesSpec"
            "Cortex/Nous/Memory/CompactSpec"
            "Cortex/Nous/Memory/ConflictSpec"
            "Cortex/Nous/Memory/DocumentSpec"
            "Cortex/Nous/Memory/PackSpec"
            "Cortex/Nous/Memory/QuerySpec"
            "Cortex/Nous/Memory/RankSpec"
            "Cortex/Nous/Memory/RetrieveSpec"
            "Cortex/Nous/Memory/SourceSpec"
            "Cortex/Nous/Patterns/DeepReport/ContractsSpec"
            "Cortex/Nous/Patterns/DeepReport/GatherSpec"
            "Cortex/Nous/Patterns/DeepReport/LegacyReportTaskSpec"
            "Cortex/Nous/Patterns/DeepReport/Section/RuntimeSpec"
            "Cortex/Nous/Patterns/DeepReport/SectionSpec"
            "Cortex/Nous/Patterns/PlanReviewSpec"
            "Cortex/Nous/Thought/FrameSpec"
            "Cortex/Nous/Thought/ToolLoopSpec"
            "Cortex/PublicPreludeSpec"
            "Cortex/Pulse/DIG447Spec"
            "Cortex/Pulse/DIG448Spec"
            "Cortex/Pulse/DIG449Spec"
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
            "Platform/DurableTask/CheckpointSpec"
            "Platform/DurableTask/CronSpec"
            "Platform/DurableTask/ErrorSpec"
            "Platform/DurableTask/PollingSpec"
            "Platform/DurableTask/PoolSpec"
            "Platform/DurableTask/ScheduleSpec"
            "Platform/DurableTask/TypesSpec"
          ];
          hsSourceDirs = [ "test" ];
          mainPath = [ "Spec.hs" ];
        };
      };
    };
  } // rec { src = pkgs.lib.mkDefault ../.; }