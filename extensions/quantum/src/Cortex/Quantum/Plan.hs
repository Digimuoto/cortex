{- |
Module      : Cortex.Quantum.Plan
Description : Walk a compiled Wire circuit to a quantum external-call payload.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The compiled-circuit walker: given a 'CompiledCircuit' produced from a native
@use quantum.*@ source, it reproduces the quantum operation/measurement stream
directly over the in-process circuit graph, locates the single @\@quantum.realize@
collect node, collects the upstream quantum frontier, and translates that
domain-specific plan into Cortex's generic external-call payload for admission,
host-binding resolution, and the idempotency digest.

The realize node is the reshaped ADR 0059 collector: it consumes the symbolic
measurement @Bit@s produced by native @\@measure_z@ nodes and returns one
correlated @QuantumResult@. Measurement therefore lives in the @\@measure_z@
nodes, not the realize node; the walker carries the measurement records through to
'QuantumPlan' so the OpenQASM lowering and result decoder can key on them.
-}
module Cortex.Quantum.Plan
  ( -- * Plan types
    Measurement (..)
  , PlanOp (..)
  , QuantumPlan (..)

    -- * Walking a compiled circuit
  , WalkError (..)
  , renderWalkError
  , compiledCircuitToPlan
  , realizeNodeRef

    -- * Lowering the realize frontier
  , RealizeError (..)
  , renderRealizeError
  , RealizeLowering (..)
  , planExternalCallPayload
  , lowerCompiledRealize
  , quantumBraketAuthority
  )
where

import Control.Applicative ((<|>))
import Control.Monad (foldM, when)
import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific (toBoundedInteger)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T

import Cortex.Algebra.Graph (Relation, predecessors, relVertices)
import Cortex.Capability.BindingPack (HostBindingPack)
import Cortex.Capability.Catalog.AwaitStrategy (AwaitStrategy (..))
import Cortex.Pulse.Lowering.Circuit
  ( LoweredExternalCall
  , LoweringError (..)
  , lowerExternalCallFrontier
  )
import Cortex.Pulse.Lowering.ExternalCallPayload
  ( ExternalCallOutput (..)
  , ExternalCallStep (..)
  )
import Cortex.Pulse.Rewrite.Contract (CollectedNode (..))
import Cortex.Wire
  ( CircuitNodeRef (..)
  , CircuitTaskNode (..)
  , CompiledCircuit (..)
  , CompiledCircuitNode (..)
  )
import Cortex.Wire.Executor (WireExecutorId (..))
import Cortex.Wire.Syntax (CorePureExpr (..), CorePureField (..), CorePureLiteral (..))

{- | A terminal measurement: the qubit wire, its classical-bit slot, and the
output port label the measuring @\@measure_z@ node produces.
-}
data Measurement = Measurement
  { measurementNode :: !Text
  , measurementWire :: !Int
  , measurementClassicalBit :: !Int
  , measurementOutput :: !Text
  }
  deriving stock (Eq, Show)

-- | One planned quantum operation, in topological order.
data PlanOp
  = -- | @\@prepare_zero@: mints a fresh qubit wire from @config.index@.
    OpPrepareZero !Text !Int !Text
  | -- | A single-qubit, parameterless gate (@h@, @sx@, @x@) on one wire.
    OpGate1 !Text !Text !Int
  | -- | @\@rz@: a Z-rotation by a radian angle on one wire.
    OpRz !Text !Int !Double
  | -- | A two-qubit, parameterless gate (@cnot@, @cz@) on (control, target).
    OpGate2 !Text !Text !Int !Int
  | -- | A terminal @\@measure_z@ on one wire.
    OpMeasureZ !Measurement
  deriving stock (Eq, Show)

{- | The backend-neutral quantum plan: operations in topological order plus the
measurement records, with the touched wire set.
-}
data QuantumPlan = QuantumPlan
  { quantumPlanTopoOrder :: ![Text]
  , quantumPlanNumQubits :: !Int
  , quantumPlanQubits :: ![Int]
  , quantumPlanOps :: ![PlanOp]
  , quantumPlanMeasurements :: ![Measurement]
  }
  deriving stock (Eq, Show)

-- | Walker failures, mirroring the structural guards of the Python bridge.
data WalkError
  = WalkNotTaskNode !Text
  | WalkMissingExecutor !Text
  | WalkUnsupportedExecutor !Text !Text
  | WalkConfigError !Text !Text
  | WalkInputArity !Text !Text !Int
  | WalkInputKind !Text !Text
  | WalkOutputArity !Text !Text
  | WalkDuplicateQubitIndex !Text !Int !Text
  | WalkDistinctQubits !Text
  | WalkQubitFanOut !Text !Text
  | WalkUnknownNode !Text
  | WalkCyclicTopology
  | WalkNoQubits
  | WalkNoRealizeNode
  | WalkMultipleRealizeNodes ![Text]
  deriving stock (Eq, Show)

renderWalkError :: WalkError -> Text
renderWalkError = \case
  WalkNotTaskNode n -> "node " <> n <> " is not a task node"
  WalkMissingExecutor n -> "node " <> n <> " is missing native executor metadata"
  WalkUnsupportedExecutor n t -> "node " <> n <> " uses unsupported quantum executor @" <> t
  WalkConfigError n msg -> "node " <> n <> ": " <> msg
  WalkInputArity n p got ->
    "node " <> n <> " input " <> p <> " expected one predecessor output, got " <> T.pack (show got)
  WalkInputKind n p -> "node " <> n <> " input " <> p <> " has the wrong value kind"
  WalkOutputArity n msg -> "node " <> n <> ": " <> msg
  WalkDuplicateQubitIndex n ix owner ->
    "node " <> n <> " reuses qubit index " <> T.pack (show ix) <> " already allocated by " <> owner
  WalkDistinctQubits n -> "node " <> n <> ": control and target must be distinct"
  WalkQubitFanOut src out ->
    "Qubit output "
      <> src
      <> "."
      <> out
      <> " fans out to more than one consumer; this runner requires linear qubit use"
  WalkUnknownNode n -> "topology references unknown node " <> n
  WalkCyclicTopology -> "compiled topology is cyclic"
  WalkNoQubits -> "quantum plan did not allocate any qubits"
  WalkNoRealizeNode -> "circuit declares no @quantum.realize collect node"
  WalkMultipleRealizeNodes ns -> "circuit declares more than one @quantum.realize node: " <> T.intercalate ", " ns

-- The leaf of a possibly-dotted name: @quantum.Qubit@ -> @Qubit@.
leafName :: Text -> Text
leafName = T.takeWhileEnd (/= '.')

-- | The symbolic value flowing along a Wire edge while the plan is built.
data ValueKind = KQubit | KBit | KConfig | KResult
  deriving stock (Eq, Show)

data QuantumValue = QuantumValue
  { qvKind :: !ValueKind
  , qvWire :: !(Maybe Int)
  , qvContract :: !Text -- contract leaf
  }
  deriving stock (Eq, Show)

data NodePorts = NodePorts
  { npInputs :: ![(Text, [Text])] -- (port name, accepted contract leaves)
  , npOutputs :: ![(Text, Text)] -- (port name, contract leaf)
  }
  deriving stock (Eq, Show)

data NodeInfo = NodeInfo
  { niTarget :: !Text
  , niPorts :: !NodePorts
  , niConfig :: !Value
  }
  deriving stock (Eq, Show)

-- Small JSON accessors over the task-node metadata @Value@.
objLookup :: Text -> Value -> Maybe Value
objLookup k (Object km) = KeyMap.lookup (Key.fromText k) km
objLookup _ _ = Nothing

asText :: Value -> Maybe Text
asText (String t) = Just t
asText _ = Nothing

asArray :: Value -> Maybe [Value]
asArray (Array a) = Just (toList a)
asArray _ = Nothing

decodeNodeInfo :: Text -> CircuitTaskNode -> Either WalkError NodeInfo
decodeNodeInfo nodeRef taskNode = do
  let md = circuitTaskNodeMetadata taskNode
  target <-
    maybe (Left (WalkMissingExecutor nodeRef)) Right $
      objLookup "executor" md >>= objLookup "target" >>= asText
  ports <- decodePorts nodeRef md
  -- Executor arguments are stored under the one-record ABI's `argument`
  -- metadata field. The compiler keeps the evaluated call value under
  -- `argument.value`; quantum options conventionally live beneath `cfg`.
  let rawArgument = objLookup "argument" md
      argumentValue = rawArgument >>= objLookup "value" >>= decodeCorePureValue
      argument = argumentValue <|> rawArgument <|> objLookup "config" md
      config =
        case argument of
          Just value -> maybe value id (objLookup "cfg" value)
          Nothing -> Object KeyMap.empty
  Right (NodeInfo target ports config)

decodeCorePureValue :: Value -> Maybe Value
decodeCorePureValue encoded =
  case Aeson.fromJSON encoded of
    Aeson.Success expression -> corePureJson expression
    Aeson.Error _ -> Nothing
  where
    corePureJson = \case
      CorePureLit literal ->
        Just $ case literal of
          CorePureString value -> String value
          CorePureNumber value -> Number value
          CorePureBool value -> Bool value
          CorePureNull -> Null
      CorePureList values -> Aeson.toJSON <$> traverse corePureJson values
      CorePureRecord fields ->
        Just (Object (foldl addField KeyMap.empty fields))
      _ -> Nothing

    addField object field =
      case corePureJson field.corePureFieldValue of
        Nothing -> object
        Just value -> mergeObject object (nestedObject (toList field.corePureFieldPath) value)

    nestedObject [name] value = KeyMap.singleton (Key.fromText name) value
    nestedObject (name : rest) value =
      KeyMap.singleton (Key.fromText name) (Object (nestedObject rest value))
    nestedObject [] value = KeyMap.singleton (Key.fromText "value") value

    mergeObject left right = KeyMap.unionWith mergeValues left right
    mergeValues (Object left) (Object right) = Object (mergeObject left right)
    mergeValues _ right = right

decodePorts :: Text -> Value -> Either WalkError NodePorts
decodePorts nodeRef md = do
  let portsValue = objLookup "ports" md
      rawInputs = portsValue >>= objLookup "inputs" >>= asArray
      rawOutputs = portsValue >>= objLookup "outputs" >>= asArray
  inputs <- traverse decodeInput (maybe [] id rawInputs)
  outputs <- traverse decodeOutput (maybe [] id rawOutputs)
  Right (NodePorts inputs outputs)
  where
    decodeInput v = do
      name <- portField "input port name" (objLookup "name" v >>= asText)
      accepts <- portField "input port accepts" (objLookup "accepts" v >>= asArray >>= traverse asText)
      Right (name, map leafName accepts)
    decodeOutput v = do
      name <- portField "output port name" (objLookup "name" v >>= asText)
      contract <- portField "output port contract" (objLookup "contract" v >>= asText)
      Right (name, leafName contract)
    portField :: Text -> Maybe a -> Either WalkError a
    portField msg = maybe (Left (WalkConfigError nodeRef ("malformed " <> msg))) Right

-- | Decode every task node of the circuit, keyed by node ref.
circuitNodeInfos :: CompiledCircuit -> Either WalkError (Map Text NodeInfo)
circuitNodeInfos circuit =
  fmap Map.fromList . traverse decode . Map.toList $ compiledCircuitNodes circuit
  where
    decode (ref, node) =
      let nodeRef = unCircuitNodeRef ref
       in case node of
            CompiledCircuitTask taskNode -> (,) nodeRef <$> decodeNodeInfo nodeRef taskNode
            CompiledCircuitSignal {} -> Left (WalkNotTaskNode nodeRef)
            CompiledCircuitArtifact {} -> Left (WalkNotTaskNode nodeRef)
            CompiledCircuitRewriteBoundary {} -> Left (WalkNotTaskNode nodeRef)
            CompiledCircuitCondition {} -> Left (WalkNotTaskNode nodeRef)

-- | The lexicographic-min Kahn topological order (deterministic gate order).
topologicalOrder :: Relation CircuitNodeRef -> Either WalkError [Text]
topologicalOrder topo = go initialReady initialIndegree []
  where
    vertices = map unCircuitNodeRef (Set.toList (relVertices topo))
    predsOf n = map unCircuitNodeRef (Set.toList (predecessors topo (CircuitNodeRef n)))
    succMap :: Map Text [Text]
    succMap =
      Map.fromListWith (++) [(p, [n]) | n <- vertices, p <- predsOf n]
    initialIndegree :: Map Text Int
    initialIndegree = Map.fromList [(n, length (predsOf n)) | n <- vertices]
    initialReady :: Set Text
    initialReady = Set.fromList [n | n <- vertices, Map.findWithDefault 0 n initialIndegree == 0]
    go ready indegree acc =
      case Set.minView ready of
        Nothing
          | length acc == length vertices -> Right (reverse acc)
          | otherwise -> Left WalkCyclicTopology
        Just (n, restReady) ->
          let succs = Map.findWithDefault [] n succMap
              (indegree', newlyReady) = foldr relax (indegree, []) succs
              relax s (im, rs) =
                let d = Map.findWithDefault 0 s im - 1
                    im' = Map.insert s d im
                 in (im', if d == 0 then s : rs else rs)
           in go (foldr Set.insert restReady newlyReady) indegree' (n : acc)

-- The per-input edges of the topology, as (producer, consumer) pairs.
topologyEdges :: Relation CircuitNodeRef -> [(Text, Text)]
topologyEdges topo =
  [ (unCircuitNodeRef p, n)
  | n <- map unCircuitNodeRef (Set.toList (relVertices topo))
  , p <- Set.toList (predecessors topo (CircuitNodeRef n))
  ]

{- | Reject any @Qubit@ output consumed by more than one downstream input
(structural no-cloning), mirroring @validate_qubit_linearity@.
-}
validateQubitLinearity :: Map Text NodeInfo -> [(Text, Text)] -> Either WalkError ()
validateQubitLinearity infos edges =
  case [(src, out) | ((src, out), n) <- Map.toList consumerCount, n > (1 :: Int)] of
    [] -> Right ()
    ((src, out) : _) -> Left (WalkQubitFanOut src out)
  where
    consumerCount =
      Map.fromListWith (+) $
        [ ((src, out), 1)
        | (src, dst) <- edges
        , Just srcInfo <- [Map.lookup src infos]
        , Just dstInfo <- [Map.lookup dst infos]
        , (out, contract) <- npOutputs (niPorts srcInfo)
        , contract == "Qubit"
        , (inName, accepts) <- npInputs (niPorts dstInfo)
        , inName == out
        , "Qubit" `elem` accepts
        ]

-- Walk accumulator state.
data WalkState = WalkState
  { wsOutputs :: !(Map Text (Map Text QuantumValue))
  , wsOps :: ![PlanOp] -- reversed
  , wsMeasures :: ![Measurement] -- reversed
  , wsMeasureCount :: !Int
  , wsWires :: !(Set Int)
  , wsAllocated :: !(Map Int Text)
  }

emptyWalkState :: WalkState
emptyWalkState = WalkState Map.empty [] [] 0 Set.empty Map.empty

-- | Walk a compiled circuit into the backend-neutral quantum plan.
compiledCircuitToPlan :: CompiledCircuit -> Either WalkError QuantumPlan
compiledCircuitToPlan circuit = do
  infos <- circuitNodeInfos circuit
  order <- topologicalOrder (compiledCircuitTopology circuit)
  let edges = topologyEdges (compiledCircuitTopology circuit)
      refs = Set.fromList order
  compiledCircuitToPlanForRefs infos order edges refs

compiledCircuitToRealizedPlan :: Text -> CompiledCircuit -> Either WalkError QuantumPlan
compiledCircuitToRealizedPlan realizeRef circuit = do
  infos <- circuitNodeInfos circuit
  order <- topologicalOrder (compiledCircuitTopology circuit)
  let edges = topologyEdges (compiledCircuitTopology circuit)
      predsMap = Map.fromListWith (++) [(dst, [src]) | (src, dst) <- edges]
  refs <- realizedDataRefs infos predsMap realizeRef
  compiledCircuitToPlanForRefs infos order edges refs

compiledCircuitToPlanForRefs
  :: Map Text NodeInfo
  -> [Text]
  -> [(Text, Text)]
  -> Set Text
  -> Either WalkError QuantumPlan
compiledCircuitToPlanForRefs infos order edges refs = do
  let selectedOrder = filter (`Set.member` refs) order
      selectedEdges = [(src, dst) | (src, dst) <- edges, src `Set.member` refs, dst `Set.member` refs]
      predsMap = Map.fromListWith (++) [(dst, [src]) | (src, dst) <- selectedEdges]
  validateQubitLinearity infos selectedEdges
  final <- foldM (stepNode infos predsMap) emptyWalkState selectedOrder
  when (Set.null (wsWires final)) (Left WalkNoQubits)
  let wires = Set.toAscList (wsWires final)
  Right
    QuantumPlan
      { quantumPlanTopoOrder = selectedOrder
      , quantumPlanNumQubits = maximum wires + 1
      , quantumPlanQubits = wires
      , quantumPlanOps = reverse (wsOps final)
      , quantumPlanMeasurements = reverse (wsMeasures final)
      }

realizedDataRefs :: Map Text NodeInfo -> Map Text [Text] -> Text -> Either WalkError (Set Text)
realizedDataRefs infos predsMap realizeRef =
  Set.delete realizeRef <$> go Set.empty [realizeRef]
  where
    go seen [] = Right seen
    go seen (nodeRef : rest)
      | nodeRef `Set.member` seen = go seen rest
      | otherwise = do
          producers <- inputProducerRefs infos predsMap nodeRef
          go (Set.insert nodeRef seen) (producers <> rest)

inputProducerRefs :: Map Text NodeInfo -> Map Text [Text] -> Text -> Either WalkError [Text]
inputProducerRefs infos predsMap nodeRef = do
  info <- maybe (Left (WalkUnknownNode nodeRef)) Right (Map.lookup nodeRef infos)
  fmap concat (traverse resolvePort (npInputs (niPorts info)))
  where
    preds = Map.findWithDefault [] nodeRef predsMap
    resolvePort (name, accepts) =
      case [ p
           | p <- preds
           , Just srcInfo <- [Map.lookup p infos]
           , (out, contract) <- npOutputs (niPorts srcInfo)
           , out == name
           , contract `elem` accepts
           ] of
        [producer] -> Right [producer]
        found -> Left (WalkInputArity nodeRef name (length found))

stepNode :: Map Text NodeInfo -> Map Text [Text] -> WalkState -> Text -> Either WalkError WalkState
stepNode infos predsMap st nodeRef = do
  info <- maybe (Left (WalkUnknownNode nodeRef)) Right (Map.lookup nodeRef infos)
  let preds = Map.findWithDefault [] nodeRef predsMap
      outs = npOutputs (niPorts info)
      config = niConfig info
  inputs <- resolveInputs nodeRef info preds (wsOutputs st)
  case niTarget info of
    "quantum.prepare_zero" -> do
      allowOnlyConfigInputs nodeRef inputs
      out <- singleOutput nodeRef outs "Qubit"
      wire <- intConfig nodeRef config "index"
      st' <- allocateQubit nodeRef wire st
      let value = QuantumValue KQubit (Just wire) "Qubit"
      Right $
        bindOutputs nodeRef [(out, value)] $
          addWire wire $
            emitOp (OpPrepareZero nodeRef wire out) st'
    target
      | target `elem` ["quantum.h", "quantum.sx", "quantum.x"] -> do
          value <- singleQubitInput nodeRef inputs
          out <- singleOutput nodeRef outs "Qubit"
          wire <- requireWire nodeRef value
          Right $
            bindOutputs nodeRef [(out, reExport value)] $
              addWire wire $
                emitOp (OpGate1 nodeRef (leafName target) wire) st
    "quantum.rz" -> do
      value <- singleQubitInput nodeRef inputs
      out <- singleOutput nodeRef outs "Qubit"
      wire <- requireWire nodeRef value
      angle <- numberConfig nodeRef config "angle"
      Right $
        bindOutputs nodeRef [(out, reExport value)] $
          addWire wire $
            emitOp (OpRz nodeRef wire angle) st
    target
      | target `elem` ["quantum.cnot", "quantum.cz"] -> do
          control <- namedQubitInput nodeRef inputs "control"
          target' <- namedQubitInput nodeRef inputs "target"
          requireOutputNames nodeRef outs ["control", "target"] "Qubit"
          controlWire <- requireWire nodeRef control
          targetWire <- requireWire nodeRef target'
          when (controlWire == targetWire) (Left (WalkDistinctQubits nodeRef))
          let controlValue = QuantumValue KQubit (Just controlWire) "Qubit"
              targetValue = QuantumValue KQubit (Just targetWire) "Qubit"
          Right $
            bindOutputs nodeRef [("control", controlValue), ("target", targetValue)] $
              addWire controlWire $
                addWire targetWire $
                  emitOp (OpGate2 nodeRef (leafName target) controlWire targetWire) st
    "quantum.measure_z" -> do
      value <- singleQubitInput nodeRef inputs
      out <- singleOutput nodeRef outs "Bit"
      wire <- requireWire nodeRef value
      let classicalBit = wsMeasureCount st
          measurement = Measurement nodeRef wire classicalBit out
          bitValue = QuantumValue KBit Nothing "Bit"
      Right $
        bindOutputs nodeRef [(out, bitValue)] $
          appendMeasure measurement $
            emitOp (OpMeasureZ measurement) st
    "quantum.realize" -> do
      out <- singleOutput nodeRef outs "QuantumResult"
      requireBitInputs nodeRef inputs
      let resultValue = QuantumValue KResult Nothing "QuantumResult"
      Right (bindOutputs nodeRef [(out, resultValue)] st)
    other -> Left (WalkUnsupportedExecutor nodeRef other)

-- State helpers.

emitOp :: PlanOp -> WalkState -> WalkState
emitOp op st = st {wsOps = op : wsOps st}

appendMeasure :: Measurement -> WalkState -> WalkState
appendMeasure m st = st {wsMeasures = m : wsMeasures st, wsMeasureCount = wsMeasureCount st + 1}

addWire :: Int -> WalkState -> WalkState
addWire wire st = st {wsWires = Set.insert wire (wsWires st)}

bindOutputs :: Text -> [(Text, QuantumValue)] -> WalkState -> WalkState
bindOutputs nodeRef binds st =
  st {wsOutputs = Map.insert nodeRef (Map.fromList binds) (wsOutputs st)}

allocateQubit :: Text -> Int -> WalkState -> Either WalkError WalkState
allocateQubit nodeRef wire st =
  case Map.lookup wire (wsAllocated st) of
    Just owner -> Left (WalkDuplicateQubitIndex nodeRef wire owner)
    Nothing -> Right st {wsAllocated = Map.insert wire nodeRef (wsAllocated st)}

reExport :: QuantumValue -> QuantumValue
reExport = id

-- Input/output validation helpers.

resolveInputs
  :: Text
  -> NodeInfo
  -> [Text]
  -> Map Text (Map Text QuantumValue)
  -> Either WalkError (Map Text QuantumValue)
resolveInputs nodeRef info preds outputs =
  Map.fromList <$> traverse resolvePort (npInputs (niPorts info))
  where
    resolvePort (name, accepts) =
      case [ value
           | p <- preds
           , Just portMap <- [Map.lookup p outputs]
           , Just value <- [Map.lookup name portMap]
           , qvContract value `elem` accepts
           ] of
        [value] -> Right (name, value)
        found -> Left (WalkInputArity nodeRef name (length found))

allowOnlyConfigInputs :: Text -> Map Text QuantumValue -> Either WalkError ()
allowOnlyConfigInputs nodeRef inputs =
  mapM_ check (Map.toList inputs)
  where
    check (name, value)
      | qvKind value == KConfig = Right ()
      | otherwise = Left (WalkInputKind nodeRef name)

requireBitInputs :: Text -> Map Text QuantumValue -> Either WalkError ()
requireBitInputs nodeRef inputs
  | Map.null inputs = Left (WalkOutputArity nodeRef "@quantum.realize collects no measurement bits")
  | otherwise = mapM_ check (Map.toList inputs)
  where
    check (name, value)
      | qvKind value == KBit = Right ()
      | otherwise = Left (WalkInputKind nodeRef name)

singleQubitInput :: Text -> Map Text QuantumValue -> Either WalkError QuantumValue
singleQubitInput nodeRef inputs =
  case Map.toList inputs of
    [(name, value)]
      | qvKind value == KQubit -> Right value
      | otherwise -> Left (WalkInputKind nodeRef name)
    _ -> Left (WalkInputArity nodeRef "(single qubit)" (Map.size inputs))

namedQubitInput :: Text -> Map Text QuantumValue -> Text -> Either WalkError QuantumValue
namedQubitInput nodeRef inputs name =
  case Map.lookup name inputs of
    Just value
      | qvKind value == KQubit -> Right value
      | otherwise -> Left (WalkInputKind nodeRef name)
    Nothing -> Left (WalkInputArity nodeRef name 0)

singleOutput :: Text -> [(Text, Text)] -> Text -> Either WalkError Text
singleOutput nodeRef outs contract =
  case [name | (name, c) <- outs, c == contract] of
    [name] -> Right name
    _ -> Left (WalkOutputArity nodeRef ("expected exactly one " <> contract <> " output"))

requireOutputNames :: Text -> [(Text, Text)] -> [Text] -> Text -> Either WalkError ()
requireOutputNames nodeRef outs names contract =
  mapM_ require names
  where
    require name
      | (name, contract) `elem` outs = Right ()
      | otherwise = Left (WalkOutputArity nodeRef ("missing " <> contract <> " output " <> name))

requireWire :: Text -> QuantumValue -> Either WalkError Int
requireWire nodeRef value =
  maybe (Left (WalkInputKind nodeRef "(expected a qubit wire)")) Right (qvWire value)

intConfig :: Text -> Value -> Text -> Either WalkError Int
intConfig nodeRef config key =
  case objLookup key config of
    Just (Number n) ->
      case integral of
        Just value
          | value < 0 ->
              Left (WalkConfigError nodeRef ("config field " <> key <> " must be a non-negative integer"))
          | otherwise -> Right value
        Nothing -> Left (WalkConfigError nodeRef ("config field " <> key <> " must be an integer"))
      where
        integral :: Maybe Int
        integral = toBoundedInteger n
    _ -> Left (WalkConfigError nodeRef ("config field " <> key <> " must be an integer"))

numberConfig :: Text -> Value -> Text -> Either WalkError Double
numberConfig nodeRef config key =
  case objLookup key config of
    Just (Number n) -> Right (realToFrac n)
    _ -> Left (WalkConfigError nodeRef ("config field " <> key <> " must be a number"))

-- | The single @\@quantum.realize@ node ref, or a typed walker error.
realizeNodeRef :: CompiledCircuit -> Either WalkError Text
realizeNodeRef circuit = do
  infos <- circuitNodeInfos circuit
  case sort [ref | (ref, info) <- Map.toList infos, niTarget info == "quantum.realize"] of
    [single] -> Right single
    [] -> Left WalkNoRealizeNode
    many -> Left (WalkMultipleRealizeNodes many)

{- | Translate the quantum operation/measurement lists into Cortex's generic
external-call payload shape.
-}
planExternalCallPayload :: QuantumPlan -> ([ExternalCallStep], [ExternalCallOutput])
planExternalCallPayload plan =
  ( map payloadStep (quantumPlanOps plan)
  , [ ExternalCallOutput
        { ecoSource = Just (wireOperand (measurementWire m))
        , ecoLabel = measurementOutput m
        }
    | m <- quantumPlanMeasurements plan
    ]
  )
  where
    payloadStep = \case
      OpPrepareZero _ wire _ -> ExternalCallStep "prepare_zero" [wireOperand wire] []
      OpGate1 _ gate wire -> ExternalCallStep gate [wireOperand wire] []
      OpRz _ wire angle -> ExternalCallStep "rz" [wireOperand wire] [("angle", Number (realToFrac angle))]
      OpGate2 _ gate control target -> ExternalCallStep gate [wireOperand control, wireOperand target] []
      OpMeasureZ m -> ExternalCallStep "measure_z" [wireOperand (measurementWire m)] []

wireOperand :: Int -> Text
wireOperand wire = "wire:" <> T.pack (show wire)

{- | The uniform external-call authority assigned to every collected quantum
node so the frontier admits as a single same-authority contraction.
-}
quantumBraketAuthority :: WireExecutorId
quantumBraketAuthority = WireExecutorId "quantum.braket"

-- | Failure of the compiled-circuit realize lowering.
data RealizeError
  = RealizeWalk !WalkError
  | RealizeLower !LoweringError
  deriving stock (Eq, Show)

renderRealizeError :: RealizeError -> Text
renderRealizeError = \case
  RealizeWalk err -> renderWalkError err
  RealizeLower (LoweringInadmissibleFrontier err) ->
    "inadmissible realize frontier: " <> T.pack (show err)
  RealizeLower (LoweringMissingRuntimeBinding (WireExecutorId executorId)) ->
    "missing host runtime binding for executor " <> executorId

-- | The full lowering of a compiled circuit's realize frontier.
data RealizeLowering = RealizeLowering
  { realizePlan :: !QuantumPlan
  , realizeNode :: !Text
  , realizeLowered :: !LoweredExternalCall
  }
  deriving stock (Eq, Show)

{- | Lower a compiled circuit's @\@quantum.realize@ frontier: walk the plan, find
the single realize node, collect the upstream quantum frontier under one
authority/await classification, and drive 'lowerExternalCallFrontier' for admission,
host-binding resolution, and the idempotency digest.
-}
lowerCompiledRealize
  :: HostBindingPack
  -> WireExecutorId
  -> CompiledCircuit
  -> Either RealizeError RealizeLowering
lowerCompiledRealize pack realizeId circuit = do
  realizeRef <- mapLeft RealizeWalk (realizeNodeRef circuit)
  plan <- mapLeft RealizeWalk (compiledCircuitToRealizedPlan realizeRef circuit)
  let collected = map collectedNode (quantumPlanTopoOrder plan)
      (steps, outputs) = planExternalCallPayload plan
  lowered <- mapLeft RealizeLower (lowerExternalCallFrontier pack realizeId collected steps outputs)
  Right (RealizeLowering plan realizeRef lowered)
  where
    collectedNode ref = CollectedNode ref (Just (quantumBraketAuthority, SubmitParkResume))

mapLeft :: (e -> e') -> Either e a -> Either e' a
mapLeft f = either (Left . f) Right
