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
  , compileWireFragmentFile
  , compileWireFragmentFileWithEnv
  , compileWireText
  , compileWireTextWithEnv
  , compileWireFragmentText
  , compileWireFragmentTextWithEnv
  )
where

import Control.Applicative ((<|>))
import Control.Monad (unless, when, zipWithM)
import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BSL
import Data.Char qualified as Char
import Data.Foldable (foldlM, traverse_)
import Data.Int (Int32)
import Data.List (nub, nubBy)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as Vector

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
import Cortex.Wire.Circuit.Node (CircuitNodeKind (Act))
import Cortex.Wire.Contract
  ( WireCompileEnv (..)
  , WireContractRegistry (..)
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
  , signalNodeBoundaryNormalForm
  , validateNodeBoundaryNormalForm
  )
import Cortex.Wire.Parser (parseWireFile, renderParseError)
import Cortex.Wire.Pure
  ( PureEvalError (..)
  , corePureStaticContextFromBindings
  , corePureWhereStaticFields
  , renderPureEvalError
  , validatePureTaskConfig
  )
import Cortex.Wire.Std
  ( stdIoCommandExecutorId
  , stdIoContractIdForName
  , stdIoExecutorIdForLeaf
  , stdIoExecutorLeaves
  , stdIoNamespace
  , stdIoStdinExecutorId
  , stdIoStdoutExecutorId
  )
import Cortex.Wire.Syntax

compileWireText :: Text -> Either WireCore.WireError CompiledCircuit
compileWireText =
  compileWireTextWithEnv emptyWireCompileEnv

compileWireTextWithEnv :: WireCompileEnv -> Text -> Either WireCore.WireError CompiledCircuit
compileWireTextWithEnv compileEnv sourceText = do
  wireFile <-
    mapLeft
      (WireCore.WireParseError . renderParseError)
      (parseWireFile "wire" sourceText)
  compileWireFileWithEnv compileEnv wireFile

compileWireFragmentText :: Text -> Either WireCore.WireError CompiledCircuit
compileWireFragmentText =
  compileWireFragmentTextWithEnv emptyWireCompileEnv

compileWireFragmentTextWithEnv
  :: WireCompileEnv -> Text -> Either WireCore.WireError CompiledCircuit
compileWireFragmentTextWithEnv compileEnv sourceText = do
  wireFile <-
    mapLeft
      (WireCore.WireParseError . renderParseError)
      (parseWireFile "wire-fragment" sourceText)
  compileWireFragmentFileWithEnv compileEnv wireFile

compileWireFile :: WireFile -> Either WireCore.WireError CompiledCircuit
compileWireFile =
  compileWireFileWithEnv emptyWireCompileEnv

compileWireFileWithEnv :: WireCompileEnv -> WireFile -> Either WireCore.WireError CompiledCircuit
compileWireFileWithEnv compileEnv wireFile = do
  lowered <- lowerWireFile compileEnv wireFile
  compileLoweredWireFile compileEnv True wireFile lowered

compileWireFragmentFile :: WireFile -> Either WireCore.WireError CompiledCircuit
compileWireFragmentFile =
  compileWireFragmentFileWithEnv emptyWireCompileEnv

compileWireFragmentFileWithEnv
  :: WireCompileEnv -> WireFile -> Either WireCore.WireError CompiledCircuit
compileWireFragmentFileWithEnv compileEnv wireFile = do
  lowered <- lowerWireFile compileEnv wireFile
  compileLoweredWireFile compileEnv False wireFile lowered

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
  let metadataValue =
        fromMaybe
          (Aeson.object ["format" Aeson..= ("cortex.workflow.wire" :: Text)])
          lowered.lwfMetadata
  pure
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

data LoweredWireFile = LoweredWireFile
  { lwfFragment :: !GraphFragment
  , lwfMetadata :: !(Maybe Aeson.Value)
  , lwfCircuitId :: !Text
  , lwfDeclaredContracts :: !(Set.Set Text)
  }

data LoweringState = LoweringState
  { lsBindings :: !(Map Text EvalValue)
  , lsPureBindings :: ![CorePureBinding]
  , lsGraphBindings :: !(Map Text GraphFragment)
  , lsNamedNodes :: !(Map Text LoweredNode)
  , lsAnonCounter :: !Int
  , lsDeclaredContracts :: !(Set.Set Text)
  , lsExecutorUses :: !(Map Text Text)
  , lsStdExecutorsInScope :: !(Set.Set Text)
  , lsContractUses :: !(Map Text Text)
  }

emptyLoweringState :: LoweringState
emptyLoweringState =
  LoweringState
    { lsBindings = Map.empty
    , lsPureBindings = []
    , lsGraphBindings = Map.empty
    , lsNamedNodes = Map.empty
    , lsAnonCounter = 0
    , lsDeclaredContracts = Set.empty
    , lsExecutorUses = Map.empty
    , lsStdExecutorsInScope = Set.empty
    , lsContractUses = Map.empty
    }

data EvalValue
  = EvalString !Text
  | EvalNumber !Scientific
  | EvalBool !Bool
  | EvalList ![EvalValue]
  | EvalQName !QName
  | EvalRecord !(Map (NonEmpty Text) EvalValue)
  | EvalConstructor !QName !(Map (NonEmpty Text) EvalValue)
  | EvalConfiguredExecutor !ConfiguredExecutor
  deriving stock (Eq, Show)

data ConfiguredExecutor = ConfiguredExecutor
  { ceExecutor :: !Text
  , ceFields :: !(Map (NonEmpty Text) EvalValue)
  }
  deriving stock (Eq, Show)

data LoweredPort = LoweredPort
  { lpNodeRef :: !CircuitNodeRef
  , lpDirection :: !PortDirection
  , lpInternalName :: !Text
  , lpContract :: !Text
  , lpLabel :: !PortLabel
  , lpCardinality :: !(Maybe WireCore.WireInputCardinality)
  , lpExclusiveGroup :: !(Maybe Int)
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
  }
  deriving stock (Eq, Show)

data BoundaryPort = BoundaryPort
  { bpNodeRef :: !CircuitNodeRef
  , bpPortName :: !Text
  , bpContract :: !Text
  , bpLabel :: !PortLabel
  , bpExclusiveGroup :: !(Maybe (CircuitNodeRef, Int))
  }
  deriving stock (Eq, Ord, Show)

data BoundaryShape = BoundaryShape
  { bsContract :: !Text
  , bsLabel :: !PortLabel
  , bsExclusiveGroup :: !(Maybe Int)
  }
  deriving stock (Eq, Ord, Show)

data GraphFragment = GraphFragment
  { gfNodes :: !(Map CircuitNodeRef LoweredNode)
  , gfEntries :: ![BoundaryPort]
  , gfExits :: ![BoundaryPort]
  , gfConnections :: ![WireCore.Connection]
  }
  deriving stock (Eq, Show)

emptyFragment :: GraphFragment
emptyFragment =
  GraphFragment
    { gfNodes = Map.empty
    , gfEntries = []
    , gfExits = []
    , gfConnections = []
    }

lowerWireFile :: WireCompileEnv -> WireFile -> Either WireCore.WireError LoweredWireFile
lowerWireFile compileEnv wireFile = do
  loweredState <-
    foldlM (lowerTopForm compileEnv) emptyLoweringState wireFile.wireFileTopForms
  fileReturn <- maybe (Left WireCore.WireMissingCircuit) Right wireFile.wireFileReturn
  (resultFragment, maybeMetadata, loweredState') <- lowerFileReturn loweredState fileReturn
  let usedNodeRefs = foldMap loweredNodeRefs resultFragment.gfNodes
      declaredNodeRefs = Set.fromList (fmap (.lnRef) (Map.elems loweredState'.lsNamedNodes))
      unusedNodeRefs = Set.toAscList (Set.difference declaredNodeRefs usedNodeRefs)
  case unusedNodeRefs of
    unusedRef : _ -> Left (WireCore.WireUnusedNodeRef unusedRef)
    [] ->
      Right
        LoweredWireFile
          { lwfFragment = resultFragment
          , lwfMetadata = maybeMetadata
          , lwfCircuitId = fromMaybe "wire" (extractCircuitId maybeMetadata)
          , lwfDeclaredContracts = loweredState'.lsDeclaredContracts
          }

loweredNodeRefs :: LoweredNode -> Set.Set CircuitNodeRef
loweredNodeRefs loweredNode =
  Set.insert loweredNode.lnRef $
    case loweredNode.lnCompiledNode of
      CompiledCircuitCondition conditionNode ->
        fragmentNodeRefs conditionNode.circuitConditionNodeThenFragment
          <> foldMap fragmentNodeRefs conditionNode.circuitConditionNodeElseFragment
      _ ->
        Set.empty
  where
    fragmentNodeRefs fragment =
      foldMap compiledNodeRefs fragment.compiledCircuitFragmentNodes

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
  :: WireCompileEnv -> LoweringState -> TopForm -> Either WireCore.WireError LoweringState
lowerTopForm compileEnv st = \case
  TopContract contractId ->
    if Map.member contractId.unContractId st.lsContractUses
      then Left (WireCore.WireDuplicateUseBinding contractId.unContractId)
      else Right st {lsDeclaredContracts = Set.insert contractId.unContractId st.lsDeclaredContracts}
  TopUse useSpec ->
    lowerUseSpec st useSpec
  TopImport _ ->
    Left (WireCore.WireParseError "Wire imports are not compiled yet.")
  TopLet _visibility name rhs -> do
    if topLevelBindingNameTaken st name
      then Left (WireCore.WireDuplicateLetBinding name)
      else case rhs of
        LetRhsCorePure expr ->
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
          lowerWireLetBinding st name expr
  TopNode nodeDecl -> do
    loweredNode <- lowerNamedNode compileEnv st nodeDecl
    let nodeName = nodeDecl.nodeDeclName
    if topLevelBindingNameTaken st nodeName
      then Left (WireCore.WireDuplicateNodeRef loweredNode.lnRef)
      else
        Right
          st
            { lsNamedNodes = Map.insert nodeName loweredNode st.lsNamedNodes
            }
  where
    topLevelBindingNameTaken state name =
      Map.member name state.lsBindings
        || Map.member name state.lsGraphBindings
        || Map.member name state.lsNamedNodes
        || Map.member name state.lsExecutorUses
        || Map.member name state.lsContractUses
        || any (\existing -> existing.corePureBindingName == name) state.lsPureBindings

lowerUseSpec :: LoweringState -> UseSpec -> Either WireCore.WireError LoweringState
lowerUseSpec st useSpec = do
  when (renderQName useSpec.useSpecNamespace /= stdIoNamespace) $
    Left (WireCore.WireUnknownUseNamespace (renderQName useSpec.useSpecNamespace))
  foldlM lowerUseItem st (NE.toList useSpec.useSpecItems)
  where
    lowerUseItem state = \case
      UseExecutor itemName maybeAlias -> do
        canonical <- stdIoExecutorId itemName
        let localName = fromMaybe itemName maybeAlias
        ensureUseNameFresh localName state
        Right
          state
            { lsExecutorUses = Map.insert localName canonical state.lsExecutorUses
            , lsStdExecutorsInScope = Set.insert canonical state.lsStdExecutorsInScope
            }
      UseContract itemName maybeAlias -> do
        canonical <- stdIoContractId itemName
        let localName = fromMaybe itemName maybeAlias
        ensureUseNameFresh localName state
        Right
          state
            { lsContractUses = Map.insert localName canonical state.lsContractUses
            , lsDeclaredContracts = Set.insert canonical state.lsDeclaredContracts
            }

    ensureUseNameFresh localName state =
      when
        ( Map.member localName state.lsExecutorUses
            || Map.member localName state.lsContractUses
            || Map.member localName state.lsBindings
            || Map.member localName state.lsGraphBindings
            || Map.member localName state.lsNamedNodes
            || Set.member localName state.lsDeclaredContracts
        )
        (Left (WireCore.WireDuplicateUseBinding localName))

stdIoExecutorId :: Text -> Either WireCore.WireError Text
stdIoExecutorId itemName =
  maybe
    (Left (WireCore.WireUnknownUseItem stdIoNamespace ("@" <> itemName)))
    Right
    (stdIoExecutorIdForLeaf itemName)

stdIoContractId :: Text -> Either WireCore.WireError Text
stdIoContractId itemName =
  maybe
    (Left (WireCore.WireUnknownUseItem stdIoNamespace itemName))
    Right
    (stdIoContractIdForName itemName)

lowerWireLetBinding
  :: LoweringState
  -> Text
  -> Expr
  -> Either WireCore.WireError LoweringState
lowerWireLetBinding st name expr
  | isGraphLetExpr st expr = do
      graphValue <- lowerGraphExpr st expr
      Right st {lsGraphBindings = Map.insert name graphValue st.lsGraphBindings}
  | otherwise = do
      value <- evalValue st expr
      let st' = st {lsBindings = Map.insert name value st.lsBindings}
      Right (appendPureBindingIfCapturable name value st')

isGraphLetExpr :: LoweringState -> Expr -> Bool
isGraphLetExpr st = \case
  ExprOverlay {} -> True
  ExprConnect {} -> True
  ExprSelect {} -> True
  ExprLit LitUnit -> True
  ExprIdent (QName (name :| [])) ->
    Map.member name st.lsNamedNodes || Map.member name st.lsGraphBindings
  _ -> False

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
  EvalConfiguredExecutor {} -> Nothing
  where
    fieldToCorePure (path, value) =
      CorePureField path <$> evalValueToCorePureExpr value

lowerNamedNode
  :: WireCompileEnv -> LoweringState -> NodeDecl -> Either WireCore.WireError LoweredNode
lowerNamedNode compileEnv st nodeDecl = do
  let nodeRef = CircuitNodeRef nodeDecl.nodeDeclName
  ports <- lowerPortSignature st nodeRef nodeDecl.nodeDeclPortSig
  case nodeDecl.nodeDeclBody of
    NodeBodyExecutor whereExpr executorCallValue -> do
      validateWhereClause st nodeRef ports.lnpInputs whereExpr
      loweredNodeFromExecutorCall compileEnv st nodeRef ports whereExpr executorCallValue
    NodeBodyPure pureBody -> do
      validateWhereClause st nodeRef ports.lnpInputs pureBody.nodePureBodyWhere
      loweredPureNodeFromBody compileEnv st nodeRef ports st.lsPureBindings pureBody

lowerFileReturn
  :: LoweringState
  -> Expr
  -> Either WireCore.WireError (GraphFragment, Maybe Aeson.Value, LoweringState)
lowerFileReturn st expr = do
  fragment <- lowerGraphExpr st expr
  Right (fragment, Nothing, st)

lowerGraphExpr :: LoweringState -> Expr -> Either WireCore.WireError GraphFragment
lowerGraphExpr st expr =
  case flattenConnectChain expr of
    [singleExpr] ->
      lowerGraphTerm st singleExpr
    chainItems ->
      lowerConnectChain st chainItems

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

lowerConnectChain :: LoweringState -> [Expr] -> Either WireCore.WireError GraphFragment
lowerConnectChain st exprs = do
  items <- filter (not . isIdentityConnectItem) <$> traverse connectItem exprs
  case items of
    [] ->
      Right emptyFragment
    firstItem : restItems -> do
      initial <- lowerGraphBase st firstItem.ciBaseExpr
      stepConnectChain st initial firstItem restItems

stepConnectChain
  :: LoweringState
  -> GraphFragment
  -> ConnectItem
  -> [ConnectItem]
  -> Either WireCore.WireError GraphFragment
stepConnectChain _st current currentItem [] =
  case currentItem.ciSelectArms of
    Nothing ->
      Right current
    Just arms ->
      lowerSelectStep _st current arms Nothing
stepConnectChain st current currentItem (nextItem : restItems) =
  case currentItem.ciSelectArms of
    Just arms -> do
      nextBase <- lowerGraphBase st nextItem.ciBaseExpr
      selectReduced <- lowerSelectStep st current arms (Just nextBase)
      stepConnectChain st selectReduced nextItem restItems
    Nothing -> do
      nextBase <- lowerGraphBase st nextItem.ciBaseExpr
      let connected = connectFragments current nextBase
      stepConnectChain st connected nextItem restItems

lowerGraphTerm :: LoweringState -> Expr -> Either WireCore.WireError GraphFragment
lowerGraphTerm st = \case
  ExprSelect baseExpr arms -> do
    baseFragment <- lowerGraphBase st baseExpr
    lowerSelectStep st baseFragment arms Nothing
  other ->
    lowerGraphBase st other

lowerGraphBase :: LoweringState -> Expr -> Either WireCore.WireError GraphFragment
lowerGraphBase st = \case
  ExprLit LitUnit ->
    Right emptyFragment
  ExprOverlay lhs rhs ->
    overlayFragments <$> lowerGraphExpr st lhs <*> lowerGraphExpr st rhs
  ExprIdent (QName (name :| [])) ->
    case Map.lookup name st.lsGraphBindings of
      Just fragment ->
        Right fragment
      Nothing ->
        lowerNamedGraphRef name
  ExprSelect baseExpr arms -> do
    baseFragment <- lowerGraphBase st baseExpr
    lowerSelectStep st baseFragment arms Nothing
  ExprConnect lhs rhs ->
    lowerGraphExpr st (ExprConnect lhs rhs)
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
            GraphFragment
              { gfNodes = Map.singleton loweredNode.lnRef loweredNode
              , gfEntries = fmap boundaryFromPort loweredNode.lnInputs
              , gfExits = fmap boundaryFromPort loweredNode.lnOutputs
              , gfConnections = []
              }
        Nothing ->
          Left (WireCore.WireUnknownNodeRef (CircuitNodeRef name))

overlayFragments :: GraphFragment -> GraphFragment -> GraphFragment
overlayFragments lhs rhs =
  GraphFragment
    { gfNodes = Map.union lhs.gfNodes rhs.gfNodes
    , gfEntries = dedupeBoundaries (lhs.gfEntries <> rhs.gfEntries)
    , gfExits = dedupeBoundaries (lhs.gfExits <> rhs.gfExits)
    , gfConnections = dedupeConnections (lhs.gfConnections <> rhs.gfConnections)
    }

connectFragments :: GraphFragment -> GraphFragment -> GraphFragment
connectFragments lhs rhs =
  let matchedPairs = matchedBoundaryPairs lhs.gfExits rhs.gfEntries
      matchedLeft = Set.fromList (fmap fst matchedPairs)
      matchedRight = Set.fromList (fmap snd matchedPairs)
      bridgeConnections =
        fmap
          ( \(leftBoundary, rightBoundary) ->
              WireCore.connect
                (boundaryEndpoint leftBoundary)
                (boundaryEndpoint rightBoundary)
          )
          matchedPairs
   in GraphFragment
        { gfNodes = Map.union lhs.gfNodes rhs.gfNodes
        , gfEntries = dedupeBoundaries (lhs.gfEntries <> filter (`Set.notMember` matchedRight) rhs.gfEntries)
        , gfExits = dedupeBoundaries (filter (`Set.notMember` matchedLeft) lhs.gfExits <> rhs.gfExits)
        , gfConnections = dedupeConnections (lhs.gfConnections <> rhs.gfConnections <> bridgeConnections)
        }

lowerSelectStep
  :: LoweringState
  -> GraphFragment
  -> NonEmpty SelectArm
  -> Maybe GraphFragment
  -> Either WireCore.WireError GraphFragment
lowerSelectStep st current arms maybeDownstream = do
  selectorVariants <- resolveExclusiveBoundary current.gfExits
  resolvedArms <- resolveSelectArms selectorVariants arms
  preparedArms <-
    traverse
      ( \(variant, resolvedArm) -> do
          armFragment <- lowerGraphExpr st resolvedArm.selectArmResolvedExpr
          armOutputBoundary <-
            inferSelectArmOutputBoundary variant resolvedArm.selectArmResolvedKey armFragment
          pure
            PreparedSelectArm
              { psaVariant = variant
              , psaKey = resolvedArm.selectArmResolvedKey
              , psaFragment = armFragment
              , psaOutputBoundary = armOutputBoundary
              }
      )
      resolvedArms
  commonBoundary <- resolveSelectCommonBoundary maybeDownstream preparedArms
  traverse_ (validatePreparedSelectArm commonBoundary) preparedArms
  if all (isIdentityFragment . psaFragment) preparedArms
    then
      pure $
        maybe
          current
          (connectFragments current)
          maybeDownstream
    else do
      conditionNode <- buildSelectConditionTree selectorVariants commonBoundary preparedArms
      let conditionFragment =
            GraphFragment
              { gfNodes = Map.singleton conditionNode.lnRef conditionNode
              , gfEntries = fmap boundaryFromPort conditionNode.lnInputs
              , gfExits = fmap boundaryFromPort (bridgeOutputPorts conditionNode)
              , gfConnections = []
              }
          currentToCondition = connectFragments current conditionFragment
      pure $
        maybe
          currentToCondition
          (connectFragments currentToCondition)
          maybeDownstream

data PreparedSelectArm = PreparedSelectArm
  { psaVariant :: !BoundaryPort
  , psaKey :: !Text
  , psaFragment :: !GraphFragment
  , psaOutputBoundary :: ![BoundaryPort]
  }

data ResolvedSelectArm = ResolvedSelectArm
  { selectArmResolvedKey :: !Text
  , selectArmResolvedExpr :: !Expr
  }

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
      resolveKey arm =
        case Map.lookup arm.selectArmKey variantsByLabel <|> Map.lookup arm.selectArmKey variantsByContract of
          Just [variant] ->
            Right
              ( variant
              , ResolvedSelectArm
                  { selectArmResolvedKey = arm.selectArmKey
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
          _ ->
            Left
              ( WireCore.WireParseError
                  ( "select arm key "
                      <> arm.selectArmKey
                      <> " does not match any variant on the selector boundary."
                  )
              )
      resolved = traverse resolveKey arms
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
      let rooted = connectFragments (fragmentFromBoundaryOutputs [selectorVariant]) armFragment
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
                    GraphFragment
                      { gfNodes = Map.singleton nestedCondition.lnRef nestedCondition
                      , gfEntries = fmap boundaryFromPort nestedCondition.lnInputs
                      , gfExits = fmap boundaryFromPort (bridgeOutputPorts nestedCondition)
                      , gfConnections = []
                      }
              Right (fmap psaKey armList, Just nestedFragment)

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
                        let nextTag = Map.size groupTags
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
  CircuitNodeRef
    ( "__select:"
        <> humanTag
        <> ":"
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

matchedBoundaryPairs :: [BoundaryPort] -> [BoundaryPort] -> [(BoundaryPort, BoundaryPort)]
matchedBoundaryPairs leftExits rightEntries =
  [ (leftBoundary, rightBoundary)
  | leftBoundary <- leftExits
  , rightBoundary <- rightEntries
  , leftBoundary.bpContract == rightBoundary.bpContract
  , leftBoundary.bpLabel == rightBoundary.bpLabel
  ]

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
  -> Maybe CorePureExpr
  -> ExecutorCall
  -> Either WireCore.WireError LoweredNode
loweredNodeFromExecutorCall compileEnv st nodeRef ports whereExpr executorCallValue = do
  (configuredExecutor, inputExpr) <- resolveExecutorCall st executorCallValue
  let exactFields = configuredExecutor.ceFields
      label = lookupMaybeTextField "label" exactFields
      genericFields = genericConfigFields exactFields knownSimpleFields
      runtimePorts = taskWirePortsFromLowered ports
      executorId = configuredExecutor.ceExecutor
      maybeSignal = lookupMaybeTextField "on" exactFields
      maybeKind = lookupMaybeTextField "kind" exactFields
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
      | isJust maybeKind || isJust maybeTarget -> do
          artifactKind <- requireTextField nodeRef "kind" exactFields
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
              configValue = executorConfigValue genericFields whereExpr inputExpr
              normalForm =
                executorNodeBoundaryNormalForm
                  nodeRef
                  runtimePorts
                  whereExpr
                  inputExpr
                  executor
                  configValue
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
                , circuitTaskNodeKind = Just Act
                , circuitTaskNodeMetadata =
                    actMetadata
                      nodeRef
                      executor
                      label
                      instructionsText
                      configValue
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
      }
  where
    knownSimpleFields =
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
      , "kind"
      , "to"
      ]

resolveExecutorCall
  :: LoweringState -> ExecutorCall -> Either WireCore.WireError (ConfiguredExecutor, CorePureExpr)
resolveExecutorCall st = \case
  ExecutorCallInline executorQName recordExpr inputExpr ->
    do
      executorId <- resolveExecutorQName st executorQName
      fields <- evalRecordFields st recordExpr
      Right (ConfiguredExecutor executorId fields, inputExpr)
  ExecutorCallConfigured name inputExpr ->
    case Map.lookup name st.lsBindings of
      Just (EvalConfiguredExecutor configuredExecutor) -> Right (configuredExecutor, inputExpr)
      Just other ->
        Left (WireCore.WireFieldTypeMismatch name "configured executor" (valueKind other))
      Nothing ->
        Left (WireCore.WireUnknownLetBinding name)

executorConfigValue
  :: Map (NonEmpty Text) EvalValue
  -> Maybe CorePureExpr
  -> CorePureExpr
  -> Maybe Aeson.Value
executorConfigValue fields whereExpr inputExpr =
  Just (Aeson.Object (insertMaybeJson "where" whereExpr baseObject))
  where
    inputValue = Aeson.toJSON inputExpr
    baseObject =
      case configValueFromFields fields of
        Just (Aeson.Object obj) ->
          KeyMap.insert (Key.fromText "input") inputValue obj
        Just value ->
          KeyMap.fromList
            [ (Key.fromText "config", value)
            , (Key.fromText "input", inputValue)
            ]
        Nothing ->
          KeyMap.singleton (Key.fromText "input") inputValue

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
  -> [CorePureBinding]
  -> NodePureBody
  -> Either WireCore.WireError LoweredNode
loweredPureNodeFromBody compileEnv st nodeRef ports topLevelBindings pureBody = do
  outputConfig <- pureOutputConfigMap st nodeRef ports.lnpOutputs pureBody.nodePureBodyOutputs
  let runtimePorts = taskWirePortsFromLowered ports
      normalForm =
        pureNodeBoundaryNormalForm
          nodeRef
          runtimePorts
          topLevelBindings
          pureBody.nodePureBodyWhere
          outputConfig
      executor = WireCore.WireExecutorNative "pure"
  mapLeft (WireCore.WireInvalidPorts nodeRef) $
    validateNodeBoundaryNormalForm normalForm
  mapLeft (WireCore.WireInvalidPorts nodeRef . renderPureEvalError) $
    validatePureTaskConfig
      (normalFormPorts normalForm)
      topLevelBindings
      pureBody.nodePureBodyWhere
      outputConfig
  validateExecutorProjection compileEnv nodeRef executor (normalFormPorts normalForm)
  pure
    LoweredNode
      { lnRef = nodeRef
      , lnCompiledNode =
          CompiledCircuitTask
            CircuitTaskNode
              { circuitTaskNodeRef = nodeRef
              , circuitTaskNodeLabel = defaultNodeLabel nodeRef Nothing
              , circuitTaskNodeKind = Just Act
              , circuitTaskNodeMetadata =
                  actMetadata
                    nodeRef
                    executor
                    Nothing
                    Nothing
                    (Just (nativePureTaskConfigValue topLevelBindings pureBody.nodePureBodyWhere outputConfig))
                    []
                    (normalFormPorts normalForm)
                    Nothing
                    Nothing
                    Nothing
                    Nothing
                    Nothing
                    Nothing
                    Nothing
              }
      , lnPorts = runtimePorts
      , lnInputs = ports.lnpInputs
      , lnOutputs = ports.lnpOutputs
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

pureOutputConfigMap
  :: LoweringState
  -> CircuitNodeRef
  -> [LoweredPort]
  -> NonEmpty PureOutputEquation
  -> Either WireCore.WireError (Map Text CorePureExpr)
pureOutputConfigMap st nodeRef outputPorts outputEquations = do
  let outputEquationList = NE.toList outputEquations
  when (length outputPorts /= length outputEquationList) $
    Left (WireCore.WireInvalidPorts nodeRef "pure output equations do not match lowered output ports")
  Map.fromList <$> zipWithM matchOutput outputPorts outputEquationList
  where
    matchOutput port outputEquation = do
      let ContractId rawContractName = outputEquation.pureOutputEquationContract
          contractName = resolveContractId st rawContractName
      when (port.lpLabel /= outputEquation.pureOutputEquationLabel || port.lpContract /= contractName) $
        Left
          (WireCore.WireInvalidPorts nodeRef "pure output equation does not match its lowered output port")
      Right (port.lpInternalName, outputEquation.pureOutputEquationExpr)

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
          (0 :: Int, [])
          decls

resolveContractId :: LoweringState -> Text -> Text
resolveContractId st contractName =
  Map.findWithDefault contractName contractName st.lsContractUses

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
  ExprConfiguredExecutor executorQName recordExpr ->
    EvalConfiguredExecutor
      <$> (ConfiguredExecutor <$> resolveExecutorQName st executorQName <*> evalRecordFields st recordExpr)
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
  ExprSelect {} ->
    Left (WireCore.WireParseError "select(...) is only supported in graph position.")

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

genericConfigFields
  :: Map (NonEmpty Text) EvalValue
  -> [Text]
  -> Map (NonEmpty Text) EvalValue
genericConfigFields fields excludedTopLevel =
  Map.filterWithKey
    (\path _ -> NE.head path `notElem` excludedTopLevel)
    fields

valueKind :: EvalValue -> Text
valueKind = \case
  EvalString _ -> "string"
  EvalNumber _ -> "number"
  EvalBool _ -> "boolean"
  EvalList _ -> "list"
  EvalQName _ -> "qualified identifier"
  EvalRecord _ -> "record"
  EvalConstructor _ _ -> "constructor"
  EvalConfiguredExecutor _ -> "configured executor"

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

configValueFromFields :: Map (NonEmpty Text) EvalValue -> Maybe Aeson.Value
configValueFromFields fields
  | Map.null fields = Nothing
  | otherwise = Just (fieldsObject fields)

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
  EvalConfiguredExecutor configuredExecutor ->
    fieldsObject configuredExecutor.ceFields

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
  :: CircuitNodeRef
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
actMetadata nodeRef executor _label instructionsText configValue tools ports timeoutSeconds retryCount stepBudget toolLoopMinSteps maxOutputTokens reasoningEnabled memoryStrategy =
  Aeson.object $
    [ "slot" Aeson..= nodeRef.unCircuitNodeRef
    , "executor" Aeson..= renderExecutor executor
    , "ports" Aeson..= portsMetadataValue ports
    ]
      <> foldMap (\instructions -> ["instructions" Aeson..= instructions]) instructionsText
      <> foldMap (\config -> ["config" Aeson..= config]) configValue
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
        concatMap (.wireInputPortAccepts) (Map.elems ports.wirePortsInputs)
          <> fmap (.wireOutputPortContract) (Map.elems ports.wirePortsOutputs)
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
resolveExecutorQName st qname@(QName segments) =
  case segments of
    localName :| []
      | Just canonical <- Map.lookup localName st.lsExecutorUses ->
          Right canonical
      | Set.member localName stdIoExecutorLeaves ->
          Left (WireCore.WireExecutorNotInScope ("@" <> localName))
      | otherwise ->
          Right rendered
    _
      | "std.io." `T.isPrefixOf` rendered ->
          if Set.member rendered st.lsStdExecutorsInScope
            then Right rendered
            else Left (WireCore.WireExecutorNotInScope ("@" <> rendered))
      | otherwise ->
          Right rendered
  where
    rendered = renderQName qname

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
      requireShape 0 1 "std.io.stdin expects zero input ports and exactly one output port."
  | executorId == stdIoStdoutExecutorId =
      requireShape 1 0 "std.io.stdout expects exactly one input port and zero output ports."
  | executorId == stdIoCommandExecutorId =
      requireAtMostOneEach "std.io.command expects zero or one input port and zero or one output port."
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

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f = \case
  Left err -> Left (f err)
  Right ok -> Right ok
