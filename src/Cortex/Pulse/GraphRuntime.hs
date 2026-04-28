module Cortex.Pulse.GraphRuntime
  ( InterruptReason (..)
  , NodeStatus (..)
  , GraphState (..)
  , initialGraphState
  , readyNodes
  , allSettled
  , hasFailedNodes
  , hasWaitingNodes
  , isTerminal
  , TransitionError (..)
  , transitionRunning
  , transitionCompleted
  , transitionFailed
  , transitionSkipped
  , transitionWaiting
  , transitionRewritten
  , resumeFromWaiting
  , markRunning
  , markCompleted
  , markFailed
  , markSkipped
  , markWaiting
  , normalizeForResume
  , StepResult (..)
  , StuckDiagnostic (..)
  , classifyGraphState
  , propagateFailure
  , BlockedReason (..)
  , blockedReasons
  , isLinearTopology
  , runTerminal
  , runOutcomeToNodeOutcome
  , NodeOutcome (..)
  , FailureDetail (..)
  , NodeResult (..)
  , applyNodeFact
  , reduceFacts
  , isForwardOutcome
  , isResetOutcome
  , finalizeGraphStep
  , applyFrontierResults
  , stepResultState
  , stepResultToOutcome
  , simulateRun
  , WorkerOracle
  , nodeInputs
  , nodeInputsWithDefault
  , NodeInputError (..)
  , nodeInputsChecked
  )
where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Either (lefts)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.Generics (Generic)

import Cortex.Algebra.Graph
  ( Relation (..)
  , predecessors
  , successors
  )
import Cortex.Pulse.Node (NodeId (..))

import Platform.DurableTask.Types (RunOutcome (..))

data NodeStatus
  = NodePending
  | NodeRunning
  | NodeCompleted
  | NodeFailed
  | NodeSkipped
  | NodeInterrupted !InterruptReason
  | NodeRewritten
  | NodeWaiting !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data InterruptReason
  = InterruptedSiblingCancelled
  | InterruptedShutdown
  | InterruptedRunCancelled
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data GraphState o = GraphState
  { gsNodeStatuses :: !(Map NodeId NodeStatus)
  , gsNodeOutputs :: !(Map NodeId o)
  }
  deriving stock (Eq, Show, Generic, Functor)
  deriving anyclass (FromJSON, ToJSON)

initialGraphState :: Relation NodeId -> GraphState o
initialGraphState rel =
  GraphState
    { gsNodeStatuses = Map.fromSet (const NodePending) (relVertices rel)
    , gsNodeOutputs = Map.empty
    }

readyNodes :: Relation NodeId -> GraphState o -> [NodeId]
readyNodes rel state =
  [ v
  | v <- Set.toList (relVertices rel)
  , Map.lookup v (gsNodeStatuses state) == Just NodePending
  , all (isCompletedOrSkipped state) (Set.toList (predecessors rel v))
  ]

allSettled :: Relation NodeId -> GraphState o -> Bool
allSettled rel state =
  all
    (\v -> isTerminalStatus (Map.findWithDefault NodePending v (gsNodeStatuses state)))
    (Set.toList (relVertices rel))

hasFailedNodes :: Relation NodeId -> GraphState o -> Bool
hasFailedNodes rel state =
  any
    (\v -> Map.lookup v (gsNodeStatuses state) == Just NodeFailed)
    (Set.toList (relVertices rel))

hasWaitingNodes :: GraphState o -> Bool
hasWaitingNodes state = any isWaiting (Map.elems (gsNodeStatuses state))
  where
    isWaiting (NodeWaiting _) = True
    isWaiting _ = False

isTerminal :: NodeStatus -> Bool
isTerminal = isTerminalStatus

data TransitionError
  = IllegalTransition NodeId NodeStatus NodeStatus
  | UnknownNode NodeId
  deriving stock (Eq, Show)

transitionRunning :: NodeId -> GraphState o -> Either TransitionError (GraphState o)
transitionRunning = checkedTransition NodeRunning (\case NodePending -> True; _ -> False)

transitionCompleted :: NodeId -> o -> GraphState o -> Either TransitionError (GraphState o)
transitionCompleted nid output gs =
  case checkedTransition NodeCompleted (\case NodeRunning -> True; _ -> False) nid gs of
    Left err -> Left err
    Right gs' -> Right gs' {gsNodeOutputs = Map.insert nid output (gsNodeOutputs gs')}

transitionFailed :: NodeId -> GraphState o -> Either TransitionError (GraphState o)
transitionFailed = checkedTransition NodeFailed $ \case
  NodePending -> True
  NodeRunning -> True
  NodeWaiting _ -> True
  _ -> False

transitionSkipped :: NodeId -> GraphState o -> Either TransitionError (GraphState o)
transitionSkipped = checkedTransition NodeSkipped $ \case
  NodePending -> True
  NodeRunning -> True
  NodeWaiting _ -> True
  _ -> False

transitionWaiting :: NodeId -> Text -> GraphState o -> Either TransitionError (GraphState o)
transitionWaiting nid signalName gs =
  case Map.lookup nid (gsNodeStatuses gs) of
    Nothing -> Left (UnknownNode nid)
    Just NodeRunning -> Right gs {gsNodeStatuses = Map.insert nid (NodeWaiting signalName) (gsNodeStatuses gs)}
    Just current -> Left (IllegalTransition nid current (NodeWaiting signalName))

resumeFromWaiting :: NodeId -> GraphState o -> Either TransitionError (GraphState o)
resumeFromWaiting = checkedTransition NodePending (\case NodeWaiting _ -> True; _ -> False)

transitionRewritten :: NodeId -> GraphState o -> Either TransitionError (GraphState o)
transitionRewritten = checkedTransition NodeRewritten (\case NodeRunning -> True; _ -> False)

checkedTransition
  :: NodeStatus
  -> (NodeStatus -> Bool)
  -> NodeId
  -> GraphState o
  -> Either TransitionError (GraphState o)
checkedTransition target allowed nid gs =
  case Map.lookup nid (gsNodeStatuses gs) of
    Nothing -> Left (UnknownNode nid)
    Just current
      | allowed current -> Right gs {gsNodeStatuses = Map.insert nid target (gsNodeStatuses gs)}
      | otherwise -> Left (IllegalTransition nid current target)

markRunning :: NodeId -> GraphState o -> GraphState o
markRunning nid gs = gs {gsNodeStatuses = Map.insert nid NodeRunning (gsNodeStatuses gs)}

markCompleted :: NodeId -> o -> GraphState o -> GraphState o
markCompleted nid output gs =
  gs
    { gsNodeStatuses = Map.insert nid NodeCompleted (gsNodeStatuses gs)
    , gsNodeOutputs = Map.insert nid output (gsNodeOutputs gs)
    }

markSkipped :: NodeId -> GraphState o -> GraphState o
markSkipped nid gs = gs {gsNodeStatuses = Map.insert nid NodeSkipped (gsNodeStatuses gs)}

markFailed :: NodeId -> GraphState o -> GraphState o
markFailed nid gs = gs {gsNodeStatuses = Map.insert nid NodeFailed (gsNodeStatuses gs)}

markWaiting :: NodeId -> Text -> GraphState o -> GraphState o
markWaiting nid signalName gs =
  gs {gsNodeStatuses = Map.insert nid (NodeWaiting signalName) (gsNodeStatuses gs)}

normalizeForResume :: GraphState o -> GraphState o
normalizeForResume gs =
  gs {gsNodeStatuses = Map.map resetOne (gsNodeStatuses gs)}
  where
    resetOne NodeRunning = NodePending
    resetOne (NodeInterrupted _) = NodePending
    resetOne NodePending = NodePending
    resetOne NodeCompleted = NodeCompleted
    resetOne NodeFailed = NodeFailed
    resetOne NodeSkipped = NodeSkipped
    resetOne NodeRewritten = NodeRewritten
    resetOne (NodeWaiting s) = NodeWaiting s

data NodeInputError
  = MissingOutput NodeId
  deriving stock (Eq, Show)

nodeInputsChecked
  :: Relation NodeId -> GraphState o -> NodeId -> Either [NodeInputError] (Map NodeId o)
nodeInputsChecked rel state nid =
  let deps = Set.toList (predecessors rel nid)
      results =
        [ case (Map.lookup depId (gsNodeStatuses state), Map.lookup depId (gsNodeOutputs state)) of
            (Just NodeCompleted, Just output) -> Right (Just (depId, output))
            (Just NodeCompleted, Nothing) -> Left (MissingOutput depId)
            (Just NodeSkipped, _) -> Right Nothing
            _ -> Right Nothing
        | depId <- deps
        ]
      errs = lefts results
      oks = [pair | Right (Just pair) <- results]
   in if null errs
        then Right (Map.fromList oks)
        else Left errs

nodeInputs :: Relation NodeId -> GraphState o -> NodeId -> Map NodeId o
nodeInputs rel state nid =
  Map.fromList
    [ (depId, output)
    | depId <- Set.toList (predecessors rel nid)
    , Just output <- [Map.lookup depId (gsNodeOutputs state)]
    ]

nodeInputsWithDefault :: Relation NodeId -> GraphState Value -> Value -> NodeId -> Map NodeId Value
nodeInputsWithDefault rel gs defaultValue nid =
  let inputs = nodeInputs rel gs nid
      isRoot = Set.null (predecessors rel nid)
   in if isRoot && Map.null inputs
        then Map.singleton (NodeId "__initial__") defaultValue
        else inputs

data NodeOutcome
  = OutcomeSucceeded Value
  | OutcomeSkipped
  | OutcomeSuspendedOn Text
  | OutcomeNodeFailed FailureDetail
  | OutcomeNodeTimedOut
  | OutcomeNodeCancelled
  | OutcomeNodeShutdown
  | OutcomeNodeRunCancelled
  | OutcomeRewritten Value Value
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data FailureDetail = FailureDetail
  { fdErrorType :: !Text
  , fdErrorMessage :: !Text
  , fdRetryable :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data NodeResult = NodeResult
  { nrNodeId :: !NodeId
  , nrOutcome :: !NodeOutcome
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

applyNodeFact :: NodeResult -> GraphState Value -> GraphState Value
applyNodeFact (NodeResult nid outcome) gs = case outcome of
  OutcomeSucceeded output ->
    gs
      { gsNodeStatuses = Map.insert nid NodeCompleted (gsNodeStatuses gs)
      , gsNodeOutputs = Map.insert nid output (gsNodeOutputs gs)
      }
  OutcomeSkipped -> gs {gsNodeStatuses = Map.insert nid NodeSkipped (gsNodeStatuses gs)}
  OutcomeSuspendedOn sigName ->
    gs {gsNodeStatuses = Map.insert nid (NodeWaiting sigName) (gsNodeStatuses gs)}
  OutcomeRewritten output _ ->
    gs
      { gsNodeStatuses = Map.insert nid NodeRewritten (gsNodeStatuses gs)
      , gsNodeOutputs = Map.insert nid output (gsNodeOutputs gs)
      }
  OutcomeNodeFailed _ -> gs {gsNodeStatuses = Map.insert nid NodeFailed (gsNodeStatuses gs)}
  OutcomeNodeTimedOut -> gs {gsNodeStatuses = Map.insert nid NodeFailed (gsNodeStatuses gs)}
  OutcomeNodeCancelled ->
    gs
      { gsNodeStatuses = Map.insert nid (NodeInterrupted InterruptedSiblingCancelled) (gsNodeStatuses gs)
      }
  OutcomeNodeShutdown ->
    gs {gsNodeStatuses = Map.insert nid (NodeInterrupted InterruptedShutdown) (gsNodeStatuses gs)}
  OutcomeNodeRunCancelled ->
    gs {gsNodeStatuses = Map.insert nid (NodeInterrupted InterruptedRunCancelled) (gsNodeStatuses gs)}

{- | Propagate failure to all pending/waiting descendants of failed nodes.

Uses a single BFS from all failed roots, visiting each vertex at most
once.  This avoids redundant 'reachable' calls that would each traverse
O(|V| + |E|).
-}
propagateFailure :: Relation NodeId -> GraphState o -> GraphState o
propagateFailure rel gs0 =
  let seeds =
        [ nid
        | (nid, NodeFailed) <- Map.toList (gsNodeStatuses gs0)
        ]
   in bfsPropagate (Set.fromList seeds) seeds gs0
  where
    bfsPropagate _ [] gs = gs
    bfsPropagate !visited (nid : queue) gs =
      let children = Set.toList (successors rel nid)
          (visited', queue', gs') = foldl' step (visited, queue, gs) children
       in bfsPropagate visited' queue' gs'

    -- Always enqueue children for traversal (to reach deeper descendants),
    -- but only mark propagatable nodes as failed.
    step (!vis, q, gs) child
      | Set.member child vis = (vis, q, gs)
      | otherwise =
          let vis' = Set.insert child vis
              q' = child : q
              gs' =
                if isPropagatableStatus gs child
                  then gs {gsNodeStatuses = Map.insert child NodeFailed (gsNodeStatuses gs)}
                  else gs
           in (vis', q', gs')

isPropagatableStatus :: GraphState o -> NodeId -> Bool
isPropagatableStatus gs nid =
  case Map.lookup nid (gsNodeStatuses gs) of
    Just NodePending -> True
    Just (NodeWaiting _) -> True
    _ -> False

data StepResult
  = Progressing (GraphState Value) [NodeId]
  | Settled (GraphState Value) RunOutcome
  | Suspended (GraphState Value)
  | Stuck (GraphState Value) StuckDiagnostic
  deriving stock (Eq, Show)

stepResultState :: StepResult -> GraphState Value
stepResultState (Progressing gs _) = gs
stepResultState (Settled gs _) = gs
stepResultState (Suspended gs) = gs
stepResultState (Stuck gs _) = gs

stepResultToOutcome :: StepResult -> Maybe RunOutcome
stepResultToOutcome (Settled _ outcome) = Just outcome
stepResultToOutcome (Suspended _) = Just OutcomeSuspended
stepResultToOutcome (Progressing _ _) = Nothing
stepResultToOutcome (Stuck _ _) = Nothing

data StuckDiagnostic = StuckDiagnostic
  { sdPendingNodes :: ![NodeId]
  , sdFailedNodes :: ![NodeId]
  , sdStuckOnFailed :: ![(NodeId, [NodeId])]
  }
  deriving stock (Eq, Show)

classifyGraphState :: Relation NodeId -> GraphState Value -> StepResult
classifyGraphState rel gs0 =
  let gs = propagateFailure rel gs0
   in if hasFailedNodes rel gs
        then Settled gs OutcomeFailed
        else
          let frontier = readyNodes rel gs
           in case frontier of
                (_ : _) -> Progressing gs frontier
                [] ->
                  if allSettled rel gs
                    then Settled gs OutcomeCompleted
                    else
                      if hasWaitingNodes gs
                        then Suspended gs
                        else
                          let pendingNodes =
                                [ nid
                                | nid <- Set.toList (relVertices rel)
                                , Map.lookup nid (gsNodeStatuses gs) == Just NodePending
                                ]
                              failedNodes =
                                [ nid
                                | nid <- Set.toList (relVertices rel)
                                , Map.lookup nid (gsNodeStatuses gs) == Just NodeFailed
                                ]
                              stuckOnFailed =
                                [ (nid, failedPreds)
                                | nid <- pendingNodes
                                , let failedPreds =
                                        [ p
                                        | p <- Set.toList (predecessors rel nid)
                                        , Map.lookup p (gsNodeStatuses gs) == Just NodeFailed
                                        ]
                                , not (null failedPreds)
                                ]
                           in Stuck gs (StuckDiagnostic pendingNodes failedNodes stuckOnFailed)

data BlockedReason
  = BlockedByFailed [NodeId]
  | BlockedByPending [NodeId]
  | BlockedUnknown
  deriving stock (Eq, Show)

blockedReasons :: Relation NodeId -> GraphState o -> [(NodeId, BlockedReason)]
blockedReasons rel gs =
  [ (nid, blockedReason nid)
  | nid <- Set.toList (relVertices rel)
  , Map.lookup nid (gsNodeStatuses gs) == Just NodePending
  , not (Set.member nid ready)
  ]
  where
    ready = Set.fromList (readyNodes rel gs)
    blockedReason nid =
      let preds = Set.toList (predecessors rel nid)
          failed = [p | p <- preds, Map.lookup p (gsNodeStatuses gs) == Just NodeFailed]
          pendingish =
            [ p
            | p <- preds
            , case Map.lookup p (gsNodeStatuses gs) of
                Just NodePending -> True
                Just NodeRunning -> True
                Just (NodeInterrupted _) -> True
                Just (NodeWaiting _) -> True
                _ -> False
            ]
       in case () of
            _
              | not (null failed) -> BlockedByFailed failed
              | not (null pendingish) -> BlockedByPending pendingish
              | otherwise -> BlockedUnknown

isLinearTopology :: Relation NodeId -> Bool
isLinearTopology rel =
  let verts = Set.toList (relVertices rel)
      degreeOk = all (\nid -> Set.size (predecessors rel nid) <= 1 && Set.size (successors rel nid) <= 1) verts
   in degreeOk && isWeaklyConnected rel

runTerminal :: NodeOutcome -> Maybe RunOutcome
runTerminal OutcomeNodeShutdown = Just OutcomeShutdown
runTerminal OutcomeNodeRunCancelled = Just OutcomeCancelled
runTerminal OutcomeNodeTimedOut = Just OutcomeTimedOut
runTerminal (OutcomeSucceeded _) = Nothing
runTerminal OutcomeSkipped = Nothing
runTerminal (OutcomeSuspendedOn _) = Nothing
runTerminal (OutcomeNodeFailed _) = Nothing
runTerminal OutcomeNodeCancelled = Nothing
runTerminal (OutcomeRewritten _ _) = Nothing

finalizeGraphStep
  :: Relation NodeId
  -> GraphState Value
  -> (GraphState Value, Maybe RunOutcome)
finalizeGraphStep rel gs0 =
  case classifyGraphState rel gs0 of
    Progressing gs _ -> (gs, Nothing)
    Settled gs outcome -> (gs, Just outcome)
    Suspended gs -> (gs, Just OutcomeSuspended)
    Stuck gs _ -> (gs, Nothing)

reduceFacts :: [NodeResult] -> GraphState Value -> GraphState Value
reduceFacts results gs = foldl' (flip applyNodeFact) gs results

applyFrontierResults
  :: Relation NodeId
  -> [NodeResult]
  -> GraphState Value
  -> StepResult
applyFrontierResults rel results gs =
  classifyGraphState rel (reduceFacts results gs)

runOutcomeToNodeOutcome :: RunOutcome -> NodeOutcome
runOutcomeToNodeOutcome = \case
  OutcomeShutdown -> OutcomeNodeShutdown
  OutcomeCancelled -> OutcomeNodeRunCancelled
  OutcomeFailed -> OutcomeNodeFailed (FailureDetail "stage_failed" "Stage execution failed" True)
  OutcomeTimedOut -> OutcomeNodeTimedOut
  OutcomeCompleted ->
    OutcomeNodeFailed
      (FailureDetail "internal_error" "Unexpected OutcomeCompleted in StageTerminal" False)
  OutcomeSuspended ->
    OutcomeNodeFailed
      (FailureDetail "internal_error" "Unexpected OutcomeSuspended in StageTerminal" False)

isForwardOutcome :: NodeOutcome -> Bool
isForwardOutcome = \case
  OutcomeSucceeded _ -> True
  OutcomeSkipped -> True
  OutcomeSuspendedOn _ -> True
  OutcomeRewritten _ _ -> True
  OutcomeNodeFailed _ -> False
  OutcomeNodeTimedOut -> False
  OutcomeNodeCancelled -> False
  OutcomeNodeShutdown -> False
  OutcomeNodeRunCancelled -> False

isResetOutcome :: NodeOutcome -> Bool
isResetOutcome = not . isForwardOutcome

type WorkerOracle = NodeId -> Map NodeId Value -> NodeOutcome

simulateRun
  :: Relation NodeId
  -> GraphState Value
  -> Value
  -> WorkerOracle
  -> Int
  -> ([(Int, [NodeId], [NodeResult])], StepResult)
simulateRun rel gs0 initialValue oracle maxWaves = go 0 gs0 []
  where
    go wave gs history
      | wave >= maxWaves = (reverse history, classifyGraphState rel gs)
      | otherwise =
          case classifyGraphState rel gs of
            Progressing gs' frontier ->
              let results =
                    [ NodeResult nid (oracle nid (nodeInputsWithDefault rel gs' initialValue nid))
                    | nid <- frontier
                    ]
                  stepResult = applyFrontierResults rel results gs'
                  gs'' = stepResultState stepResult
                  entry = (wave, frontier, results)
               in case stepResult of
                    Progressing _ _ -> go (wave + 1) gs'' (entry : history)
                    _ -> (reverse (entry : history), stepResult)
            other -> (reverse history, other)

isCompletedOrSkipped :: GraphState o -> NodeId -> Bool
isCompletedOrSkipped state nid =
  case Map.lookup nid (gsNodeStatuses state) of
    Just NodeCompleted -> True
    Just NodeSkipped -> True
    Just NodeRewritten -> True
    Just NodePending -> False
    Just NodeRunning -> False
    Just NodeFailed -> False
    Just (NodeInterrupted _) -> False
    Just (NodeWaiting _) -> False
    Nothing -> False

isTerminalStatus :: NodeStatus -> Bool
isTerminalStatus = \case
  NodeCompleted -> True
  NodeFailed -> True
  NodeSkipped -> True
  NodeRewritten -> True
  NodePending -> False
  NodeRunning -> False
  NodeInterrupted _ -> False
  NodeWaiting _ -> False

isWeaklyConnected :: Ord a => Relation a -> Bool
isWeaklyConnected rel =
  case Set.toList (relVertices rel) of
    [] -> True
    [_] -> True
    (root : _) ->
      let undirectedNeighbors v = Set.union (successors rel v) (predecessors rel v)
          go visited [] [] = visited
          go visited [] back = go visited (reverse back) []
          go visited (v : front) back
            | Set.member v visited = go visited front back
            | otherwise =
                let nbrs = Set.toList (undirectedNeighbors v)
                 in go (Set.insert v visited) front (nbrs <> back)
          reached = go Set.empty [root] []
       in Set.size reached == Set.size (relVertices rel)
