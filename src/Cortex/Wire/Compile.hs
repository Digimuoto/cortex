{- |
Module      : Cortex.Wire.Compile
Description : Wire support for compile.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.Compile
  ( compileWireFile
  , compileWireFileWithEnv
  , compileWireFileWithReturn
  , compileWireFileWithReturnAndEnv
  , compileWireFragmentFile
  , compileWireFragmentFileWithEnv
  , compileWireText
  , compileWireTextWithEnv
  , compileWireTextWithReturn
  , compileWireTextWithReturnAndEnv
  , compileWireFragmentText
  , compileWireFragmentTextWithEnv
  , WireModuleId (..)
  , WireModule (..)
  , WireModuleExports
  , compileWireModules
  , compileWireModulesForRun
  , compileWireModulesWithReturn
  )
where

import Control.Applicative ((<|>))
import Control.Monad (guard, unless, when, zipWithM)
import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BSL
import Data.Char qualified as Char
import Data.Foldable (foldlM, traverse_)
import Data.Int (Int32)
import Data.List (nub, nubBy, sortOn)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing, mapMaybe)
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as Vector
import Numeric.Natural (Natural)

import Cortex.Algebra.Graph
  ( Relation
  , edges
  , reachable
  , relVertices
  , sinks
  , sources
  , toRelation
  , transposeRelation
  , validateDAG
  , vertices
  )
import Cortex.Pulse.Memory.Types (MemoryStrategy (..))
import Cortex.Wire.AST qualified as WireCore
import Cortex.Wire.AdmissionArtifact
  ( AdmissionBoundaryPort (..)
  , AdmissionConnection (..)
  , AdmissionPortLabel (..)
  , AdmissionStaticField (..)
  , AdmissionStaticValue (..)
  , GeneratedChildArtifact (..)
  , GeneratedChildSourceArtifact (..)
  , GeneratedFormArtifact (..)
  , GeneratedFormKind (..)
  , PhantomAdapterArtifact (..)
  , PhantomAdapterDirection (..)
  , PrimitiveGraphStep (..)
  , ProductShapeArtifact (..)
  , SelectAdmissionArtifact (..)
  , SelectArmAdmissionArtifact (..)
  , SelectResolutionMode (..)
  , SelectVariantArtifact (..)
  , WireAdmissionArtifact (..)
  , WireAdmissionClosureMode (..)
  , appendGeneratedFormArtifact
  , appendPhantomAdapterArtifact
  , appendPrimitiveStep
  , appendSelectAdmissionArtifact
  , combineWireAdmissionArtifacts
  , emptyWireAdmissionArtifact
  , finalizeWireAdmissionArtifact
  , wireAdmissionMetadataKey
  , wireAdmissionMetadataValue
  )
import Cortex.Wire.AdmissionBundle
  ( AdmissionBundleError (..)
  , admitWireAdmissionBundle
  )
import Cortex.Wire.Circuit.Artifact
  ( CircuitCompatibilityWitness (..)
  , CircuitConditionNode (..)
  , CompiledCircuit (..)
  , CompiledCircuitFragment (..)
  , CompiledCircuitNode (..)
  )
import Cortex.Wire.Circuit.IR
  ( CircuitArtifactBoundary (..)
  , CircuitCondition (..)
  , CircuitNodeRef (..)
  , CircuitRewriteBoundary (..)
  , CircuitSignalBoundary (..)
  , CircuitTaskNode (..)
  )
import Cortex.Wire.Contract
  ( WireCompileEnv (..)
  , WireContractRegistry (..)
  , WireContractSpec (..)
  , WireProjectionMode (..)
  , emptyWireCompileEnv
  , portsMetadataValue
  )
import Cortex.Wire.Executor
  ( WireExecutorPortPolicy (..)
  , WireExecutorProjection (..)
  , lookupWireExecutorProjection
  , wireExecutorIdFromWireExecutor
  , wireExecutorIdToText
  , wireExecutorRegistryVocabulary
  )
import Cortex.Wire.NodeBoundary
  ( artifactNodeBoundaryNormalForm
  , executorNodeBoundaryNormalForm
  , normalFormPorts
  , pureNodeBoundaryNormalForm
  , pureSumNodeBoundaryNormalForm
  , signalNodeBoundaryNormalForm
  , validateNodeBoundaryNormalForm
  )
import Cortex.Wire.Package qualified as Package
import Cortex.Wire.Parser
  ( GeneratedFamilyChild (..)
  , GeneratedFamilyKind (..)
  , GeneratedFamilyProvenance (..)
  , WireParseInfo (..)
  , parseWireFileWithInfo
  , renderParseError
  )
import Cortex.Wire.Pure
  ( PureEvalError (..)
  , corePureStaticContextFromBindings
  , corePureWhereStaticFields
  , renderPureEvalError
  , validatePureTaskConfig
  , validatePureVariantTaskConfig
  )
import Cortex.Wire.Std
  ( stdIoCommandExecutorId
  , stdIoCommandShapeMessage
  , stdIoReadFileExecutorId
  , stdIoReadFileShapeMessage
  , stdIoStdinExecutorId
  , stdIoStdinShapeMessage
  , stdIoStdoutExecutorId
  , stdIoStdoutShapeMessage
  , stdIoWriteFileExecutorId
  , stdIoWriteFileShapeMessage
  )
import Cortex.Wire.Syntax
import Cortex.Wire.Use
  ( WireUseError (..)
  , WireUseScope (..)
  , applyWireUseSpec
  , emptyWireUseScope
  , resolveWireContract
  , resolveWireExecutorQName
  , wireUseDeclaredContracts
  )

compileWireText :: Text -> Either WireCore.WireError CompiledCircuit
compileWireText =
  compileWireTextWithEnv emptyWireCompileEnv

compileWireTextWithEnv :: WireCompileEnv -> Text -> Either WireCore.WireError CompiledCircuit
compileWireTextWithEnv compileEnv sourceText = do
  (parseInfo, wireFile) <-
    mapLeft
      (WireCore.WireParseError . renderParseError)
      (parseWireFileWithInfo "wire" sourceText)
  compileWireParsedFileWithEnv compileEnv parseInfo wireFile

compileWireTextWithReturn :: Text -> Text -> Either WireCore.WireError CompiledCircuit
compileWireTextWithReturn =
  compileWireTextWithReturnAndEnv emptyWireCompileEnv

compileWireTextWithReturnAndEnv
  :: WireCompileEnv -> Text -> Text -> Either WireCore.WireError CompiledCircuit
compileWireTextWithReturnAndEnv compileEnv selectedReturn sourceText = do
  (parseInfo, wireFile) <-
    mapLeft
      (WireCore.WireParseError . renderParseError)
      (parseWireFileWithInfo "wire" sourceText)
  compileWireParsedFileWithReturnAndEnv compileEnv parseInfo selectedReturn wireFile

compileWireFragmentText :: Text -> Either WireCore.WireError CompiledCircuit
compileWireFragmentText =
  compileWireFragmentTextWithEnv emptyWireCompileEnv

compileWireFragmentTextWithEnv
  :: WireCompileEnv -> Text -> Either WireCore.WireError CompiledCircuit
compileWireFragmentTextWithEnv compileEnv sourceText = do
  (parseInfo, wireFile) <-
    mapLeft
      (WireCore.WireParseError . renderParseError)
      (parseWireFileWithInfo "wire-fragment" sourceText)
  compileWireParsedFragmentFileWithEnv compileEnv parseInfo wireFile

compileWireFile :: WireFile -> Either WireCore.WireError CompiledCircuit
compileWireFile =
  compileWireFileWithEnv emptyWireCompileEnv

compileWireFileWithEnv :: WireCompileEnv -> WireFile -> Either WireCore.WireError CompiledCircuit
compileWireFileWithEnv compileEnv wireFile = do
  lowered <- lowerWireFile compileEnv wireFile
  compileLoweredWireFile compileEnv True wireFile lowered

compileWireParsedFileWithEnv
  :: WireCompileEnv -> WireParseInfo -> WireFile -> Either WireCore.WireError CompiledCircuit
compileWireParsedFileWithEnv compileEnv parseInfo wireFile = do
  lowered <-
    lowerWireFileWithProvenance
      compileEnv
      parseInfo.wireParseGeneratedFamilies
      RequireAllDeclaredNodesUsed
      wireFile
  compileLoweredWireFile compileEnv True wireFile lowered

compileWireFileWithReturn :: Text -> WireFile -> Either WireCore.WireError CompiledCircuit
compileWireFileWithReturn =
  compileWireFileWithReturnAndEnv emptyWireCompileEnv

compileWireFileWithReturnAndEnv
  :: WireCompileEnv -> Text -> WireFile -> Either WireCore.WireError CompiledCircuit
compileWireFileWithReturnAndEnv compileEnv selectedReturn wireFile =
  let selectedWireFile =
        wireFile
          { wireFileReturn = Just (ExprIdent (QName (selectedReturn :| [])))
          }
   in do
        lowered <- lowerWireFileWithUnusedPolicy compileEnv AllowUnusedDeclaredNodes selectedWireFile
        compileLoweredWireFile compileEnv True selectedWireFile lowered

compileWireParsedFileWithReturnAndEnv
  :: WireCompileEnv
  -> WireParseInfo
  -> Text
  -> WireFile
  -> Either WireCore.WireError CompiledCircuit
compileWireParsedFileWithReturnAndEnv compileEnv parseInfo selectedReturn wireFile =
  let selectedWireFile =
        wireFile
          { wireFileReturn = Just (ExprIdent (QName (selectedReturn :| [])))
          }
   in do
        lowered <-
          lowerWireFileWithProvenance
            compileEnv
            parseInfo.wireParseGeneratedFamilies
            AllowUnusedDeclaredNodes
            selectedWireFile
        compileLoweredWireFile compileEnv True selectedWireFile lowered

compileWireFragmentFile :: WireFile -> Either WireCore.WireError CompiledCircuit
compileWireFragmentFile =
  compileWireFragmentFileWithEnv emptyWireCompileEnv

compileWireFragmentFileWithEnv
  :: WireCompileEnv -> WireFile -> Either WireCore.WireError CompiledCircuit
compileWireFragmentFileWithEnv compileEnv wireFile = do
  lowered <- lowerWireFile compileEnv wireFile
  compileLoweredWireFile compileEnv False wireFile lowered

-- Text entry points retain parser expansion provenance, so they can emit generated-form
-- admission artifacts for `make`/`makeEach`. Public `WireFile` values are plain surface syntax;
-- their compile path intentionally uses empty provenance rather than trusting caller-supplied
-- generation claims.
compileWireParsedFragmentFileWithEnv
  :: WireCompileEnv -> WireParseInfo -> WireFile -> Either WireCore.WireError CompiledCircuit
compileWireParsedFragmentFileWithEnv compileEnv parseInfo wireFile = do
  lowered <-
    lowerWireFileWithProvenance
      compileEnv
      parseInfo.wireParseGeneratedFamilies
      RequireAllDeclaredNodesUsed
      wireFile
  compileLoweredWireFile compileEnv False wireFile lowered

{- | One parsed module of an import closure. Loading, path resolution, and
ordering are IO concerns owned by "Cortex.Wire.Import"; the compiler consumes
an already-ordered closure purely (dependencies first, root last).
-}
data WireModule = WireModule
  { wireModulePath :: !WireModuleId
  -- ^ Canonical identity of the module; unique within a closure.
  , wireModuleDisplayPath :: !Text
  -- ^ Path used in diagnostics.
  , wireModuleParseInfo :: !WireParseInfo
  , wireModuleFile :: !WireFile
  , wireModuleImportPaths :: !(Map Text WireModuleId)
  {- ^ Import path text as written in this module, resolved to the canonical
  path of the target module.
  -}
  }
  deriving stock (Eq, Show)

data WireModuleId
  = WireFileModule !FilePath
  | WirePackageModule !Text
  deriving stock (Eq, Ord, Show)

-- | The importable surface of a lowered module.
data WireModuleExports = WireModuleExports
  { wmeDisplayPath :: !Text
  , wmeGraphs :: !(Map Text GraphFragment)
  , wmeValues :: !(Map Text EvalValue)
  , wmePure :: !(Map Text [CorePureBinding])
  {- ^ Exported CorePure bindings together with their in-module support
  closure, in module declaration order.
  -}
  , wmeFileReturn :: !(Maybe GraphFragment)
  , wmePrivateNames :: !(Set.Set Text)
  , wmeContracts :: !(Set.Set Text)
  , wmeRecordContracts :: !(Map Text (Map Text ContractId))
  }
  deriving stock (Eq, Show)

-- | Compile an import closure to the root module's circuit.
compileWireModules
  :: WireCompileEnv -> NonEmpty WireModule -> Either WireCore.WireError CompiledCircuit
compileWireModules compileEnv modules =
  fst <$> compileWireModulesForRun compileEnv modules

{- | Compile an import closure and also return the merged top-level CorePure
bindings, which a local runner needs to evaluate pure nodes whose bindings
were imported from another module.
-}
compileWireModulesForRun
  :: WireCompileEnv
  -> NonEmpty WireModule
  -> Either WireCore.WireError (CompiledCircuit, [CorePureBinding])
compileWireModulesForRun = compileModulesInternal Nothing

{- | Compile an import closure selecting a named graph binding of the root
module as the compiled return, mirroring 'compileWireFileWithReturnAndEnv'.
-}
compileWireModulesWithReturn
  :: WireCompileEnv
  -> Text
  -> NonEmpty WireModule
  -> Either WireCore.WireError CompiledCircuit
compileWireModulesWithReturn compileEnv selectedReturn modules =
  fst <$> compileModulesInternal (Just selectedReturn) compileEnv modules

compileModulesInternal
  :: Maybe Text
  -> WireCompileEnv
  -> NonEmpty WireModule
  -> Either WireCore.WireError (CompiledCircuit, [CorePureBinding])
compileModulesInternal maybeSelectedReturn compileEnv modules = do
  let dependencyModules = NE.init modules
      rootModule = NE.last modules
  exportsByPath <- foldlM (addModuleExports compileEnv) Map.empty dependencyModules
  rootCtx <- moduleImportContext exportsByPath rootModule
  let rootFile = case maybeSelectedReturn of
        Nothing -> rootModule.wireModuleFile
        Just selectedReturn ->
          (rootModule.wireModuleFile)
            { wireFileReturn = Just (ExprIdent (QName (selectedReturn :| [])))
            }
      unusedPolicy = case maybeSelectedReturn of
        Nothing -> RequireAllDeclaredNodesUsed
        Just _ -> AllowUnusedDeclaredNodes
  (lowered, loweredState) <-
    lowerWireFileWithImports
      compileEnv
      rootCtx
      rootModule.wireModuleParseInfo.wireParseGeneratedFamilies
      unusedPolicy
      rootFile
  compiled <- compileLoweredWireFile compileEnv True rootFile lowered
  pure (compiled, loweredState.lsPureBindings)

addModuleExports
  :: WireCompileEnv
  -> Map WireModuleId WireModuleExports
  -> WireModule
  -> Either WireCore.WireError (Map WireModuleId WireModuleExports)
addModuleExports compileEnv exportsByPath wireModule = do
  importCtx <- moduleImportContext exportsByPath wireModule
  moduleExports <- lowerModuleExports compileEnv importCtx wireModule
  Right (Map.insert wireModule.wireModulePath moduleExports exportsByPath)

moduleImportContext
  :: Map WireModuleId WireModuleExports
  -> WireModule
  -> Either WireCore.WireError (Map Text WireModuleExports)
moduleImportContext exportsByPath wireModule =
  traverse lookupExports wireModule.wireModuleImportPaths
  where
    lookupExports resolvedPath =
      case Map.lookup resolvedPath exportsByPath of
        Just moduleExports -> Right moduleExports
        Nothing ->
          Left
            ( WireCore.WireParseError
                ( "internal Wire import closure is out of dependency order at "
                    <> wireModule.wireModuleDisplayPath
                )
            )

-- | Lower a dependency module and compute its importable surface.
lowerModuleExports
  :: WireCompileEnv
  -> Map Text WireModuleExports
  -> WireModule
  -> Either WireCore.WireError WireModuleExports
lowerModuleExports compileEnv importCtx wireModule = do
  let wireFile = wireModule.wireModuleFile
  loweredState <-
    foldlM
      (lowerTopForm compileEnv importCtx)
      (loweringStateWithProvenance wireModule.wireModuleParseInfo.wireParseGeneratedFamilies)
      wireFile.wireFileTopForms
  returnFragment <- moduleReturnFragment compileEnv loweredState wireFile
  let usedNodeRefs =
        foldMap (foldMap loweredNodeRefs . (.gfNodes)) returnFragment
          <> loweredState.lsExportedGraphNodeRefs
  case unusedDeclaredNodeRefs loweredState usedNodeRefs of
    unusedRef : _ -> Left (WireCore.WireUnusedNodeRef unusedRef)
    [] -> Right ()
  let exportedNames = loweredState.lsExportedLetNames
      pureBindingNames =
        Set.fromList (fmap (.corePureBindingName) loweredState.lsPureBindings)
      definedNames =
        Map.keysSet loweredState.lsGraphBindings
          <> Map.keysSet loweredState.lsBindings
          <> Map.keysSet loweredState.lsNamedNodes
          <> pureBindingNames
  Right
    WireModuleExports
      { wmeDisplayPath = wireModule.wireModuleDisplayPath
      , wmeGraphs = Map.restrictKeys loweredState.lsGraphBindings exportedNames
      , wmeValues = Map.restrictKeys loweredState.lsBindings exportedNames
      , wmePure =
          Map.fromList
            [ (name, pureBindingSupportClosure loweredState.lsPureBindings name)
            | name <- Set.toAscList (Set.intersection exportedNames pureBindingNames)
            ]
      , wmeFileReturn = returnFragment
      , wmePrivateNames = definedNames `Set.difference` exportedNames
      , wmeContracts = loweredState.lsDeclaredContracts
      , wmeRecordContracts = loweredState.lsDeclaredRecordContracts
      }

moduleReturnFragment
  :: WireCompileEnv
  -> LoweringState
  -> WireFile
  -> Either WireCore.WireError (Maybe GraphFragment)
moduleReturnFragment compileEnv st wireFile =
  case wireFile.wireFileReturn of
    Nothing -> Right Nothing
    Just returnExpr
      | isGraphLetExpr st returnExpr -> do
          (fragment, _metadata, st') <- lowerFileReturn compileEnv st returnExpr
          Right (Just (annotateGeneratedFamiliesInFragment st' fragment))
      | otherwise -> Right Nothing

-- | Resolve one @import@ statement against the loaded module surface.
lowerImportSpec
  :: Map Text WireModuleExports
  -> LoweringState
  -> ImportSpec
  -> Either WireCore.WireError LoweringState
lowerImportSpec importCtx st importSpec = do
  let pathText = importSpecPath importSpec
  moduleExports <-
    case Map.lookup pathText importCtx of
      Just moduleExports -> Right moduleExports
      Nothing ->
        Left
          ( WireCore.WireParseError
              ( "import \""
                  <> pathText
                  <> "\" requires file-based compilation; compile through the module loader"
                  <> " (wire build/run or Cortex.Wire.Import)"
              )
          )
  stWithContracts <- mergeAmbientContracts moduleExports st
  case importSpec of
    ImportNamed name _path ->
      case moduleExports.wmeFileReturn of
        Nothing ->
          Left
            ( WireCore.WireParseError
                ( "imported file "
                    <> moduleExports.wmeDisplayPath
                    <> " has no graph-valued file-return to import as "
                    <> name
                )
            )
        Just fragment ->
          bindImportedGraph moduleExports name fragment stWithContracts
    ImportExplicit names _path ->
      foldlM (bindImportedName moduleExports) stWithContracts names

importSpecPath :: ImportSpec -> Text
importSpecPath = \case
  ImportNamed _name path -> path
  ImportExplicit _names path -> path

{- | Contracts are ambient once a file is loaded: every import merges the
imported module's contract surface. Identical shapes merge silently; a
shape conflict is an error.
-}
mergeAmbientContracts
  :: WireModuleExports -> LoweringState -> Either WireCore.WireError LoweringState
mergeAmbientContracts moduleExports st = do
  traverse_ checkContract (Set.toAscList moduleExports.wmeContracts)
  Right
    st
      { lsDeclaredContracts = st.lsDeclaredContracts <> moduleExports.wmeContracts
      , lsDeclaredRecordContracts =
          st.lsDeclaredRecordContracts <> moduleExports.wmeRecordContracts
      , lsAmbientContracts = st.lsAmbientContracts <> moduleExports.wmeContracts
      }
  where
    checkContract contractName
      | Set.member contractName st.lsDeclaredContracts =
          if Map.lookup contractName st.lsDeclaredRecordContracts
            == Map.lookup contractName moduleExports.wmeRecordContracts
            then Right ()
            else
              Left
                ( WireCore.WireParseError
                    ( "contract "
                        <> contractName
                        <> " imported from "
                        <> moduleExports.wmeDisplayPath
                        <> " conflicts with an existing declaration of a different shape"
                    )
                )
      | topLevelBindingNameTaken st contractName =
          Left
            ( WireCore.WireParseError
                ( "contract "
                    <> contractName
                    <> " imported from "
                    <> moduleExports.wmeDisplayPath
                    <> " collides with an existing non-contract binding"
                )
            )
      | otherwise = Right ()

bindImportedGraph
  :: WireModuleExports
  -> Text
  -> GraphFragment
  -> LoweringState
  -> Either WireCore.WireError LoweringState
bindImportedGraph moduleExports name fragment st = do
  when (topLevelBindingNameTaken st name) (Left (WireCore.WireDuplicateLetBinding name))
  foreignRefs <-
    foldlM recordForeignNodeRef st.lsForeignNodeRefs (Map.keys fragment.gfNodes)
  Right
    st
      { lsGraphBindings = Map.insert name fragment st.lsGraphBindings
      , lsForeignNodeRefs = foreignRefs
      }
  where
    localNodeRefs = Set.fromList (fmap (.lnRef) (Map.elems st.lsNamedNodes))

    recordForeignNodeRef refs nodeRef
      | Set.member nodeRef localNodeRefs =
          Left
            ( WireCore.WireParseError
                ( "graph "
                    <> name
                    <> " imported from "
                    <> moduleExports.wmeDisplayPath
                    <> " contains node "
                    <> nodeRef.unCircuitNodeRef
                    <> ", which collides with a locally declared node"
                )
            )
      | otherwise =
          case Map.lookup nodeRef refs of
            Just existingSource
              | existingSource == moduleExports.wmeDisplayPath ->
                  -- The same module surface reached through two import
                  -- routes refers to the same node instance; linearity
                  -- rules govern its use, not the import.
                  Right refs
              | otherwise ->
                  Left
                    ( WireCore.WireParseError
                        ( "graph "
                            <> name
                            <> " imported from "
                            <> moduleExports.wmeDisplayPath
                            <> " contains node "
                            <> nodeRef.unCircuitNodeRef
                            <> ", which collides with a node imported from "
                            <> existingSource
                        )
                    )
            Nothing ->
              Right (Map.insert nodeRef moduleExports.wmeDisplayPath refs)

bindImportedName
  :: WireModuleExports -> LoweringState -> Text -> Either WireCore.WireError LoweringState
bindImportedName moduleExports st name
  | Just fragment <- Map.lookup name moduleExports.wmeGraphs =
      bindImportedGraph moduleExports name fragment st
  | Just value <- Map.lookup name moduleExports.wmeValues = do
      when (topLevelBindingNameTaken st name) (Left (WireCore.WireDuplicateLetBinding name))
      let st' = st {lsBindings = Map.insert name value st.lsBindings}
      Right (appendPureBindingIfCapturable name value st')
  | Just supportClosure <- Map.lookup name moduleExports.wmePure =
      foldlM (appendImportedPureBinding moduleExports name) st supportClosure
  | Set.member name moduleExports.wmePrivateNames =
      Left
        ( WireCore.WireParseError
            ( "file "
                <> moduleExports.wmeDisplayPath
                <> " defines "
                <> name
                <> " but does not export it; mark it `export let "
                <> name
                <> " = ...`"
            )
        )
  | otherwise =
      Left
        ( WireCore.WireParseError
            ( "file "
                <> moduleExports.wmeDisplayPath
                <> " does not export "
                <> name
            )
        )

{- | Add one imported CorePure binding. A support dependency that is already
present with an identical expression merges silently, so diamond imports of
the same helper stay legal; any other collision is an error.
-}
appendImportedPureBinding
  :: WireModuleExports
  -> Text
  -> LoweringState
  -> CorePureBinding
  -> Either WireCore.WireError LoweringState
appendImportedPureBinding moduleExports importedName st binding =
  case existingExpr of
    Just expr
      | expr == binding.corePureBindingExpr -> Right st
      | otherwise -> Left collisionError
    Nothing
      | topLevelBindingNameTaken st binding.corePureBindingName -> Left collisionError
      | otherwise ->
          Right st {lsPureBindings = st.lsPureBindings <> [binding]}
  where
    existingExpr =
      lookup
        binding.corePureBindingName
        [ (existing.corePureBindingName, existing.corePureBindingExpr)
        | existing <- st.lsPureBindings
        ]

    collisionError =
      WireCore.WireParseError $
        if binding.corePureBindingName == importedName
          then
            "imported binding "
              <> importedName
              <> " from "
              <> moduleExports.wmeDisplayPath
              <> " collides with an existing binding"
          else
            "binding "
              <> binding.corePureBindingName
              <> ", imported from "
              <> moduleExports.wmeDisplayPath
              <> " as a dependency of "
              <> importedName
              <> ", collides with an existing binding"

{- | The dependency-closed slice of a module's CorePure bindings needed by
one exported binding, in module declaration order.
-}
pureBindingSupportClosure :: [CorePureBinding] -> Text -> [CorePureBinding]
pureBindingSupportClosure moduleBindings rootName =
  [ binding
  | binding <- moduleBindings
  , Set.member binding.corePureBindingName neededNames
  ]
  where
    bindingsByName =
      Map.fromList
        [ (binding.corePureBindingName, binding)
        | binding <- moduleBindings
        ]

    neededNames = grow (Set.singleton rootName) [rootName]

    grow seen [] = seen
    grow seen (name : queue) =
      case Map.lookup name bindingsByName of
        Nothing -> grow seen queue
        Just binding ->
          let references =
                corePureFreeNames Set.empty binding.corePureBindingExpr
                  `Set.intersection` Map.keysSet bindingsByName
              fresh = references `Set.difference` seen
           in grow (seen <> fresh) (queue <> Set.toAscList fresh)

compileLoweredWireFile
  :: WireCompileEnv
  -> Bool
  -> WireFile
  -> LoweredWireFile
  -> Either WireCore.WireError CompiledCircuit
compileLoweredWireFile compileEnv requireConnected wireFile lowered = do
  relation <- fragmentRelation requireConnected lowered.lwfFragment
  validateKnownContracts
    compileEnv
    lowered.lwfDeclaredContracts
    (Map.map (.lnPorts) lowered.lwfFragment.gfNodes)
  if requireConnected
    then
      validateFragmentContracts
        (Map.map (.lnPorts) lowered.lwfFragment.gfNodes)
        (Map.keysSet lowered.lwfFragment.gfNodes)
        lowered.lwfFragment.gfConnections
    else
      validateFragmentContractsWithOpenEntries
        (Map.map (.lnPorts) lowered.lwfFragment.gfNodes)
        (Map.keysSet lowered.lwfFragment.gfNodes)
        lowered.lwfFragment.gfEntries
        lowered.lwfFragment.gfConnections
  let closureMode =
        if requireConnected
          then AdmissionClosedExecutable
          else AdmissionOpenFragment
      finalizedAdmission =
        finalizeWireAdmissionArtifact closureMode lowered.lwfFragment.gfAdmission
  let metadataValue =
        attachAdmissionMetadata
          lowered.lwfMetadata
          finalizedAdmission
      compiled =
        CompiledCircuit
          { compiledCircuitId = lowered.lwfCircuitId
          , compiledCircuitLabel = lowered.lwfCircuitId
          , compiledCircuitCompatibility = compatibilityWitness wireFile
          , compiledCircuitEntryNodes = Set.toAscList (sources relation)
          , compiledCircuitExitNodes = Set.toAscList (sinks relation)
          , compiledCircuitTopology = relation
          , compiledCircuitNodes = Map.map (.lnCompiledNode) lowered.lwfFragment.gfNodes
          , compiledCircuitMetadata = metadataValue
          }
  -- The artifact and the circuit are derived from the same lowering fragment
  -- through parallel paths; gating on the admission bundle turns that shared
  -- derivation into one enforced boundary instead of a refactor hazard.
  case admitWireAdmissionBundle finalizedAdmission compiled of
    Right _bundle -> pure compiled
    Left bundleError ->
      Left
        ( WireCore.WireParseError
            ( "internal Wire admission bundle was rejected: "
                <> renderAdmissionBundleError bundleError
            )
        )

renderAdmissionBundleError :: AdmissionBundleError -> Text
renderAdmissionBundleError = \case
  AdmissionBundleArtifactNotValidatorReady ->
    "artifact failed validator-ready checks"
  AdmissionBundleCircuitBindingFailed bindingError ->
    "artifact does not bind to the compiled circuit: " <> T.pack (show bindingError)

attachAdmissionMetadata :: Maybe Aeson.Value -> WireAdmissionArtifact -> Aeson.Value
attachAdmissionMetadata maybeMetadata admission =
  let admissionKey = Key.fromText wireAdmissionMetadataKey
      admissionValue = wireAdmissionMetadataValue admission
      base =
        fromMaybe
          (Aeson.object ["format" Aeson..= ("cortex.workflow.wire" :: Text)])
          maybeMetadata
   in case base of
        Aeson.Object objectValue ->
          Aeson.Object (KeyMap.insert admissionKey admissionValue objectValue)
        nonObjectMetadata ->
          -- Preserve a defensive non-object metadata value under "metadata" while
          -- keeping the compiled circuit's public metadata object-shaped.
          Aeson.object
            [ "format" Aeson..= ("cortex.workflow.wire" :: Text)
            , "metadata" Aeson..= nonObjectMetadata
            , admissionKey Aeson..= admissionValue
            ]

data LoweredWireFile = LoweredWireFile
  { lwfFragment :: !GraphFragment
  , lwfMetadata :: !(Maybe Aeson.Value)
  , lwfCircuitId :: !Text
  , lwfDeclaredContracts :: !(Set.Set Text)
  }

data UnusedNodePolicy
  = RequireAllDeclaredNodesUsed
  | AllowUnusedDeclaredNodes
  deriving stock (Eq, Show)

data GeneratedNodeProvenance = GeneratedNodeProvenance
  { generatedNodeProvenanceBinding :: !Text
  , generatedNodeProvenanceKind :: !GeneratedFamilyKind
  , generatedNodeProvenanceKindName :: !Text
  , generatedNodeProvenanceLabel :: !Text
  , generatedNodeProvenanceValue :: !(Maybe CorePureExpr)
  }
  deriving stock (Eq, Show)

data LoweringState = LoweringState
  { lsBindings :: !(Map Text EvalValue)
  , lsPureBindings :: ![CorePureBinding]
  , lsGraphBindings :: !(Map Text GraphFragment)
  , lsGeneratedFamilies :: !(Map Text GeneratedFamilyProvenance)
  , lsGeneratedNodes :: !(Map Text GeneratedNodeProvenance)
  , lsExportedGraphNodeRefs :: !(Set.Set CircuitNodeRef)
  , lsExportedLetNames :: !(Set.Set Text)
  , lsNamedNodes :: !(Map Text LoweredNode)
  , lsForeignNodeRefs :: !(Map CircuitNodeRef Text)
  {- ^ Node refs carried in from imported graph values, mapped to the
  display path of the module that declared them. Used to reject
  cross-module node-name collisions with a useful message.
  -}
  , lsAmbientContracts :: !(Set.Set Text)
  {- ^ Contracts that became ambient through a file import. A local
  redeclaration with an identical shape is a readability no-op;
  a local duplicate of a locally declared contract stays an error.
  -}
  , lsAnonCounter :: !Int
  , lsDeclaredContracts :: !(Set.Set Text)
  , lsDeclaredRecordContracts :: !(Map Text (Map Text ContractId))
  , lsUseScope :: !WireUseScope
  }

emptyLoweringState :: LoweringState
emptyLoweringState =
  LoweringState
    { lsBindings = Map.empty
    , lsPureBindings = []
    , lsGraphBindings = Map.empty
    , lsGeneratedFamilies = Map.empty
    , lsGeneratedNodes = Map.empty
    , lsExportedGraphNodeRefs = Set.empty
    , lsExportedLetNames = Set.empty
    , lsNamedNodes = Map.empty
    , lsForeignNodeRefs = Map.empty
    , lsAmbientContracts = Set.empty
    , lsAnonCounter = 0
    , lsDeclaredContracts = Set.empty
    , lsDeclaredRecordContracts = Map.empty
    , lsUseScope = emptyWireUseScope
    }

loweringStateWithProvenance :: Map Text GeneratedFamilyProvenance -> LoweringState
loweringStateWithProvenance generatedFamilies =
  emptyLoweringState
    { lsGeneratedFamilies = generatedFamilies
    , lsGeneratedNodes = generatedNodeProvenanceMap generatedFamilies
    }

generatedNodeProvenanceMap
  :: Map Text GeneratedFamilyProvenance -> Map Text GeneratedNodeProvenance
generatedNodeProvenanceMap generatedFamilies =
  Map.fromList
    [ ( child.generatedFamilyChildNode
      , GeneratedNodeProvenance
          { generatedNodeProvenanceBinding = family.generatedFamilyBinding
          , generatedNodeProvenanceKind = family.generatedFamilyKind
          , generatedNodeProvenanceKindName = family.generatedFamilyKindName
          , generatedNodeProvenanceLabel = child.generatedFamilyChildLabel
          , generatedNodeProvenanceValue = child.generatedFamilyChildValue
          }
      )
    | family <- Map.elems generatedFamilies
    , child <- family.generatedFamilyChildren
    ]

data EvalValue
  = EvalString !Text
  | EvalNumber !Scientific
  | EvalBool !Bool
  | EvalList ![EvalValue]
  | EvalQName !QName
  | EvalRecord !(Map (NonEmpty Text) EvalValue)
  | EvalConstructor !QName !(Map (NonEmpty Text) EvalValue)
  | EvalExecutor !ExecutorAuthority
  deriving stock (Eq, Show)

newtype ExecutorAuthority = ExecutorAuthority
  { ceExecutorId :: Text
  }
  deriving stock (Eq, Show)

data LoweredPort = LoweredPort
  { lpNodeRef :: !CircuitNodeRef
  , lpDirection :: !PortDirection
  , lpInternalName :: !Text
  , lpContract :: !Text
  , lpLabel :: !PortLabel
  , lpCardinality :: !(Maybe WireCore.WireInputCardinality)
  , lpExclusiveGroup :: !(Maybe Natural)
  }
  deriving stock (Eq, Show)

data LoweredNodePorts = LoweredNodePorts
  { lnpInputs :: ![LoweredPort]
  , lnpOutputs :: ![LoweredPort]
  }
  deriving stock (Eq, Show)

data LoweredNode = LoweredNode
  { lnRef :: !CircuitNodeRef
  , lnCompiledNode :: !CompiledCircuitNode
  , lnPorts :: !WireCore.WirePorts
  , lnInputs :: ![LoweredPort]
  , lnOutputs :: ![LoweredPort]
  , lnGeneratedOrigin :: !(Maybe GeneratedNodeProvenance)
  }
  deriving stock (Eq, Show)

data BoundaryPort = BoundaryPort
  { bpNodeRef :: !CircuitNodeRef
  , bpPortName :: !Text
  , bpContract :: !Text
  , bpLabel :: !PortLabel
  , bpExclusiveGroup :: !(Maybe (CircuitNodeRef, Natural))
  }
  deriving stock (Eq, Ord, Show)

data BoundaryShape = BoundaryShape
  { bsContract :: !Text
  , bsLabel :: !PortLabel
  , bsExclusiveGroup :: !(Maybe Natural)
  }
  deriving stock (Eq, Ord, Show)

admissionLabelFromPortLabel :: PortLabel -> AdmissionPortLabel
admissionLabelFromPortLabel = \case
  NoLabel -> AdmissionNoLabel
  Label labelText -> AdmissionLabel labelText

admissionBoundaryFromPort :: BoundaryPort -> AdmissionBoundaryPort
admissionBoundaryFromPort boundary =
  AdmissionBoundaryPort
    { admissionBoundaryNode = boundary.bpNodeRef
    , admissionBoundaryPort = boundary.bpPortName
    , admissionBoundaryContract = boundary.bpContract
    , admissionBoundaryLabel = admissionLabelFromPortLabel boundary.bpLabel
    , admissionBoundaryExclusiveGroup = boundary.bpExclusiveGroup
    }

admissionConnectionFromPair :: (BoundaryPort, BoundaryPort) -> AdmissionConnection
admissionConnectionFromPair (fromBoundary, toBoundary) =
  AdmissionConnection
    { admissionConnectionFrom = admissionBoundaryFromPort fromBoundary
    , admissionConnectionTo = admissionBoundaryFromPort toBoundary
    }

data GraphFragment = GraphFragment
  { gfNodes :: !(Map CircuitNodeRef LoweredNode)
  , gfEntries :: ![BoundaryPort]
  , gfExits :: ![BoundaryPort]
  , gfConnections :: ![WireCore.Connection]
  , gfAdmission :: !WireAdmissionArtifact
  }
  deriving stock (Eq, Show)

emptyFragment :: GraphFragment
emptyFragment =
  GraphFragment
    { gfNodes = Map.empty
    , gfEntries = []
    , gfExits = []
    , gfConnections = []
    , gfAdmission = appendPrimitiveStep PrimitiveEmpty emptyWireAdmissionArtifact
    }

syncFragmentAdmission :: GraphFragment -> GraphFragment
syncFragmentAdmission fragment =
  fragment
    { gfAdmission =
        fragment.gfAdmission
          { wireAdmissionNodes = Map.keys fragment.gfNodes
          , wireAdmissionEntries = fmap admissionBoundaryFromPort fragment.gfEntries
          , wireAdmissionExits = fmap admissionBoundaryFromPort fragment.gfExits
          , wireAdmissionConnections = fragment.gfConnections
          }
    }

nodeAdmissionArtifact :: LoweredNode -> WireAdmissionArtifact
nodeAdmissionArtifact loweredNode =
  appendPrimitiveStep (PrimitiveNode loweredNode.lnRef entries exits) $
    emptyWireAdmissionArtifact
      { wireAdmissionNodes = [loweredNode.lnRef]
      , wireAdmissionEntries = entries
      , wireAdmissionExits = exits
      }
  where
    entries =
      fmap (admissionBoundaryFromPort . boundaryFromPort) loweredNode.lnInputs

    exits =
      fmap (admissionBoundaryFromPort . boundaryFromPort) loweredNode.lnOutputs

markGraphBindingRef :: Text -> GraphFragment -> GraphFragment
markGraphBindingRef bindingName fragment =
  fragment
    { gfAdmission =
        appendPrimitiveStep (PrimitiveBindingRef bindingName) $
          fragment.gfAdmission
            { wireAdmissionBindingRefs =
                fragment.gfAdmission.wireAdmissionBindingRefs <> [bindingName]
            }
    }

annotateGeneratedFamiliesInFragment :: LoweringState -> GraphFragment -> GraphFragment
annotateGeneratedFamiliesInFragment state fragment =
  foldl appendFamily fragment (Map.elems state.lsGeneratedFamilies)
  where
    appendFamily current family =
      case generatedFormArtifactForFamily current family of
        Nothing -> current
        Just artifact ->
          current
            { gfAdmission = appendGeneratedFormArtifact artifact current.gfAdmission
            }

generatedFormArtifactForFamily
  :: GraphFragment -> GeneratedFamilyProvenance -> Maybe GeneratedFormArtifact
generatedFormArtifactForFamily fragment family = do
  sourceChildren <- traverse generatedChildSourceArtifact family.generatedFamilyChildren
  let artifact =
        GeneratedFormArtifact
          { generatedFormKind = generatedFormKindFromProvenance family.generatedFamilyKind
          , generatedFormKindName = family.generatedFamilyKindName
          , generatedFormBinding = family.generatedFamilyBinding
          , generatedFormSourceChildren = sourceChildren
          , generatedFormUsedChildren = usedChildren
          }
  case (usedChildren, sourceChildren, familyBindingUsed) of
    ([], [], True) -> Just artifact
    ([], _, _) -> Nothing
    (_ : _, _, _) -> Just artifact
  where
    familyBindingUsed =
      family.generatedFamilyBinding `elem` fragment.gfAdmission.wireAdmissionBindingRefs

    usedChildren =
      mapMaybe generatedChildArtifactIfUsed family.generatedFamilyChildren

    generatedChildArtifactIfUsed child = do
      let childRef = CircuitNodeRef child.generatedFamilyChildNode
      loweredNode <- Map.lookup childRef fragment.gfNodes
      origin <- loweredNode.lnGeneratedOrigin
      guard (origin.generatedNodeProvenanceBinding == family.generatedFamilyBinding)
      guard (origin.generatedNodeProvenanceKind == family.generatedFamilyKind)
      guard (origin.generatedNodeProvenanceKindName == family.generatedFamilyKindName)
      guard (origin.generatedNodeProvenanceLabel == child.generatedFamilyChildLabel)
      guard (origin.generatedNodeProvenanceValue == child.generatedFamilyChildValue)
      pure (generatedChildArtifact child loweredNode)

    generatedChildArtifact child loweredNode =
      GeneratedChildArtifact
        { generatedChildNode = loweredNode.lnRef
        , generatedChildLabel = child.generatedFamilyChildLabel
        , generatedChildOutputs =
            fmap
              (admissionBoundaryFromPort . boundaryFromPort)
              loweredNode.lnOutputs
        , generatedChildInputs =
            fmap
              (admissionBoundaryFromPort . boundaryFromPort)
              loweredNode.lnInputs
        }

generatedChildSourceArtifact :: GeneratedFamilyChild -> Maybe GeneratedChildSourceArtifact
generatedChildSourceArtifact child = do
  staticValue <- traverse admissionStaticValueFromCorePure child.generatedFamilyChildValue
  Just
    GeneratedChildSourceArtifact
      { generatedSourceChildNode = CircuitNodeRef child.generatedFamilyChildNode
      , generatedSourceChildLabel = child.generatedFamilyChildLabel
      , generatedSourceChildValue = staticValue
      }

admissionStaticValueFromCorePure :: CorePureExpr -> Maybe AdmissionStaticValue
admissionStaticValueFromCorePure = \case
  CorePureLit (CorePureString text) ->
    Just (AdmissionStaticString text)
  CorePureLit (CorePureBool boolValue) ->
    Just (AdmissionStaticBool boolValue)
  CorePureLit (CorePureNumber numberValue) -> do
    integerValue <- scientificToNatural numberValue
    Just (AdmissionStaticNat integerValue)
  CorePureLit CorePureNull ->
    Nothing
  CorePureList items ->
    AdmissionStaticList <$> traverse admissionStaticValueFromCorePure items
  CorePureRecord fields -> do
    guard (corePureStaticRecordFieldLabelsUnique fields)
    AdmissionStaticRecord <$> traverse admissionStaticFieldFromCorePure fields
  CorePureIdent _name ->
    Nothing
  CorePureFieldAccess _target _fieldName ->
    Nothing
  CorePureIndex _target _index ->
    Nothing
  CorePureLambda _params _body ->
    Nothing
  CorePureCall _function _arguments ->
    Nothing
  CorePureUnary _operator _value ->
    Nothing
  CorePureBinary _operator _lhs _rhs ->
    Nothing
  CorePureLet _bindings _body ->
    Nothing
  CorePureIf _condition _thenBranch _elseBranch ->
    Nothing

corePureStaticRecordFieldLabelsUnique :: [CorePureField] -> Bool
corePureStaticRecordFieldLabelsUnique fields =
  Set.size (Set.fromList fieldNames) == length fieldNames
  where
    fieldNames =
      [ fieldName
      | CorePureField (fieldName :| []) _value <- fields
      ]

admissionStaticFieldFromCorePure :: CorePureField -> Maybe AdmissionStaticField
admissionStaticFieldFromCorePure = \case
  CorePureField (fieldName :| []) value -> do
    staticValue <- admissionStaticValueFromCorePure value
    Just
      AdmissionStaticField
        { admissionStaticFieldLabel = fieldName
        , admissionStaticFieldValue = staticValue
        }
  CorePureField (_fieldName :| _nestedPath) _value ->
    Nothing

scientificToNatural :: Scientific -> Maybe Natural
scientificToNatural numberValue =
  case floatingOrInteger numberValue :: Either Double Integer of
    Right integerValue
      | integerValue >= 0 -> Just (fromInteger integerValue)
    Right _negativeValue -> Nothing
    Left _fractionalValue -> Nothing

generatedFormKindFromProvenance :: GeneratedFamilyKind -> GeneratedFormKind
generatedFormKindFromProvenance = \case
  GeneratedFamilyFromMake -> GeneratedMake
  GeneratedFamilyFromMakeEach -> GeneratedMakeEach

lowerWireFile :: WireCompileEnv -> WireFile -> Either WireCore.WireError LoweredWireFile
lowerWireFile compileEnv =
  lowerWireFileWithUnusedPolicy compileEnv RequireAllDeclaredNodesUsed

lowerWireFileWithUnusedPolicy
  :: WireCompileEnv -> UnusedNodePolicy -> WireFile -> Either WireCore.WireError LoweredWireFile
lowerWireFileWithUnusedPolicy compileEnv unusedNodePolicy wireFile = do
  lowerWireFileWithProvenance compileEnv Map.empty unusedNodePolicy wireFile

lowerWireFileWithProvenance
  :: WireCompileEnv
  -> Map Text GeneratedFamilyProvenance
  -> UnusedNodePolicy
  -> WireFile
  -> Either WireCore.WireError LoweredWireFile
lowerWireFileWithProvenance compileEnv generatedFamilies unusedNodePolicy wireFile =
  fst <$> lowerWireFileWithImports compileEnv Map.empty generatedFamilies unusedNodePolicy wireFile

lowerWireFileWithImports
  :: WireCompileEnv
  -> Map Text WireModuleExports
  -> Map Text GeneratedFamilyProvenance
  -> UnusedNodePolicy
  -> WireFile
  -> Either WireCore.WireError (LoweredWireFile, LoweringState)
lowerWireFileWithImports compileEnv importCtx generatedFamilies unusedNodePolicy wireFile = do
  loweredState <-
    foldlM
      (lowerTopForm compileEnv importCtx)
      (loweringStateWithProvenance generatedFamilies)
      wireFile.wireFileTopForms
  fileReturn <- maybe (Left WireCore.WireMissingCircuit) Right wireFile.wireFileReturn
  (resultFragment, maybeMetadata, loweredState') <- lowerFileReturn compileEnv loweredState fileReturn
  let witnessedFragment = annotateGeneratedFamiliesInFragment loweredState' resultFragment
  let usedNodeRefs =
        foldMap loweredNodeRefs witnessedFragment.gfNodes
          <> loweredState'.lsExportedGraphNodeRefs
      lowered =
        LoweredWireFile
          { lwfFragment = witnessedFragment
          , lwfMetadata = maybeMetadata
          , lwfCircuitId = fromMaybe "wire" (extractCircuitId maybeMetadata)
          , lwfDeclaredContracts = loweredState'.lsDeclaredContracts
          }
  case (unusedNodePolicy, unusedDeclaredNodeRefs loweredState' usedNodeRefs) of
    (RequireAllDeclaredNodesUsed, unusedRef : _) -> Left (WireCore.WireUnusedNodeRef unusedRef)
    (RequireAllDeclaredNodesUsed, []) -> Right (lowered, loweredState')
    (AllowUnusedDeclaredNodes, _) -> Right (lowered, loweredState')

unusedDeclaredNodeRefs :: LoweringState -> Set.Set CircuitNodeRef -> [CircuitNodeRef]
unusedDeclaredNodeRefs loweredState usedNodeRefs =
  Set.toAscList
    (declaredNodeRefs `Set.difference` usedNodeRefs `Set.difference` generatedNodeRefs)
  where
    declaredNodeRefs = Set.fromList (fmap (.lnRef) (Map.elems loweredState.lsNamedNodes))
    generatedNodeRefs = generatedSiblingRefsForUsedFamilies loweredState usedNodeRefs

loweredNodeRefs :: LoweredNode -> Set.Set CircuitNodeRef
loweredNodeRefs loweredNode =
  Set.insert loweredNode.lnRef $
    case loweredNode.lnCompiledNode of
      CompiledCircuitCondition conditionNode ->
        fragmentNodeRefs conditionNode.circuitConditionNodeThenFragment
          <> foldMap fragmentNodeRefs conditionNode.circuitConditionNodeElseFragment
      CompiledCircuitTask {} ->
        Set.empty
      CompiledCircuitSignal {} ->
        Set.empty
      CompiledCircuitArtifact {} ->
        Set.empty
      CompiledCircuitRewriteBoundary {} ->
        Set.empty
  where
    fragmentNodeRefs fragment =
      foldMap compiledNodeRefs fragment.compiledCircuitFragmentNodes

generatedSiblingRefsForUsedFamilies
  :: LoweringState -> Set.Set CircuitNodeRef -> Set.Set CircuitNodeRef
generatedSiblingRefsForUsedFamilies state usedNodeRefs =
  Set.fromList
    [ CircuitNodeRef child.generatedFamilyChildNode
    | family <- Map.elems state.lsGeneratedFamilies
    , Set.member family.generatedFamilyBinding usedFamilies
    , child <- family.generatedFamilyChildren
    ]
  where
    usedFamilies =
      Set.fromList
        [ origin.generatedNodeProvenanceBinding
        | loweredNode <- Map.elems state.lsNamedNodes
        , Set.member loweredNode.lnRef usedNodeRefs
        , Just origin <- [loweredNode.lnGeneratedOrigin]
        ]

compiledNodeRefs :: CompiledCircuitNode -> Set.Set CircuitNodeRef
compiledNodeRefs = \case
  CompiledCircuitTask taskNode ->
    Set.singleton taskNode.circuitTaskNodeRef
  CompiledCircuitSignal signalBoundary ->
    Set.singleton signalBoundary.circuitSignalBoundaryRef
  CompiledCircuitArtifact artifactBoundary ->
    Set.singleton artifactBoundary.circuitArtifactBoundaryRef
  CompiledCircuitRewriteBoundary rewriteBoundary ->
    Set.singleton rewriteBoundary.circuitRewriteBoundaryRef
  CompiledCircuitCondition conditionNode ->
    Set.insert conditionNode.circuitConditionNodeRef $
      fragmentNodeRefs conditionNode.circuitConditionNodeThenFragment
        <> foldMap fragmentNodeRefs conditionNode.circuitConditionNodeElseFragment
  where
    fragmentNodeRefs fragment =
      foldMap compiledNodeRefs fragment.compiledCircuitFragmentNodes

lowerTopForm
  :: WireCompileEnv
  -> Map Text WireModuleExports
  -> LoweringState
  -> TopForm
  -> Either WireCore.WireError LoweringState
lowerTopForm compileEnv importCtx st = \case
  TopContract contractDeclValue -> do
    let ContractId contractName = contractDeclValue.contractDeclId
        recordFields = fromMaybe [] contractDeclValue.contractDeclRecordFields
        resolvedFields =
          Map.fromList
            [ (fieldName, ContractId (resolveContractId st fieldContract.unContractId))
            | (fieldName, fieldContract) <- recordFields
            ]
        declaredShape =
          case contractDeclValue.contractDeclRecordFields of
            Nothing -> Nothing
            Just _ -> Just resolvedFields
    case duplicatePortNames (fmap fst recordFields) of
      duplicateField : _ ->
        Left
          ( WireCore.WireParseError
              ( "contract "
                  <> contractName
                  <> " declares record field "
                  <> duplicateField
                  <> " more than once"
              )
          )
      [] -> Right ()
    if Set.member contractName st.lsAmbientContracts
      then
        if Map.lookup contractName st.lsDeclaredRecordContracts == declaredShape
          then Right st
          else
            Left
              ( WireCore.WireParseError
                  ( "contract "
                      <> contractName
                      <> " is ambient from a file import with a different shape"
                  )
              )
      else
        if topLevelBindingNameTaken st contractName
          then Left (WireCore.WireDuplicateBinding contractName)
          else
            Right
              st
                { lsDeclaredContracts = Set.insert contractName st.lsDeclaredContracts
                , lsDeclaredRecordContracts =
                    case declaredShape of
                      Nothing -> st.lsDeclaredRecordContracts
                      Just _ -> Map.insert contractName resolvedFields st.lsDeclaredRecordContracts
                }
  TopUse useSpec ->
    lowerUseSpec compileEnv st useSpec
  TopImport importSpec ->
    lowerImportSpec importCtx st importSpec
  TopLet visibility name rhs -> do
    if topLevelBindingNameTaken st name
      then Left (WireCore.WireDuplicateLetBinding name)
      else do
        st' <- case rhs of
          LetRhsCorePure expr -> do
            validateCorePureScope st (WireCore.WireParseError . corePureTopLevelScopeError name) Set.empty expr
            Right
              st
                { lsPureBindings =
                    st.lsPureBindings
                      <> [ CorePureBinding
                             { corePureBindingName = name
                             , corePureBindingExpr = expr
                             }
                         ]
                }
          LetRhsWire expr ->
            lowerWireLetBinding compileEnv visibility st name expr
        Right $
          case visibility of
            LetExported -> st' {lsExportedLetNames = Set.insert name st'.lsExportedLetNames}
            LetPrivate -> st'
  TopNode nodeDecl -> do
    loweredNode <- lowerNamedNode compileEnv st nodeDecl
    let nodeName = nodeDecl.nodeDeclName
    if topLevelBindingNameTaken st nodeName
      then Left (WireCore.WireDuplicateNodeRef loweredNode.lnRef)
      else case Map.lookup loweredNode.lnRef st.lsForeignNodeRefs of
        Just foreignSource ->
          Left
            ( WireCore.WireParseError
                ( "node "
                    <> nodeName
                    <> " collides with a node of the same name inside a graph imported from "
                    <> foreignSource
                )
            )
        Nothing ->
          Right
            st
              { lsNamedNodes = Map.insert nodeName loweredNode st.lsNamedNodes
              }

topLevelBindingNameTaken :: LoweringState -> Text -> Bool
topLevelBindingNameTaken state name =
  Map.member name state.lsBindings
    || Map.member name state.lsGraphBindings
    || Map.member name state.lsNamedNodes
    || Map.member name state.lsUseScope.wireUseExecutors
    || Map.member name state.lsUseScope.wireUseContracts
    || Set.member name state.lsDeclaredContracts
    || any (\existing -> existing.corePureBindingName == name) state.lsPureBindings

lowerUseSpec
  :: WireCompileEnv -> LoweringState -> UseSpec -> Either WireCore.WireError LoweringState
lowerUseSpec compileEnv st useSpec = do
  useScope <-
    mapLeft wireUseErrorToWireError $
      applyWireUseSpec
        (compileEnvNamespaceRegistry compileEnv)
        (topLevelBindingNameTaken st)
        st.lsUseScope
        useSpec
  Right
    st
      { lsUseScope = useScope
      , lsDeclaredContracts = st.lsDeclaredContracts <> wireUseDeclaredContracts useScope
      }

compileEnvNamespaceRegistry :: WireCompileEnv -> Package.NamespaceRegistry
compileEnvNamespaceRegistry compileEnv =
  fromMaybe Package.stdOnlyRegistry compileEnv.wireCompileEnvNamespaceRegistry

wireUseErrorToWireError :: WireUseError -> WireCore.WireError
wireUseErrorToWireError = \case
  WireUseUnknownNamespace namespace ->
    WireCore.WireUnknownUseNamespace namespace
  WireUseUnknownItem namespace itemName ->
    WireCore.WireUnknownUseItem namespace itemName
  WireUseDuplicateBinding name ->
    WireCore.WireDuplicateBinding name

lowerWireLetBinding
  :: WireCompileEnv
  -> LetVisibility
  -> LoweringState
  -> Text
  -> Expr
  -> Either WireCore.WireError LoweringState
lowerWireLetBinding compileEnv visibility st name expr
  | isGraphLetExpr st expr = do
      graphValue <- lowerGraphExpr compileEnv st expr
      let exportedNodeRefs =
            case visibility of
              LetExported ->
                foldMap loweredNodeRefs graphValue.gfNodes
              LetPrivate ->
                Set.empty
      Right
        st
          { lsGraphBindings = Map.insert name graphValue st.lsGraphBindings
          , lsExportedGraphNodeRefs = st.lsExportedGraphNodeRefs <> exportedNodeRefs
          }
  | otherwise = do
      value <- evalValue st expr
      let st' = st {lsBindings = Map.insert name value st.lsBindings}
      Right (appendPureBindingIfCapturable name value st')

isGraphLetExpr :: LoweringState -> Expr -> Bool
isGraphLetExpr st = \case
  ExprOverlay {} -> True
  ExprConnect {} -> True
  ExprStar {} -> True
  ExprSelect {} -> True
  ExprLit LitUnit -> True
  ExprIdent (QName (name :| [])) ->
    Map.member name st.lsNamedNodes || Map.member name st.lsGraphBindings
  ExprFamilyProjection {} -> True
  ExprMerge {} -> False
  ExprConcat {} -> False
  ExprExecutor {} -> False
  ExprConstructor {} -> False
  ExprRecord {} -> False
  ExprList {} -> False
  ExprLit (LitString _text) -> False
  ExprLit (LitMultilineString _text) -> False
  ExprLit (LitNumber _number) -> False
  ExprLit (LitBool _boolValue) -> False
  ExprIdent (QName (_name :| _qualifier)) -> False

appendPureBindingIfCapturable :: Text -> EvalValue -> LoweringState -> LoweringState
appendPureBindingIfCapturable name value st =
  case evalValueToCorePureExpr value of
    Nothing -> st
    Just expr ->
      st
        { lsPureBindings =
            st.lsPureBindings
              <> [ CorePureBinding
                     { corePureBindingName = name
                     , corePureBindingExpr = expr
                     }
                 ]
        }

evalValueToCorePureExpr :: EvalValue -> Maybe CorePureExpr
evalValueToCorePureExpr = \case
  EvalString text -> Just (CorePureLit (CorePureString text))
  EvalNumber numberValue -> Just (CorePureLit (CorePureNumber numberValue))
  EvalBool boolValue -> Just (CorePureLit (CorePureBool boolValue))
  EvalList items ->
    CorePureList <$> traverse evalValueToCorePureExpr items
  EvalRecord fields ->
    CorePureRecord <$> traverse fieldToCorePure (Map.toList fields)
  EvalQName {} -> Nothing
  EvalConstructor {} -> Nothing
  EvalExecutor {} -> Nothing
  where
    fieldToCorePure (path, value) =
      CorePureField path <$> evalValueToCorePureExpr value

lowerNamedNode
  :: WireCompileEnv -> LoweringState -> NodeDecl -> Either WireCore.WireError LoweredNode
lowerNamedNode compileEnv st nodeDecl = do
  let nodeRef = CircuitNodeRef nodeDecl.nodeDeclName
  ports <- lowerPortSignature st nodeRef nodeDecl.nodeDeclPortSig
  loweredNode <- case nodeDecl.nodeDeclBody of
    NodeBodyExecutor whereExpr executorCallValue -> do
      validateWhereClause st nodeRef ports.lnpInputs whereExpr
      loweredNodeFromExecutorCall
        compileEnv
        st
        nodeRef
        ports
        nodeDecl.nodeDeclMetadata
        whereExpr
        executorCallValue
    NodeBodyPure pureBody -> do
      validateWhereClause st nodeRef ports.lnpInputs pureBody.nodePureBodyWhere
      loweredPureNodeFromBody
        compileEnv
        st
        nodeRef
        ports
        nodeDecl.nodeDeclMetadata
        st.lsPureBindings
        pureBody
  Right (loweredNode {lnGeneratedOrigin = Map.lookup nodeDecl.nodeDeclName st.lsGeneratedNodes})

lowerFileReturn
  :: WireCompileEnv
  -> LoweringState
  -> Expr
  -> Either WireCore.WireError (GraphFragment, Maybe Aeson.Value, LoweringState)
lowerFileReturn compileEnv st expr = do
  fragment <- lowerGraphExpr compileEnv st expr
  Right (fragment, Nothing, st)

lowerGraphExpr :: WireCompileEnv -> LoweringState -> Expr -> Either WireCore.WireError GraphFragment
lowerGraphExpr compileEnv st expr =
  case flattenConnectChain expr of
    [singleExpr] ->
      lowerGraphTerm compileEnv st singleExpr
    chainItems ->
      lowerConnectChain compileEnv st chainItems

data ConnectItem = ConnectItem
  { ciBaseExpr :: !Expr
  , ciSelectArms :: !(Maybe (NonEmpty SelectArm))
  }

flattenConnectChain :: Expr -> [Expr]
flattenConnectChain = \case
  ExprConnect lhs rhs -> flattenConnectChain lhs <> flattenConnectChain rhs
  other -> [other]

connectItem :: Expr -> Either WireCore.WireError ConnectItem
connectItem = \case
  ExprSelect baseExpr arms ->
    Right (ConnectItem baseExpr (Just arms))
  other ->
    Right (ConnectItem other Nothing)

isIdentityConnectItem :: ConnectItem -> Bool
isIdentityConnectItem item =
  isNothing item.ciSelectArms
    && case item.ciBaseExpr of
      ExprLit LitUnit -> True
      _ -> False

lowerConnectChain
  :: WireCompileEnv -> LoweringState -> [Expr] -> Either WireCore.WireError GraphFragment
lowerConnectChain compileEnv st exprs = do
  items <- filter (not . isIdentityConnectItem) <$> traverse connectItem exprs
  case items of
    [] ->
      Right emptyFragment
    firstItem : restItems -> do
      initial <- lowerGraphBase compileEnv st firstItem.ciBaseExpr
      stepConnectChain compileEnv st initial firstItem restItems

stepConnectChain
  :: WireCompileEnv
  -> LoweringState
  -> GraphFragment
  -> ConnectItem
  -> [ConnectItem]
  -> Either WireCore.WireError GraphFragment
stepConnectChain compileEnv st current currentItem [] =
  case currentItem.ciSelectArms of
    Nothing ->
      Right current
    Just arms ->
      lowerSelectStep compileEnv st current arms Nothing
stepConnectChain compileEnv st current currentItem (nextItem : restItems) =
  case currentItem.ciSelectArms of
    Just arms -> do
      nextBase <- lowerGraphBase compileEnv st nextItem.ciBaseExpr
      selectReduced <- lowerSelectStep compileEnv st current arms (Just nextBase)
      stepConnectChain compileEnv st selectReduced nextItem restItems
    Nothing -> do
      nextBase <- lowerGraphBase compileEnv st nextItem.ciBaseExpr
      connected <- connectFragments current nextBase
      stepConnectChain compileEnv st connected nextItem restItems

lowerGraphTerm :: WireCompileEnv -> LoweringState -> Expr -> Either WireCore.WireError GraphFragment
lowerGraphTerm compileEnv st = \case
  ExprSelect baseExpr arms -> do
    baseFragment <- lowerGraphBase compileEnv st baseExpr
    lowerSelectStep compileEnv st baseFragment arms Nothing
  other ->
    lowerGraphBase compileEnv st other

lowerGraphBase :: WireCompileEnv -> LoweringState -> Expr -> Either WireCore.WireError GraphFragment
lowerGraphBase compileEnv st = \case
  ExprLit LitUnit ->
    Right emptyFragment
  ExprOverlay lhs rhs -> do
    lhsFragment <- lowerGraphExpr compileEnv st lhs
    rhsFragment <- lowerGraphExpr compileEnv st rhs
    joinGraphFragments "overlay (<>)" lhsFragment rhsFragment
  ExprStar lhs rhs -> do
    lhsFragment <- lowerGraphExpr compileEnv st lhs
    rhsFragment <- lowerGraphExpr compileEnv st rhs
    lowerStarFragments compileEnv st lhsFragment rhsFragment
  ExprIdent (QName (name :| [])) ->
    case Map.lookup name st.lsGraphBindings of
      Just fragment ->
        Right (markGraphBindingRef name fragment)
      Nothing ->
        lowerNamedGraphRef name
  ExprSelect baseExpr arms -> do
    baseFragment <- lowerGraphBase compileEnv st baseExpr
    lowerSelectStep compileEnv st baseFragment arms Nothing
  ExprFamilyProjection familyName indexValue ->
    Left
      ( WireCore.WireParseError
          ( "Unexpanded indexed family projection "
              <> familyName
              <> "["
              <> T.pack (show indexValue)
              <> "] reached graph lowering."
          )
      )
  ExprConnect lhs rhs ->
    lowerGraphExpr compileEnv st (ExprConnect lhs rhs)
  other ->
    Left
      ( WireCore.WireParseError
          ( "Unsupported Wire graph-position expression: "
              <> T.pack (show other)
          )
      )
  where
    lowerNamedGraphRef name =
      case Map.lookup name st.lsNamedNodes of
        Just loweredNode ->
          Right
            ( syncFragmentAdmission
                GraphFragment
                  { gfNodes = Map.singleton loweredNode.lnRef loweredNode
                  , gfEntries = fmap boundaryFromPort loweredNode.lnInputs
                  , gfExits = fmap boundaryFromPort loweredNode.lnOutputs
                  , gfConnections = []
                  , gfAdmission = nodeAdmissionArtifact loweredNode
                  }
            )
        Nothing ->
          Left (WireCore.WireUnknownNodeRef (CircuitNodeRef name))

joinGraphFragments
  :: Text -> GraphFragment -> GraphFragment -> Either WireCore.WireError GraphFragment
joinGraphFragments context lhs rhs = do
  ensureDisjointGraphDomains context lhs rhs
  Right $
    syncFragmentAdmission
      GraphFragment
        { gfNodes = Map.union lhs.gfNodes rhs.gfNodes
        , gfEntries = dedupeBoundaries (lhs.gfEntries <> rhs.gfEntries)
        , gfExits = dedupeBoundaries (lhs.gfExits <> rhs.gfExits)
        , gfConnections = dedupeConnections (lhs.gfConnections <> rhs.gfConnections)
        , gfAdmission =
            appendPrimitiveStep
              ( PrimitiveOverlay
                  (Map.keys lhs.gfNodes)
                  (Map.keys rhs.gfNodes)
                  lhs.gfAdmission.wireAdmissionBindingRefs
                  rhs.gfAdmission.wireAdmissionBindingRefs
              )
              (combineWireAdmissionArtifacts lhs.gfAdmission rhs.gfAdmission)
        }

connectFragments :: GraphFragment -> GraphFragment -> Either WireCore.WireError GraphFragment
connectFragments lhs rhs = do
  ensureDisjointGraphDomains "connect (=>)" lhs rhs
  matchedPairs <- linearBoundaryMatches lhs.gfExits rhs.gfEntries
  let matchedLeft = Set.fromList (fmap fst matchedPairs)
      matchedRight = Set.fromList (fmap snd matchedPairs)
      bridgeConnections =
        fmap
          ( \(leftBoundary, rightBoundary) ->
              WireCore.connect
                (boundaryEndpoint leftBoundary)
                (boundaryEndpoint rightBoundary)
          )
          matchedPairs
  Right $
    syncFragmentAdmission
      GraphFragment
        { gfNodes = Map.union lhs.gfNodes rhs.gfNodes
        , gfEntries = dedupeBoundaries (lhs.gfEntries <> filter (`Set.notMember` matchedRight) rhs.gfEntries)
        , gfExits = dedupeBoundaries (filter (`Set.notMember` matchedLeft) lhs.gfExits <> rhs.gfExits)
        , gfConnections = dedupeConnections (lhs.gfConnections <> rhs.gfConnections <> bridgeConnections)
        , gfAdmission =
            appendPrimitiveStep
              ( PrimitiveConnect
                  (fmap admissionBoundaryFromPort lhs.gfExits)
                  (fmap admissionBoundaryFromPort rhs.gfEntries)
                  (fmap admissionConnectionFromPair matchedPairs)
                  (fmap admissionBoundaryFromPort (filter (`Set.notMember` matchedLeft) lhs.gfExits))
                  (fmap admissionBoundaryFromPort (filter (`Set.notMember` matchedRight) rhs.gfEntries))
              )
              (combineWireAdmissionArtifacts lhs.gfAdmission rhs.gfAdmission)
        }

ensureDisjointGraphDomains
  :: Text -> GraphFragment -> GraphFragment -> Either WireCore.WireError ()
ensureDisjointGraphDomains context lhs rhs =
  case Set.toAscList (Map.keysSet lhs.gfNodes `Set.intersection` Map.keysSet rhs.gfNodes) of
    [] -> Right ()
    duplicateRefs ->
      Left
        ( WireCore.WireParseError
            ( context
                <> " cannot reuse graph node(s): "
                <> T.intercalate ", " (fmap (.unCircuitNodeRef) duplicateRefs)
                <> ". Bind fresh nodes or use make(...) to generate a fresh family."
            )
        )

linearBoundaryMatches
  :: [BoundaryPort] -> [BoundaryPort] -> Either WireCore.WireError [(BoundaryPort, BoundaryPort)]
linearBoundaryMatches leftExits rightEntries = do
  traverse_ validateLeft leftExits
  traverse_ validateRight rightEntries
  Right
    [ (leftBoundary, rightBoundary)
    | leftBoundary <- leftExits
    , [rightBoundary] <- [Map.findWithDefault [] (boundaryKey leftBoundary) rightByKey]
    ]
  where
    leftByKey = boundariesByKey leftExits
    rightByKey = boundariesByKey rightEntries

    validateLeft leftBoundary =
      let compatibleRights = Map.findWithDefault [] (boundaryKey leftBoundary) rightByKey
       in case compatibleRights of
            _ : _ : _ ->
              Left
                ( WireCore.WireParseError
                    ( "Wire connect (=>) would copy output endpoint "
                        <> renderBoundaryEndpoint leftBoundary
                        <> " into multiple compatible input endpoints: "
                        <> renderBoundaryList compatibleRights
                        <> ". Insert an explicit adapter with `*` or rename ports."
                    )
                )
            _ -> Right ()

    validateRight rightBoundary =
      let compatibleLefts = Map.findWithDefault [] (boundaryKey rightBoundary) leftByKey
       in case compatibleLefts of
            _ : _ : _ ->
              Left
                ( WireCore.WireParseError
                    ( "Wire connect (=>) would merge multiple output endpoints into input endpoint "
                        <> renderBoundaryEndpoint rightBoundary
                        <> ": "
                        <> renderBoundaryList compatibleLefts
                        <> ". Insert an explicit adapter with `*` or rename ports."
                    )
                )
            _ -> Right ()

type BoundaryKey = (PortLabel, Text)

boundaryKey :: BoundaryPort -> BoundaryKey
boundaryKey boundary =
  (boundary.bpLabel, boundary.bpContract)

boundariesByKey :: [BoundaryPort] -> Map BoundaryKey [BoundaryPort]
boundariesByKey =
  foldr (\boundary -> Map.insertWith (<>) (boundaryKey boundary) [boundary]) Map.empty

data StarDirection = StarGather | StarScatter
  deriving stock (Eq, Show)

lowerStarFragments
  :: WireCompileEnv
  -> LoweringState
  -> GraphFragment
  -> GraphFragment
  -> Either WireCore.WireError GraphFragment
lowerStarFragments compileEnv st lhs rhs = do
  plan <- resolveStarPlan compileEnv st lhs.gfExits rhs.gfEntries
  phantom <- buildStarPhantomNode compileEnv st plan
  let phantomFragment =
        syncFragmentAdmission
          GraphFragment
            { gfNodes = Map.singleton phantom.lnRef phantom
            , gfEntries = fmap boundaryFromPort phantom.lnInputs
            , gfExits = fmap boundaryFromPort phantom.lnOutputs
            , gfConnections = []
            , gfAdmission = nodeAdmissionArtifact phantom
            }
  leftPairs <- linearBoundaryMatches lhs.gfExits phantomFragment.gfEntries
  leftToPhantom <- connectFragments lhs phantomFragment
  rightPairs <- linearBoundaryMatches leftToPhantom.gfExits rhs.gfEntries
  connected <- connectFragments leftToPhantom rhs
  Right
    connected
      { gfAdmission =
          appendPhantomAdapterArtifact
            (phantomAdapterArtifactFromPlan plan phantom leftPairs rightPairs)
            connected.gfAdmission
      }

data StarPlan = StarPlan
  { starPlanDirection :: !StarDirection
  , starPlanSingular :: !BoundaryPort
  , starPlanMulti :: ![BoundaryPort]
  , starPlanProductShape :: !StarProductShape
  }
  deriving stock (Eq, Show)

data StarProductShape
  = StarRecordShape !(Map Text ContractId)
  | StarIndexedShape !Text !Natural
  deriving stock (Eq, Show)

data StarPortSide = StarInputSide | StarOutputSide
  deriving stock (Eq, Show)

phantomAdapterArtifactFromPlan
  :: StarPlan
  -> LoweredNode
  -> [(BoundaryPort, BoundaryPort)]
  -> [(BoundaryPort, BoundaryPort)]
  -> PhantomAdapterArtifact
phantomAdapterArtifactFromPlan plan phantom leftPairs rightPairs =
  PhantomAdapterArtifact
    { phantomAdapterDirection = phantomAdapterDirectionFromStar plan.starPlanDirection
    , phantomAdapterNode = phantom.lnRef
    , phantomAdapterProductShape =
        productShapeArtifact plan.starPlanSingular plan.starPlanProductShape
    , phantomAdapterSingular = admissionBoundaryFromPort plan.starPlanSingular
    , phantomAdapterMulti = fmap admissionBoundaryFromPort plan.starPlanMulti
    , phantomAdapterLeftBulk = fmap admissionConnectionFromPair leftPairs
    , phantomAdapterRightBulk = fmap admissionConnectionFromPair rightPairs
    }

phantomAdapterDirectionFromStar :: StarDirection -> PhantomAdapterDirection
phantomAdapterDirectionFromStar = \case
  StarGather -> PhantomGather
  StarScatter -> PhantomScatter

productShapeArtifact :: BoundaryPort -> StarProductShape -> ProductShapeArtifact
productShapeArtifact singular = \case
  StarRecordShape fields ->
    ProductRecord
      singular.bpContract
      [ (label, contract.unContractId)
      | (label, contract) <- Map.toAscList fields
      ]
  StarIndexedShape elementContract count ->
    ProductIndexed elementContract count

resolveStarPlan
  :: WireCompileEnv
  -> LoweringState
  -> [BoundaryPort]
  -> [BoundaryPort]
  -> Either WireCore.WireError StarPlan
resolveStarPlan compileEnv st leftExits rightEntries =
  case (leftExits, rightEntries) of
    ([], [singular]) ->
      gather singular []
    ([singular], []) ->
      scatter singular []
    ([left], [right]) ->
      resolveSingletonStarPlan left right
    (_ : _ : _, [singular]) ->
      gather singular leftExits
    ([singular], _ : _ : _) ->
      scatter singular rightEntries
    (_ : _ : _, _ : _ : _) ->
      Left
        ( WireCore.WireParseError
            "`*` requires exactly one singular side; both operands expose multi-element frontiers."
        )
    _ ->
      Left
        ( WireCore.WireParseError
            "`*` requires one singular record frontier and one multi-port frontier."
        )
  where
    gather singular multi = do
      productShape <- productShapeForStar compileEnv st singular.bpContract
      validateStarMultiSide productShape multi
      Right
        StarPlan
          { starPlanDirection = StarGather
          , starPlanSingular = singular
          , starPlanMulti = multi
          , starPlanProductShape = productShape
          }

    scatter singular multi = do
      productShape <- productShapeForStar compileEnv st singular.bpContract
      validateStarMultiSide productShape multi
      Right
        StarPlan
          { starPlanDirection = StarScatter
          , starPlanSingular = singular
          , starPlanMulti = multi
          , starPlanProductShape = productShape
          }

    resolveSingletonStarPlan left right = do
      let leftShape = productShapeForStarMaybe compileEnv st left.bpContract
          rightShape = productShapeForStarMaybe compileEnv st right.bpContract
      case (leftShape, rightShape) of
        (Nothing, Just _) ->
          gather right [left]
        (Just _, Nothing) ->
          scatter left [right]
        _ ->
          Left
            ( WireCore.WireParseError
                "`*` requires a product boundary on one side and its scalar leaf frontier on the other; use `=>` for one-to-one aggregate wiring."
            )

productShapeForStar
  :: WireCompileEnv -> LoweringState -> Text -> Either WireCore.WireError StarProductShape
productShapeForStar compileEnv st contractId =
  case parseBoundedIndexedContractName contractId of
    Just (elementContract, count) ->
      Right (StarIndexedShape elementContract count)
    Nothing ->
      StarRecordShape <$> recordFieldsForStar compileEnv st contractId

productShapeForStarMaybe :: WireCompileEnv -> LoweringState -> Text -> Maybe StarProductShape
productShapeForStarMaybe compileEnv st contractId =
  case parseBoundedIndexedContractName contractId of
    Just (elementContract, count) ->
      Just (StarIndexedShape elementContract count)
    Nothing ->
      StarRecordShape <$> recordFieldsForStarMaybe compileEnv st contractId

recordFieldsForStarMaybe :: WireCompileEnv -> LoweringState -> Text -> Maybe (Map Text ContractId)
recordFieldsForStarMaybe compileEnv st contractId =
  case Map.lookup contractId st.lsDeclaredRecordContracts of
    Just fields ->
      Just fields
    Nothing ->
      case compileEnv.wireCompileEnvContractRegistry of
        Nothing ->
          Nothing
        Just registry ->
          case Map.lookup contractId registry.wireContractRegistryContracts of
            Nothing ->
              Nothing
            Just spec ->
              spec.wireContractSpecRecordFields

recordFieldsForStar
  :: WireCompileEnv -> LoweringState -> Text -> Either WireCore.WireError (Map Text ContractId)
recordFieldsForStar compileEnv st contractId =
  case Map.lookup contractId st.lsDeclaredRecordContracts of
    Just fields ->
      Right fields
    Nothing ->
      case compileEnv.wireCompileEnvContractRegistry of
        Nothing ->
          Left
            ( WireCore.WireParseError
                ( "`*` requires either [T; N] syntax or a nominal record contract; no record registry was available for "
                    <> contractId
                    <> ". Use [T; N] syntax for indexed products or provide a nominal record registry."
                )
            )
        Just registry ->
          case Map.lookup contractId registry.wireContractRegistryContracts of
            Nothing ->
              Left (WireCore.WireUnknownContract "`*` singular side" contractId)
            Just spec ->
              case spec.wireContractSpecRecordFields of
                Just fields ->
                  Right fields
                Nothing ->
                  Left
                    ( WireCore.WireParseError
                        ( "`*` singular side contract "
                            <> contractId
                            <> " is not a nominal record contract. Use [T; N] syntax for bounded indexed products."
                        )
                    )

validateStarMultiSide
  :: StarProductShape -> [BoundaryPort] -> Either WireCore.WireError ()
validateStarMultiSide productShape multiBoundaries =
  case productShape of
    StarRecordShape fields -> do
      observed <- boundaryFieldMap multiBoundaries
      when (observed /= fields) $
        Left
          ( WireCore.WireParseError
              ( "`*` multi-side frontier does not match nominal record fields. Expected "
                  <> renderFieldMap fields
                  <> "; observed "
                  <> renderFieldMap observed
                  <> "."
              )
          )
    StarIndexedShape elementContract count -> do
      validateIndexedStarArity elementContract count multiBoundaries
      traverse_ (validateIndexedBoundary elementContract) multiBoundaries
      validateIndexedBoundaryKeys multiBoundaries

validateIndexedStarArity :: Text -> Natural -> [BoundaryPort] -> Either WireCore.WireError ()
validateIndexedStarArity elementContract count multiBoundaries =
  when (fromIntegral (length multiBoundaries) /= count) $
    Left
      ( WireCore.WireParseError
          ( "`*` multi-side frontier does not match bounded indexed product. Expected "
              <> renderContractId (ContractId (boundedIndexedContractName elementContract count))
              <> " with "
              <> T.pack (show count)
              <> " endpoint(s); observed "
              <> T.pack (show (length multiBoundaries))
              <> "."
          )
      )

validateIndexedBoundary :: Text -> BoundaryPort -> Either WireCore.WireError ()
validateIndexedBoundary elementContract boundary =
  when (boundary.bpContract /= elementContract) $
    Left
      ( WireCore.WireParseError
          ( "`*` indexed multi-side endpoint "
              <> renderBoundaryEndpoint boundary
              <> " has contract "
              <> renderContractId (ContractId boundary.bpContract)
              <> ", expected "
              <> renderContractId (ContractId elementContract)
              <> "."
          )
      )

validateIndexedBoundaryKeys :: [BoundaryPort] -> Either WireCore.WireError ()
validateIndexedBoundaryKeys multiBoundaries =
  case firstBoundaryInDuplicateKeyGroups multiBoundaries of
    duplicateBoundary : _ ->
      Left
        ( WireCore.WireParseError
            ( "`*` indexed multi-side frontier repeats endpoint key "
                <> renderBoundaryLabel duplicateBoundary.bpLabel
                <> ": "
                <> duplicateBoundary.bpContract
                <> ". Generated families need distinct labels before they can be gathered."
            )
        )
    [] ->
      Right ()

boundaryFieldMap :: [BoundaryPort] -> Either WireCore.WireError (Map Text ContractId)
boundaryFieldMap boundaries = do
  pairs <-
    traverse
      ( \boundary ->
          case boundary.bpLabel of
            Label labelText ->
              Right (labelText, ContractId boundary.bpContract)
            NoLabel ->
              Left
                ( WireCore.WireParseError
                    ( "`*` multi-side endpoint "
                        <> renderBoundaryEndpoint boundary
                        <> " must have a label matching a record field."
                    )
                )
      )
      boundaries
  case duplicatePortNames (fmap fst pairs) of
    duplicateLabel : _ ->
      Left
        ( WireCore.WireParseError
            ( "`*` multi-side frontier repeats record field label "
                <> duplicateLabel
                <> "."
            )
        )
    [] ->
      Right (Map.fromList pairs)

firstBoundaryInDuplicateKeyGroups :: [BoundaryPort] -> [BoundaryPort]
firstBoundaryInDuplicateKeyGroups boundaries =
  [ boundary
  | boundaryGroup <- Map.elems (boundariesByKey boundaries)
  , length boundaryGroup > 1
  , boundary <- take 1 boundaryGroup
  ]

renderFieldMap :: Map Text ContractId -> Text
renderFieldMap fields
  | Map.null fields = "{}"
  | otherwise =
      "{"
        <> T.intercalate
          ", "
          [ label <> ": " <> renderContractId contract
          | (label, contract) <- Map.toAscList fields
          ]
        <> "}"

buildStarPhantomNode
  :: WireCompileEnv -> LoweringState -> StarPlan -> Either WireCore.WireError LoweredNode
buildStarPhantomNode compileEnv st plan = do
  let nodeRef = generatedStarPhantomNodeRef plan
      singular = plan.starPlanSingular
      inputDecls =
        case plan.starPlanDirection of
          StarGather ->
            productMultiPortDecls StarInputSide plan.starPlanProductShape plan.starPlanMulti
          StarScatter ->
            [PortInputDecl singular.bpLabel (ContractId singular.bpContract)]
      outputDecls =
        case plan.starPlanDirection of
          StarGather ->
            [PortOutputDecl singular.bpLabel (ContractId singular.bpContract)]
          StarScatter ->
            productMultiPortDecls StarOutputSide plan.starPlanProductShape plan.starPlanMulti
  ports <- lowerPortSignature st nodeRef (inputDecls <> outputDecls)
  outputEquations <- starPhantomOutputEquations plan ports
  outputConfig <-
    case NE.nonEmpty outputEquations of
      Nothing
        | null ports.lnpOutputs ->
            Right Map.empty
      Nothing ->
        Left (WireCore.WireParseError "internal `*` lowering error: phantom has no output equation")
      Just outputs ->
        pureOutputConfigMap st nodeRef ports.lnpInputs ports.lnpOutputs outputs
  loweredPureNodeFromOutputConfig
    compileEnv
    st
    nodeRef
    ports
    Map.empty
    []
    Nothing
    outputConfig

productMultiPortDecls
  :: StarPortSide -> StarProductShape -> [BoundaryPort] -> [PortDecl]
productMultiPortDecls side productShape multiBoundaries =
  case productShape of
    StarRecordShape fields ->
      [ starPortDecl side (Label label) contract
      | (label, contract) <- Map.toAscList fields
      ]
    StarIndexedShape {} ->
      [ starPortDecl side boundary.bpLabel (ContractId boundary.bpContract)
      | boundary <- multiBoundaries
      ]

starPortDecl :: StarPortSide -> PortLabel -> ContractId -> PortDecl
starPortDecl side label contract =
  case side of
    StarInputSide ->
      PortInputDecl label contract
    StarOutputSide ->
      PortOutputDecl label contract

starPhantomOutputEquations
  :: StarPlan -> LoweredNodePorts -> Either WireCore.WireError [PureOutputEquation]
starPhantomOutputEquations plan ports =
  case (plan.starPlanDirection, plan.starPlanProductShape) of
    (StarGather, StarRecordShape fields) -> do
      gatheredFields <- traverse gatherRecordField (Map.toAscList fields)
      Right
        [ PureOutputEquation
            { pureOutputEquationLabel = plan.starPlanSingular.bpLabel
            , pureOutputEquationContract = ContractId plan.starPlanSingular.bpContract
            , pureOutputEquationExpr = CorePureRecord gatheredFields
            }
        ]
    (StarGather, StarIndexedShape {}) -> do
      items <- traverse gatherIndexedItem plan.starPlanMulti
      Right
        [ PureOutputEquation
            { pureOutputEquationLabel = plan.starPlanSingular.bpLabel
            , pureOutputEquationContract = ContractId plan.starPlanSingular.bpContract
            , pureOutputEquationExpr = CorePureList items
            }
        ]
    (StarScatter, StarRecordShape fields) -> do
      inputName <- starScatterInputName ports
      Right
        [ PureOutputEquation
            { pureOutputEquationLabel = Label label
            , pureOutputEquationContract = contract
            , pureOutputEquationExpr = CorePureFieldAccess (CorePureIdent inputName) label
            }
        | (label, contract) <- Map.toAscList fields
        ]
    (StarScatter, StarIndexedShape {}) -> do
      inputName <- starScatterInputName ports
      Right
        [ PureOutputEquation
            { pureOutputEquationLabel = boundary.bpLabel
            , pureOutputEquationContract = ContractId boundary.bpContract
            , pureOutputEquationExpr =
                CorePureIndex
                  (CorePureIdent inputName)
                  (CorePureLit (CorePureNumber (fromIntegral indexValue)))
            }
        | (indexValue, boundary) <- zip [0 :: Int ..] plan.starPlanMulti
        ]
  where
    gatherRecordField (label, contract) = do
      inputName <- fieldInputName label contract
      Right (CorePureField (label :| []) (CorePureIdent inputName))

    gatherIndexedItem boundary =
      CorePureIdent <$> boundaryInputName boundary

    fieldInputName label (ContractId contract) =
      case [ input.lpInternalName
           | input <- ports.lnpInputs
           , input.lpLabel == Label label
           , input.lpContract == contract
           ] of
        [inputName] -> Right inputName
        _ ->
          Left
            ( WireCore.WireParseError
                ( "internal `*` lowering error: missing phantom input for field "
                    <> label
                )
            )

    boundaryInputName boundary =
      case [ input.lpInternalName
           | input <- ports.lnpInputs
           , input.lpLabel == boundary.bpLabel
           , input.lpContract == boundary.bpContract
           ] of
        [inputName] -> Right inputName
        _ ->
          Left
            ( WireCore.WireParseError
                ( "internal `*` lowering error: missing phantom input for indexed endpoint "
                    <> renderBoundaryEndpoint boundary
                )
            )

starScatterInputName :: LoweredNodePorts -> Either WireCore.WireError Text
starScatterInputName ports =
  case ports.lnpInputs of
    [input] -> Right input.lpInternalName
    _ ->
      Left
        ( WireCore.WireParseError
            "internal `*` lowering error: scatter phantom input is not singular"
        )

generatedStarPhantomNodeRef :: StarPlan -> CircuitNodeRef
generatedStarPhantomNodeRef plan =
  CircuitNodeRef
    ( "__star:"
        <> directionText
        <> ":"
        <> T.take
          12
          ( digestText
              ( Aeson.encode
                  ( Aeson.object
                      [ "direction" Aeson..= directionText
                      , "singular" Aeson..= renderBoundaryPort plan.starPlanSingular
                      , "multi" Aeson..= fmap renderBoundaryPort plan.starPlanMulti
                      , "shape" Aeson..= renderStarProductShape plan.starPlanProductShape
                      ]
                  )
              )
          )
    )
  where
    directionText =
      case plan.starPlanDirection of
        StarGather -> "gather"
        StarScatter -> "scatter"

renderStarProductShape :: StarProductShape -> Aeson.Value
renderStarProductShape = \case
  StarRecordShape fields ->
    Aeson.object
      [ "kind" Aeson..= ("record" :: Text)
      , "fields" Aeson..= fmap (.unContractId) fields
      ]
  StarIndexedShape elementContract count ->
    Aeson.object
      [ "kind" Aeson..= ("indexed" :: Text)
      , "element" Aeson..= elementContract
      , "count" Aeson..= count
      ]

lowerSelectStep
  :: WireCompileEnv
  -> LoweringState
  -> GraphFragment
  -> NonEmpty SelectArm
  -> Maybe GraphFragment
  -> Either WireCore.WireError GraphFragment
lowerSelectStep compileEnv st current arms maybeDownstream = do
  selectorVariants <- resolveExclusiveBoundary current.gfExits
  resolvedArms <- resolveSelectArms selectorVariants arms
  preparedArms <-
    traverse
      ( \(variant, resolvedArm) -> do
          armFragment <- lowerGraphExpr compileEnv st resolvedArm.selectArmResolvedExpr
          armOutputBoundary <-
            inferSelectArmOutputBoundary variant resolvedArm.selectArmResolvedKey armFragment
          pure
            PreparedSelectArm
              { psaVariant = variant
              , psaSourceIndex = resolvedArm.selectArmSourceIndex
              , psaKey = resolvedArm.selectArmResolvedKey
              , psaResolutionMode = resolvedArm.selectArmResolvedMode
              , psaFragment = armFragment
              , psaOutputBoundary = armOutputBoundary
              }
      )
      resolvedArms
  commonBoundary <- resolveSelectCommonBoundary maybeDownstream preparedArms
  traverse_ (validatePreparedSelectArm commonBoundary) preparedArms
  -- An all-identity select cannot reach this point: identity arms expose their
  -- variant's shape at the common boundary, and variants carry pairwise distinct
  -- labels, so convergence validation above already rejected the clause. Guard
  -- loudly instead of passing the diagram through so a future change to arm
  -- validation cannot silently skip condition-tree construction.
  when (all (isIdentityFragment . psaFragment) preparedArms) $
    Left
      ( WireCore.WireParseError
          "internal Wire select lowering error: all-identity arms survived convergence validation"
      )
  conditionNode <- buildSelectConditionTree selectorVariants commonBoundary preparedArms
  let conditionFragment =
        selectConditionFragment selectorVariants preparedArms conditionNode
  currentToCondition <- connectFragments current conditionFragment
  maybe (pure currentToCondition) (connectFragments currentToCondition) maybeDownstream

data PreparedSelectArm = PreparedSelectArm
  { psaVariant :: !BoundaryPort
  , psaSourceIndex :: !Natural
  , psaKey :: !Text
  , psaResolutionMode :: !SelectResolutionMode
  , psaFragment :: !GraphFragment
  , psaOutputBoundary :: ![BoundaryPort]
  }

data ResolvedSelectArm = ResolvedSelectArm
  { selectArmSourceIndex :: !Natural
  , selectArmResolvedKey :: !Text
  , selectArmResolvedMode :: !SelectResolutionMode
  , selectArmResolvedExpr :: !Expr
  }

{- | The mixed-boundary rejection below rejects a @select(...)@ left-hand graph that
is not a single exclusive group (an exclusive sum plus ordinary exits, or several
groups). This is a select-boundary restriction, not a grammar one: the node grammar
itself permits a sum group beside ordinary output clauses (see 'executorImplementation'
and 'outputPort'). ADR 0062 makes the same single-exclusive-group rule the
variant-emitting boundary.
-}
resolveExclusiveBoundary :: [BoundaryPort] -> Either WireCore.WireError (NonEmpty BoundaryPort)
resolveExclusiveBoundary exits =
  case dedupeBoundaries exits of
    [] ->
      Left
        ( WireCore.WireParseError
            "`select(...)` requires a non-empty exclusive output boundary on its left-hand graph."
        )
    variant : variants ->
      case nub (fmap bpExclusiveGroup (variant : variants)) of
        [Just groupId]
          | all ((== Just groupId) . bpExclusiveGroup) (variant : variants) ->
              Right (variant :| variants)
        _ ->
          Left
            ( WireCore.WireParseError
                "`select(...)` currently requires the left-hand graph to expose exactly one exclusive output boundary and no additional ordinary exits."
            )

resolveSelectArms
  :: NonEmpty BoundaryPort
  -> NonEmpty SelectArm
  -> Either WireCore.WireError (NonEmpty (BoundaryPort, ResolvedSelectArm))
resolveSelectArms selectorVariants arms = do
  let variantsByContract =
        Map.fromListWith
          (<>)
          [ (variant.bpContract, [variant])
          | variant <- NE.toList selectorVariants
          ]
      variantsByLabel =
        Map.fromListWith
          (<>)
          [ (labelText, [variant])
          | variant <- NE.toList selectorVariants
          , Label labelText <- [variant.bpLabel]
          ]
      resolveKey (sourceIndex, arm) =
        case Map.lookup arm.selectArmKey variantsByLabel of
          Just [variant] ->
            Right
              ( variant
              , ResolvedSelectArm
                  { selectArmSourceIndex = sourceIndex
                  , selectArmResolvedKey = arm.selectArmKey
                  , selectArmResolvedMode = SelectResolvedByLabel
                  , selectArmResolvedExpr = arm.selectArmExpr
                  }
              )
          Just (_ : _ : _) ->
            Left
              ( WireCore.WireParseError
                  ( "select arm key "
                      <> arm.selectArmKey
                      <> " is ambiguous. Use an explicit unique variant label."
                  )
              )
          Just [] ->
            Left (WireCore.WireParseError "internal select lowering error: empty label bucket")
          Nothing ->
            case Map.lookup arm.selectArmKey variantsByContract of
              Just [variant] ->
                Right
                  ( variant
                  , ResolvedSelectArm
                      { selectArmSourceIndex = sourceIndex
                      , selectArmResolvedKey = arm.selectArmKey
                      , selectArmResolvedMode = SelectResolvedByContract
                      , selectArmResolvedExpr = arm.selectArmExpr
                      }
                  )
              Just (_ : _ : _) ->
                Left
                  ( WireCore.WireParseError
                      ( "select arm key "
                          <> arm.selectArmKey
                          <> " is ambiguous. Use an explicit unique variant label."
                      )
                  )
              Just [] ->
                Left (WireCore.WireParseError "internal select lowering error: empty contract bucket")
              Nothing ->
                Left
                  ( WireCore.WireParseError
                      ( "select arm key "
                          <> arm.selectArmKey
                          <> " does not match any variant on the selector boundary."
                      )
                  )
      indexedArms = NE.zip (0 :| [1 ..]) arms
      resolved = traverse resolveKey indexedArms
  case resolved of
    Left err ->
      Left err
    Right resolvedPairs -> do
      let resolvedMap =
            Map.fromListWith
              (<>)
              [ (variant, [resolvedArm])
              | (variant, resolvedArm) <- NE.toList resolvedPairs
              ]
      traverse
        ( \variant ->
            case Map.lookup variant resolvedMap of
              Nothing ->
                Left
                  ( WireCore.WireParseError
                      "select(...) must cover every variant on the selector boundary exactly once."
                  )
              Just [] ->
                Left (WireCore.WireParseError "internal select lowering error: empty variant arm bucket")
              Just [resolvedArm] ->
                Right (variant, resolvedArm)
              Just (_ : _ : _) ->
                Left (WireCore.WireParseError "select(...) must not repeat a selector variant.")
        )
        selectorVariants

inferSelectArmOutputBoundary
  :: BoundaryPort
  -> Text
  -> GraphFragment
  -> Either WireCore.WireError [BoundaryPort]
inferSelectArmOutputBoundary selectorVariant armKey armFragment =
  if isIdentityFragment armFragment
    then
      Right
        [ selectorVariant
            { bpExclusiveGroup = Nothing
            }
        ]
    else do
      rooted <- connectFragments (fragmentFromBoundaryOutputs [selectorVariant]) armFragment
      unless (null rooted.gfEntries) $
        Left
          ( WireCore.WireParseError
              ( "select arm "
                  <> armKey
                  <> " requires external inputs beyond the selected variant."
              )
          )
      pure rooted.gfExits

resolveSelectCommonBoundary
  :: Maybe GraphFragment
  -> NonEmpty PreparedSelectArm
  -> Either WireCore.WireError [BoundaryShape]
resolveSelectCommonBoundary maybeDownstream preparedArms =
  case maybeDownstream of
    Just downstream -> do
      let commonBoundary = boundaryShapes (dedupeDownstreamEntries downstream.gfEntries)
      when (null commonBoundary) $
        Left
          (WireCore.WireParseError "`select(...)` requires a productive shared continuation boundary.")
      pure commonBoundary
    Nothing -> do
      let firstArm :| _ = preparedArms
          commonBoundary = boundaryShapes firstArm.psaOutputBoundary
      when (null commonBoundary) $
        Left
          ( WireCore.WireParseError
              "select(...) arms must be productive and expose a non-empty common boundary."
          )
      pure commonBoundary

validatePreparedSelectArm
  :: [BoundaryShape]
  -> PreparedSelectArm
  -> Either WireCore.WireError ()
validatePreparedSelectArm commonBoundary preparedArm =
  when (boundaryShapes preparedArm.psaOutputBoundary /= commonBoundary) $
    Left
      ( WireCore.WireParseError
          ( "select arm "
              <> preparedArm.psaKey
              <> " does not converge to the common downstream boundary."
          )
      )

buildSelectConditionTree
  :: NonEmpty BoundaryPort
  -> [BoundaryShape]
  -> NonEmpty PreparedSelectArm
  -> Either WireCore.WireError LoweredNode
buildSelectConditionTree selectorVariants commonBoundary (firstArm :| restArms) =
  case NE.nonEmpty restArms of
    Nothing ->
      Left (WireCore.WireParseError "internal select lowering error: singleton select tree")
    Just restArmsNE -> do
      (thenKeys, thenFragment) <- buildSelectBranchGroup commonBoundary (firstArm :| [])
      (elseKeys, elseFragment) <- buildSelectBranchGroup commonBoundary restArmsNE
      buildBinarySelectConditionNode
        selectorVariants
        commonBoundary
        thenKeys
        thenFragment
        elseKeys
        elseFragment

buildSelectBranchGroup
  :: [BoundaryShape]
  -> NonEmpty PreparedSelectArm
  -> Either WireCore.WireError ([Text], Maybe GraphFragment)
buildSelectBranchGroup commonBoundary arms@(firstArm :| restArms) =
  case restArms of
    [] ->
      Right ([firstArm.psaKey], nonIdentityFragment firstArm.psaFragment)
    _ ->
      let armList = NE.toList arms
       in if all (isIdentityFragment . psaFragment) armList
            then Right (fmap psaKey armList, Nothing)
            else do
              nestedCondition <- buildSelectConditionTree (fmap psaVariant arms) commonBoundary arms
              let nestedFragment =
                    selectConditionFragment (fmap psaVariant arms) arms nestedCondition
              Right (fmap psaKey armList, Just nestedFragment)

selectConditionFragment
  :: NonEmpty BoundaryPort -> NonEmpty PreparedSelectArm -> LoweredNode -> GraphFragment
selectConditionFragment selectorVariants preparedArms conditionNode =
  syncFragmentAdmission
    GraphFragment
      { gfNodes = Map.singleton conditionNode.lnRef conditionNode
      , gfEntries = fmap boundaryFromPort conditionNode.lnInputs
      , gfExits = fmap boundaryFromPort (bridgeOutputPorts conditionNode)
      , gfConnections = []
      , gfAdmission =
          appendSelectAdmissionArtifact
            (selectAdmissionArtifact selectorVariants preparedArms conditionNode.lnRef)
            (nodeAdmissionArtifact conditionNode)
      }

selectAdmissionArtifact
  :: NonEmpty BoundaryPort -> NonEmpty PreparedSelectArm -> CircuitNodeRef -> SelectAdmissionArtifact
selectAdmissionArtifact selectorVariants preparedArms conditionRef =
  SelectAdmissionArtifact
    { selectAdmissionOwner = conditionRef
    , selectAdmissionVariants =
        [ SelectVariantArtifact
            { selectVariantKey = selectVariantCanonicalKey variant
            , selectVariantPort = admissionBoundaryFromPort variant
            }
        | variant <- NE.toList selectorVariants
        ]
    , selectAdmissionArms =
        [ SelectArmAdmissionArtifact
            { selectArmSourceIndex = preparedArm.psaSourceIndex
            , selectArmSourceKey = preparedArm.psaKey
            , selectArmCanonicalKey = selectVariantCanonicalKey preparedArm.psaVariant
            , selectArmResolutionMode = preparedArm.psaResolutionMode
            , selectArmBodyNodes = Map.keys preparedArm.psaFragment.gfNodes
            , selectArmBodyEntries = fmap admissionBoundaryFromPort preparedArm.psaFragment.gfEntries
            , selectArmBodyExits = fmap admissionBoundaryFromPort preparedArm.psaFragment.gfExits
            }
        | preparedArm <- sortOn psaSourceIndex (NE.toList preparedArms)
        ]
    , selectAdmissionConditionNode = conditionRef
    }

selectVariantCanonicalKey :: BoundaryPort -> Text
selectVariantCanonicalKey variant =
  case variant.bpLabel of
    Label labelText -> labelText
    NoLabel -> variant.bpContract

buildBinarySelectConditionNode
  :: NonEmpty BoundaryPort
  -> [BoundaryShape]
  -> [Text]
  -> Maybe GraphFragment
  -> [Text]
  -> Maybe GraphFragment
  -> Either WireCore.WireError LoweredNode
buildBinarySelectConditionNode selectorVariants commonBoundary thenKeys thenFragment elseKeys elseFragment = do
  thenCompiled <- traverse fragmentToCompiledFragment thenFragment
  elseCompiled <- traverse fragmentToCompiledFragment elseFragment
  let (chosenThenKeys, chosenThenCompiled, chosenElseKeys, chosenElseCompiled) =
        case (thenCompiled, elseCompiled) of
          (Nothing, Just compiledElse) ->
            (elseKeys, Just compiledElse, thenKeys, Nothing)
          _ ->
            (thenKeys, thenCompiled, elseKeys, elseCompiled)
  let conditionRef =
        generatedSelectConditionNodeRef (NE.toList selectorVariants) commonBoundary (thenKeys <> elseKeys)
      inputs =
        zipWith
          (loweredConditionInputPort conditionRef)
          [1 :: Int ..]
          (NE.toList selectorVariants)
      variantOutputs =
        zipWith
          (loweredConditionVariantOutputPort conditionRef)
          [1 :: Int ..]
          (NE.toList selectorVariants)
      bridgeOutputs =
        zipWith
          (loweredConditionBridgeOutputPort conditionRef)
          [1 :: Int ..]
          commonBoundary
      outputs = dedupePortsByIdentity (variantOutputs <> bridgeOutputs)
      ports = loweredPortsToWirePorts inputs outputs
      conditionNode =
        CircuitConditionNode
          { circuitConditionNodeRef = conditionRef
          , circuitConditionNodeCondition = CircuitConditionRef "__wire_select__"
          , circuitConditionNodeThenFragment = fromMaybe emptyCompiledFragment chosenThenCompiled
          , circuitConditionNodeElseFragment = chosenElseCompiled
          , circuitConditionNodeMetadata =
              Aeson.object
                [ "kind" Aeson..= ("wire_select" :: Text)
                , "selectorMode" Aeson..= ("exclusive_output" :: Text)
                , "selector" Aeson..= fmap renderBoundaryPort (NE.toList selectorVariants)
                , "thenKeys" Aeson..= chosenThenKeys
                , "elseKeys" Aeson..= chosenElseKeys
                , "ports" Aeson..= portsMetadataValue ports
                ]
          }
  when (null chosenThenKeys) $
    Left (WireCore.WireParseError "internal select lowering error: empty then-branch key set")
  when (null chosenElseKeys) $
    Left (WireCore.WireParseError "internal select lowering error: empty else-branch key set")
  when (isNothing chosenThenCompiled) $
    Left
      ( WireCore.WireParseError
          "internal select lowering error: binary select node requires a concrete then fragment"
      )
  pure
    LoweredNode
      { lnRef = conditionRef
      , lnCompiledNode = CompiledCircuitCondition conditionNode
      , lnPorts = ports
      , lnInputs = inputs
      , lnOutputs = outputs
      , lnGeneratedOrigin = Nothing
      }

loweredPureNodeFromVariantConfig
  :: WireCompileEnv
  -> CircuitNodeRef
  -> LoweredNodePorts
  -> Map (NonEmpty Text) EvalValue
  -> [CorePureBinding]
  -> Maybe CorePureExpr
  -> [Text]
  -> CorePureExpr
  -> Either WireCore.WireError LoweredNode
loweredPureNodeFromVariantConfig
  compileEnv
  nodeRef
  ports
  metadata
  topLevelBindings
  whereExpr
  labels
  bodyExpr = do
    when (any (`Map.member` metadata) [("on" :| []), ("artifactKind" :| []), ("to" :| [])]) $
      Left (WireCore.WireInvalidPorts nodeRef "signal and artifact metadata require an executor body")
    tools <- maybe (Right []) evalTools (Map.lookup ("tools" :| []) metadata)
    memoryStrategy <- traverse evalMemoryStrategy (Map.lookup ("memory" :| []) metadata)
    let runtimePorts = taskWirePortsFromLowered ports
        label = lookupMaybeTextField "label" metadata
        instructionsText =
          lookupMaybeTextField "instructions" metadata
            <|> lookupMaybeTextField "prompt" metadata
        normalForm =
          pureSumNodeBoundaryNormalForm
            nodeRef
            runtimePorts
            topLevelBindings
            whereExpr
            labels
            bodyExpr
        executor = WireCore.WireExecutorNative "pure"
    mapLeft (WireCore.WireInvalidPorts nodeRef) $
      validateNodeBoundaryNormalForm normalForm
    mapLeft (WireCore.WireInvalidPorts nodeRef . renderPureEvalError) $
      validatePureVariantTaskConfig
        (normalFormPorts normalForm)
        topLevelBindings
        whereExpr
        labels
        bodyExpr
    validateExecutorProjection compileEnv nodeRef executor (normalFormPorts normalForm)
    pure
      LoweredNode
        { lnRef = nodeRef
        , lnCompiledNode =
            CompiledCircuitTask
              CircuitTaskNode
                { circuitTaskNodeRef = nodeRef
                , circuitTaskNodeLabel = defaultNodeLabel nodeRef label
                , circuitTaskNodeMetadata =
                    actMetadata
                      "config"
                      nodeRef
                      executor
                      label
                      instructionsText
                      (Just (nativePureVariantTaskConfigValue topLevelBindings whereExpr labels bodyExpr))
                      tools
                      (normalFormPorts normalForm)
                      (lookupMaybeInt32Field "timeout" metadata)
                      (lookupMaybeInt32Field "retry" metadata)
                      (lookupMaybeInt32Field "stepBudget" metadata)
                      (lookupMaybeInt32Field "toolLoopMinSteps" metadata)
                      (lookupMaybeInt32Field "maxOutputTokens" metadata)
                      (lookupMaybeBoolField "reasoningEnabled" metadata)
                      memoryStrategy
                }
        , lnPorts = runtimePorts
        , lnInputs = ports.lnpInputs
        , lnOutputs = ports.lnpOutputs
        , lnGeneratedOrigin = Nothing
        }

nonIdentityFragment :: GraphFragment -> Maybe GraphFragment
nonIdentityFragment fragment
  | isIdentityFragment fragment = Nothing
  | otherwise = Just fragment

isIdentityFragment :: GraphFragment -> Bool
isIdentityFragment fragment =
  Map.null fragment.gfNodes
    && null fragment.gfEntries
    && null fragment.gfExits
    && null fragment.gfConnections

fragmentFromBoundaryOutputs :: [BoundaryPort] -> GraphFragment
fragmentFromBoundaryOutputs outputs =
  GraphFragment
    { gfNodes = Map.empty
    , gfEntries = []
    , gfExits = outputs
    , gfConnections = []
    , gfAdmission =
        emptyWireAdmissionArtifact
          { wireAdmissionExits = fmap admissionBoundaryFromPort outputs
          }
    }

dedupeDownstreamEntries :: [BoundaryPort] -> [BoundaryPort]
dedupeDownstreamEntries =
  nubBySameBoundary

dedupePortsByIdentity :: [LoweredPort] -> [LoweredPort]
dedupePortsByIdentity =
  nubBy
    ( \lhs rhs ->
        lhs.lpDirection == rhs.lpDirection
          && lhs.lpContract == rhs.lpContract
          && lhs.lpLabel == rhs.lpLabel
          && lhs.lpExclusiveGroup == rhs.lpExclusiveGroup
    )

nubBySameBoundary :: [BoundaryPort] -> [BoundaryPort]
nubBySameBoundary =
  nubBy
    ( \lhs rhs ->
        lhs.bpContract == rhs.bpContract
          && lhs.bpLabel == rhs.bpLabel
          && lhs.bpExclusiveGroup == rhs.bpExclusiveGroup
    )

boundaryShapes :: [BoundaryPort] -> [BoundaryShape]
boundaryShapes boundaries =
  snd $
    foldl
      ( \(groupTags, acc) boundary ->
          let (groupTags', normalizedGroup) =
                case boundary.bpExclusiveGroup of
                  Nothing ->
                    (groupTags, Nothing)
                  Just groupId ->
                    case Map.lookup groupId groupTags of
                      Just existingTag ->
                        (groupTags, Just existingTag)
                      Nothing ->
                        let nextTag = fromIntegral (Map.size groupTags)
                         in (Map.insert groupId nextTag groupTags, Just nextTag)
           in ( groupTags'
              , acc
                  <> [ BoundaryShape
                         { bsContract = boundary.bpContract
                         , bsLabel = boundary.bpLabel
                         , bsExclusiveGroup = normalizedGroup
                         }
                     ]
              )
      )
      (Map.empty, [])
      boundaries

bridgeOutputPorts :: LoweredNode -> [LoweredPort]
bridgeOutputPorts =
  filter (\port -> "bridge_out_" `T.isPrefixOf` port.lpInternalName) . (.lnOutputs)

generatedSelectConditionNodeRef :: [BoundaryPort] -> [BoundaryShape] -> [Text] -> CircuitNodeRef
generatedSelectConditionNodeRef selectorVariants commonBoundary armKeys =
  -- The separator must never be ':', the rewrite namespace delimiter:
  -- a select condition inside a latent branch is a rewrite-local node, and
  -- namespace discipline rejects local ids containing the delimiter. This is
  -- what blocked nested selects from materializing.
  CircuitNodeRef
    ( "__select."
        <> humanTag
        <> "."
        <> T.take
          12
          ( digestText
              ( Aeson.encode
                  ( Aeson.object
                      [ "selector" Aeson..= fmap renderBoundaryPort selectorVariants
                      , "downstream" Aeson..= fmap renderBoundaryShape commonBoundary
                      , "arms" Aeson..= armKeys
                      ]
                  )
              )
          )
    )
  where
    humanTag =
      case armKeys of
        [] -> "noarms"
        _ -> T.intercalate "_" (fmap (T.map sanitizeChar) armKeys)
    sanitizeChar c
      | Char.isAlphaNum c || c == '_' = c
      | otherwise = '_'

renderBoundaryPort :: BoundaryPort -> Aeson.Value
renderBoundaryPort boundary =
  Aeson.object
    [ "node" Aeson..= boundary.bpNodeRef.unCircuitNodeRef
    , "port" Aeson..= boundary.bpPortName
    , "contract" Aeson..= boundary.bpContract
    , "label" Aeson..= renderPortLabel boundary.bpLabel
    ]

renderBoundaryEndpoint :: BoundaryPort -> Text
renderBoundaryEndpoint boundary =
  boundary.bpNodeRef.unCircuitNodeRef
    <> "."
    <> boundary.bpPortName
    <> " ("
    <> renderBoundaryLabel boundary.bpLabel
    <> ": "
    <> boundary.bpContract
    <> ")"

renderBoundaryList :: [BoundaryPort] -> Text
renderBoundaryList =
  T.intercalate ", " . fmap renderBoundaryEndpoint

renderBoundaryLabel :: PortLabel -> Text
renderBoundaryLabel = \case
  NoLabel -> "_"
  Label labelText -> labelText

renderPortLabel :: PortLabel -> Aeson.Value
renderPortLabel = \case
  NoLabel -> Aeson.Null
  Label labelText -> Aeson.String labelText

renderBoundaryShape :: BoundaryShape -> Aeson.Value
renderBoundaryShape boundaryShape =
  Aeson.object
    [ "contract" Aeson..= boundaryShape.bsContract
    , "label" Aeson..= renderPortLabel boundaryShape.bsLabel
    , "exclusiveGroup" Aeson..= boundaryShape.bsExclusiveGroup
    ]

loweredConditionInputPort :: CircuitNodeRef -> Int -> BoundaryPort -> LoweredPort
loweredConditionInputPort nodeRef idx boundary =
  LoweredPort
    { lpNodeRef = nodeRef
    , lpDirection = PortInput
    , lpInternalName = "variant_in_" <> T.pack (show idx)
    , lpContract = boundary.bpContract
    , lpLabel = boundary.bpLabel
    , lpCardinality = Just WireCore.WireInputCardinalityOne
    , lpExclusiveGroup = Nothing
    }

loweredConditionVariantOutputPort :: CircuitNodeRef -> Int -> BoundaryPort -> LoweredPort
loweredConditionVariantOutputPort nodeRef idx boundary =
  LoweredPort
    { lpNodeRef = nodeRef
    , lpDirection = PortOutput
    , lpInternalName = "variant_out_" <> T.pack (show idx)
    , lpContract = boundary.bpContract
    , lpLabel = boundary.bpLabel
    , lpCardinality = Nothing
    , lpExclusiveGroup = Just 0
    }

loweredConditionBridgeOutputPort :: CircuitNodeRef -> Int -> BoundaryShape -> LoweredPort
loweredConditionBridgeOutputPort nodeRef idx boundary =
  LoweredPort
    { lpNodeRef = nodeRef
    , lpDirection = PortOutput
    , lpInternalName = "bridge_out_" <> T.pack (show idx)
    , lpContract = boundary.bsContract
    , lpLabel = boundary.bsLabel
    , lpCardinality = Nothing
    , lpExclusiveGroup = boundary.bsExclusiveGroup
    }

loweredPortsToWirePorts :: [LoweredPort] -> [LoweredPort] -> WireCore.WirePorts
loweredPortsToWirePorts inputs outputs =
  WireCore.WirePorts
    { wirePortsInputs =
        Map.fromList
          [ ( port.lpInternalName
            , WireCore.WireInputPort
                { wireInputPortAccepts = [port.lpContract]
                , wireInputPortCardinality = fromMaybe WireCore.WireInputCardinalityOne port.lpCardinality
                , wireInputPortRequired = True
                }
            )
          | port <- inputs
          ]
    , wirePortsOutputs =
        Map.fromList
          [ ( port.lpInternalName
            , WireCore.WireOutputPort
                { wireOutputPortContract = port.lpContract
                , wireOutputPortExclusiveGroup = port.lpExclusiveGroup
                }
            )
          | port <- outputs
          ]
    }

emptyCompiledFragment :: CompiledCircuitFragment
emptyCompiledFragment =
  CompiledCircuitFragment
    { compiledCircuitFragmentEntryNodes = []
    , compiledCircuitFragmentExitNodes = []
    , compiledCircuitFragmentTopology = mempty
    , compiledCircuitFragmentNodes = Map.empty
    }

fragmentToCompiledFragment :: GraphFragment -> Either WireCore.WireError CompiledCircuitFragment
fragmentToCompiledFragment fragment = do
  relation <- fragmentRelation True fragment
  validateFragmentContractsWithOpenEntries
    (Map.map (.lnPorts) fragment.gfNodes)
    (Map.keysSet fragment.gfNodes)
    fragment.gfEntries
    fragment.gfConnections
  pure
    CompiledCircuitFragment
      { compiledCircuitFragmentEntryNodes = Set.toAscList (sources relation)
      , compiledCircuitFragmentExitNodes = Set.toAscList (sinks relation)
      , compiledCircuitFragmentTopology = relation
      , compiledCircuitFragmentNodes = Map.map (.lnCompiledNode) fragment.gfNodes
      }

dedupeBoundaries :: [BoundaryPort] -> [BoundaryPort]
dedupeBoundaries =
  nub

dedupeConnections :: [WireCore.Connection] -> [WireCore.Connection]
dedupeConnections =
  nub

boundaryFromPort :: LoweredPort -> BoundaryPort
boundaryFromPort port =
  BoundaryPort
    { bpNodeRef = port.lpNodeRef
    , bpPortName = port.lpInternalName
    , bpContract = port.lpContract
    , bpLabel = port.lpLabel
    , bpExclusiveGroup = fmap (port.lpNodeRef,) port.lpExclusiveGroup
    }

boundaryEndpoint :: BoundaryPort -> WireCore.EndpointRef
boundaryEndpoint boundary =
  WireCore.EndpointRef
    { endpointNodeRef = boundary.bpNodeRef
    , endpointPortName = Just boundary.bpPortName
    }

loweredNodeFromExecutorCall
  :: WireCompileEnv
  -> LoweringState
  -> CircuitNodeRef
  -> LoweredNodePorts
  -> Maybe Record
  -> Maybe CorePureExpr
  -> ExecutorCall
  -> Either WireCore.WireError LoweredNode
loweredNodeFromExecutorCall compileEnv st nodeRef ports metadata whereExpr executorCallValue = do
  (executorAuthority, inputExpr) <- resolveExecutorCall st executorCallValue
  validateCorePureNodeScopeWithLocals st nodeRef (inputPortLocalNames ports.lnpInputs) inputExpr
  exactFields <- maybe (Right Map.empty) (evalRecordFields st) metadata
  validateNodeMetadataFields nodeRef exactFields
  let
    label = lookupMaybeTextField "label" exactFields
    runtimePorts = taskWirePortsFromLowered ports
    executorId = executorAuthority.ceExecutorId
    maybeSignal = lookupMaybeTextField "on" exactFields
    maybeArtifactKind = lookupMaybeTextField "artifactKind" exactFields
    maybeTarget = lookupMaybeQNameField "to" exactFields
  validateStdIoExecutorShape nodeRef executorId runtimePorts
  compiledNode <- case () of
    _
      | isJust maybeSignal -> do
          signalName <- requireTextField nodeRef "on" exactFields
          let normalForm =
                signalNodeBoundaryNormalForm nodeRef runtimePorts whereExpr inputExpr signalName
          mapLeft (WireCore.WireInvalidPorts nodeRef) $
            validateNodeBoundaryNormalForm normalForm
          Right $
            CompiledCircuitSignal
              CircuitSignalBoundary
                { circuitSignalBoundaryRef = nodeRef
                , circuitSignalName = signalName
                , circuitSignalDescription = label
                , circuitSignalMetadata =
                    awaitMetadata
                      label
                      (normalFormPorts normalForm)
                      (lookupMaybeInt32Field "timeout" exactFields)
                }
      | isJust maybeArtifactKind || isJust maybeTarget -> do
          artifactKind <-
            maybe
              (Left (WireCore.WireMissingRequiredField nodeRef "artifactKind"))
              Right
              maybeArtifactKind
          targetRef <- requireQNameField nodeRef "to" exactFields
          let normalForm =
                artifactNodeBoundaryNormalForm
                  nodeRef
                  runtimePorts
                  whereExpr
                  inputExpr
                  artifactKind
                  (qnameToQualifiedRef targetRef)
          mapLeft (WireCore.WireInvalidPorts nodeRef) $
            validateNodeBoundaryNormalForm normalForm
          Right $
            CompiledCircuitArtifact
              CircuitArtifactBoundary
                { circuitArtifactBoundaryRef = nodeRef
                , circuitArtifactKind = artifactKind
                , circuitArtifactLabel = defaultNodeLabel nodeRef label
                , circuitArtifactMetadata =
                    emitMetadata
                      artifactKind
                      (qnameToQualifiedRef targetRef)
                      (normalFormPorts normalForm)
                      (lookupMaybeInt32Field "timeout" exactFields)
                }
      | otherwise -> do
          let executor = WireCore.WireExecutorNative executorId
          when (executor == WireCore.WireExecutorNative "pure") $
            Left
              ( WireCore.WireParseError
                  "Pure nodes must be authored with output equations, not @pure executor application."
              )
          let instructionsText =
                lookupMaybeTextField "instructions" exactFields
                  <|> lookupMaybeTextField "prompt" exactFields
              argumentValue = executorArgumentValue whereExpr inputExpr
              normalForm =
                executorNodeBoundaryNormalForm
                  nodeRef
                  runtimePorts
                  whereExpr
                  inputExpr
                  executor
                  argumentValue
          mapLeft (WireCore.WireInvalidPorts nodeRef) $
            validateNodeBoundaryNormalForm normalForm
          validateExecutorProjection compileEnv nodeRef executor (normalFormPorts normalForm)
          tools <- maybe (Right []) evalTools (Map.lookup ("tools" :| []) exactFields)
          memoryStrategy <- traverse evalMemoryStrategy (Map.lookup ("memory" :| []) exactFields)
          Right $
            CompiledCircuitTask
              CircuitTaskNode
                { circuitTaskNodeRef = nodeRef
                , circuitTaskNodeLabel = defaultNodeLabel nodeRef label
                , circuitTaskNodeMetadata =
                    actMetadata
                      "argument"
                      nodeRef
                      executor
                      label
                      instructionsText
                      (Just argumentValue)
                      tools
                      (normalFormPorts normalForm)
                      (lookupMaybeInt32Field "timeout" exactFields)
                      (lookupMaybeInt32Field "retry" exactFields)
                      (lookupMaybeInt32Field "stepBudget" exactFields)
                      (lookupMaybeInt32Field "toolLoopMinSteps" exactFields)
                      (lookupMaybeInt32Field "maxOutputTokens" exactFields)
                      (lookupMaybeBoolField "reasoningEnabled" exactFields)
                      memoryStrategy
                }
  Right
    LoweredNode
      { lnRef = nodeRef
      , lnCompiledNode = compiledNode
      , lnPorts = runtimePorts
      , lnInputs = ports.lnpInputs
      , lnOutputs = ports.lnpOutputs
      , lnGeneratedOrigin = Nothing
      }
resolveExecutorCall
  :: LoweringState -> ExecutorCall -> Either WireCore.WireError (ExecutorAuthority, CorePureExpr)
resolveExecutorCall st = \case
  ExecutorCallInline executorQName@(QName (name :| [])) inputExpr
    | Just (EvalExecutor executorAuthority) <- Map.lookup name st.lsBindings ->
        Right (executorAuthority, normalizeExecutorArgument inputExpr)
    | otherwise -> do
        executorId <- resolveExecutorQName st executorQName
        Right (ExecutorAuthority executorId, normalizeExecutorArgument inputExpr)
  ExecutorCallInline executorQName inputExpr -> do
    executorId <- resolveExecutorQName st executorQName
    Right (ExecutorAuthority executorId, normalizeExecutorArgument inputExpr)
  ExecutorCallBound name inputExpr ->
    case Map.lookup name st.lsBindings of
      Just (EvalExecutor executorAuthority) ->
        Right (executorAuthority, normalizeExecutorArgument inputExpr)
      Just other ->
        Left (WireCore.WireFieldTypeMismatch name "executor" (valueKind other))
      Nothing ->
        Left (WireCore.WireUnknownLetBinding name)

normalizeExecutorArgument :: Maybe CorePureExpr -> CorePureExpr
normalizeExecutorArgument = \case
  Nothing -> CorePureRecord []
  Just record@CorePureRecord {} -> record
  Just value -> CorePureRecord [CorePureField ("payload" :| []) value]

validateNodeMetadataFields
  :: CircuitNodeRef
  -> Map (NonEmpty Text) EvalValue
  -> Either WireCore.WireError ()
validateNodeMetadataFields nodeRef fields =
  case [ NE.head path
       | path <- Map.keys fields
       , NE.head path `notElem` allowed
       ] of
    [] -> Right ()
    unknown : _ ->
      Left (WireCore.WireInvalidPorts nodeRef ("unknown node metadata field " <> unknown))
  where
    allowed =
      [ "label"
      , "instructions"
      , "prompt"
      , "tools"
      , "memory"
      , "timeout"
      , "retry"
      , "stepBudget"
      , "toolLoopMinSteps"
      , "maxOutputTokens"
      , "reasoningEnabled"
      , "on"
      , "artifactKind"
      , "to"
      ]

executorArgumentValue
  :: Maybe CorePureExpr
  -> CorePureExpr
  -> Aeson.Value
executorArgumentValue whereExpr inputExpr =
  Aeson.Object (insertMaybeJson "where" whereExpr baseObject)
  where
    baseObject = KeyMap.singleton (Key.fromText "value") (Aeson.toJSON inputExpr)

insertMaybeJson
  :: Aeson.ToJSON a => Text -> Maybe a -> KeyMap.KeyMap Aeson.Value -> KeyMap.KeyMap Aeson.Value
insertMaybeJson fieldName maybeValue object =
  case maybeValue of
    Nothing -> object
    Just value -> KeyMap.insert (Key.fromText fieldName) (Aeson.toJSON value) object

loweredPureNodeFromBody
  :: WireCompileEnv
  -> LoweringState
  -> CircuitNodeRef
  -> LoweredNodePorts
  -> Maybe Record
  -> [CorePureBinding]
  -> NodePureBody
  -> Either WireCore.WireError LoweredNode
loweredPureNodeFromBody compileEnv st nodeRef ports metadata topLevelBindings pureBody = do
  exactFields <- maybe (Right Map.empty) (evalRecordFields st) metadata
  validateNodeMetadataFields nodeRef exactFields
  case pureBody of
    NodePureBody whereExpr (NodePureProduct outputEquations) -> do
      outputConfig <-
        pureOutputConfigMap st nodeRef ports.lnpInputs ports.lnpOutputs outputEquations
      loweredPureNodeFromOutputConfig
        compileEnv
        st
        nodeRef
        ports
        exactFields
        topLevelBindings
        whereExpr
        outputConfig
    NodePureBody whereExpr (NodePureSum variants bodyExpr) -> do
      labels <- pureSumLabels st nodeRef ports.lnpInputs ports.lnpOutputs variants bodyExpr
      loweredPureNodeFromVariantConfig
        compileEnv
        nodeRef
        ports
        exactFields
        topLevelBindings
        whereExpr
        labels
        bodyExpr

loweredPureNodeFromOutputConfig
  :: WireCompileEnv
  -> LoweringState
  -> CircuitNodeRef
  -> LoweredNodePorts
  -> Map (NonEmpty Text) EvalValue
  -> [CorePureBinding]
  -> Maybe CorePureExpr
  -> Map Text CorePureExpr
  -> Either WireCore.WireError LoweredNode
loweredPureNodeFromOutputConfig compileEnv _st nodeRef ports metadata topLevelBindings whereExpr outputConfig = do
  when (any (`Map.member` metadata) [("on" :| []), ("artifactKind" :| []), ("to" :| [])]) $
    Left (WireCore.WireInvalidPorts nodeRef "signal and artifact metadata require an executor body")
  tools <- maybe (Right []) evalTools (Map.lookup ("tools" :| []) metadata)
  memoryStrategy <- traverse evalMemoryStrategy (Map.lookup ("memory" :| []) metadata)
  let runtimePorts = taskWirePortsFromLowered ports
      label = lookupMaybeTextField "label" metadata
      instructionsText =
        lookupMaybeTextField "instructions" metadata
          <|> lookupMaybeTextField "prompt" metadata
      normalForm =
        pureNodeBoundaryNormalForm
          nodeRef
          runtimePorts
          topLevelBindings
          whereExpr
          outputConfig
      executor = WireCore.WireExecutorNative "pure"
  mapLeft (WireCore.WireInvalidPorts nodeRef) $
    validateNodeBoundaryNormalForm normalForm
  mapLeft (WireCore.WireInvalidPorts nodeRef . renderPureEvalError) $
    validatePureTaskConfig
      (normalFormPorts normalForm)
      topLevelBindings
      whereExpr
      outputConfig
  validateExecutorProjection compileEnv nodeRef executor (normalFormPorts normalForm)
  pure
    LoweredNode
      { lnRef = nodeRef
      , lnCompiledNode =
          CompiledCircuitTask
            CircuitTaskNode
              { circuitTaskNodeRef = nodeRef
              , circuitTaskNodeLabel = defaultNodeLabel nodeRef label
              , circuitTaskNodeMetadata =
                  actMetadata
                    "config"
                    nodeRef
                    executor
                    label
                    instructionsText
                    (Just (nativePureTaskConfigValue topLevelBindings whereExpr outputConfig))
                    tools
                    (normalFormPorts normalForm)
                    (lookupMaybeInt32Field "timeout" metadata)
                    (lookupMaybeInt32Field "retry" metadata)
                    (lookupMaybeInt32Field "stepBudget" metadata)
                    (lookupMaybeInt32Field "toolLoopMinSteps" metadata)
                    (lookupMaybeInt32Field "maxOutputTokens" metadata)
                    (lookupMaybeBoolField "reasoningEnabled" metadata)
                    memoryStrategy
              }
      , lnPorts = runtimePorts
      , lnInputs = ports.lnpInputs
      , lnOutputs = ports.lnpOutputs
      , lnGeneratedOrigin = Nothing
      }

nativePureTaskConfigValue
  :: [CorePureBinding]
  -> Maybe CorePureExpr
  -> Map Text CorePureExpr
  -> Aeson.Value
nativePureTaskConfigValue topLevelBindings whereExpr outputConfig =
  Aeson.Object $
    insertMaybeJson
      "where"
      whereExpr
      ( KeyMap.fromList
          [ (Key.fromText "bindings", Aeson.toJSON topLevelBindings)
          , (Key.fromText "outputs", Aeson.toJSON outputConfig)
          ]
      )

nativePureVariantTaskConfigValue
  :: [CorePureBinding]
  -> Maybe CorePureExpr
  -> [Text]
  -> CorePureExpr
  -> Aeson.Value
nativePureVariantTaskConfigValue topLevelBindings whereExpr labels bodyExpr =
  Aeson.Object $
    insertMaybeJson
      "where"
      whereExpr
      ( KeyMap.fromList
          [ (Key.fromText "bindings", Aeson.toJSON topLevelBindings)
          ,
            ( Key.fromText "variant"
            , Aeson.object
                [ "labels" Aeson..= labels
                , "expression" Aeson..= bodyExpr
                ]
            )
          ]
      )

validateWhereClause
  :: LoweringState
  -> CircuitNodeRef
  -> [LoweredPort]
  -> Maybe CorePureExpr
  -> Either WireCore.WireError ()
validateWhereClause st nodeRef inputPorts whereExpr =
  case whereExpr of
    Nothing -> Right ()
    Just exprValue -> do
      validateCorePureNodeScopeWithLocals st nodeRef (inputPortLocalNames inputPorts) exprValue
      staticContext <-
        mapLeft
          (WireCore.WireInvalidPorts nodeRef . renderStaticWhereError)
          (corePureStaticContextFromBindings st.lsPureBindings)
      fieldNames <-
        mapLeft
          (WireCore.WireInvalidPorts nodeRef . renderStaticWhereError)
          (corePureWhereStaticFields staticContext exprValue)
      let inputNames = Set.fromList (fmap (.lpInternalName) inputPorts)
          collisions = Set.toAscList (Set.intersection fieldNames inputNames)
      case collisions of
        collision : _ ->
          Left
            ( WireCore.WireInvalidPorts
                nodeRef
                ("where field collides with input port " <> collision)
            )
        [] -> Right ()

renderStaticWhereError :: PureEvalError -> Text
renderStaticWhereError = \case
  PureStaticFieldSetUndeterminable ->
    "where-clause field set is not statically determinable"
  PureStaticBindingCycle _ ->
    "where-clause field set is not statically determinable"
  PureStaticLetShadowsStatic bindingName ->
    "where-clause local let binding shadows static binding " <> bindingName
  err ->
    renderPureEvalError err

pureSumLabels
  :: LoweringState
  -> CircuitNodeRef
  -> [LoweredPort]
  -> [LoweredPort]
  -> NonEmpty SumVariant
  -> CorePureExpr
  -> Either WireCore.WireError [Text]
pureSumLabels st nodeRef inputPorts outputPorts variants bodyExpr = do
  let variantList = NE.toList variants
  when (length outputPorts /= length variantList) $
    Left (WireCore.WireInvalidPorts nodeRef "pure sum variants do not match lowered output ports")
  labels <- zipWithM matchVariant outputPorts variantList
  let constructorNames = Set.fromList labels
      localNames = inputPortLocalNames inputPorts <> constructorNames
  validateCorePureNodeScopeWithLocals st nodeRef localNames bodyExpr
  pure labels
  where
    matchVariant port variant = do
      label <- case variant.svLabel of
        Label value -> Right value
        NoLabel -> Left (WireCore.WireInvalidPorts nodeRef "pure sum variants require labels")
      let ContractId rawContractName = variant.svContract
          contractName = resolveContractId st rawContractName
      when (port.lpLabel /= variant.svLabel || port.lpContract /= contractName) $
        Left (WireCore.WireInvalidPorts nodeRef "pure sum variant does not match its lowered output port")
      pure label

pureOutputConfigMap
  :: LoweringState
  -> CircuitNodeRef
  -> [LoweredPort]
  -> [LoweredPort]
  -> NonEmpty PureOutputEquation
  -> Either WireCore.WireError (Map Text CorePureExpr)
pureOutputConfigMap st nodeRef inputPorts outputPorts outputEquations = do
  let outputEquationList = NE.toList outputEquations
  when (length outputPorts /= length outputEquationList) $
    Left (WireCore.WireInvalidPorts nodeRef "pure output equations do not match lowered output ports")
  Map.fromList <$> zipWithM matchOutput outputPorts outputEquationList
  where
    localNames = inputPortLocalNames inputPorts

    matchOutput port outputEquation = do
      let ContractId rawContractName = outputEquation.pureOutputEquationContract
          contractName = resolveContractId st rawContractName
      when (port.lpLabel /= outputEquation.pureOutputEquationLabel || port.lpContract /= contractName) $
        Left
          (WireCore.WireInvalidPorts nodeRef "pure output equation does not match its lowered output port")
      validateCorePureNodeScopeWithLocals st nodeRef localNames outputEquation.pureOutputEquationExpr
      Right (port.lpInternalName, outputEquation.pureOutputEquationExpr)

validateCorePureNodeScopeWithLocals
  :: LoweringState
  -> CircuitNodeRef
  -> Set.Set Text
  -> CorePureExpr
  -> Either WireCore.WireError ()
validateCorePureNodeScopeWithLocals st nodeRef =
  validateCorePureScope st (WireCore.WireInvalidPorts nodeRef . corePureNodeScopeError)

validateCorePureScope
  :: LoweringState
  -> (Text -> WireCore.WireError)
  -> Set.Set Text
  -> CorePureExpr
  -> Either WireCore.WireError ()
validateCorePureScope st mkError initialLocalNames =
  mapLeft mkError . go initialLocalNames
  where
    -- Keep this match exhaustive: every CorePure constructor must classify its free identifiers.
    go localNames = \case
      CorePureLit {} ->
        Right ()
      CorePureIdent name ->
        validateIdent localNames name
      CorePureList items ->
        traverse_ (go localNames) items
      CorePureRecord fields ->
        traverse_ (go localNames . (.corePureFieldValue)) fields
      CorePureFieldAccess baseExpr _fieldName ->
        go localNames baseExpr
      CorePureIndex baseExpr indexExpr ->
        go localNames baseExpr *> go localNames indexExpr
      CorePureLambda params bodyExpr ->
        go (localNames <> Set.fromList (NE.toList params)) bodyExpr
      CorePureCall functionExpr argumentExprs ->
        go localNames functionExpr *> traverse_ (go localNames) argumentExprs
      CorePureUnary _unaryOp operandExpr ->
        go localNames operandExpr
      CorePureBinary _binaryOp lhsExpr rhsExpr ->
        go localNames lhsExpr *> go localNames rhsExpr
      CorePureLet bindings bodyExpr ->
        goBindings localNames (NE.toList bindings) >>= \localNames' ->
          go localNames' bodyExpr
      CorePureIf conditionExpr thenExpr elseExpr ->
        go localNames conditionExpr
          *> go localNames thenExpr
          *> go localNames elseExpr

    goBindings =
      foldlM $ \localNames binding -> do
        go localNames binding.corePureBindingExpr
        Right (Set.insert binding.corePureBindingName localNames)

    validateIdent localNames name
      | Set.member name localNames = Right ()
      | otherwise =
          case nonCorePureTopLevelBindingKind st name of
            Just bindingKind -> Left (corePureScopeError name bindingKind)
            Nothing -> Right ()

{- | Free identifiers of a CorePure expression outside the given local
binders. Mirrors the traversal of 'validateCorePureScope'; keep the match
exhaustive so new CorePure constructors classify their identifiers here too.
-}
corePureFreeNames :: Set.Set Text -> CorePureExpr -> Set.Set Text
corePureFreeNames localNames = \case
  CorePureLit {} ->
    Set.empty
  CorePureIdent name
    | Set.member name localNames -> Set.empty
    | otherwise -> Set.singleton name
  CorePureList items ->
    foldMap (corePureFreeNames localNames) items
  CorePureRecord fields ->
    foldMap (corePureFreeNames localNames . (.corePureFieldValue)) fields
  CorePureFieldAccess baseExpr _fieldName ->
    corePureFreeNames localNames baseExpr
  CorePureIndex baseExpr indexExpr ->
    corePureFreeNames localNames baseExpr <> corePureFreeNames localNames indexExpr
  CorePureLambda params bodyExpr ->
    corePureFreeNames (localNames <> Set.fromList (NE.toList params)) bodyExpr
  CorePureCall functionExpr argumentExprs ->
    corePureFreeNames localNames functionExpr
      <> foldMap (corePureFreeNames localNames) argumentExprs
  CorePureUnary _unaryOp operandExpr ->
    corePureFreeNames localNames operandExpr
  CorePureBinary _binaryOp lhsExpr rhsExpr ->
    corePureFreeNames localNames lhsExpr <> corePureFreeNames localNames rhsExpr
  CorePureLet bindings bodyExpr ->
    let (boundNames, bindingFree) =
          foldl
            ( \(bound, free) binding ->
                ( Set.insert binding.corePureBindingName bound
                , free <> corePureFreeNames bound binding.corePureBindingExpr
                )
            )
            (localNames, Set.empty)
            (NE.toList bindings)
     in bindingFree <> corePureFreeNames boundNames bodyExpr
  CorePureIf conditionExpr thenExpr elseExpr ->
    corePureFreeNames localNames conditionExpr
      <> corePureFreeNames localNames thenExpr
      <> corePureFreeNames localNames elseExpr

inputPortLocalNames :: [LoweredPort] -> Set.Set Text
inputPortLocalNames =
  Set.fromList . fmap (.lpInternalName)

nonCorePureTopLevelBindingKind :: LoweringState -> Text -> Maybe Text
nonCorePureTopLevelBindingKind st name =
  valueBindingKind
    <|> graphBindingKind
    <|> nodeBindingKind
    <|> importedExecutorKind
    <|> contractBindingKind
  where
    valueBindingKind =
      Map.lookup name st.lsBindings >>= \value ->
        case evalValueToCorePureExpr value of
          Just _ -> Nothing
          Nothing -> Just (valueKind value)

    graphBindingKind =
      "graph value" <$ Map.lookup name st.lsGraphBindings

    nodeBindingKind =
      "node value" <$ Map.lookup name st.lsNamedNodes

    importedExecutorKind =
      "imported executor" <$ Map.lookup name st.lsUseScope.wireUseExecutors

    contractBindingKind =
      "contract" <$ Map.lookup name st.lsUseScope.wireUseContracts
        <|> "contract" <$ guard (Set.member name st.lsDeclaredContracts)

corePureTopLevelScopeError :: Text -> Text -> Text
corePureTopLevelScopeError bindingName message =
  "CorePure let "
    <> bindingName
    <> " "
    <> message

corePureNodeScopeError :: Text -> Text
corePureNodeScopeError message =
  "CorePure expression " <> message

corePureScopeError :: Text -> Text -> Text
corePureScopeError bindingName bindingKind =
  "cannot capture "
    <> bindingKind
    <> " "
    <> bindingName
    <> "; use executor values as node bodies and keep CorePure expressions authority-free."

taskWirePortsFromLowered :: LoweredNodePorts -> WireCore.WirePorts
taskWirePortsFromLowered ports =
  WireCore.WirePorts
    { wirePortsInputs =
        Map.fromList
          [ ( port.lpInternalName
            , WireCore.WireInputPort
                { wireInputPortAccepts = [port.lpContract]
                , wireInputPortCardinality = fromMaybe WireCore.WireInputCardinalityMany port.lpCardinality
                , wireInputPortRequired = False
                }
            )
          | port <- ports.lnpInputs
          ]
    , wirePortsOutputs =
        Map.fromList
          [ ( port.lpInternalName
            , WireCore.WireOutputPort
                { wireOutputPortContract = port.lpContract
                , wireOutputPortExclusiveGroup = port.lpExclusiveGroup
                }
            )
          | port <- ports.lnpOutputs
          ]
    }

evalTools :: EvalValue -> Either WireCore.WireError [WireCore.QualifiedRef]
evalTools value = case value of
  EvalList items -> traverse toQualifiedRef items
  other -> Left (WireCore.WireFieldTypeMismatch "tools" "list" (valueKind other))
  where
    toQualifiedRef = \case
      EvalQName qname -> Right (qnameToQualifiedRef qname)
      other -> Left (WireCore.WireFieldTypeMismatch "tools" "qualified identifier" (valueKind other))

evalMemoryStrategy :: EvalValue -> Either WireCore.WireError MemoryStrategy
evalMemoryStrategy = \case
  EvalQName (QName ("classic" :| [])) -> Right MemoryClassic
  EvalConstructor (QName ("topological" :| [])) fields ->
    case Aeson.fromJSON (fieldsObject fields) of
      Aeson.Success cfg -> Right (MemoryTopological cfg)
      Aeson.Error err ->
        Left (WireCore.WireParseError ("invalid topological memory configuration: " <> T.pack err))
  other ->
    Left (WireCore.WireFieldTypeMismatch "memory" "memory strategy" (valueKind other))

lowerPortSignature
  :: LoweringState
  -> CircuitNodeRef
  -> [PortDecl]
  -> Either WireCore.WireError LoweredNodePorts
lowerPortSignature st nodeRef portSig = do
  let inputs =
        [ (label, resolveContractId st contractName, WireCore.WireInputCardinalityOne)
        | PortInputDecl label (ContractId contractName) <- portSig
        ]
      outputs =
        flattenOutputs portSig
      loweredInputs =
        zipWith
          ( \idx (label, contractName, cardinality) ->
              LoweredPort
                { lpNodeRef = nodeRef
                , lpDirection = PortInput
                , lpInternalName = allocatedPortName True idx label contractName (length inputs)
                , lpContract = contractName
                , lpLabel = label
                , lpCardinality = Just cardinality
                , lpExclusiveGroup = Nothing
                }
          )
          [1 ..]
          inputs
      loweredOutputs =
        zipWith
          ( \idx (maybeGroup, label, contractName) ->
              LoweredPort
                { lpNodeRef = nodeRef
                , lpDirection = PortOutput
                , lpInternalName = allocatedPortName False idx label contractName (length outputs)
                , lpContract = contractName
                , lpLabel = label
                , lpCardinality = Nothing
                , lpExclusiveGroup = maybeGroup
                }
          )
          [1 ..]
          outputs
      duplicateInputs = duplicatePortNames (fmap (.lpInternalName) loweredInputs)
      duplicateOutputs = duplicatePortNames (fmap (.lpInternalName) loweredOutputs)
  case duplicateInputs <> duplicateOutputs of
    duplicatedPort : _ ->
      Left (WireCore.WireInvalidPorts nodeRef ("duplicate lowered port name " <> duplicatedPort))
    [] ->
      Right
        LoweredNodePorts
          { lnpInputs = loweredInputs
          , lnpOutputs = loweredOutputs
          }
  where
    flattenOutputs decls =
      snd $
        foldl
          ( \(nextGroup, acc) -> \case
              PortOutputDecl label (ContractId contractName) ->
                (nextGroup, acc <> [(Nothing, label, resolveContractId st contractName)])
              PortOutputSumDecl variants ->
                ( nextGroup + 1
                , acc
                    <> [ (Just nextGroup, variant.svLabel, resolveContractId st variant.svContract.unContractId)
                       | variant <- NE.toList variants
                       ]
                )
              PortInputDecl {} ->
                (nextGroup, acc)
          )
          (0 :: Natural, [])
          decls

resolveContractId :: LoweringState -> Text -> Text
resolveContractId st contractName =
  case parseBoundedIndexedContractName contractName of
    Just (elementContract, count) ->
      boundedIndexedContractName (resolveWireContract st.lsUseScope elementContract) count
    Nothing ->
      resolveWireContract st.lsUseScope contractName

allocatedPortName :: Bool -> Int -> PortLabel -> Text -> Int -> Text
allocatedPortName isInput idx portLabel contractName totalPorts =
  case portLabel of
    Label labelText -> labelText
    NoLabel
      | totalPorts == 1 ->
          if isInput
            then WireCore.defaultInputPortName
            else WireCore.defaultOutputPortName
      | otherwise ->
          contractName <> "_" <> T.pack (show idx)

duplicatePortNames :: [Text] -> [Text]
duplicatePortNames portNames =
  [ portName
  | portName <- nub portNames
  , length (filter (== portName) portNames) > 1
  ]

evalValue :: LoweringState -> Expr -> Either WireCore.WireError EvalValue
evalValue st = \case
  ExprExecutor executorQName ->
    EvalExecutor . ExecutorAuthority <$> resolveExecutorQName st executorQName
  ExprConstructor constructorQName recordExpr ->
    EvalConstructor constructorQName <$> evalRecordFields st recordExpr
  ExprRecord recordExpr ->
    EvalRecord <$> evalRecordFields st recordExpr
  ExprList items ->
    EvalList <$> traverse (evalValue st) items
  ExprLit literal ->
    pure $
      case literal of
        LitString text -> EvalString text
        LitMultilineString text -> EvalString text
        LitNumber numberValue -> EvalNumber numberValue
        LitBool boolValue -> EvalBool boolValue
        LitUnit -> EvalRecord Map.empty
  ExprIdent (QName (name :| [])) ->
    case Map.lookup name st.lsBindings of
      Just value -> Right value
      Nothing -> Right (EvalQName (QName (name :| [])))
  ExprIdent qname ->
    Right (EvalQName qname)
  ExprConcat lhs rhs -> do
    leftValue <- evalValue st lhs
    rightValue <- evalValue st rhs
    case (leftValue, rightValue) of
      (EvalString leftText, EvalString rightText) ->
        Right (EvalString (leftText <> rightText))
      (EvalList leftItems, EvalList rightItems) ->
        Right (EvalList (leftItems <> rightItems))
      _ ->
        Left (WireCore.WireTypeMismatchInConcat (valueKind leftValue) (valueKind rightValue))
  ExprMerge lhs rhs -> do
    leftValue <- evalValue st lhs
    rightValue <- evalValue st rhs
    mergeValues leftValue rightValue
  ExprOverlay {} ->
    Left (WireCore.WireParseError "Graph overlay cannot appear in an ordinary-value position.")
  ExprConnect {} ->
    Left (WireCore.WireParseError "Graph connect cannot appear in an ordinary-value position.")
  ExprStar {} ->
    Left (WireCore.WireParseError "Graph star adapter cannot appear in an ordinary-value position.")
  ExprSelect {} ->
    Left (WireCore.WireParseError "select(...) is only supported in graph position.")
  ExprFamilyProjection familyName indexValue ->
    Left
      ( WireCore.WireParseError
          ( "Indexed family projection "
              <> familyName
              <> "["
              <> T.pack (show indexValue)
              <> "] is graph-only and cannot appear in an ordinary-value position."
          )
      )

evalRecordFields
  :: LoweringState
  -> Record
  -> Either WireCore.WireError (Map (NonEmpty Text) EvalValue)
evalRecordFields st (Record fields) =
  Map.fromList
    <$> traverse
      ( \field -> do
          value <- evalValue st field.fieldValue
          Right (field.fieldPath, value)
      )
      fields

mergeValues :: EvalValue -> EvalValue -> Either WireCore.WireError EvalValue
mergeValues leftValue rightValue =
  case (leftValue, rightValue) of
    (EvalRecord leftFields, EvalRecord rightFields) ->
      Right (EvalRecord (Map.union rightFields leftFields))
    _ ->
      Left
        ( WireCore.WireParseError
            ( "`//` expects record operands; got "
                <> valueKind leftValue
                <> " and "
                <> valueKind rightValue
                <> "."
            )
        )

lookupMaybeTextField :: Text -> Map (NonEmpty Text) EvalValue -> Maybe Text
lookupMaybeTextField fieldName fields =
  Map.lookup (fieldName :| []) fields >>= \case
    EvalString text -> Just text
    _ -> Nothing

lookupMaybeQNameField :: Text -> Map (NonEmpty Text) EvalValue -> Maybe QName
lookupMaybeQNameField fieldName fields =
  Map.lookup (fieldName :| []) fields >>= \case
    EvalQName qname -> Just qname
    _ -> Nothing

lookupMaybeInt32Field :: Text -> Map (NonEmpty Text) EvalValue -> Maybe Int32
lookupMaybeInt32Field fieldName fields =
  Map.lookup (fieldName :| []) fields >>= numberToInt32

lookupMaybeBoolField :: Text -> Map (NonEmpty Text) EvalValue -> Maybe Bool
lookupMaybeBoolField fieldName fields =
  Map.lookup (fieldName :| []) fields >>= \case
    EvalBool boolValue -> Just boolValue
    _ -> Nothing

requireTextField
  :: CircuitNodeRef -> Text -> Map (NonEmpty Text) EvalValue -> Either WireCore.WireError Text
requireTextField nodeRef fieldName fields =
  case Map.lookup (fieldName :| []) fields of
    Just (EvalString text) -> Right text
    Just other -> Left (WireCore.WireFieldTypeMismatch fieldName "string" (valueKind other))
    Nothing -> Left (WireCore.WireMissingRequiredField nodeRef fieldName)

requireQNameField
  :: CircuitNodeRef -> Text -> Map (NonEmpty Text) EvalValue -> Either WireCore.WireError QName
requireQNameField nodeRef fieldName fields =
  case Map.lookup (fieldName :| []) fields of
    Just (EvalQName qname) -> Right qname
    Just other -> Left (WireCore.WireFieldTypeMismatch fieldName "qualified identifier" (valueKind other))
    Nothing -> Left (WireCore.WireMissingRequiredField nodeRef fieldName)

valueKind :: EvalValue -> Text
valueKind = \case
  EvalString _ -> "string"
  EvalNumber _ -> "number"
  EvalBool _ -> "boolean"
  EvalList _ -> "list"
  EvalQName _ -> "qualified identifier"
  EvalRecord _ -> "record"
  EvalConstructor _ _ -> "constructor"
  EvalExecutor _ -> "executor"

numberToInt32 :: EvalValue -> Maybe Int32
numberToInt32 = \case
  EvalNumber numberValue ->
    case floatingOrInteger numberValue :: Either Double Integer of
      Right integerValue ->
        if integerValue >= fromIntegral (minBound :: Int32)
          && integerValue <= fromIntegral (maxBound :: Int32)
          then Just (fromIntegral integerValue)
          else Nothing
      Left _ -> Nothing
  _ -> Nothing

fieldsObject :: Map (NonEmpty Text) EvalValue -> Aeson.Value
fieldsObject fields =
  Aeson.Object $
    foldl'
      mergeObjects
      KeyMap.empty
      [ objectForPath (NE.toList path) (evalValueToAeson value)
      | (path, value) <- Map.toList fields
      ]

objectForPath :: [Text] -> Aeson.Value -> KeyMap.KeyMap Aeson.Value
objectForPath [] value =
  case value of
    Aeson.Object obj -> obj
    _ -> KeyMap.empty
objectForPath [segment] value =
  KeyMap.singleton (Key.fromText segment) value
objectForPath (segment : rest) value =
  KeyMap.singleton
    (Key.fromText segment)
    (Aeson.Object (objectForPath rest value))

mergeObjects :: KeyMap.KeyMap Aeson.Value -> KeyMap.KeyMap Aeson.Value -> KeyMap.KeyMap Aeson.Value
mergeObjects =
  KeyMap.unionWith mergeJsonValue

mergeJsonValue :: Aeson.Value -> Aeson.Value -> Aeson.Value
mergeJsonValue (Aeson.Object leftObj) (Aeson.Object rightObj) =
  Aeson.Object (mergeObjects leftObj rightObj)
mergeJsonValue _ rightValue = rightValue

evalValueToAeson :: EvalValue -> Aeson.Value
evalValueToAeson = \case
  EvalString text -> Aeson.String text
  EvalNumber numberValue -> Aeson.Number numberValue
  EvalBool boolValue -> Aeson.Bool boolValue
  EvalList items -> Aeson.Array (fromListAeson (fmap evalValueToAeson items))
  EvalQName qname -> Aeson.String (renderQName qname)
  EvalRecord fields -> fieldsObject fields
  EvalConstructor constructorQName fields ->
    Aeson.Object $
      mergeObjects
        (KeyMap.singleton "__constructor" (Aeson.String (renderQName constructorQName)))
        ( case fieldsObject fields of
            Aeson.Object obj -> obj
            _ -> KeyMap.empty
        )
  EvalExecutor executorAuthority ->
    Aeson.String executorAuthority.ceExecutorId

fromListAeson :: [Aeson.Value] -> Vector.Vector Aeson.Value
fromListAeson = Vector.fromList

compatibilityWitness :: WireFile -> CircuitCompatibilityWitness
compatibilityWitness wireFile =
  CircuitCompatibilityWitness
    { circuitCompatibilityFamily = "cortex.workflow.wire"
    , circuitCompatibilityDigest = digestText (Aeson.encode wireFile)
    }

digestText :: BSL.ByteString -> Text
digestText bytes =
  T.pack (show (hashlazy bytes :: Digest SHA256))

defaultNodeLabel :: CircuitNodeRef -> Maybe Text -> Text
defaultNodeLabel nodeRef =
  fromMaybe nodeRef.unCircuitNodeRef

actMetadata
  :: Text
  -> CircuitNodeRef
  -> WireCore.WireExecutor
  -> Maybe Text
  -> Maybe Text
  -> Maybe Aeson.Value
  -> [WireCore.QualifiedRef]
  -> WireCore.WirePorts
  -> Maybe Int32
  -> Maybe Int32
  -> Maybe Int32
  -> Maybe Int32
  -> Maybe Int32
  -> Maybe Bool
  -> Maybe MemoryStrategy
  -> Aeson.Value
actMetadata valueKey nodeRef executor _label instructionsText argumentValue tools ports timeoutSeconds retryCount stepBudget toolLoopMinSteps maxOutputTokens reasoningEnabled memoryStrategy =
  Aeson.object $
    [ "slot" Aeson..= nodeRef.unCircuitNodeRef
    , "executor" Aeson..= renderExecutor executor
    , "ports" Aeson..= portsMetadataValue ports
    ]
      <> foldMap (\instructions -> ["instructions" Aeson..= instructions]) instructionsText
      <> foldMap (\argument -> [Key.fromText valueKey Aeson..= argument]) argumentValue
      <> [ "tools" Aeson..= fmap WireCore.renderQualifiedRef tools
         | not (null tools)
         ]
      <> foldMap (\timeout -> ["timeoutSeconds" Aeson..= timeout]) timeoutSeconds
      <> foldMap (\retry -> ["retryCount" Aeson..= retry]) retryCount
      <> foldMap (\budget -> ["stepBudget" Aeson..= budget]) stepBudget
      <> foldMap (\minSteps -> ["toolLoopMinSteps" Aeson..= minSteps]) toolLoopMinSteps
      <> foldMap (\tokens -> ["maxOutputTokens" Aeson..= tokens]) maxOutputTokens
      <> foldMap (\enabled -> ["reasoningEnabled" Aeson..= enabled]) reasoningEnabled
      <> foldMap (\memory -> ["memory" Aeson..= memory]) memoryStrategy

awaitMetadata :: Maybe Text -> WireCore.WirePorts -> Maybe Int32 -> Aeson.Value
awaitMetadata _label ports timeoutSeconds =
  Aeson.object $
    [ "ports" Aeson..= portsMetadataValue ports
    ]
      <> foldMap (\timeout -> ["timeoutSeconds" Aeson..= timeout]) timeoutSeconds

emitMetadata :: Text -> WireCore.QualifiedRef -> WireCore.WirePorts -> Maybe Int32 -> Aeson.Value
emitMetadata kind target ports timeoutSeconds =
  Aeson.object $
    [ "kind" Aeson..= kind
    , "to" Aeson..= WireCore.renderQualifiedRef target
    , "ports" Aeson..= portsMetadataValue ports
    ]
      <> foldMap (\timeout -> ["timeoutSeconds" Aeson..= timeout]) timeoutSeconds

renderExecutor :: WireCore.WireExecutor -> Aeson.Value
renderExecutor = \case
  WireCore.WireExecutorNative targetId ->
    Aeson.object
      [ "kind" Aeson..= ("native" :: Text)
      , "target" Aeson..= targetId
      ]

fragmentRelation :: Bool -> GraphFragment -> Either WireCore.WireError (Relation CircuitNodeRef)
fragmentRelation requireConnected fragment = do
  let relation =
        toRelation $
          vertices (Map.keys fragment.gfNodes)
            <> edges
              [ (connection.connectionFrom.endpointNodeRef, connection.connectionTo.endpointNodeRef)
              | connection <- fragment.gfConnections
              ]
  validateFragmentTopology requireConnected relation
  pure relation

validateKnownContracts
  :: WireCompileEnv
  -> Set.Set Text
  -> Map CircuitNodeRef WireCore.WirePorts
  -> Either WireCore.WireError ()
validateKnownContracts compileEnv declaredContracts portsCatalog =
  traverse_
    validateContract
    [ contractName
    | ports <- Map.elems portsCatalog
    , contractName <-
        concatMap
          (concatMap contractValidationLeaves . (.wireInputPortAccepts))
          (Map.elems ports.wirePortsInputs)
          <> concatMap (contractValidationLeaves . (.wireOutputPortContract)) (Map.elems ports.wirePortsOutputs)
    ]
  where
    knownContracts registry =
      declaredContracts
        <> Map.keysSet registry.wireContractRegistryContracts
        <> wireExecutorRegistryVocabulary compileEnv.wireCompileEnvExecutorRegistry

    validateContract contractName =
      case compileEnv.wireCompileEnvContractRegistry of
        Nothing -> Right ()
        Just registry ->
          if Set.member contractName (knownContracts registry)
            then Right ()
            else Left (WireCore.WireUnknownContract "node ports" contractName)

contractValidationLeaves :: Text -> [Text]
contractValidationLeaves contractName =
  case parseBoundedIndexedContractName contractName of
    Just (elementContract, _) -> [elementContract]
    Nothing -> [contractName]

validateFragmentContracts
  :: Map CircuitNodeRef WireCore.WirePorts
  -> Set.Set CircuitNodeRef
  -> [WireCore.Connection]
  -> Either WireCore.WireError ()
validateFragmentContracts portsCatalog fragmentNodeRefs connections = do
  validateFragmentContractsWithOpenEntries portsCatalog fragmentNodeRefs [] connections

validateFragmentContractsWithOpenEntries
  :: Map CircuitNodeRef WireCore.WirePorts
  -> Set.Set CircuitNodeRef
  -> [BoundaryPort]
  -> [WireCore.Connection]
  -> Either WireCore.WireError ()
validateFragmentContractsWithOpenEntries portsCatalog fragmentNodeRefs openEntries connections = do
  validateConnections portsCatalog connections
  resolvedSinks <- traverse (fmap snd . resolveConnectionEndpoints portsCatalog) connections
  let inboundCounts =
        foldl'
          accumulateInboundCounts
          Map.empty
          resolvedSinks
      openEntryKeys =
        Set.fromList
          [ (boundary.bpNodeRef, boundary.bpPortName)
          | boundary <- openEntries
          ]
  traverse_
    (validateNodeInputPorts openEntryKeys inboundCounts)
    [ (nodeRef, nodePorts)
    | nodeRef <- Set.toAscList fragmentNodeRefs
    , Just nodePorts <- [Map.lookup nodeRef portsCatalog]
    ]

validateConnections
  :: Map CircuitNodeRef WireCore.WirePorts
  -> [WireCore.Connection]
  -> Either WireCore.WireError ()
validateConnections portsCatalog =
  traverse_ (validateConnection portsCatalog)

validateConnection
  :: Map CircuitNodeRef WireCore.WirePorts
  -> WireCore.Connection
  -> Either WireCore.WireError ()
validateConnection portsCatalog connection = do
  _ <- resolveConnectionEndpoints portsCatalog connection
  Right ()

resolveConnectionEndpoints
  :: Map CircuitNodeRef WireCore.WirePorts
  -> WireCore.Connection
  -> Either
       WireCore.WireError
       ((CircuitNodeRef, Text, Text), (CircuitNodeRef, Text, WireCore.WireInputPort))
resolveConnectionEndpoints portsCatalog connection = do
  sourceCandidates <- resolveSourceEndpointCandidates portsCatalog connection.connectionFrom
  sinkCandidates <- resolveSinkEndpointCandidates portsCatalog connection.connectionTo
  case compatiblePairs sourceCandidates sinkCandidates of
    [pair] -> Right pair
    compatiblePairList@(_ : _) ->
      Left
        ( WireCore.WireAmbiguousCompatiblePorts
            connection.connectionFrom
            connection.connectionTo
            (fmap renderCompatiblePair compatiblePairList)
        )
    [] ->
      case (sourceCandidates, sinkCandidates) of
        ((_, _, actualContract) : _, (_, sinkPortName, sinkPortSpec) : _) ->
          if bothEndpointsExplicit
            then
              Left
                ( WireCore.WirePortContractMismatch
                    connection.connectionFrom
                    actualContract
                    connection.connectionTo
                    sinkPortName
                    sinkPortSpec.wireInputPortAccepts
                )
            else Left (WireCore.WireNoCompatiblePorts connection.connectionFrom connection.connectionTo)
        _ ->
          Left (WireCore.WireNoCompatiblePorts connection.connectionFrom connection.connectionTo)
  where
    bothEndpointsExplicit =
      isJust connection.connectionFrom.endpointPortName
        && isJust connection.connectionTo.endpointPortName
    compatiblePairs sourceCandidates sinkCandidates =
      [ (sourceCandidate, sinkCandidate)
      | sourceCandidate@(_, _, actualContract) <- sourceCandidates
      , sinkCandidate@(_, _, sinkPortSpec) <- sinkCandidates
      , actualContract `elem` sinkPortSpec.wireInputPortAccepts
      ]
    renderCompatiblePair ((_, sourcePortName, actualContract), (_, sinkPortName, _)) =
      sourcePortName <> " -> " <> sinkPortName <> " (" <> actualContract <> ")"

validateNodeInputPorts
  :: Set.Set (CircuitNodeRef, Text)
  -> Map (CircuitNodeRef, Text) Int
  -> (CircuitNodeRef, WireCore.WirePorts)
  -> Either WireCore.WireError ()
validateNodeInputPorts openEntryKeys inboundCounts (nodeRef, nodePorts) =
  traverse_ validateInputPort (Map.toList nodePorts.wirePortsInputs)
  where
    validateInputPort (portName, portSpec) =
      let inboundCount = Map.findWithDefault 0 (nodeRef, portName) inboundCounts
       in do
            when
              ( portSpec.wireInputPortRequired
                  && inboundCount == 0
                  && Set.notMember (nodeRef, portName) openEntryKeys
              )
              $ Left (WireCore.WireMissingRequiredInputPort nodeRef portName)
            when (portSpec.wireInputPortCardinality == WireCore.WireInputCardinalityOne && inboundCount > 1) $
              Left (WireCore.WireInputPortCardinalityViolation nodeRef portName inboundCount)

accumulateInboundCounts
  :: Map (CircuitNodeRef, Text) Int
  -> (CircuitNodeRef, Text, WireCore.WireInputPort)
  -> Map (CircuitNodeRef, Text) Int
accumulateInboundCounts inboundCounts (nodeRef, portName, _portSpec) =
  Map.insertWith (+) (nodeRef, portName) 1 inboundCounts

resolveSourceEndpointCandidates
  :: Map CircuitNodeRef WireCore.WirePorts
  -> WireCore.EndpointRef
  -> Either WireCore.WireError [(CircuitNodeRef, Text, Text)]
resolveSourceEndpointCandidates portsCatalog endpointRef = do
  nodePorts <- requirePorts endpointRef.endpointNodeRef
  case endpointRef.endpointPortName of
    Just portName ->
      case Map.lookup portName nodePorts.wirePortsOutputs of
        Just portSpec -> Right [(endpointRef.endpointNodeRef, portName, portSpec.wireOutputPortContract)]
        Nothing -> Left (WireCore.WireUnknownPort endpointRef.endpointNodeRef portName)
    Nothing ->
      case Map.toList nodePorts.wirePortsOutputs of
        [] -> Left (WireCore.WireMissingDefaultOutputPort endpointRef.endpointNodeRef)
        outputPorts ->
          Right
            [ (endpointRef.endpointNodeRef, portName, portSpec.wireOutputPortContract)
            | (portName, portSpec) <- outputPorts
            ]
  where
    requirePorts nodeRef =
      case Map.lookup nodeRef portsCatalog of
        Just ports -> Right ports
        Nothing -> Left (WireCore.WireUnknownNodeRef nodeRef)

resolveSinkEndpointCandidates
  :: Map CircuitNodeRef WireCore.WirePorts
  -> WireCore.EndpointRef
  -> Either WireCore.WireError [(CircuitNodeRef, Text, WireCore.WireInputPort)]
resolveSinkEndpointCandidates portsCatalog endpointRef = do
  nodePorts <- requirePorts endpointRef.endpointNodeRef
  case endpointRef.endpointPortName of
    Just portName ->
      case Map.lookup portName nodePorts.wirePortsInputs of
        Just portSpec -> Right [(endpointRef.endpointNodeRef, portName, portSpec)]
        Nothing -> Left (WireCore.WireUnknownPort endpointRef.endpointNodeRef portName)
    Nothing ->
      case Map.toList nodePorts.wirePortsInputs of
        [] -> Left (WireCore.WireMissingDefaultInputPort endpointRef.endpointNodeRef)
        inputPorts ->
          Right
            [ (endpointRef.endpointNodeRef, portName, portSpec)
            | (portName, portSpec) <- inputPorts
            ]
  where
    requirePorts nodeRef =
      case Map.lookup nodeRef portsCatalog of
        Just ports -> Right ports
        Nothing -> Left (WireCore.WireUnknownNodeRef nodeRef)

validateFragmentTopology :: Bool -> Relation CircuitNodeRef -> Either WireCore.WireError ()
validateFragmentTopology requireConnected relation = do
  when (Set.null (relVertices relation)) $
    Left WireCore.WireEmptyCircuit
  case validateDAG relation of
    Left err -> Left (WireCore.WireInvalidTopology err)
    Right () -> pure ()
  when requireConnected $
    case Set.lookupMin (relVertices relation) of
      Nothing -> Left WireCore.WireEmptyCircuit
      Just rootRef ->
        let undirected = relation <> transposeRelation relation
            reachableRefs = reachable undirected rootRef
         in if reachableRefs == relVertices relation
              then Right ()
              else
                Left
                  ( WireCore.WireDisconnectedTopology
                      (Set.toAscList (Set.difference (relVertices relation) reachableRefs))
                  )

extractCircuitId :: Maybe Aeson.Value -> Maybe Text
extractCircuitId Nothing = Nothing
extractCircuitId (Just (Aeson.Object obj)) =
  case KeyMap.lookup "defaultReportTitle" obj of
    Just (Aeson.String text) -> Just (slugify text)
    _ -> Nothing
extractCircuitId _ = Nothing

slugify :: Text -> Text
slugify =
  T.map (\c -> if c == ' ' then '_' else c)
    . T.toLower
    . T.filter (\c -> c == ' ' || c == '_' || c == '-' || Char.isAlphaNum c)

qnameToQualifiedRef :: QName -> WireCore.QualifiedRef
qnameToQualifiedRef (QName segments) =
  WireCore.QualifiedRef
    { qualifiedRefSegments = segments
    }

resolveExecutorQName :: LoweringState -> QName -> Either WireCore.WireError Text
resolveExecutorQName st qname =
  mapLeft WireCore.WireExecutorNotInScope $
    resolveWireExecutorQName st.lsUseScope qname

validateExecutorProjection
  :: WireCompileEnv
  -> CircuitNodeRef
  -> WireCore.WireExecutor
  -> WireCore.WirePorts
  -> Either WireCore.WireError ()
validateExecutorProjection compileEnv nodeRef executor ports =
  case compileEnv.wireCompileEnvProjectionMode of
    WireProjectionPermissive ->
      Right ()
    WireProjectionStrict ->
      let executorId = wireExecutorIdFromWireExecutor executor
       in case lookupWireExecutorProjection executorId compileEnv.wireCompileEnvExecutorRegistry of
            Nothing ->
              Left (WireCore.WireUnknownExecutor nodeRef (wireExecutorIdToText executorId))
            Just projection
              | projection.wireExecutorProjectionPortPolicy == WireExecutorAuthorDeclaredPorts ->
                  Right ()
              | projection.wireExecutorProjectionPorts == ports ->
                  Right ()
              | otherwise ->
                  Left (WireCore.WireExecutorPortsMismatch nodeRef (wireExecutorIdToText executorId))

validateStdIoExecutorShape
  :: CircuitNodeRef -> Text -> WireCore.WirePorts -> Either WireCore.WireError ()
validateStdIoExecutorShape nodeRef executorId ports
  | executorId == stdIoStdinExecutorId =
      requireShape 0 1 stdIoStdinShapeMessage
  | executorId == stdIoStdoutExecutorId =
      requireShape 1 0 stdIoStdoutShapeMessage
  | executorId == stdIoCommandExecutorId =
      requireAtMostOneEach stdIoCommandShapeMessage
  | executorId == stdIoReadFileExecutorId =
      requireInputAtMostOutputExactOne stdIoReadFileShapeMessage
  | executorId == stdIoWriteFileExecutorId =
      requireShape 1 0 stdIoWriteFileShapeMessage
  | otherwise =
      Right ()
  where
    inputCount = Map.size ports.wirePortsInputs
    outputCount = Map.size ports.wirePortsOutputs

    requireShape expectedInputs expectedOutputs message =
      unless (inputCount == expectedInputs && outputCount == expectedOutputs) $
        Left (WireCore.WireInvalidPorts nodeRef message)

    requireAtMostOneEach message =
      unless (inputCount <= 1 && outputCount <= 1) $
        Left (WireCore.WireInvalidPorts nodeRef message)

    requireInputAtMostOutputExactOne message =
      unless (inputCount <= 1 && outputCount == 1) $
        Left (WireCore.WireInvalidPorts nodeRef message)

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = \case
  Left err -> Left (f err)
  Right ok -> Right ok
