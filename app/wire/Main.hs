{- |
Module      : Main
Description : Command-line entry point for local Wire source workflows.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The command exposes the public Wire compile surface, a local runner for
CorePure nodes plus standard std.io executors, and a minimal host for generated
Circuit engine bundles. Pulse remains the production durable host.
-}
module Main (main) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (IOException, displayException, try, uninterruptibleMask_)
import Control.Monad (foldM, forM, forM_, unless, when, zipWithM)
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty qualified as AesonPretty
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.List (find, nub)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Paths_cortex (getDataFileName)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (splitSearchPath, takeDirectory, (</>))
import System.IO (hFlush, stderr, stdout)
import System.Info (arch, os)
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)

import Cortex.Algebra.Graph (Relation, predecessors, relVertices)
import Cortex.Capability.Executor.Pure
  ( PureTaskConfig (..)
  , PureVariantConfig (..)
  , pureTaskConfigFromMetadata
  )
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Wire
  ( CircuitNodeRef (..)
  , CircuitTaskNode (..)
  , CompiledCircuit (..)
  , CompiledCircuitNode (..)
  , ContractId (..)
  , CorePureBinding (..)
  , CorePureExpr (..)
  , CorePureField (..)
  , CorePureLiteral (..)
  , ExecutorCall (..)
  , Expr (..)
  , Field (..)
  , HostedProgramManifest (..)
  , Literal (..)
  , NodeBody (..)
  , NodeDecl (..)
  , NodePureBody (..)
  , NodePureResult (..)
  , PortDecl (..)
  , PortLabel (..)
  , PureOutputEquation (..)
  , QName (..)
  , Record (..)
  , SumVariant (..)
  , TopForm (..)
  , WireFile (..)
  , WireInputBundle (..)
  , WireInputCardinality (..)
  , WireInputPort (..)
  , WireOutputPort (..)
  , WirePayloadKind (..)
  , WirePorts (..)
  , WireValue (..)
  , WireValueSet (..)
  , engineAbi
  , engineStateSchema
  , evaluatePureTaskOutputs
  , evaluatePureTaskVariant
  , formatWireSourceWithExpanded
  , hostedLinuxTarget
  , hostedProcessProtocol
  , hostedProgramManifestSchema
  , loadHostedProgramArtifact
  , normalizeNativePureInput
  , parseWireFile
  , realizeNativePurePlan
  , renderHostedProgramError
  , renderHostedRunError
  , renderNativePureArtifactError
  , renderNativePureLeanError
  , renderNativePurePlanModule
  , renderParseError
  , renderPureEvalError
  , renderWireError
  , renderWireFormatError
  , runHostedReferenceHost
  , sha256Hex
  , stdIoCommandExecutorId
  , stdIoReadFileExecutorId
  , stdIoStdinExecutorId
  , stdIoStdoutExecutorId
  , stdIoWriteFileExecutorId
  , wireInputBundleFromStageInputs
  , wirePayloadKindMediaType
  )
import Cortex.Wire.Cli.Frontier
  ( FrontierClosure (..)
  , FrontierCommand (..)
  , FrontierFormat (..)
  , FrontierScope (..)
  , parseFrontierCommand
  )
import Cortex.Wire.Compile
  ( WireModule (..)
  , compileWireFragmentTextWithEnv
  , compileWireModules
  , compileWireModulesForRun
  , compileWireModulesWithReturn
  )
import Cortex.Wire.Contract (WireCompileEnv (..), emptyWireCompileEnv)
import Cortex.Wire.ContractValidation (renderWireContractValidationError)
import Cortex.Wire.EndpointUse qualified as EndpointUse
import Cortex.Wire.Import (loadWireModuleClosureWithEnv, renderWireImportError)
import Cortex.Wire.Include (expandWireSourceIncludes)
import Cortex.Wire.LeanFixture
  ( ContractValidationFixture (..)
  , EmittedFixture (..)
  , compiledWireAdmissionArtifact
  , contractValidationFixtures
  , differentialFixtures
  , emittedFixtures
  , renderContractValidationFixtureModule
  , renderContractValidationUmbrellaModule
  , renderDifferentialModuleText
  , renderDifferentialUmbrellaModule
  , renderEmittedFixtureModule
  , renderEmittedUmbrellaModule
  )
import Cortex.Wire.NativePure.Differential (emitNativePureDifferentialCorpus)
import Cortex.Wire.Package
  ( NamespaceRegistry
  , renderPackageConflict
  , stdOnlyRegistry
  , wireCompileEnvWithPackagesChecked
  )
import Cortex.Wire.Package.Manifest
  ( loadWirePackageManifests
  , renderWirePackageManifestError
  )
import Cortex.Wire.StaticDifferential (emitDifferentialCorpus)
import Cortex.Wire.StaticProgram
  ( StaticProgram (..)
  , StaticProgramNode (..)
  , lowerCompiledCircuitToStaticProgram
  , renderStaticProgramError
  )
import Cortex.Wire.Use
  ( WireUseError (..)
  , WireUseScope
  , applyWireUseSpecs
  , resolveWireContract
  , resolveWireExecutorQName
  )

data Command
  = CommandBuild !BuildOptions
  | CommandHostedReference !FilePath
  | CommandFmt !FmtMode ![FilePath]
  | CommandRun !FilePath
  | CommandLeanFixtures !FilePath
  | CommandParse !FilePath
  | CommandFrontier !FrontierCommand
  | CommandDifferential !FilePath
  | CommandNativePureDifferential !FilePath
  | CommandHelp
  deriving stock (Eq, Show)

data BuildTarget
  = BuildCompiledCircuit
  | BuildStaticProgramV1
  | BuildX86_64LinuxV1
  | BuildNativePureLeanV1
  deriving stock (Eq, Show)

data BuildOptions = BuildOptions
  { buildTarget :: !BuildTarget
  , buildOutputDirectory :: !(Maybe FilePath)
  , buildSelectedReturn :: !(Maybe Text)
  , buildInputFile :: !FilePath
  }
  deriving stock (Eq, Show)

data FmtMode
  = FmtWrite
  | FmtCheck
  | FmtStdout
  deriving stock (Eq, Show)

data RunState = RunState
  { runStateOutputsByNode :: !(Map NodeId (Map Text WireValue))
  }
  deriving stock (Eq, Show)

data NodeInputs = NodeInputs
  { nodeInputProducerOutputs :: !(Map NodeId (Map Text WireValue))
  , nodeInputMergedOutputs :: !(Map Text WireValue)
  }
  deriving stock (Eq, Show)

data LoweredPort = LoweredPort
  { loweredPortName :: !Text
  , loweredPortLabel :: !PortLabel
  , loweredPortContract :: !Text
  , loweredPortCardinality :: !(Maybe WireInputCardinality)
  }
  deriving stock (Eq, Show)

data LoweredPorts = LoweredPorts
  { loweredInputs :: ![LoweredPort]
  , loweredOutputs :: ![LoweredPort]
  }
  deriving stock (Eq, Show)

data BuiltinExecutor
  = BuiltinExecutorStdin
  | BuiltinExecutorStdout
  | BuiltinExecutorCommand
  | BuiltinExecutorReadFile
  | BuiltinExecutorWriteFile
  deriving stock (Eq, Show)

data CommandSpec = CommandSpec
  { commandSpecName :: !Text
  , commandSpecTarget :: !(Maybe Text)
  , commandSpecArgv :: ![Text]
  , commandSpecCwd :: !(Maybe FilePath)
  , commandSpecStdin :: !Text
  , commandSpecRequired :: !Bool
  , commandSpecSkip :: !Bool
  , commandSpecEcho :: !Bool
  , commandSpecSuccessExitCodes :: ![Int]
  }
  deriving stock (Eq, Show)

data CommandRunResult = CommandRunResult
  { commandRunExitCode :: !(Maybe Int)
  , commandRunStdout :: !Text
  , commandRunStderr :: !Text
  , commandRunStatus :: !Text
  , commandRunOk :: !Bool
  }
  deriving stock (Eq, Show)

main :: IO ()
main = do
  (packagePaths, commandArgs) <- extractWirePackageFlags <$> getArgs
  case parseCommand commandArgs of
    Left errText -> dieText errText
    Right CommandHelp -> TIO.putStr usageText
    Right (CommandBuild options) -> buildWire packagePaths options
    Right (CommandHostedReference directory) -> hostedReference directory
    Right (CommandFmt mode paths) -> fmtWire mode paths
    Right (CommandRun path) -> runWire packagePaths path
    Right (CommandLeanFixtures outDir) -> leanFixturesWire outDir
    Right (CommandParse path) -> parseWireOnly path
    Right (CommandFrontier frontierCommand) -> frontierWire packagePaths frontierCommand
    Right (CommandDifferential outDir) -> differentialWire outDir
    Right (CommandNativePureDifferential outDir) -> nativePureDifferentialWire outDir

{- | Pull repeatable @--wire-package PATH@ options out of the raw argv, returning the
collected manifest paths and the remaining command arguments. These flags select which
Wire packages compile-time @use@ resolves against; without them (and without
@CORTEX_WIRE_PACKAGE_MANIFESTS@) the CLI knows only Cortex's standard namespaces.
-}
extractWirePackageFlags :: [String] -> ([FilePath], [String])
extractWirePackageFlags = go [] []
  where
    go paths rest [] = (reverse paths, reverse rest)
    go paths rest ("--wire-package" : path : more) = go (path : paths) rest more
    go paths rest (arg : more) = go paths (arg : rest) more

parseCommand :: [String] -> Either Text Command
parseCommand = \case
  [] -> Right CommandHelp
  ["--help"] -> Right CommandHelp
  ["-h"] -> Right CommandHelp
  "build" : args -> CommandBuild <$> parseBuildCommand args
  ["hosted-reference", directory] -> Right (CommandHostedReference directory)
  "fmt" : args -> parseFmtCommand args
  ["run", path] -> Right (CommandRun path)
  ["lean-fixtures", outDir] -> Right (CommandLeanFixtures outDir)
  ["differential", "emit", outDir] -> Right (CommandDifferential outDir)
  ["native-pure", "differential", "emit", outDir] ->
    Right (CommandNativePureDifferential outDir)
  ["parse", path] -> Right (CommandParse path)
  "frontier" : args -> CommandFrontier <$> parseFrontierCommand args
  [path] -> Right (CommandRun path)
  "run" : _ -> Left "usage: wire run FILE"
  "hosted-reference" : _ -> Left "usage: wire hosted-reference BUNDLE_DIR"
  "lean-fixtures" : _ -> Left "usage: wire lean-fixtures OUTDIR"
  "differential" : _ -> Left "usage: wire differential emit OUTDIR"
  "native-pure" : _ -> Left "usage: wire native-pure differential emit OUTDIR"
  "parse" : _ -> Left "usage: wire parse FILE"
  _ -> Left usageText

parseBuildCommand :: [String] -> Either Text BuildOptions
parseBuildCommand = go BuildCompiledCircuit Nothing Nothing []
  where
    go target output selectedReturn files = \case
      [] ->
        case reverse files of
          [path]
            | target `elem` [BuildX86_64LinuxV1, BuildNativePureLeanV1]
                && isNothing output ->
                Left
                  ( "wire build --target "
                      <> renderBuildTarget target
                      <> " requires --output DIR."
                  )
            | target `notElem` [BuildX86_64LinuxV1, BuildNativePureLeanV1]
                && isJust output ->
                Left
                  "wire build --output is supported only by x86_64-linux-v1 and native-pure-lean-v1."
            | otherwise ->
                Right
                  BuildOptions
                    { buildTarget = target
                    , buildOutputDirectory = output
                    , buildSelectedReturn = selectedReturn
                    , buildInputFile = path
                    }
          _paths -> Left buildUsageText
      "--target" : value : rest -> do
        parsedTarget <- parseBuildTarget value
        go parsedTarget output selectedReturn files rest
      "--output" : directory : rest ->
        go target (Just directory) selectedReturn files rest
      "--return" : name : rest ->
        go target output (Just (T.pack name)) files rest
      option : _rest
        | "--" `T.isPrefixOf` T.pack option -> Left buildUsageText
      path : rest -> go target output selectedReturn (path : files) rest

parseBuildTarget :: String -> Either Text BuildTarget
parseBuildTarget = \case
  "compiled-circuit" -> Right BuildCompiledCircuit
  "static-program-v1" -> Right BuildStaticProgramV1
  "x86_64-linux-v1" -> Right BuildX86_64LinuxV1
  "native-pure-lean-v1" -> Right BuildNativePureLeanV1
  target -> Left ("unsupported Wire build target: " <> T.pack target)

renderBuildTarget :: BuildTarget -> Text
renderBuildTarget = \case
  BuildCompiledCircuit -> "compiled-circuit"
  BuildStaticProgramV1 -> "static-program-v1"
  BuildX86_64LinuxV1 -> "x86_64-linux-v1"
  BuildNativePureLeanV1 -> "native-pure-lean-v1"

buildUsageText :: Text
buildUsageText =
  "usage: wire build [--target compiled-circuit|static-program-v1|x86_64-linux-v1|native-pure-lean-v1] "
    <> "[--output DIR] [--return NAME] FILE"

parseFmtCommand :: [String] -> Either Text Command
parseFmtCommand args = do
  (mode, revFiles) <- foldM step (FmtWrite, []) args
  let files = reverse revFiles
  case (mode, files) of
    (_, []) -> Left "usage: wire fmt [--check | --stdout] FILE..."
    (FmtStdout, [_path]) -> Right (CommandFmt mode files)
    (FmtStdout, _paths) -> Left "wire fmt --stdout expects exactly one FILE."
    _ -> Right (CommandFmt mode files)
  where
    step (mode, files) = \case
      "--check" -> setMode FmtCheck mode files
      "--stdout" -> setMode FmtStdout mode files
      path -> Right (mode, path : files)

    setMode newMode oldMode files
      | oldMode == FmtWrite = Right (newMode, files)
      | oldMode == newMode = Right (newMode, files)
      | otherwise = Left "wire fmt accepts only one of --check or --stdout."

usageText :: Text
usageText =
  T.unlines
    [ "wire - work with Wire source files"
    , ""
    , "usage:"
    , "  wire FILE                        (alias for `wire run FILE`)"
    , "  wire run FILE"
    , "  wire build [--target compiled-circuit|static-program-v1] [--return NAME] FILE"
    , "  wire build --target x86_64-linux-v1 --output DIR [--return NAME] FILE"
    , "  wire build --target native-pure-lean-v1 --output DIR [--return NAME] FILE"
    , "  wire hosted-reference BUNDLE_DIR"
    , "  wire fmt [--check | --stdout] FILE..."
    , "  wire lean-fixtures OUTDIR    (regenerate emitted Lean artifact fixtures)"
    , "  wire differential emit OUTDIR    (emit the static-C-backend differential corpus)"
    , "  wire native-pure differential emit OUTDIR"
    , "                                      (emit the NativePure differential corpus)"
    , "  wire parse FILE              (expand includes and parse; no compilation)"
    , "  wire frontier [--return NAME] [--closure | --open] [--node NODE] [--json] FILE"
    , "                              (inspect endpoint-use / closure accounting; no execution)"
    , ""
    , "global options:"
    , "  --wire-package PATH         compose a Wire package manifest (repeatable)."
    , "                              Default: Cortex standard namespaces only."
    , "                              CORTEX_WIRE_PACKAGE_MANIFESTS (search path) is an alternative."
    , ""
    , "The local runner supports CorePure DAG frontiers plus standard std.io executors:"
    , "  stdin, stdout, command, readFile, writeFile."
    , "The hosted reference command executes every admitted effect with an inert success host."
    ]

hostedReference :: FilePath -> IO ()
hostedReference directory = do
  artifact <-
    loadHostedProgramArtifact directory
      >>= either (dieText . renderHostedProgramError) pure
  finalState <-
    runHostedReferenceHost artifact
      >>= either (dieText . renderHostedRunError) pure
  writeJsonStdout finalState

buildWire :: [FilePath] -> BuildOptions -> IO ()
buildWire packagePaths options = do
  compileEnv <- loadCliWireCompileEnv packagePaths
  modules <- loadWireModules compileEnv options.buildInputFile
  let compile =
        maybe
          (compileWireModules compileEnv)
          (compileWireModulesWithReturn compileEnv)
          options.buildSelectedReturn
  compiled <- either (dieText . renderWireError) pure (compile modules)
  case options.buildTarget of
    BuildCompiledCircuit -> writeJsonStdout compiled
    BuildStaticProgramV1 -> do
      staticProgram <- lowerStaticProgram compiled
      writeJsonStdout staticProgram
    BuildX86_64LinuxV1 -> do
      staticProgram <- lowerStaticProgram compiled
      case options.buildOutputDirectory of
        Nothing -> dieText "x86_64-linux-v1 requires an output directory"
        Just directory -> buildHostedLinux directory staticProgram
    BuildNativePureLeanV1 ->
      case options.buildOutputDirectory of
        Nothing -> dieText "native-pure-lean-v1 requires an output directory"
        Just directory -> buildNativePureLean directory compileEnv compiled

buildNativePureLean :: FilePath -> WireCompileEnv -> CompiledCircuit -> IO ()
buildNativePureLean outputDirectory compileEnv compiled = do
  contractRegistry <-
    maybe
      (dieText "native-pure-lean-v1 requires a strict contract registry with native_shape projections")
      pure
      compileEnv.wireCompileEnvContractRegistry
  normalized <-
    either
      (dieText . renderNativePureArtifactError)
      pure
      (normalizeNativePureInput contractRegistry compiled)
  plan <-
    either
      (dieText . renderNativePureArtifactError)
      pure
      (realizeNativePurePlan normalized)
  leanModule <-
    either
      (dieText . renderNativePureLeanError)
      pure
      ( renderNativePurePlanModule
          "Cortex.Wire.NativePure.Generated.Program"
          normalized
          plan
      )
  createDirectoryIfMissing True outputDirectory
  let normalizedPath = outputDirectory </> "native-pure-input.json"
      planPath = outputDirectory </> "native-pure-plan.json"
      leanPath = outputDirectory </> "Program.lean"
  BS.writeFile normalizedPath (prettyJsonBytes normalized)
  BS.writeFile planPath (prettyJsonBytes plan)
  TIO.writeFile leanPath leanModule
  forM_ [normalizedPath, planPath, leanPath] $ \path ->
    TIO.putStrLn ("wrote " <> T.pack path)

lowerStaticProgram :: CompiledCircuit -> IO StaticProgram
lowerStaticProgram compiled =
  either
    (dieText . renderStaticProgramError)
    pure
    (lowerCompiledCircuitToStaticProgram compiled)

writeJsonStdout :: Aeson.ToJSON value => value -> IO ()
writeJsonStdout value = do
  BSL.putStr (AesonPretty.encodePretty value)
  BSL.putStr "\n"

buildHostedLinux :: FilePath -> StaticProgram -> IO ()
buildHostedLinux outputDirectory staticProgram = do
  unless (arch == "x86_64" && os == "linux") $
    dieText
      ( "x86_64-linux-v1 builds require an x86_64 Linux build host; detected "
          <> T.pack arch
          <> "-"
          <> T.pack os
      )
  createDirectoryIfMissing True outputDirectory
  compiler <- fromMaybe "cortex-wire-c" <$> lookupEnv "CORTEX_WIRE_C_BIN"
  clang <- fromMaybe "clang" <$> lookupEnv "CORTEX_CLANG_BIN"
  runnerSource <- getDataFileName "cortex-wire-hosted-runner-v1.c"
  let staticProgramPath = outputDirectory </> "static-program.json"
      executorMapPath = outputDirectory </> "executor-map.json"
      executablePath = outputDirectory </> "circuit-engine"
      programSourcePath = outputDirectory </> "program.c"
      programHeaderPath = outputDirectory </> "program.h"
      programManifestPath = outputDirectory </> "program.manifest.json"
      hostedManifestPath = outputDirectory </> "hosted.manifest.json"
      staticProgramBytes = prettyJsonBytes staticProgram
      executorMapBytes = prettyJsonBytes (executorMapValue staticProgram)
  BS.writeFile staticProgramPath staticProgramBytes
  runBuildTool
    "Lean-hosted C generation"
    compiler
    [staticProgramPath, outputDirectory]
  BS.writeFile executorMapPath executorMapBytes
  runBuildTool
    "x86_64 Linux compilation"
    clang
    [ "-std=c11"
    , "-O2"
    , "-fPIE"
    , "-pie"
    , "-D_FORTIFY_SOURCE=2"
    , "-fstack-protector-strong"
    , "-Wall"
    , "-Wextra"
    , "-Werror"
    , "-Wl,-z,relro,-z,now"
    , "-Wl,--build-id=sha1"
    , "-I"
    , outputDirectory
    , programSourcePath
    , runnerSource
    , "-o"
    , executablePath
    ]
  clangVersion <- toolVersion clang
  executableDigest <- sha256File executablePath
  programSourceDigest <- sha256File programSourcePath
  programHeaderDigest <- sha256File programHeaderPath
  programManifestDigest <- sha256File programManifestPath
  runnerDigest <- sha256File runnerSource
  let manifest =
        HostedProgramManifest
          { hpmSchema = hostedProgramManifestSchema
          , hpmTarget = hostedLinuxTarget
          , hpmTargetTriple = "x86_64-unknown-linux-gnu"
          , hpmProtocol = hostedProcessProtocol
          , hpmEngineStateSchema = engineStateSchema
          , hpmEngineAbi = engineAbi
          , hpmProgramIdentity = staticProgram.staticProgramIdentity
          , hpmExecutable = "circuit-engine"
          , hpmExecutableSha256 = executableDigest
          , hpmStaticProgramSha256 = sha256Hex staticProgramBytes
          , hpmNodeExecutors =
              Map.fromList
                [ (node.staticProgramNodeId, node.staticProgramNodeExecutor)
                | node <- staticProgram.staticProgramNodes
                ]
          , hpmGeneratedDigests =
              Map.fromList
                [ ("executor-map.json", sha256Hex executorMapBytes)
                , ("program.c", programSourceDigest)
                , ("program.h", programHeaderDigest)
                , ("program.manifest.json", programManifestDigest)
                , ("runner.c", runnerDigest)
                ]
          , hpmToolchainProvenance =
              Map.fromList
                [ ("cortex_wire_c", T.pack compiler)
                , ("clang", clangVersion)
                ]
          }
  BS.writeFile hostedManifestPath (prettyJsonBytes manifest)
  TIO.putStrLn ("built x86_64-linux-v1 circuit bundle in " <> T.pack outputDirectory)

prettyJsonBytes :: Aeson.ToJSON value => value -> BS.ByteString
prettyJsonBytes = BSL.toStrict . (<> "\n") . AesonPretty.encodePretty

executorMapValue :: StaticProgram -> Aeson.Value
executorMapValue staticProgram =
  Aeson.object
    [ "schema" Aeson..= ("cortex.wire.executor-map/v1" :: Text)
    , "program_identity" Aeson..= staticProgram.staticProgramIdentity
    , "nodes"
        Aeson..= [ Aeson.object
                     [ "id" Aeson..= node.staticProgramNodeId
                     , "ref" Aeson..= node.staticProgramNodeRef.unCircuitNodeRef
                     , "executor" Aeson..= node.staticProgramNodeExecutor
                     ]
                 | node <- staticProgram.staticProgramNodes
                 ]
    ]

sha256File :: FilePath -> IO Text
sha256File path = do
  result <- try @IOException (BS.readFile path)
  case result of
    Left err -> dieText ("reading generated file " <> T.pack path <> ": " <> tshow err)
    Right bytes -> pure (sha256Hex bytes)

toolVersion :: FilePath -> IO Text
toolVersion tool = do
  result <- try @IOException (readCreateProcessWithExitCode (proc tool ["--version"]) "")
  case result of
    Left err -> dieText ("running tool " <> T.pack tool <> ": " <> tshow err)
    Right (ExitSuccess, output, _stderrText) ->
      pure (T.takeWhile (/= '\n') (T.pack output))
    Right (ExitFailure code, _output, stderrText) ->
      dieText
        ( "tool "
            <> T.pack tool
            <> " --version failed with exit "
            <> tshow code
            <> ": "
            <> T.take 4096 (T.pack stderrText)
        )

runBuildTool :: Text -> FilePath -> [String] -> IO ()
runBuildTool label tool arguments = do
  result <- try @IOException (readCreateProcessWithExitCode (proc tool arguments) "")
  case result of
    Left err -> dieText (label <> " failed to start: " <> tshow err)
    Right (ExitSuccess, _output, _stderrText) -> pure ()
    Right (ExitFailure code, output, stderrText) ->
      dieText
        ( label
            <> " failed with exit "
            <> tshow code
            <> ": "
            <> T.take 4096 (T.pack (stderrText <> output))
        )

loadWireModules :: WireCompileEnv -> FilePath -> IO (NonEmpty WireModule)
loadWireModules compileEnv path =
  loadWireModuleClosureWithEnv compileEnv path
    >>= either (dieText . renderWireImportError) pure

{- | Inspect the endpoint-use / closure accounting of a compiled Wire file
(ADR 0081). Runs the normal validator-ready compile path, projects closed or
open endpoint-use accounting over the admission artifact, and prints either the
whole graph, a single node, or the JSON surface. This is an inspection command;
it does not execute.
-}
frontierWire :: [FilePath] -> FrontierCommand -> IO ()
frontierWire packagePaths frontierCommand = do
  compileEnv <- loadCliWireCompileEnv packagePaths
  modules <- loadWireModules compileEnv frontierCommand.frontierCommandFile
  let compile =
        maybe
          (compileWireModules compileEnv)
          (compileWireModulesWithReturn compileEnv)
          frontierCommand.frontierCommandSelectedReturn
  compiled <-
    either (dieText . renderWireError) pure (compile modules)
  artifact <-
    maybe
      (dieText "compiled circuit carries no Wire admission artifact")
      pure
      (compiledWireAdmissionArtifact compiled)
  let report =
        case frontierCommand.frontierCommandClosure of
          FrontierClosed -> EndpointUse.endpointUseReportFromArtifact artifact
          FrontierOpen -> EndpointUse.endpointUseReport EndpointUse.OpenFragment artifact
  case frontierCommand.frontierCommandScope of
    FrontierNode nodeName ->
      case EndpointUse.lookupNodeFrontier (CircuitNodeRef nodeName) report of
        Nothing -> dieText ("wire frontier: no such node: " <> nodeName)
        Just nodeFrontier -> case frontierCommand.frontierCommandFormat of
          FrontierJson -> putJsonLn nodeFrontier
          FrontierText -> TIO.putStr (EndpointUse.renderNodeFrontierText nodeFrontier)
    FrontierGraph -> case frontierCommand.frontierCommandFormat of
      FrontierJson -> putJsonLn report
      FrontierText -> TIO.putStr (EndpointUse.renderEndpointUseReportText report)
  where
    putJsonLn :: Aeson.ToJSON a => a -> IO ()
    putJsonLn value = do
      BSL.putStr (AesonPretty.encodePretty value)
      BSL.putStr "\n"

{- | Regenerate the Lean fixture modules for emitted admission artifacts.
The umbrella module is rewritten alongside the per-fixture modules so lake
registration only tracks one root.
-}
leanFixturesWire :: FilePath -> IO ()
leanFixturesWire outDir = do
  createDirectoryIfMissing True outDir
  forM_ emittedFixtures $ \fixture -> do
    rendered <-
      either
        (dieText . renderWireError)
        pure
        (renderEmittedFixtureModule fixture)
    let path = outDir </> T.unpack fixture.emittedFixtureSlug <> ".lean"
    TIO.writeFile path rendered
    TIO.putStrLn ("wrote " <> T.pack path)
  let umbrellaPath = takeDirectory outDir </> "Emitted.lean"
  TIO.writeFile umbrellaPath (renderEmittedUmbrellaModule emittedFixtures)
  TIO.putStrLn ("wrote " <> T.pack umbrellaPath)
  let diffDir = takeDirectory outDir </> "Differential"
  createDirectoryIfMissing True diffDir
  forM_ differentialFixtures $ \fixture -> do
    compiled <-
      either
        (dieText . renderWireError)
        pure
        (compileWireFragmentTextWithEnv fixture.emittedFixtureEnv fixture.emittedFixtureSource)
    artifact <-
      maybe
        (dieText "compiled fixture carries no admission artifact")
        pure
        (compiledWireAdmissionArtifact compiled)
    rendered <- either dieText pure (renderDifferentialModuleText fixture artifact)
    let path = diffDir </> T.unpack fixture.emittedFixtureSlug <> ".lean"
    TIO.writeFile path rendered
    TIO.putStrLn ("wrote " <> T.pack path)
  let diffUmbrellaPath = takeDirectory outDir </> "Differential.lean"
  TIO.writeFile diffUmbrellaPath (renderDifferentialUmbrellaModule differentialFixtures)
  TIO.putStrLn ("wrote " <> T.pack diffUmbrellaPath)
  let contractValidationDir =
        takeDirectory (takeDirectory outDir) </> "ContractValidation" </> "Emitted"
  createDirectoryIfMissing True contractValidationDir
  forM_ contractValidationFixtures $ \fixture -> do
    rendered <-
      either
        (dieText . renderWireContractValidationError)
        pure
        (renderContractValidationFixtureModule fixture)
    let path = contractValidationDir </> T.unpack fixture.cvFixtureSlug <> ".lean"
    TIO.writeFile path rendered
    TIO.putStrLn ("wrote " <> T.pack path)
  let contractValidationUmbrellaPath = takeDirectory contractValidationDir </> "Emitted.lean"
  TIO.writeFile
    contractValidationUmbrellaPath
    (renderContractValidationUmbrellaModule contractValidationFixtures)
  TIO.putStrLn ("wrote " <> T.pack contractValidationUmbrellaPath)

{- | Emit the ADR 0091 three-way differential corpus.

Writes the shared scenario corpus, per-topology static-program artifacts, and
the Haskell GraphRuntime reference traces under @outDir@ for the Lean driver and
generated C harness to replay. Reports the covered topology and scenario counts.
-}
differentialWire :: FilePath -> IO ()
differentialWire outDir = do
  (topologies, scenarios) <- emitDifferentialCorpus outDir
  TIO.putStrLn
    ( "emitted differential corpus to "
        <> T.pack outDir
        <> " ("
        <> T.pack (show topologies)
        <> " topologies, "
        <> T.pack (show scenarios)
        <> " scenarios)"
    )

nativePureDifferentialWire :: FilePath -> IO ()
nativePureDifferentialWire outDir = do
  cases <- emitNativePureDifferentialCorpus outDir
  TIO.putStrLn
    ( "emitted NativePure differential corpus to "
        <> T.pack outDir
        <> " ("
        <> T.pack (show cases)
        <> " cases)"
    )

-- | Parse-only acceptance check used by the grammar differential harness.
parseWireOnly :: FilePath -> IO ()
parseWireOnly path = do
  _wireFile <- readAndParseWireFile path
  TIO.putStrLn ("parse ok: " <> T.pack path)

fmtWire :: FmtMode -> [FilePath] -> IO ()
fmtWire mode paths = do
  results <- forM paths (fmtWireFile mode)
  unless (and results) exitFailure

fmtWireFile :: FmtMode -> FilePath -> IO Bool
fmtWireFile mode path = do
  source <- TIO.readFile path
  expandedResult <- expandWireSourceIncludes path source
  case expandedResult of
    Left err -> do
      TIO.hPutStrLn stderr (T.pack path <> ": " <> err)
      pure False
    Right expanded ->
      applyFmtResult source (formatWireSourceWithExpanded path source expanded)
  where
    applyFmtResult source = \case
      Left err -> do
        TIO.hPutStrLn stderr (T.pack path <> ": " <> renderWireFormatError err)
        pure False
      Right formatted ->
        case mode of
          FmtWrite -> do
            when (formatted /= source) (TIO.writeFile path formatted)
            pure True
          FmtCheck -> do
            let message =
                  T.pack path <> ": Wire formatting differs; run `wire fmt " <> T.pack path <> "`."
            when (formatted /= source) (TIO.hPutStrLn stderr message)
            pure (formatted == source)
          FmtStdout -> do
            TIO.putStr formatted
            pure True

runWire :: [FilePath] -> FilePath -> IO ()
runWire packagePaths path = do
  compileEnv <- loadCliWireCompileEnv packagePaths
  modules <- loadWireModules compileEnv path
  let namespaceRegistry =
        fromMaybe stdOnlyRegistry compileEnv.wireCompileEnvNamespaceRegistry
  let rootFile = (NE.last modules).wireModuleFile
      -- Node declarations from every closure module, so the local runner can
      -- execute nodes that entered the circuit through an imported graph.
      closureFile =
        rootFile
          { wireFileTopForms =
              concatMap (.wireModuleFile.wireFileTopForms) (NE.toList modules)
          }
  (compiled, pureBindings) <-
    either
      (dieText . renderWireError)
      pure
      (compileWireModulesForRun compileEnv modules)
  -- `use` stays source-local: each node resolves executors against the use
  -- scope of the module that declared it.
  runnerScopes <- either dieText pure (runnerScopesFromModules namespaceRegistry modules)
  nodePlan <- either dieText pure (executionLevels compiled closureFile)
  outputLock <- newMVar ()
  _finalState <-
    foldM (runNodeLevel outputLock runnerScopes pureBindings compiled) emptyRunState nodePlan
  pure ()

data RunnerScopes = RunnerScopes
  { runnerRootScope :: !WireUseScope
  , runnerNodeScopes :: !(Map Text WireUseScope)
  }

scopeForNode :: RunnerScopes -> Text -> WireUseScope
scopeForNode scopes nodeName =
  fromMaybe scopes.runnerRootScope (Map.lookup nodeName scopes.runnerNodeScopes)

runnerScopesFromModules :: NamespaceRegistry -> NonEmpty WireModule -> Either Text RunnerScopes
runnerScopesFromModules namespaceRegistry modules = do
  rootScope <- useScopeFromWireFile namespaceRegistry (NE.last modules).wireModuleFile
  nodeScopes <-
    Map.unions
      <$> traverse
        ( \wireModule -> do
            moduleScope <- useScopeFromWireFile namespaceRegistry wireModule.wireModuleFile
            pure
              ( Map.fromList
                  [ (nodeDecl.nodeDeclName, moduleScope)
                  | TopNode nodeDecl <- wireModule.wireModuleFile.wireFileTopForms
                  ]
              )
        )
        (NE.toList modules)
  pure RunnerScopes {runnerRootScope = rootScope, runnerNodeScopes = nodeScopes}

loadCliWireCompileEnv :: [FilePath] -> IO WireCompileEnv
loadCliWireCompileEnv explicitPaths = do
  manifestPaths <- cliWirePackageManifestPaths explicitPaths
  loadedPackages <- loadWirePackageManifests manifestPaths
  packages <- either (dieText . renderWirePackageManifestError) pure loadedPackages
  case wireCompileEnvWithPackagesChecked packages emptyWireCompileEnv of
    Right compileEnv -> pure compileEnv
    Left conflicts ->
      dieText
        ( "conflicting Wire packages:\n"
            <> T.intercalate "\n" (fmap (("  - " <>) . renderPackageConflict) conflicts)
        )

{- | Wire package manifests to compose, in precedence order: explicit @--wire-package@
flags, else the @CORTEX_WIRE_PACKAGE_MANIFESTS@ search path, else none. The default
compile environment knows only Cortex's standard namespaces (ADR 0060); downstream
packages such as the quantum showcase are opt-in, not auto-loaded by the CLI.
-}
cliWirePackageManifestPaths :: [FilePath] -> IO [FilePath]
cliWirePackageManifestPaths explicitPaths
  | not (null explicitPaths) = pure explicitPaths
  | otherwise = do
      configured <- lookupEnv "CORTEX_WIRE_PACKAGE_MANIFESTS"
      pure $ case configured of
        Just raw | not (null raw) -> splitSearchPath raw
        _ -> []

readAndParseWireFile :: FilePath -> IO WireFile
readAndParseWireFile path = do
  source <- TIO.readFile path
  expanded <- either dieText pure =<< expandWireSourceIncludes path source
  either (dieText . renderParseError) pure (parseWireFile path expanded)

emptyRunState :: RunState
emptyRunState =
  RunState
    { runStateOutputsByNode = Map.empty
    }

runNodeLevel
  :: MVar ()
  -> RunnerScopes
  -> [CorePureBinding]
  -> CompiledCircuit
  -> RunState
  -> [RunnableNode]
  -> IO RunState
runNodeLevel outputLock runnerScopes pureBindings compiled state runnableNodes = do
  levelOutputs <-
    mapConcurrently
      ( \runnableNode -> do
          let nodeRef = runnableNodeRef runnableNode
              nodeId = NodeId nodeRef.unCircuitNodeRef
              directPredecessors =
                Set.toAscList (predecessors compiled.compiledCircuitTopology nodeRef)
          nodeInputs <- either (dieTextLocked outputLock) pure (nodeInputsFromState state directPredecessors)
          outputs <- runRunnableNode outputLock runnerScopes pureBindings nodeInputs runnableNode
          pure (nodeId, outputs)
      )
      runnableNodes
  pure
    state
      { runStateOutputsByNode =
          Map.union (Map.fromList levelOutputs) state.runStateOutputsByNode
      }

data RunnableNode
  = RunnableSourceNode !NodeDecl
  | RunnableCompiledPure !CircuitTaskNode !PureTaskConfig

runnableNodeRef :: RunnableNode -> CircuitNodeRef
runnableNodeRef = \case
  RunnableSourceNode nodeDecl ->
    CircuitNodeRef nodeDecl.nodeDeclName
  RunnableCompiledPure taskNode _config ->
    taskNode.circuitTaskNodeRef

runRunnableNode
  :: MVar ()
  -> RunnerScopes
  -> [CorePureBinding]
  -> NodeInputs
  -> RunnableNode
  -> IO (Map Text WireValue)
runRunnableNode outputLock runnerScopes pureBindings nodeInputs = \case
  RunnableSourceNode nodeDecl ->
    runNode
      outputLock
      (scopeForNode runnerScopes nodeDecl.nodeDeclName)
      pureBindings
      nodeInputs
      nodeDecl
  RunnableCompiledPure _taskNode config ->
    runCompiledPureNode outputLock nodeInputs config

runNode
  :: MVar () -> WireUseScope -> [CorePureBinding] -> NodeInputs -> NodeDecl -> IO (Map Text WireValue)
runNode outputLock useScope pureBindings nodeInputs nodeDecl = do
  loweredPorts <-
    either (dieTextLocked outputLock) pure (lowerPortSignature useScope nodeDecl.nodeDeclPortSig)
  let ports = wirePortsFromLowered loweredPorts
  case nodeDecl.nodeDeclBody of
    NodeBodyPure pureBody ->
      runPureNode outputLock useScope pureBindings nodeInputs ports loweredPorts pureBody
    NodeBodyExecutor _whereExpr executorCall ->
      runExecutorNode outputLock useScope nodeDecl.nodeDeclName nodeInputs ports executorCall

runPureNode
  :: MVar ()
  -> WireUseScope
  -> [CorePureBinding]
  -> NodeInputs
  -> WirePorts
  -> LoweredPorts
  -> NodePureBody
  -> IO (Map Text WireValue)
runPureNode outputLock useScope pureBindings nodeInputs ports loweredPorts pureBody = do
  outputValues <-
    case pureBody.nodePureBodyResult of
      NodePureProduct outputEquations -> do
        outputExprs <-
          either
            (dieTextLocked outputLock)
            pure
            (pureOutputConfigMap useScope loweredPorts.loweredOutputs outputEquations)
        evaluate
          ( evaluatePureTaskOutputs
              ports
              inputBundle
              pureBindings
              pureBody.nodePureBodyWhere
              outputExprs
          )
      NodePureSum _variants bodyExpr ->
        evaluate
          ( evaluatePureTaskVariant
              ports
              inputBundle
              pureBindings
              pureBody.nodePureBodyWhere
              (Map.keys ports.wirePortsOutputs)
              bodyExpr
          )
  pure (wrapOutputs Nothing ports outputValues)
  where
    inputBundle = wireInputBundleFromNodeInputs nodeInputs
    evaluate = either (dieTextLocked outputLock . renderPureEvalError) pure

runCompiledPureNode
  :: MVar () -> NodeInputs -> PureTaskConfig -> IO (Map Text WireValue)
runCompiledPureNode outputLock nodeInputs config = do
  outputValues <-
    either
      (dieTextLocked outputLock . renderPureEvalError)
      pure
      ( case config.pureTaskConfigVariant of
          Nothing ->
            evaluatePureTaskOutputs
              config.pureTaskConfigPorts
              inputBundle
              config.pureTaskConfigBindings
              config.pureTaskConfigWhere
              config.pureTaskConfigOutputs
          Just variant ->
            evaluatePureTaskVariant
              config.pureTaskConfigPorts
              inputBundle
              config.pureTaskConfigBindings
              config.pureTaskConfigWhere
              variant.pureVariantConfigLabels
              variant.pureVariantConfigExpression
      )
  pure (wrapOutputs Nothing config.pureTaskConfigPorts outputValues)
  where
    inputBundle = wireInputBundleFromNodeInputs nodeInputs

runExecutorNode
  :: MVar ()
  -> WireUseScope
  -> Text
  -> NodeInputs
  -> WirePorts
  -> ExecutorCall
  -> IO (Map Text WireValue)
runExecutorNode outputLock useScope nodeName nodeInputs ports = \case
  ExecutorCallInline executorName argumentExpr -> do
    (record, inputExpr) <-
      either (dieTextLocked outputLock) pure (executorArgumentParts argumentExpr)
    runInline executorName record inputExpr
  ExecutorCallBound authorityName _argumentExpr ->
    unsupportedBoundExecutor authorityName
  where
    runInline executorName record inputExpr =
      case builtinExecutorFromQName useScope executorName of
        Right BuiltinExecutorStdin ->
          runStdinNode outputLock ports record
        Right BuiltinExecutorStdout ->
          runStdoutNode outputLock nodeInputs record inputExpr
        Right BuiltinExecutorCommand ->
          runCommandNode outputLock nodeInputs ports record inputExpr
        Right BuiltinExecutorReadFile ->
          runReadFileNode outputLock nodeInputs ports record inputExpr
        Right BuiltinExecutorWriteFile ->
          runWriteFileNode outputLock nodeInputs record inputExpr
        Left errText ->
          dieTextLocked outputLock (errText <> " Node: " <> nodeName <> ".")
    unsupportedBoundExecutor authorityName =
      dieTextLocked outputLock $
        "wire run does not yet support bound executor authority "
          <> authorityName
          <> " in node "
          <> nodeName
          <> "."

executorArgumentParts :: Maybe CorePureExpr -> Either Text (Record, CorePureExpr)
executorArgumentParts = \case
  Nothing -> Right (Record [], CorePureLit CorePureNull)
  Just (CorePureRecord fields) -> do
    let payload = fromMaybe (CorePureLit CorePureNull) (lookupCorePureField "payload" fields)
    record <- Record <$> traverse corePureFieldToWireField fields
    Right (record, payload)
  Just scalar -> Right (Record [], scalar)
  where
    lookupCorePureField fieldName =
      fmap (.corePureFieldValue)
        . find ((== fieldName :| []) . (.corePureFieldPath))
    corePureFieldToWireField field =
      Field field.corePureFieldPath <$> corePureToWireExpr field.corePureFieldValue

corePureToWireExpr :: CorePureExpr -> Either Text Expr
corePureToWireExpr = \case
  CorePureLit (CorePureString value) -> Right (ExprLit (LitString value))
  CorePureLit (CorePureNumber value) -> Right (ExprLit (LitNumber value))
  CorePureLit (CorePureBool value) -> Right (ExprLit (LitBool value))
  CorePureLit CorePureNull -> Left "executor cfg cannot contain null in wire run"
  CorePureIdent name -> Right (ExprIdent (QName (name :| [])))
  CorePureList values -> ExprList <$> traverse corePureToWireExpr values
  CorePureRecord fields ->
    ExprRecord . Record
      <$> traverse
        (\field -> Field field.corePureFieldPath <$> corePureToWireExpr field.corePureFieldValue)
        fields
  other -> Left ("wire run requires statically evaluable executor cfg, got " <> tshow other <> ".")

builtinExecutorFromQName :: WireUseScope -> QName -> Either Text BuiltinExecutor
builtinExecutorFromQName useScope executorName = do
  executorId <-
    case resolveWireExecutorQName useScope executorName of
      Right resolved -> Right resolved
      Left outOfScope ->
        Left ("Executor " <> outOfScope <> " is not in Wire source scope; import it with `use` first.")
  case executorId of
    _ | executorId == stdIoStdinExecutorId -> Right BuiltinExecutorStdin
    _ | executorId == stdIoStdoutExecutorId -> Right BuiltinExecutorStdout
    _ | executorId == stdIoCommandExecutorId -> Right BuiltinExecutorCommand
    _ | executorId == stdIoReadFileExecutorId -> Right BuiltinExecutorReadFile
    _ | executorId == stdIoWriteFileExecutorId -> Right BuiltinExecutorWriteFile
    _ -> Left ("wire run does not yet support executor @" <> executorId)

runStdinNode :: MVar () -> WirePorts -> Record -> IO (Map Text WireValue)
runStdinNode outputLock ports record = do
  let promptText = fromMaybe "" (lookupTextField "prompt" record)
  unless (T.null promptText) $ do
    withMVar outputLock $ \() -> do
      TIO.putStr promptText
      hFlush stdout
  inputText <- TIO.getLine
  wrapSingleOutput outputLock "std.io.stdin" ports (Aeson.String inputText)

runStdoutNode :: MVar () -> NodeInputs -> Record -> CorePureExpr -> IO (Map Text WireValue)
runStdoutNode outputLock nodeInputs record inputExpr = do
  value <- either (dieTextLocked outputLock) pure (lookupExecutorInput nodeInputs inputExpr)
  let rendered = renderOutputValue value.wireValueValue
      newline = fromMaybe True (lookupBoolField "newline" record)
  withMVar outputLock $ \() ->
    if newline
      then TIO.putStrLn rendered
      else TIO.putStr rendered
  noOutputs

runCommandNode
  :: MVar () -> NodeInputs -> WirePorts -> Record -> CorePureExpr -> IO (Map Text WireValue)
runCommandNode outputLock nodeInputs ports record inputExpr = do
  maybeInput <-
    either (dieTextLocked outputLock) pure (lookupOptionalExecutorInput nodeInputs inputExpr)
  commandSpec <- either (dieTextLocked outputLock) pure (commandSpecFromInput record maybeInput)
  commandResult <- executeCommandSpec commandSpec
  when commandSpec.commandSpecEcho $
    echoCommandResult outputLock commandSpec commandResult
  let result = commandResultValue commandSpec commandResult
  wrapSingleOutput outputLock "std.io.command" ports result

runReadFileNode
  :: MVar () -> NodeInputs -> WirePorts -> Record -> CorePureExpr -> IO (Map Text WireValue)
runReadFileNode outputLock nodeInputs ports record inputExpr = do
  maybeInput <-
    either (dieTextLocked outputLock) pure (lookupOptionalExecutorInput nodeInputs inputExpr)
  path <-
    either
      (dieTextLocked outputLock)
      pure
      (filePathFromConfigOrInput "std.io.readFile" record maybeInput)
  result <- try @IOException (TIO.readFile path)
  content <-
    case result of
      Right text -> pure text
      Left err ->
        dieTextLocked outputLock ("std.io.readFile failed for " <> T.pack path <> ": " <> exceptionText err)
  wrapSingleOutput outputLock "std.io.readFile" ports (Aeson.String content)

runWriteFileNode :: MVar () -> NodeInputs -> Record -> CorePureExpr -> IO (Map Text WireValue)
runWriteFileNode outputLock nodeInputs record inputExpr = do
  value <- either (dieTextLocked outputLock) pure (lookupExecutorInput nodeInputs inputExpr)
  path <- either (dieTextLocked outputLock) pure (filePathFromConfig "std.io.writeFile" record)
  result <- try @IOException (TIO.writeFile path (renderOutputValue value.wireValueValue))
  case result of
    Right () -> noOutputs
    Left err ->
      dieTextLocked
        outputLock
        ("std.io.writeFile failed for " <> T.pack path <> ": " <> exceptionText err)

wrapSingleOutput :: MVar () -> Text -> WirePorts -> Aeson.Value -> IO (Map Text WireValue)
wrapSingleOutput outputLock executorName ports value =
  case Map.toList ports.wirePortsOutputs of
    [(portName, _port)] ->
      pure (wrapOutputs Nothing ports (Map.singleton portName value))
    [] ->
      noOutputs
    outputs ->
      dieTextLocked outputLock $
        executorName
          <> " expects zero or one output port in the local runner, got "
          <> tshow (length outputs)
          <> "."

noOutputs :: IO (Map Text WireValue)
noOutputs =
  pure Map.empty

executeCommandSpec :: CommandSpec -> IO CommandRunResult
executeCommandSpec commandSpec
  | commandSpec.commandSpecSkip =
      pure commandSkipped
  | otherwise =
      case commandSpec.commandSpecArgv of
        [] ->
          pure (commandFailure 127 "missing argv")
        program : args -> do
          let createProcess =
                (proc (T.unpack program) (fmap T.unpack args))
                  { cwd = commandSpec.commandSpecCwd
                  }
          result <-
            try @IOException
              ( readCreateProcessWithExitCode
                  createProcess
                  (T.unpack commandSpec.commandSpecStdin)
              )
          case result of
            Left err ->
              pure (commandFailure 127 (tshow err))
            Right (exitCode, outText, errText) -> do
              pure
                ( commandSuccess
                    exitCode
                    (T.pack outText)
                    (T.pack errText)
                    commandSpec.commandSpecSuccessExitCodes
                )

commandSkipped :: CommandRunResult
commandSkipped =
  CommandRunResult
    { commandRunExitCode = Nothing
    , commandRunStdout = ""
    , commandRunStderr = ""
    , commandRunStatus = "skipped"
    , commandRunOk = True
    }

commandFailure :: Int -> Text -> CommandRunResult
commandFailure exitCode stderrText =
  CommandRunResult
    { commandRunExitCode = Just exitCode
    , commandRunStdout = ""
    , commandRunStderr = stderrText
    , commandRunStatus = "error"
    , commandRunOk = False
    }

commandSuccess :: ExitCode -> Text -> Text -> [Int] -> CommandRunResult
commandSuccess exitCode stdoutText stderrText successExitCodes =
  CommandRunResult
    { commandRunExitCode = Just code
    , commandRunStdout = stdoutText
    , commandRunStderr = stderrText
    , commandRunStatus = status
    , commandRunOk = ok
    }
  where
    code = exitCodeToInt exitCode
    ok = code `elem` successExitCodes
    status = if ok then "ok" else "failed"

commandResultValue :: CommandSpec -> CommandRunResult -> Aeson.Value
commandResultValue commandSpec commandResult =
  Aeson.object
    [ "name" Aeson..= commandSpec.commandSpecName
    , "target" Aeson..= commandSpec.commandSpecTarget
    , "argv" Aeson..= commandSpec.commandSpecArgv
    , "cwd" Aeson..= commandSpec.commandSpecCwd
    , "required" Aeson..= commandSpec.commandSpecRequired
    , "skipped" Aeson..= commandSpec.commandSpecSkip
    , "echo" Aeson..= commandSpec.commandSpecEcho
    , "ok" Aeson..= commandResult.commandRunOk
    , "status" Aeson..= commandResult.commandRunStatus
    , "exitCode" Aeson..= commandResult.commandRunExitCode
    , "stdout" Aeson..= commandResult.commandRunStdout
    , "stderr" Aeson..= commandResult.commandRunStderr
    ]

echoCommandResult :: MVar () -> CommandSpec -> CommandRunResult -> IO ()
echoCommandResult outputLock commandSpec commandResult =
  withMVar outputLock $ \() -> do
    TIO.putStrLn ""
    TIO.putStrLn $
      "== "
        <> commandSpec.commandSpecName
        <> " :: "
        <> commandLine
        <> " =="
    TIO.putStrLn $
      "status: "
        <> commandResult.commandRunStatus
        <> ", exit: "
        <> maybe commandResult.commandRunStatus tshow commandResult.commandRunExitCode
    when (T.null commandResult.commandRunStdout && T.null commandResult.commandRunStderr) $
      TIO.putStrLn "(no output)"
    unless (T.null commandResult.commandRunStdout) $ do
      TIO.putStrLn "-- stdout --"
      TIO.putStr (ensureTrailingNewline commandResult.commandRunStdout)
    unless (T.null commandResult.commandRunStderr) $ do
      TIO.putStrLn "-- stderr --"
      TIO.putStr (ensureTrailingNewline commandResult.commandRunStderr)
  where
    commandLine =
      if null commandSpec.commandSpecArgv
        then "<no argv>"
        else T.unwords commandSpec.commandSpecArgv

ensureTrailingNewline :: Text -> Text
ensureTrailingNewline text
  | T.null text = text
  | T.isSuffixOf "\n" text = text
  | otherwise = text <> "\n"

exitCodeToInt :: ExitCode -> Int
exitCodeToInt = \case
  ExitSuccess -> 0
  ExitFailure code -> code

lookupExecutorInput :: NodeInputs -> CorePureExpr -> Either Text WireValue
lookupExecutorInput nodeInputs = \case
  CorePureIdent inputName ->
    case Map.lookup inputName nodeInputs.nodeInputMergedOutputs of
      Just value -> Right value
      Nothing ->
        Left ("wire run could not find input port " <> inputName <> " in the previous node output.")
  CorePureLit CorePureNull ->
    Left "wire run does not have an input value for null."
  other ->
    Left ("wire run only supports simple identifier executor inputs today, got " <> tshow other <> ".")

lookupOptionalExecutorInput :: NodeInputs -> CorePureExpr -> Either Text (Maybe WireValue)
lookupOptionalExecutorInput _nodeInputs (CorePureLit CorePureNull) =
  Right Nothing
lookupOptionalExecutorInput nodeInputs inputExpr =
  Just <$> lookupExecutorInput nodeInputs inputExpr

commandSpecFromInput :: Record -> Maybe WireValue -> Either Text CommandSpec
commandSpecFromInput config maybeInput = do
  inputObject <- traverse wireValueObject maybeInput
  skip <- fieldWithDefault False "skip" inputObject
  argv <- fieldWithDefault (fromMaybe [] (lookupTextListField "argv" config)) "argv" inputObject
  name <- fieldWithDefault (commandNameFromArgv argv) "name" inputObject
  target <- fieldWithDefault Nothing "target" inputObject
  cwdText <- fieldWithDefault (lookupTextField "cwd" config) "cwd" inputObject
  stdinText <- fieldWithDefault "" "stdin" inputObject
  required <- fieldWithDefault True "required" inputObject
  echo <- fieldWithDefault (fromMaybe False (lookupBoolField "echo" config)) "echo" inputObject
  successExitCodes <- fieldWithDefault [0] "successExitCodes" inputObject
  when (not skip && null argv) $
    Left "std.io.command requires argv unless skip is true."
  Right
    CommandSpec
      { commandSpecName = name
      , commandSpecTarget = target
      , commandSpecArgv = argv
      , commandSpecCwd = T.unpack <$> cwdText
      , commandSpecStdin = stdinText
      , commandSpecRequired = required
      , commandSpecSkip = skip
      , commandSpecEcho = echo
      , commandSpecSuccessExitCodes = successExitCodes
      }

wireValueObject :: WireValue -> Either Text Aeson.Object
wireValueObject wireValue =
  case wireValue.wireValueValue of
    Aeson.Object objectValue -> Right objectValue
    value ->
      Left ("std.io.command expected an object input, got " <> renderOutputValue value <> ".")

fieldWithDefault :: Aeson.FromJSON a => a -> Text -> Maybe Aeson.Object -> Either Text a
fieldWithDefault fallback fieldName maybeObject =
  case maybeObject >>= AesonKeyMap.lookup (AesonKey.fromText fieldName) of
    Nothing ->
      Right fallback
    Just value ->
      case Aeson.fromJSON value of
        Aeson.Success parsedValue -> Right parsedValue
        Aeson.Error err ->
          Left ("std.io.command field " <> fieldName <> " is invalid: " <> T.pack err <> ".")

commandNameFromArgv :: [Text] -> Text
commandNameFromArgv = \case
  [] -> "command"
  program : args -> T.unwords (program : args)

filePathFromConfigOrInput :: Text -> Record -> Maybe WireValue -> Either Text FilePath
filePathFromConfigOrInput executorName record maybeInput =
  case maybeInput of
    Just wireValue ->
      case wireValue.wireValueValue of
        Aeson.Object objectValue -> T.unpack <$> requiredObjectTextField executorName "path" objectValue
        _ -> filePathFromConfig executorName record
    Nothing ->
      filePathFromConfig executorName record

filePathFromConfig :: Text -> Record -> Either Text FilePath
filePathFromConfig executorName record =
  case lookupTextField "path" record of
    Just path
      | not (T.null path) -> Right (T.unpack path)
      | otherwise -> Left (executorName <> " config field path must not be empty.")
    Nothing -> Left (executorName <> " requires a path field in config.")

requiredObjectTextField :: Text -> Text -> Aeson.Object -> Either Text Text
requiredObjectTextField executorName fieldName objectValue =
  case AesonKeyMap.lookup (AesonKey.fromText fieldName) objectValue of
    Just (Aeson.String text)
      | not (T.null text) -> Right text
      | otherwise -> Left (executorName <> " input field " <> fieldName <> " must not be empty.")
    Just value ->
      Left
        ( executorName
            <> " input field "
            <> fieldName
            <> " must be a string, got "
            <> renderOutputValue value
            <> "."
        )
    Nothing ->
      Left (executorName <> " requires input field " <> fieldName <> ".")

nodeInputsFromState :: RunState -> [CircuitNodeRef] -> Either Text NodeInputs
nodeInputsFromState state producerRefs = do
  producerOutputs <-
    Map.fromList
      <$> traverse
        ( \producerRef -> do
            let producerId = NodeId producerRef.unCircuitNodeRef
            outputs <-
              maybe
                (Left ("wire run is missing outputs for predecessor node " <> producerRef.unCircuitNodeRef <> "."))
                Right
                (Map.lookup producerId state.runStateOutputsByNode)
            Right (producerId, outputs)
        )
        producerRefs
  let mergedOutputs = Map.unions (Map.elems producerOutputs)
  Right
    NodeInputs
      { nodeInputProducerOutputs = producerOutputs
      , nodeInputMergedOutputs = mergedOutputs
      }

wireInputBundleFromNodeInputs :: NodeInputs -> WireInputBundle
wireInputBundleFromNodeInputs nodeInputs =
  wireInputBundleFromStageInputs $
    Map.map
      (Aeson.toJSON . WireValueSet . Map.elems)
      nodeInputs.nodeInputProducerOutputs

wrapOutputs :: Maybe Text -> WirePorts -> Map Text Aeson.Value -> Map Text WireValue
wrapOutputs producer ports =
  Map.mapWithKey wrapOutput
  where
    wrapOutput portName value =
      let contract =
            maybe portName (.wireOutputPortContract) (Map.lookup portName ports.wirePortsOutputs)
       in WireValue
            { wireValueContract = contract
            , wireValuePort = Just portName
            , wireValuePayloadKind = WirePayloadJson
            , wireValueMediaType = wirePayloadKindMediaType WirePayloadJson
            , wireValueProducer = producer
            , wireValueValue = value
            , wireValueProvenance = Nothing
            }

renderOutputValue :: Aeson.Value -> Text
renderOutputValue = \case
  Aeson.String text -> text
  value -> TE.decodeUtf8 (BSL.toStrict (AesonPretty.encodePretty value))

executionLevels :: CompiledCircuit -> WireFile -> Either Text [[RunnableNode]]
executionLevels compiled wireFile = do
  let nodeMap =
        Map.fromList
          [ (nodeDecl.nodeDeclName, nodeDecl)
          | TopNode nodeDecl <- wireFile.wireFileTopForms
          ]
  levels <- topologyLevels compiled.compiledCircuitTopology
  traverse
    ( traverse
        ( \nodeRef ->
            case Map.lookup nodeRef.unCircuitNodeRef nodeMap of
              Just nodeDecl ->
                Right (sourceRunnableNode nodeRef nodeDecl)
              Nothing ->
                generatedRunnableNode nodeRef
        )
    )
    levels
  where
    sourceRunnableNode nodeRef nodeDecl =
      case nodeDecl.nodeDeclBody of
        NodeBodyPure {} ->
          fromMaybe (RunnableSourceNode nodeDecl) (compiledPureNode nodeRef)
        NodeBodyExecutor {} ->
          RunnableSourceNode nodeDecl

    compiledPureNode nodeRef =
      case Map.lookup nodeRef compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) ->
          case pureTaskConfigFromMetadata taskNode of
            Right config -> Just (RunnableCompiledPure taskNode config)
            Left _err -> Nothing
        Just _other -> Nothing
        Nothing -> Nothing

    generatedRunnableNode nodeRef =
      case Map.lookup nodeRef compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) ->
          case pureTaskConfigFromMetadata taskNode of
            Right config ->
              Right (RunnableCompiledPure taskNode config)
            Left _err ->
              Left
                ( "wire run references generated task node "
                    <> nodeRef.unCircuitNodeRef
                    <> ", but local wire run only supports generated native pure tasks."
                )
        Just compiledNode ->
          Left
            ( "wire run references generated "
                <> compiledNodeKind compiledNode
                <> " node "
                <> nodeRef.unCircuitNodeRef
                <> ", which local wire run does not yet support."
            )
        Nothing ->
          Left ("wire run references unknown node " <> nodeRef.unCircuitNodeRef <> ".")

compiledNodeKind :: CompiledCircuitNode -> Text
compiledNodeKind = \case
  CompiledCircuitTask {} -> "task"
  CompiledCircuitSignal {} -> "signal"
  CompiledCircuitArtifact {} -> "artifact"
  CompiledCircuitRewriteBoundary {} -> "rewrite-boundary"
  CompiledCircuitCondition {} -> "condition"

topologyLevels :: Ord a => Relation a -> Either Text [[a]]
topologyLevels relation =
  go Set.empty (relVertices relation) []
  where
    go done remaining acc
      | Set.null remaining = Right (reverse acc)
      | otherwise =
          let ready =
                Set.filter
                  (\node -> predecessors relation node `Set.isSubsetOf` done)
                  remaining
           in if Set.null ready
                then Left "wire run could not derive an acyclic execution frontier."
                else
                  let done' = done <> ready
                      remaining' = remaining `Set.difference` ready
                   in go done' remaining' (Set.toAscList ready : acc)

useScopeFromWireFile :: NamespaceRegistry -> WireFile -> Either Text WireUseScope
useScopeFromWireFile namespaceRegistry wireFile =
  case applyWireUseSpecs namespaceRegistry (const False) useSpecs of
    Left err -> Left (renderRunUseError err)
    Right scope -> Right scope
  where
    useSpecs =
      [ useSpec
      | TopUse useSpec <- wireFile.wireFileTopForms
      ]

renderRunUseError :: WireUseError -> Text
renderRunUseError = \case
  WireUseUnknownNamespace namespace ->
    "wire run does not know use namespace " <> namespace <> "."
  WireUseUnknownItem namespace itemName ->
    "wire run does not know use item " <> itemName <> " in namespace " <> namespace <> "."
  WireUseDuplicateBinding name ->
    "Wire file binds name " <> name <> " more than once."

lowerPortSignature :: WireUseScope -> [PortDecl] -> Either Text LoweredPorts
lowerPortSignature useScope portSig = do
  let inputs =
        [ (label, resolveWireContract useScope contractName, WireInputCardinalityOne)
        | PortInputDecl label (ContractId contractName) <- portSig
        ]
      outputs =
        flattenOutputs
      loweredInputs =
        zipWith
          ( \idx (label, contractName, cardinality) ->
              LoweredPort
                { loweredPortName = allocatedPortName True idx label contractName (length inputs)
                , loweredPortLabel = label
                , loweredPortContract = contractName
                , loweredPortCardinality = Just cardinality
                }
          )
          [1 ..]
          inputs
      loweredOutputs =
        zipWith
          ( \idx (label, contractName) ->
              LoweredPort
                { loweredPortName = allocatedPortName False idx label contractName (length outputs)
                , loweredPortLabel = label
                , loweredPortContract = contractName
                , loweredPortCardinality = Nothing
                }
          )
          [1 ..]
          outputs
      duplicateInputs = duplicateNames (fmap (.loweredPortName) loweredInputs)
      duplicateOutputs = duplicateNames (fmap (.loweredPortName) loweredOutputs)
  case duplicateInputs <> duplicateOutputs of
    duplicatePort : _ -> Left ("duplicate lowered port name " <> duplicatePort <> ".")
    [] ->
      Right
        LoweredPorts
          { loweredInputs = loweredInputs
          , loweredOutputs = loweredOutputs
          }
  where
    flattenOutputs =
      concatMap
        ( \case
            PortOutputDecl label (ContractId contractName) ->
              [(label, resolveWireContract useScope contractName)]
            PortOutputSumDecl variants ->
              [ (variant.svLabel, resolveWireContract useScope variant.svContract.unContractId)
              | variant <- NE.toList variants
              ]
            PortInputDecl {} ->
              []
        )
        portSig

wirePortsFromLowered :: LoweredPorts -> WirePorts
wirePortsFromLowered loweredPorts =
  WirePorts
    { wirePortsInputs =
        Map.fromList
          [ ( port.loweredPortName
            , WireInputPort
                { wireInputPortAccepts = [port.loweredPortContract]
                , wireInputPortCardinality = fromMaybe WireInputCardinalityMany port.loweredPortCardinality
                , wireInputPortRequired = False
                }
            )
          | port <- loweredPorts.loweredInputs
          ]
    , wirePortsOutputs =
        Map.fromList
          [ ( port.loweredPortName
            , WireOutputPort
                { wireOutputPortContract = port.loweredPortContract
                , wireOutputPortExclusiveGroup = Nothing
                }
            )
          | port <- loweredPorts.loweredOutputs
          ]
    }

pureOutputConfigMap
  :: WireUseScope -> [LoweredPort] -> NonEmpty PureOutputEquation -> Either Text (Map Text CorePureExpr)
pureOutputConfigMap useScope outputPorts outputEquations = do
  let outputEquationList = NE.toList outputEquations
  when (length outputPorts /= length outputEquationList) $
    Left "pure output equations do not match lowered output ports."
  Map.fromList <$> zipWithM matchOutput outputPorts outputEquationList
  where
    matchOutput port outputEquation = do
      let ContractId rawContractName = outputEquation.pureOutputEquationContract
          contractName = resolveWireContract useScope rawContractName
      when
        ( port.loweredPortLabel /= outputEquation.pureOutputEquationLabel
            || port.loweredPortContract /= contractName
        )
        (Left "pure output equation does not match its lowered output port.")
      Right (port.loweredPortName, outputEquation.pureOutputEquationExpr)

allocatedPortName :: Bool -> Int -> PortLabel -> Text -> Int -> Text
allocatedPortName isInput idx portLabel contractName totalPorts =
  case portLabel of
    Label labelText -> labelText
    NoLabel
      | totalPorts == 1 ->
          if isInput then "in" else "out"
      | otherwise ->
          contractName <> "_" <> tshow idx

duplicateNames :: Eq a => [a] -> [a]
duplicateNames names =
  [ name
  | name <- nub names
  , length (filter (== name) names) > 1
  ]

lookupTextField :: Text -> Record -> Maybe Text
lookupTextField name (Record fields) =
  firstJust
    [ case field of
        Field (fieldName NE.:| []) (ExprLit (LitString value))
          | fieldName == name -> Just value
        Field (fieldName NE.:| []) (ExprLit (LitMultilineString value))
          | fieldName == name -> Just value
        _ -> Nothing
    | field <- fields
    ]

lookupBoolField :: Text -> Record -> Maybe Bool
lookupBoolField name (Record fields) =
  firstJust
    [ case field of
        Field (fieldName NE.:| []) (ExprLit (LitBool value))
          | fieldName == name -> Just value
        _ -> Nothing
    | field <- fields
    ]

lookupTextListField :: Text -> Record -> Maybe [Text]
lookupTextListField name (Record fields) =
  firstJust
    [ case field of
        Field (fieldName NE.:| []) (ExprList items)
          | fieldName == name ->
              traverse exprText items
        _ -> Nothing
    | field <- fields
    ]

exprText :: Expr -> Maybe Text
exprText = \case
  ExprLit (LitString value) -> Just value
  ExprLit (LitMultilineString value) -> Just value
  _ -> Nothing

firstJust :: [Maybe a] -> Maybe a
firstJust = \case
  [] -> Nothing
  Just value : _ -> Just value
  Nothing : rest -> firstJust rest

tshow :: Show a => a -> Text
tshow =
  T.pack . show

exceptionText :: IOException -> Text
exceptionText =
  T.pack . displayException

dieText :: Text -> IO a
dieText errText = do
  TIO.hPutStrLn stderr errText
  exitFailure

dieTextLocked :: MVar () -> Text -> IO a
dieTextLocked outputLock errText =
  -- Mask so sibling cancellation cannot interleave this stderr write.
  uninterruptibleMask_ $ do
    withMVar outputLock $ \() -> do
      TIO.hPutStrLn stderr errText
      hFlush stderr
    exitFailure
