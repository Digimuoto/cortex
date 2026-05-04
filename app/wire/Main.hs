{- |
Module      : Main
Description : Command-line entry point for local Wire source workflows.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The command is intentionally small in this first slice. It exposes the public
Wire compile surface and a local smoke runner for linear stdin -> CorePure ->
stdout examples. Durable execution remains the job of Pulse.
-}
module Main (main) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (IOException, displayException, try, uninterruptibleMask_)
import Control.Monad (foldM, unless, when, zipWithM)
import Data.Aeson qualified as Aeson
import Data.Aeson.Encode.Pretty qualified as AesonPretty
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.ByteString.Lazy qualified as BSL
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitFailure)
import System.IO (hFlush, stderr, stdout)
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)

import Cortex.Algebra.Graph (Relation, predecessors, relVertices)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Wire
  ( CircuitNodeRef (..)
  , CompiledCircuit (..)
  , ContractId (..)
  , CorePureBinding (..)
  , CorePureExpr (..)
  , CorePureLiteral (..)
  , ExecutorCall (..)
  , Expr (..)
  , Field (..)
  , LetRhs (..)
  , Literal (..)
  , NodeBody (..)
  , NodeDecl (..)
  , NodePureBody (..)
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
  , compileWireFile
  , compileWireFileWithReturn
  , evaluatePureTaskOutputs
  , parseWireFile
  , renderParseError
  , renderPureEvalError
  , renderWireError
  , stdIoCommandExecutorId
  , stdIoReadFileExecutorId
  , stdIoStdinExecutorId
  , stdIoStdoutExecutorId
  , stdIoWriteFileExecutorId
  , wireInputBundleFromStageInputs
  , wirePayloadKindMediaType
  )
import Cortex.Wire.Use
  ( WireUseError (..)
  , WireUseScope
  , applyWireUseSpecs
  , resolveWireContract
  , resolveWireExecutorQName
  )

data Command
  = CommandBuild !(Maybe Text) !FilePath
  | CommandRun !FilePath
  | CommandHelp
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
  command <- parseCommand <$> getArgs
  case command of
    Left errText -> dieText errText
    Right CommandHelp -> TIO.putStr usageText
    Right (CommandBuild maybeSelectedReturn path) -> buildWire maybeSelectedReturn path
    Right (CommandRun path) -> runWire path

parseCommand :: [String] -> Either Text Command
parseCommand = \case
  [] -> Right CommandHelp
  ["--help"] -> Right CommandHelp
  ["-h"] -> Right CommandHelp
  ["build", path] -> Right (CommandBuild Nothing path)
  ["build", "--return", selectedReturn, path] ->
    Right (CommandBuild (Just (T.pack selectedReturn)) path)
  ["run", path] -> Right (CommandRun path)
  [path] -> Right (CommandRun path)
  "build" : _ -> Left "usage: wire build [--return NAME] FILE"
  "run" : _ -> Left "usage: wire run FILE"
  _ -> Left usageText

usageText :: Text
usageText =
  T.unlines
    [ "wire - work with Wire source files"
    , ""
    , "usage:"
    , "  wire FILE"
    , "  wire run FILE"
    , "  wire build [--return NAME] FILE"
    , ""
    , "The local runner currently supports stdin/stdout executors plus CorePure DAG frontiers."
    ]

buildWire :: Maybe Text -> FilePath -> IO ()
buildWire maybeSelectedReturn path = do
  wireFile <- readAndParseWireFile path
  let compile =
        maybe compileWireFile compileWireFileWithReturn maybeSelectedReturn
  compiled <- either (dieText . renderWireError) pure (compile wireFile)
  BSL.putStr (AesonPretty.encodePretty compiled)
  BSL.putStr "\n"

runWire :: FilePath -> IO ()
runWire path = do
  wireFile <- readAndParseWireFile path
  compiled <- either (dieText . renderWireError) pure (compileWireFile wireFile)
  useScope <- either dieText pure (useScopeFromWireFile wireFile)
  nodePlan <- either dieText pure (executionLevels compiled wireFile)
  outputLock <- newMVar ()
  let pureBindings = topLevelPureBindings wireFile
  _finalState <- foldM (runNodeLevel outputLock useScope pureBindings compiled) emptyRunState nodePlan
  pure ()

readAndParseWireFile :: FilePath -> IO WireFile
readAndParseWireFile path = do
  source <- TIO.readFile path
  either (dieText . renderParseError) pure (parseWireFile path source)

emptyRunState :: RunState
emptyRunState =
  RunState
    { runStateOutputsByNode = Map.empty
    }

runNodeLevel
  :: MVar ()
  -> WireUseScope
  -> [CorePureBinding]
  -> CompiledCircuit
  -> RunState
  -> [NodeDecl]
  -> IO RunState
runNodeLevel outputLock useScope pureBindings compiled state nodeDecls = do
  levelOutputs <-
    mapConcurrently
      ( \nodeDecl -> do
          let nodeRef = CircuitNodeRef nodeDecl.nodeDeclName
              nodeId = NodeId nodeDecl.nodeDeclName
              directPredecessors =
                Set.toAscList (predecessors compiled.compiledCircuitTopology nodeRef)
          nodeInputs <- either (dieTextLocked outputLock) pure (nodeInputsFromState state directPredecessors)
          outputs <- runNode outputLock useScope pureBindings nodeInputs nodeDecl
          pure (nodeId, outputs)
      )
      nodeDecls
  pure
    state
      { runStateOutputsByNode =
          Map.union (Map.fromList levelOutputs) state.runStateOutputsByNode
      }

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
  outputExprs <-
    either
      (dieTextLocked outputLock)
      pure
      (pureOutputConfigMap useScope loweredPorts.loweredOutputs pureBody.nodePureBodyOutputs)
  outputValues <-
    either
      (dieTextLocked outputLock . renderPureEvalError)
      pure
      ( evaluatePureTaskOutputs
          ports
          (wireInputBundleFromNodeInputs nodeInputs)
          pureBindings
          pureBody.nodePureBodyWhere
          outputExprs
      )
  pure (wrapOutputs Nothing ports outputValues)

runExecutorNode
  :: MVar ()
  -> WireUseScope
  -> Text
  -> NodeInputs
  -> WirePorts
  -> ExecutorCall
  -> IO (Map Text WireValue)
runExecutorNode outputLock useScope nodeName nodeInputs ports = \case
  ExecutorCallInline executorName record inputExpr ->
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
  ExecutorCallConfigured configuredName _inputExpr ->
    dieTextLocked outputLock $
      "wire run does not yet support configured executor "
        <> configuredName
        <> " in node "
        <> nodeName
        <> "."

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

executionLevels :: CompiledCircuit -> WireFile -> Either Text [[NodeDecl]]
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
            maybe
              (Left ("wire run references unknown node " <> nodeRef.unCircuitNodeRef <> "."))
              Right
              (Map.lookup nodeRef.unCircuitNodeRef nodeMap)
        )
    )
    levels

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

topLevelPureBindings :: WireFile -> [CorePureBinding]
topLevelPureBindings wireFile =
  [ CorePureBinding
      { corePureBindingName = name
      , corePureBindingExpr = expr
      }
  | TopLet _visibility name (LetRhsCorePure expr) <- wireFile.wireFileTopForms
  ]

useScopeFromWireFile :: WireFile -> Either Text WireUseScope
useScopeFromWireFile wireFile =
  case applyWireUseSpecs (const False) useSpecs of
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
      duplicatePorts = duplicateNames (fmap (.loweredPortName) loweredInputs <> fmap (.loweredPortName) loweredOutputs)
  case duplicatePorts of
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
            , WireOutputPort {wireOutputPortContract = port.loweredPortContract}
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
