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
          "Cortex/Graph/Core"
          "Cortex/Graph/Modify"
          "Cortex/Graph/Search"
          "Cortex/Graph/Decompose"
          "Cortex/Graph/Influence"
          "Cortex/Graph/Validate"
          "Cortex/Nous/Types"
          "Cortex/Wire/AST"
          "Cortex/Wire/Contracts"
          "Cortex/Wire/Proposal"
          "Cortex/Wire/Runtime"
          "Cortex/Wire/Value"
          "Cortex/Wire/V1/AST"
          "Cortex/Wire/V1/Compiler"
          "Cortex/Wire/V1/Parser"
          "Cortex"
          "Cortex/Agent/Config"
          "Cortex/Agent/Definition"
          "Cortex/Agent/Policy"
          "Cortex/Capability"
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
          "Cortex/Capability/Tool/Host"
          "Cortex/Capability/Tool/Loop"
          "Cortex/Capability/Tool/Record"
          "Cortex/Document"
          "Cortex/Document/Host"
          "Cortex/Document/IR"
          "Cortex/Document/Metadata"
          "Cortex/Document/Report"
          "Cortex/Document/Section"
          "Cortex/Event"
          "Cortex/Events"
          "Cortex/Graph"
          "Cortex/Graph/Algebra"
          "Cortex/Graph/Mokhov"
          "Cortex/Json/Object"
          "Cortex/Json/Preview"
          "Cortex/Json/Text"
          "Cortex/Nous"
          "Cortex/Nous/Episteme"
          "Cortex/Nous/Episteme/Capability"
          "Cortex/Nous/Kritikos"
          "Cortex/Nous/Kritikos/Capability"
          "Cortex/Nous/Logos"
          "Cortex/Nous/Logos/Capability"
          "Cortex/Nous/Poiesis"
          "Cortex/Nous/Poiesis/Capability"
          "Cortex/Nous/Sophia"
          "Cortex/Nous/Sophia/Capability"
          "Cortex/Nous/Techne"
          "Cortex/Nous/Techne/Capability"
          "Cortex/Nous/Themis"
          "Cortex/Nous/Themis/Capability"
          "Cortex/Provider/OpenRouter"
          "Cortex/Provider/OpenRouter/Client"
          "Cortex/Provider/OpenRouter/Embeddings"
          "Cortex/Provider/OpenRouter/Wire"
          "Cortex/Memory"
          "Cortex/Memory/Candidate"
          "Cortex/Memory/Candidates"
          "Cortex/Memory/Compact"
          "Cortex/Memory/Conflict"
          "Cortex/Memory/Document"
          "Cortex/Memory/Host"
          "Cortex/Memory/Pack"
          "Cortex/Memory/Query"
          "Cortex/Memory/Rank"
          "Cortex/Memory/Retrieve"
          "Cortex/Memory/Source"
          "Cortex/Memory/Types"
          "Cortex/MemoryCompaction"
          "Cortex/Research/Runtime"
          "Cortex/Research/Section"
          "Cortex/Run/Engine"
          "Cortex/Run/Types"
          "Cortex/Task/Gather"
          "Cortex/Task/Host"
          "Cortex/Task/Plan"
          "Cortex/Task/Report"
          "Cortex/Task/Runtime"
          "Cortex/Task/StructuredOutput"
          "Cortex/Task/ToolHost"
          "Cortex/Task/ToolLoop"
          "Cortex/Text"
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
          "Cortex/Circuit"
          "Cortex/Circuit/Artifact"
          "Cortex/Circuit/Compile"
          "Cortex/Wire"
          "Cortex/Wire/Compile"
          "Cortex/Wire/Contract"
          "Cortex/Wire/Parser"
          "Cortex/Wire/Syntax"
          "Cortex/Wire/V1"
          "Cortex/Circuit/Compiled"
          "Cortex/Circuit/Compiler"
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
          "Cortex/Circuit/IR"
          "Cortex/Circuit/Lower"
          "Cortex/Circuit/Lowering"
          "Cortex/Circuit/Node"
          "Cortex/Circuit/NodeKind"
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
            "Cortex/PublicPreludeSpec"
            "Cortex/Agent/ConfigSpec"
            "Cortex/Circuit/CompilerSpec"
            "Cortex/Circuit/IRSpec"
            "Cortex/Document/IRSpec"
            "Cortex/GraphSpec"
            "Cortex/Memory/CandidatesSpec"
            "Cortex/Memory/ConflictSpec"
            "Cortex/Memory/DocumentSpec"
            "Cortex/Memory/PackSpec"
            "Cortex/Memory/QuerySpec"
            "Cortex/Memory/RankSpec"
            "Cortex/Memory/RetrieveSpec"
            "Cortex/Memory/SourceSpec"
            "Cortex/MemoryCompactionSpec"
            "Cortex/Provider/OpenRouterSpec"
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
            "Cortex/Research/RuntimeSpec"
            "Cortex/Research/SectionSpec"
            "Cortex/Task/GatherSpec"
            "Cortex/Task/PlanSpec"
            "Cortex/Task/ReportSpec"
            "Cortex/Task/StructuredOutputSpec"
            "Cortex/Task/ToolLoopSpec"
            "Cortex/TestSupport/Database"
            "Cortex/Wire/V1/CompilerSpec"
            "Cortex/Wire/V1/ParserSpec"
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