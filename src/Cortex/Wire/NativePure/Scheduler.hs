{- |
Module      : Cortex.Wire.NativePure.Scheduler
Description : Additive NativePure v2 quotient scheduler and hosted protocol model.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

This module is the executable policy model for the additive NativePure v2
profile. It specializes the witnessed realization quotient into dense runtime
units, executes pure units synchronously without host authority, and makes
checkpoint acknowledgement a hard gate before any later effect request.

The existing v1 program, engine, state, hosted protocol, and target remain
separate and unchanged.
-}
module Cortex.Wire.NativePure.Scheduler
  ( NativePureProgramV2 (..)
  , NativePureProgramV2Unit (..)
  , NativePureProgramV2UnitKind (..)
  , NativePureProgramV2Edge (..)
  , NativePureSelectV2 (..)
  , NativePureSelectPlanV2 (..)
  , NativePureProgramV2Error (..)
  , NativePureEngineStateV2 (..)
  , NativePureV2Status (..)
  , NativePureV2Result (..)
  , NativePureV2EffectCompletion (..)
  , NativePureV2Action (..)
  , NativePureV2Transition (..)
  , NativePureV2HostCommand (..)
  , NativePureV2EngineEvent (..)
  , nativePureStaticProgramV2Schema
  , nativePureEngineV2Abi
  , nativePureEngineStateV2Schema
  , nativePureHostProcessV2Protocol
  , nativePureHostedLinuxV2Target
  , nativePureHostedMessageCeiling
  , specializeNativePureProgramV2
  , validateNativePureProgramV2
  , initialNativePureEngineStateV2
  , validateNativePureEngineStateV2
  , restoreNativePureEngineStateV2
  , driveNativePureV2
  , acknowledgeNativePureCheckpointV2
  , completeNativePureEffectV2
  , cancelNativePureV2
  , encodeNativePureV2HostCommand
  , decodeNativePureV2HostCommand
  , encodeNativePureV2EngineEvent
  , decodeNativePureV2EngineEvent
  , renderNativePureProgramV2Error
  )
where

import Control.Monad (foldM, join, unless, when)
import Data.Aeson (FromJSON (..), ToJSON (..), (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32, Word64)
import GHC.Generics (Generic)

import Cortex.Wire.Circuit.Engine
  ( EngineTerminalState (..)
  , parseEngineTerminalState
  , renderEngineTerminalState
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..))
import Cortex.Wire.NativePure.Artifact
  ( NativePurePlan (..)
  , RealizationArtifact (..)
  , RealizationRuntimeKind (..)
  , RealizationRuntimeUnit (..)
  )

nativePureStaticProgramV2Schema :: Text
nativePureStaticProgramV2Schema = "cortex.wire.static-program/v2"

nativePureEngineV2Abi :: Text
nativePureEngineV2Abi = "cortex.wire.engine/v2"

nativePureEngineStateV2Schema :: Text
nativePureEngineStateV2Schema = "cortex.wire.engine-state/v2"

nativePureHostProcessV2Protocol :: Text
nativePureHostProcessV2Protocol = "cortex.wire.host-process/v2"

nativePureHostedLinuxV2Target :: Text
nativePureHostedLinuxV2Target = "cortex.wire.target/x86_64-linux-v2"

nativePureHostedMessageCeiling :: Int
nativePureHostedMessageCeiling = 2 * 1024 * 1024

data NativePureProgramV2UnitKind
  = NativePureV2Effect
  | NativePureV2PureRegion
  | NativePureV2SelectGuard
  | NativePureV2Rejoin
  deriving stock (Eq, Ord, Show, Generic)

data NativePureProgramV2Unit = NativePureProgramV2Unit
  { nativePureProgramV2UnitId :: !Word32
  , nativePureProgramV2UnitRef :: !Text
  , nativePureProgramV2UnitKind :: !NativePureProgramV2UnitKind
  , nativePureProgramV2UnitSources :: ![CircuitNodeRef]
  }
  deriving stock (Eq, Show, Generic)

data NativePureProgramV2Edge = NativePureProgramV2Edge
  { nativePureProgramV2EdgeFrom :: !Word32
  , nativePureProgramV2EdgeTo :: !Word32
  }
  deriving stock (Eq, Ord, Show, Generic)

{- | Authored select structure expressed over witnessed runtime-unit refs.
Empty variant lists are identity arms. The guard and rejoin themselves are
preserved quotient units; branch members may be pure regions or effects.
-}
data NativePureSelectV2 = NativePureSelectV2
  { nativePureSelectV2GuardRef :: !Text
  , nativePureSelectV2Variants :: !(Map Text [Text])
  , nativePureSelectV2RejoinRef :: !Text
  }
  deriving stock (Eq, Show, Generic)

data NativePureSelectPlanV2 = NativePureSelectPlanV2
  { nativePureSelectPlanV2Guard :: !Word32
  , nativePureSelectPlanV2Variants :: !(Map Text [Word32])
  , nativePureSelectPlanV2Rejoin :: !Word32
  }
  deriving stock (Eq, Show, Generic)

data NativePureProgramV2 = NativePureProgramV2
  { nativePureProgramV2Id :: !Text
  , nativePureProgramV2Identity :: !Text
  , nativePureProgramV2PlanDigest :: !Text
  , nativePureProgramV2Units :: ![NativePureProgramV2Unit]
  , nativePureProgramV2Edges :: ![NativePureProgramV2Edge]
  , nativePureProgramV2Selects :: ![NativePureSelectPlanV2]
  }
  deriving stock (Eq, Show, Generic)

data NativePureProgramV2Error
  = NativePureProgramV2UnitCountOverflow !Integer
  | NativePureProgramV2MissingRuntimeRef !Text
  | NativePureProgramV2InvalidSelect !Text
  | NativePureProgramV2State !Text
  | NativePureProgramV2Stuck
  | NativePureProgramV2PureFailure !Word32 !Text
  | NativePureProgramV2Protocol !Text
  | NativePureProgramV2MessageTooLarge !Int
  deriving stock (Eq, Show)

renderNativePureProgramV2Error :: NativePureProgramV2Error -> Text
renderNativePureProgramV2Error = \case
  NativePureProgramV2UnitCountOverflow count ->
    "NativePure v2 runtime-unit count exceeds uint32_t: " <> T.pack (show count)
  NativePureProgramV2MissingRuntimeRef runtimeRef ->
    "NativePure v2 select refers to unknown runtime unit " <> runtimeRef
  NativePureProgramV2InvalidSelect reason -> "invalid NativePure v2 select: " <> reason
  NativePureProgramV2State reason -> "invalid NativePure v2 engine state: " <> reason
  NativePureProgramV2Stuck -> "NativePure v2 scheduler has unsettled units but no ready transition"
  NativePureProgramV2PureFailure unitId reason ->
    "NativePure v2 pure unit " <> T.pack (show unitId) <> " failed: " <> reason
  NativePureProgramV2Protocol reason -> "NativePure v2 protocol error: " <> reason
  NativePureProgramV2MessageTooLarge bytes ->
    "NativePure v2 hosted message is " <> T.pack (show bytes) <> " bytes; maximum is 2097152"

specializeNativePureProgramV2
  :: NativePurePlan
  -> [NativePureSelectV2]
  -> Either NativePureProgramV2Error NativePureProgramV2
specializeNativePureProgramV2 plan selectSpecs = do
  let artifact = plan.nativePurePlanRealization
      runtimeRows = Map.toAscList artifact.realizationArtifactRuntimeUnits
      count = toInteger (length runtimeRows)
  when (count > toInteger (maxBound :: Word32)) $
    Left (NativePureProgramV2UnitCountOverflow count)
  let refs = Map.fromAscList (zip (fmap fst runtimeRows) [0 ..])
      baseUnits =
        [ NativePureProgramV2Unit
            { nativePureProgramV2UnitId = unitId
            , nativePureProgramV2UnitRef = runtimeRef
            , nativePureProgramV2UnitKind = runtimeKind unit.realizationRuntimeUnitKind
            , nativePureProgramV2UnitSources = unit.realizationRuntimeUnitSources
            }
        | ((runtimeRef, unit), unitId) <- zip runtimeRows [0 ..]
        ]
  edges <-
    traverse
      (\(source, target) -> NativePureProgramV2Edge <$> lookupRef refs source <*> lookupRef refs target)
      (Set.toAscList artifact.realizationArtifactRuntimeEdges)
  (selects, selectKinds) <- foldM (lowerSelect refs) ([], Map.empty) selectSpecs
  let units =
        [ unit
            { nativePureProgramV2UnitKind =
                Map.findWithDefault unit.nativePureProgramV2UnitKind unit.nativePureProgramV2UnitId selectKinds
            }
        | unit <- baseUnits
        ]
  let program =
        NativePureProgramV2
          { nativePureProgramV2Id = plan.nativePurePlanProgramId
          , nativePureProgramV2Identity = plan.nativePurePlanProgramIdentity
          , nativePureProgramV2PlanDigest = plan.nativePurePlanDigest
          , nativePureProgramV2Units = units
          , nativePureProgramV2Edges = edges
          , nativePureProgramV2Selects = selects
          }
  validateNativePureProgramV2 program
  pure program
  where
    runtimeKind = \case
      RealizationPureRegion -> NativePureV2PureRegion
      RealizationPreservedNode -> NativePureV2Effect

    lowerSelect refs (plans, assignedKinds) authored = do
      guardId <- lookupRef refs authored.nativePureSelectV2GuardRef
      rejoinId <- lookupRef refs authored.nativePureSelectV2RejoinRef
      when (guardId == rejoinId) $
        Left (NativePureProgramV2InvalidSelect "guard and rejoin must be distinct")
      when (Map.size authored.nativePureSelectV2Variants < 2) $
        Left (NativePureProgramV2InvalidSelect "at least two variants are required")
      when (any (T.null . T.strip) (Map.keys authored.nativePureSelectV2Variants)) $
        Left (NativePureProgramV2InvalidSelect "variant labels must be nonblank")
      loweredVariants <- traverse (traverse (lookupRef refs)) authored.nativePureSelectV2Variants
      let branchMembers = concat (Map.elems loweredVariants)
      when (length branchMembers /= Set.size (Set.fromList branchMembers)) $
        Left (NativePureProgramV2InvalidSelect "variant branch units must be pairwise disjoint")
      when (guardId `elem` branchMembers || rejoinId `elem` branchMembers) $
        Left (NativePureProgramV2InvalidSelect "guard or rejoin occurs inside a branch")
      when (Map.member guardId assignedKinds || Map.member rejoinId assignedKinds) $
        Left (NativePureProgramV2InvalidSelect "guard or rejoin is owned by multiple selects")
      pure
        ( plans
            <> [ NativePureSelectPlanV2
                   { nativePureSelectPlanV2Guard = guardId
                   , nativePureSelectPlanV2Variants = loweredVariants
                   , nativePureSelectPlanV2Rejoin = rejoinId
                   }
               ]
        , Map.insert rejoinId NativePureV2Rejoin (Map.insert guardId NativePureV2SelectGuard assignedKinds)
        )

lookupRef :: Map Text Word32 -> Text -> Either NativePureProgramV2Error Word32
lookupRef refs runtimeRef =
  maybe (Left (NativePureProgramV2MissingRuntimeRef runtimeRef)) Right (Map.lookup runtimeRef refs)

validateNativePureProgramV2 :: NativePureProgramV2 -> Either NativePureProgramV2Error ()
validateNativePureProgramV2 program = do
  when (T.null (T.strip program.nativePureProgramV2Id)) $
    invalidState "program identifier must be nonblank"
  when (T.null (T.strip program.nativePureProgramV2Identity)) $
    invalidState "program identity must be nonblank"
  when (T.null (T.strip program.nativePureProgramV2PlanDigest)) $
    invalidState "plan digest must be nonblank"
  let units = program.nativePureProgramV2Units
      unitIds = fmap (.nativePureProgramV2UnitId) units
      expectedIds = fmap fromIntegral [0 .. length units - 1]
      unitRefs = fmap (.nativePureProgramV2UnitRef) units
  unless (unitIds == expectedIds) $
    invalidState "runtime unit identifiers must be dense, ascending, and zero-based"
  when (any (T.null . T.strip) unitRefs) $
    invalidState "runtime unit references must be nonblank"
  unless (length unitRefs == Set.size (Set.fromList unitRefs)) $
    invalidState "runtime unit references must be unique"
  unless (length edgePairs == Set.size (Set.fromList edgePairs)) $
    invalidState "runtime edges must be unique"
  mapM_ validateEdge edgePairs
  when (hasCycle unitIds edgePairs) $
    invalidState "runtime quotient must be acyclic"
  _owned <- foldM validateSelect Set.empty program.nativePureProgramV2Selects
  pure ()
  where
    knownUnit unitId = isJust (unitById program unitId)

    validateEdge (source, target) = do
      unless (knownUnit source && knownUnit target) $
        invalidState "runtime edge endpoint is outside the specialized program"
      when (source == target) $
        invalidState "runtime quotient contains a self-edge"

    validateSelect owned selection = do
      let guardId = selection.nativePureSelectPlanV2Guard
          rejoinId = selection.nativePureSelectPlanV2Rejoin
          variants = selection.nativePureSelectPlanV2Variants
          branchMembers = concat (Map.elems variants)
          selectionMembers = Set.fromList (guardId : rejoinId : branchMembers)
      when (guardId == rejoinId) $
        invalidSelect "guard and rejoin must be distinct"
      unless (unitKindIs guardId NativePureV2SelectGuard) $
        invalidSelect "select guard does not name a guard unit"
      unless (unitKindIs rejoinId NativePureV2Rejoin) $
        invalidSelect "select rejoin does not name a rejoin unit"
      when (Map.size variants < 2 || any (T.null . T.strip) (Map.keys variants)) $
        invalidSelect "select requires at least two nonblank variant labels"
      unless (all knownUnit branchMembers) $
        invalidSelect "select branch contains an unknown runtime unit"
      unless (length branchMembers == Set.size (Set.fromList branchMembers)) $
        invalidSelect "select branch units must be pairwise disjoint"
      when (guardId `elem` branchMembers || rejoinId `elem` branchMembers) $
        invalidSelect "guard or rejoin occurs inside a branch"
      unless (Set.null (Set.intersection owned selectionMembers)) $
        invalidSelect "runtime units cannot be owned by multiple select plans"
      mapM_ (validateBranch guardId rejoinId) (Map.toAscList variants)
      pure (Set.union owned selectionMembers)

    validateBranch guardId rejoinId (_label, []) =
      unless ((guardId, rejoinId) `elem` edgePairs) $
        invalidSelect "an identity select arm requires a direct guard-to-rejoin edge"
    validateBranch guardId rejoinId (_label, members) = do
      let memberSet = Set.fromList members
          forward = reachableWithin memberSet (successors program) [guardId]
          backward = reachableWithin memberSet (predecessors program) [rejoinId]
      unless (memberSet `Set.isSubsetOf` forward) $
        invalidSelect "every branch unit must be reachable from its guard within that branch"
      unless (memberSet `Set.isSubsetOf` backward) $
        invalidSelect "every branch unit must reach its declared rejoin within that branch"
      -- Rejoin reads exactly one branch member's value (its unique direct
      -- predecessor); an internal fan-in that leaves two members both
      -- feeding rejoin would let the runtime value silently pick one and
      -- discard the other, so it is rejected here instead.
      case filter (\member -> (member, rejoinId) `elem` edgePairs) members of
        [_singleTail] -> pure ()
        [] -> invalidSelect "no branch unit has a direct edge into rejoin"
        _multipleTails -> invalidSelect "more than one branch unit has a direct edge into rejoin"

    unitKindIs unitId kind =
      maybe False ((== kind) . (.nativePureProgramV2UnitKind)) (unitById program unitId)

    edgePairs =
      fmap
        (\edge -> (edge.nativePureProgramV2EdgeFrom, edge.nativePureProgramV2EdgeTo))
        program.nativePureProgramV2Edges

    invalidState = Left . NativePureProgramV2State
    invalidSelect = Left . NativePureProgramV2InvalidSelect

hasCycle :: [Word32] -> [(Word32, Word32)] -> Bool
hasCycle unitIds edgePairs = visit Set.empty Set.empty unitIds
  where
    visit _visited _active [] = False
    visit visited active (unitId : rest)
      | Set.member unitId visited = visit visited active rest
      | otherwise = case descend visited active unitId of
          Nothing -> True
          Just visited' -> visit visited' active rest

    descend visited active unitId
      | Set.member unitId active = Nothing
      | Set.member unitId visited = Just visited
      | otherwise = do
          visited' <-
            foldM
              (\seen successor -> descend seen (Set.insert unitId active) successor)
              visited
              [target | (source, target) <- edgePairs, source == unitId]
          pure (Set.insert unitId visited')

reachableWithin
  :: Set.Set Word32
  -> (Word32 -> [Word32])
  -> [Word32]
  -> Set.Set Word32
reachableWithin allowed adjacent = go Set.empty
  where
    go visited [] = visited
    go visited (current : rest) =
      let next = filter (`Set.member` allowed) (adjacent current)
          unseen = filter (`Set.notMember` visited) next
       in go (Set.union visited (Set.fromList unseen)) (rest <> unseen)

data NativePureV2Status
  = NativePureV2Pending
  | NativePureV2RunningEffect
  | NativePureV2Completed
  | NativePureV2Failed
  | NativePureV2Skipped
  deriving stock (Eq, Ord, Show, Generic)

data NativePureEngineStateV2 = NativePureEngineStateV2
  { nativePureEngineStateV2ProgramIdentity :: !Text
  , nativePureEngineStateV2CheckpointSequence :: !Word64
  , nativePureEngineStateV2NextEffectSequence :: !Word64
  , nativePureEngineStateV2AwaitingCheckpoint :: !Bool
  , nativePureEngineStateV2Terminal :: !EngineTerminalState
  , nativePureEngineStateV2Statuses :: ![NativePureV2Status]
  , nativePureEngineStateV2Values :: ![Maybe Aeson.Value]
  , nativePureEngineStateV2EffectSequences :: ![Maybe Word64]
  , nativePureEngineStateV2SelectedTags :: !(Map Word32 Text)
  , nativePureEngineStateV2Failure :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

data NativePureV2Result = NativePureV2Result
  { nativePureV2ResultValue :: !Aeson.Value
  , nativePureV2ResultSelectedTag :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

data NativePureV2EffectCompletion
  = NativePureV2EffectSucceeded !Aeson.Value
  | NativePureV2EffectSkipped
  | NativePureV2EffectFailed !Text
  deriving stock (Eq, Show, Generic)

data NativePureV2Action
  = NativePureV2CheckpointRequired !NativePureEngineStateV2
  | NativePureV2EffectRequested !Word64 !Word32 !Text !(Map Text Aeson.Value)
  | NativePureV2AwaitingEffects
  | NativePureV2Terminal !EngineTerminalState
  deriving stock (Eq, Show, Generic)

data NativePureV2Transition = NativePureV2Transition
  { nativePureV2TransitionState :: !NativePureEngineStateV2
  , nativePureV2TransitionAction :: !NativePureV2Action
  }
  deriving stock (Eq, Show, Generic)

initialNativePureEngineStateV2 :: NativePureProgramV2 -> NativePureEngineStateV2
initialNativePureEngineStateV2 program =
  NativePureEngineStateV2
    { nativePureEngineStateV2ProgramIdentity = program.nativePureProgramV2Identity
    , nativePureEngineStateV2CheckpointSequence = 1
    , nativePureEngineStateV2NextEffectSequence = 1
    , nativePureEngineStateV2AwaitingCheckpoint = True
    , nativePureEngineStateV2Terminal = EngineActive
    , nativePureEngineStateV2Statuses = replicate count NativePureV2Pending
    , nativePureEngineStateV2Values = replicate count Nothing
    , nativePureEngineStateV2EffectSequences = replicate count Nothing
    , nativePureEngineStateV2SelectedTags = Map.empty
    , nativePureEngineStateV2Failure = Nothing
    }
  where
    count = length program.nativePureProgramV2Units

validateNativePureEngineStateV2
  :: NativePureProgramV2
  -> NativePureEngineStateV2
  -> Either NativePureProgramV2Error ()
validateNativePureEngineStateV2 program state = do
  validateNativePureProgramV2 program
  unless (state.nativePureEngineStateV2ProgramIdentity == program.nativePureProgramV2Identity) $
    stateError "program identity mismatch"
  when (state.nativePureEngineStateV2CheckpointSequence == 0) $
    stateError "checkpoint sequence must be positive"
  when (state.nativePureEngineStateV2NextEffectSequence == 0) $
    stateError "next effect sequence must be positive"
  let count = length program.nativePureProgramV2Units
  unless
    ( length state.nativePureEngineStateV2Statuses == count
        && length state.nativePureEngineStateV2Values == count
        && length state.nativePureEngineStateV2EffectSequences == count
    )
    (stateError "unit-state arrays do not match the specialized program")
  sequence_
    [ validateSlot index status value effectSequence
    | (index, (status, value, effectSequence)) <-
        zip [0 :: Int ..] $
          zip3
            state.nativePureEngineStateV2Statuses
            state.nativePureEngineStateV2Values
            state.nativePureEngineStateV2EffectSequences
    ]
  sequence_
    [ validateSelectedTag guardId label
    | (guardId, label) <- Map.toAscList state.nativePureEngineStateV2SelectedTags
    ]
  validateTerminal
  let encodedSize = fromIntegral (BSL.length (Aeson.encode state))
  when (encodedSize > nativePureHostedMessageCeiling) $
    Left (NativePureProgramV2MessageTooLarge encodedSize)
  where
    stateError = Left . NativePureProgramV2State

    validateSlot index status value effectSequence = case status of
      NativePureV2Pending -> absent index value effectSequence
      NativePureV2RunningEffect -> do
        when (isJust value) (stateError (slotReason index "running effect has a value"))
        unless (isJust effectSequence) (stateError (slotReason index "running effect has no sequence"))
        case program.nativePureProgramV2Units List.!? index of
          Just unit
            | unit.nativePureProgramV2UnitKind == NativePureV2Effect -> pure ()
          _ -> stateError (slotReason index "non-effect unit is marked running")
      NativePureV2Completed -> do
        unless (isJust value) (stateError (slotReason index "completed unit has no value"))
        when
          (isJust effectSequence)
          (stateError (slotReason index "completed unit keeps an effect sequence"))
      NativePureV2Failed -> absent index value effectSequence
      NativePureV2Skipped -> absent index value effectSequence

    absent index value effectSequence =
      unless (isNothing value && isNothing effectSequence) $
        stateError (slotReason index "non-completed unit carries value or effect sequence")

    validateSelectedTag guardId label =
      case List.find ((== guardId) . (.nativePureSelectPlanV2Guard)) program.nativePureProgramV2Selects of
        Nothing -> stateError "selected tag refers to a non-guard unit"
        Just selection ->
          unless (Map.member label selection.nativePureSelectPlanV2Variants) $
            stateError "selected tag is not declared by its guard"

    validateTerminal = case state.nativePureEngineStateV2Terminal of
      EngineActive -> requireNoFailure
      EngineSucceeded -> do
        requireNoFailure
        unless (all settled state.nativePureEngineStateV2Statuses) $
          stateError "successful terminal contains an unsettled or failed unit"
      EngineTerminalFailed -> do
        unless (isJust state.nativePureEngineStateV2Failure) $
          stateError "failed terminal contains no failure reason"
        unless (NativePureV2Failed `elem` state.nativePureEngineStateV2Statuses) $
          stateError "failed terminal contains no failed unit"
      EngineCancelled -> do
        requireNoFailure
        when (NativePureV2RunningEffect `elem` state.nativePureEngineStateV2Statuses) $
          stateError "cancelled terminal contains a running effect"

    requireNoFailure =
      when (isJust state.nativePureEngineStateV2Failure) $
        stateError "non-failed terminal carries a failure reason"

    slotReason index reason = "unit " <> T.pack (show index) <> " " <> reason

restoreNativePureEngineStateV2
  :: NativePureProgramV2
  -> NativePureEngineStateV2
  -> Either NativePureProgramV2Error NativePureEngineStateV2
restoreNativePureEngineStateV2 program state = do
  validateNativePureEngineStateV2 program state
  let statuses = fmap restoreStatus state.nativePureEngineStateV2Statuses
      restored =
        state
          { nativePureEngineStateV2AwaitingCheckpoint = True
          , nativePureEngineStateV2Statuses = statuses
          , nativePureEngineStateV2EffectSequences = replicate (length statuses) Nothing
          }
  validateNativePureEngineStateV2 program restored
  pure restored
  where
    restoreStatus = \case
      NativePureV2RunningEffect -> NativePureV2Pending
      NativePureV2Pending -> NativePureV2Pending
      NativePureV2Completed -> NativePureV2Completed
      NativePureV2Failed -> NativePureV2Failed
      NativePureV2Skipped -> NativePureV2Skipped

driveNativePureV2
  :: (NativePureProgramV2Unit -> Map Text Aeson.Value -> Either Text NativePureV2Result)
  -> NativePureProgramV2
  -> NativePureEngineStateV2
  -> Either NativePureProgramV2Error NativePureV2Transition
driveNativePureV2 runPure program state = do
  validateNativePureEngineStateV2 program state
  if state.nativePureEngineStateV2AwaitingCheckpoint
    then transition state (NativePureV2CheckpointRequired state)
    else case state.nativePureEngineStateV2Terminal of
      terminal | terminal /= EngineActive -> transition state (NativePureV2Terminal terminal)
      _ ->
        case List.find (unitReady program state) program.nativePureProgramV2Units of
          Just unit -> runUnit runPure program state unit
          Nothing
            | NativePureV2RunningEffect `elem` state.nativePureEngineStateV2Statuses ->
                transition state NativePureV2AwaitingEffects
            | all settled state.nativePureEngineStateV2Statuses ->
                checkpointTransition state {nativePureEngineStateV2Terminal = EngineSucceeded}
            | otherwise -> Left NativePureProgramV2Stuck

acknowledgeNativePureCheckpointV2
  :: NativePureProgramV2
  -> Word64
  -> NativePureEngineStateV2
  -> Either NativePureProgramV2Error NativePureEngineStateV2
acknowledgeNativePureCheckpointV2 program sequenceNumber state = do
  validateNativePureEngineStateV2 program state
  unless state.nativePureEngineStateV2AwaitingCheckpoint $
    Left (NativePureProgramV2Protocol "no checkpoint is awaiting acknowledgement")
  unless (sequenceNumber == state.nativePureEngineStateV2CheckpointSequence) $
    Left (NativePureProgramV2Protocol "checkpoint acknowledgement sequence mismatch")
  pure state {nativePureEngineStateV2AwaitingCheckpoint = False}

completeNativePureEffectV2
  :: NativePureProgramV2
  -> Word64
  -> Word32
  -> NativePureV2EffectCompletion
  -> NativePureEngineStateV2
  -> Either NativePureProgramV2Error NativePureEngineStateV2
completeNativePureEffectV2 program sequenceNumber unitId completion state = do
  validateNativePureEngineStateV2 program state
  when state.nativePureEngineStateV2AwaitingCheckpoint $
    Left (NativePureProgramV2Protocol "effect completion arrived before checkpoint acknowledgement")
  index <- unitIndex program unitId
  unless (state.nativePureEngineStateV2Statuses List.!? index == Just NativePureV2RunningEffect) $
    Left (NativePureProgramV2Protocol "effect completion targets a unit that is not running")
  unless (state.nativePureEngineStateV2EffectSequences List.!? index == Just (Just sequenceNumber)) $
    Left (NativePureProgramV2Protocol "effect completion sequence mismatch")
  let cleared = setAt index Nothing state.nativePureEngineStateV2EffectSequences
      base = state {nativePureEngineStateV2EffectSequences = cleared}
      completed = case completion of
        NativePureV2EffectSucceeded value ->
          base
            { nativePureEngineStateV2Statuses =
                setAt index NativePureV2Completed base.nativePureEngineStateV2Statuses
            , nativePureEngineStateV2Values =
                setAt index (Just value) base.nativePureEngineStateV2Values
            }
        NativePureV2EffectSkipped ->
          base
            { nativePureEngineStateV2Statuses =
                setAt index NativePureV2Skipped base.nativePureEngineStateV2Statuses
            }
        NativePureV2EffectFailed reason ->
          base
            { nativePureEngineStateV2Statuses =
                setAt index NativePureV2Failed base.nativePureEngineStateV2Statuses
            , nativePureEngineStateV2Terminal = EngineTerminalFailed
            , nativePureEngineStateV2Failure = Just reason
            }
  pure (checkpointState completed)

cancelNativePureV2
  :: NativePureProgramV2
  -> NativePureEngineStateV2
  -> Either NativePureProgramV2Error NativePureEngineStateV2
cancelNativePureV2 program state = do
  validateNativePureEngineStateV2 program state
  unless (state.nativePureEngineStateV2Terminal == EngineActive) $
    Left (NativePureProgramV2Protocol "cannot cancel a terminal engine")
  let cancelStatus = \case
        NativePureV2Pending -> NativePureV2Skipped
        NativePureV2RunningEffect -> NativePureV2Skipped
        NativePureV2Completed -> NativePureV2Completed
        NativePureV2Failed -> NativePureV2Failed
        NativePureV2Skipped -> NativePureV2Skipped
      cancelled =
        state
          { nativePureEngineStateV2Statuses = fmap cancelStatus state.nativePureEngineStateV2Statuses
          , nativePureEngineStateV2EffectSequences =
              replicate (length state.nativePureEngineStateV2Statuses) Nothing
          , nativePureEngineStateV2Terminal = EngineCancelled
          }
  pure (checkpointState cancelled)

runUnit
  :: (NativePureProgramV2Unit -> Map Text Aeson.Value -> Either Text NativePureV2Result)
  -> NativePureProgramV2
  -> NativePureEngineStateV2
  -> NativePureProgramV2Unit
  -> Either NativePureProgramV2Error NativePureV2Transition
runUnit runPure program state unit = do
  index <- unitIndex program unit.nativePureProgramV2UnitId
  let inputs = unitInputValues program state unit.nativePureProgramV2UnitId
  case unit.nativePureProgramV2UnitKind of
    NativePureV2Effect -> do
      let sequenceNumber = state.nativePureEngineStateV2NextEffectSequence
          requested =
            state
              { nativePureEngineStateV2NextEffectSequence = sequenceNumber + 1
              , nativePureEngineStateV2Statuses =
                  setAt index NativePureV2RunningEffect state.nativePureEngineStateV2Statuses
              , nativePureEngineStateV2EffectSequences =
                  setAt index (Just sequenceNumber) state.nativePureEngineStateV2EffectSequences
              }
      transition
        requested
        ( NativePureV2EffectRequested
            sequenceNumber
            unit.nativePureProgramV2UnitId
            unit.nativePureProgramV2UnitRef
            inputs
        )
    NativePureV2PureRegion -> do
      case runPure unit inputs of
        Left reason -> failUnitTransition index reason state
        Right result
          | isJust result.nativePureV2ResultSelectedTag ->
              failUnitTransition index "non-guard returned a selected tag" state
          | otherwise -> checkpointTransition (completeUnit index result.nativePureV2ResultValue state)
    NativePureV2SelectGuard -> do
      selection <-
        maybe
          (Left (NativePureProgramV2InvalidSelect "guard has no select plan"))
          Right
          ( List.find
              ((== unit.nativePureProgramV2UnitId) . (.nativePureSelectPlanV2Guard))
              program.nativePureProgramV2Selects
          )
      case runPure unit inputs of
        Left reason -> failUnitTransition index reason state
        Right result -> case result.nativePureV2ResultSelectedTag of
          Nothing -> failUnitTransition index "guard returned no selected tag" state
          Just label
            | not (Map.member label selection.nativePureSelectPlanV2Variants) ->
                failUnitTransition index "guard returned an undeclared tag" state
            | otherwise -> do
                let selected =
                      completeUnit
                        index
                        result.nativePureV2ResultValue
                        state
                          { nativePureEngineStateV2SelectedTags =
                              Map.insert unit.nativePureProgramV2UnitId label state.nativePureEngineStateV2SelectedTags
                          }
                    skipped = skipUnselected selection label selected
                checkpointTransition skipped
    NativePureV2Rejoin -> do
      selection <-
        maybe
          (Left (NativePureProgramV2InvalidSelect "rejoin has no select plan"))
          Right
          ( List.find
              ((== unit.nativePureProgramV2UnitId) . (.nativePureSelectPlanV2Rejoin))
              program.nativePureProgramV2Selects
          )
      label <-
        maybe
          (Left (NativePureProgramV2InvalidSelect "rejoin has no persisted selected tag"))
          Right
          (Map.lookup selection.nativePureSelectPlanV2Guard state.nativePureEngineStateV2SelectedTags)
      branch <-
        maybe
          (Left (NativePureProgramV2InvalidSelect "persisted selected tag is undeclared"))
          Right
          (Map.lookup label selection.nativePureSelectPlanV2Variants)
      -- validateSelect guarantees exactly one branch member has a direct
      -- edge into this rejoin (or, for an identity arm, the branch is empty
      -- and the guard's own value is used); rejoin reads exactly that unit's
      -- value rather than scanning the declared member list, so an internal
      -- fan-in can never silently pick one predecessor and drop another.
      let directPredecessor edge =
            edge.nativePureProgramV2EdgeTo == unit.nativePureProgramV2UnitId
              && edge.nativePureProgramV2EdgeFrom `elem` branch
          tail_ = (.nativePureProgramV2EdgeFrom) <$> List.find directPredecessor program.nativePureProgramV2Edges
          source = tail_ <|> if null branch then Just selection.nativePureSelectPlanV2Guard else Nothing
      value <-
        maybe
          (Left (NativePureProgramV2InvalidSelect "rejoin branch has no unique direct predecessor"))
          (Right . fromMaybe Aeson.Null . valueAt state)
          source
      checkpointTransition (completeUnit index value state)

failUnitTransition
  :: Int
  -> Text
  -> NativePureEngineStateV2
  -> Either NativePureProgramV2Error NativePureV2Transition
failUnitTransition index reason state =
  checkpointTransition
    state
      { nativePureEngineStateV2Statuses =
          setAt index NativePureV2Failed state.nativePureEngineStateV2Statuses
      , nativePureEngineStateV2Terminal = EngineTerminalFailed
      , nativePureEngineStateV2Failure = Just reason
      }

unitReady :: NativePureProgramV2 -> NativePureEngineStateV2 -> NativePureProgramV2Unit -> Bool
unitReady program state unit =
  statusAt state unit.nativePureProgramV2UnitId == Just NativePureV2Pending
    && branchEnabled program state unit.nativePureProgramV2UnitId
    && all (maybe False settled . statusAt state) (predecessors program unit.nativePureProgramV2UnitId)

branchEnabled :: NativePureProgramV2 -> NativePureEngineStateV2 -> Word32 -> Bool
branchEnabled program state unitId =
  all enabledBy program.nativePureProgramV2Selects
  where
    enabledBy selection =
      case [ label
           | (label, members) <- Map.toAscList selection.nativePureSelectPlanV2Variants
           , unitId `elem` members
           ] of
        [] -> True
        labels ->
          case Map.lookup selection.nativePureSelectPlanV2Guard state.nativePureEngineStateV2SelectedTags of
            Nothing -> False
            Just selectedLabel -> selectedLabel `elem` labels

predecessors :: NativePureProgramV2 -> Word32 -> [Word32]
predecessors program unitId =
  [ edge.nativePureProgramV2EdgeFrom
  | edge <- program.nativePureProgramV2Edges
  , edge.nativePureProgramV2EdgeTo == unitId
  ]

successors :: NativePureProgramV2 -> Word32 -> [Word32]
successors program unitId =
  [ edge.nativePureProgramV2EdgeTo
  | edge <- program.nativePureProgramV2Edges
  , edge.nativePureProgramV2EdgeFrom == unitId
  ]

unitInputValues
  :: NativePureProgramV2
  -> NativePureEngineStateV2
  -> Word32
  -> Map Text Aeson.Value
unitInputValues program state unitId =
  Map.fromList $
    catMaybes
      [ do
          unit <- unitById program predecessor
          value <- valueAt state predecessor
          pure (unit.nativePureProgramV2UnitRef, value)
      | predecessor <- predecessors program unitId
      ]

skipUnselected
  :: NativePureSelectPlanV2
  -> Text
  -> NativePureEngineStateV2
  -> NativePureEngineStateV2
skipUnselected selection selectedLabel state =
  foldl skip state unselected
  where
    unselected =
      concat
        [ members
        | (label, members) <- Map.toAscList selection.nativePureSelectPlanV2Variants
        , label /= selectedLabel
        ]
    skip current unitId = case word32Index unitId of
      Nothing -> current
      Just index ->
        current
          { nativePureEngineStateV2Statuses =
              setAt index NativePureV2Skipped current.nativePureEngineStateV2Statuses
          , nativePureEngineStateV2Values =
              setAt index Nothing current.nativePureEngineStateV2Values
          , nativePureEngineStateV2EffectSequences =
              setAt index Nothing current.nativePureEngineStateV2EffectSequences
          }

completeUnit :: Int -> Aeson.Value -> NativePureEngineStateV2 -> NativePureEngineStateV2
completeUnit index value state =
  state
    { nativePureEngineStateV2Statuses =
        setAt index NativePureV2Completed state.nativePureEngineStateV2Statuses
    , nativePureEngineStateV2Values =
        setAt index (Just value) state.nativePureEngineStateV2Values
    }

checkpointTransition
  :: NativePureEngineStateV2
  -> Either NativePureProgramV2Error NativePureV2Transition
checkpointTransition state =
  let checkpointed = checkpointState state
   in transition checkpointed (NativePureV2CheckpointRequired checkpointed)

checkpointState :: NativePureEngineStateV2 -> NativePureEngineStateV2
checkpointState state =
  state
    { nativePureEngineStateV2CheckpointSequence = state.nativePureEngineStateV2CheckpointSequence + 1
    , nativePureEngineStateV2AwaitingCheckpoint = True
    }

transition
  :: NativePureEngineStateV2
  -> NativePureV2Action
  -> Either NativePureProgramV2Error NativePureV2Transition
transition state action = Right (NativePureV2Transition state action)

settled :: NativePureV2Status -> Bool
settled NativePureV2Completed = True
settled NativePureV2Skipped = True
settled _ = False

statusAt :: NativePureEngineStateV2 -> Word32 -> Maybe NativePureV2Status
statusAt state unitId = word32Index unitId >>= (state.nativePureEngineStateV2Statuses List.!?)

valueAt :: NativePureEngineStateV2 -> Word32 -> Maybe Aeson.Value
valueAt state unitId = join (word32Index unitId >>= (state.nativePureEngineStateV2Values List.!?))

unitById :: NativePureProgramV2 -> Word32 -> Maybe NativePureProgramV2Unit
unitById program unitId = List.find ((== unitId) . (.nativePureProgramV2UnitId)) program.nativePureProgramV2Units

unitIndex :: NativePureProgramV2 -> Word32 -> Either NativePureProgramV2Error Int
unitIndex program unitId =
  case List.findIndex ((== unitId) . (.nativePureProgramV2UnitId)) program.nativePureProgramV2Units of
    Nothing -> Left (NativePureProgramV2State "unit identifier is outside the specialized program")
    Just index -> Right index

word32Index :: Word32 -> Maybe Int
word32Index value
  | toInteger value <= toInteger (maxBound :: Int) = Just (fromIntegral value)
  | otherwise = Nothing

setAt :: Int -> value -> [value] -> [value]
setAt index value values =
  let (prefix, suffix) = splitAt index values
   in case suffix of
        [] -> values
        _old : rest -> prefix <> (value : rest)

infixr 3 <|>
(<|>) :: Maybe value -> Maybe value -> Maybe value
Nothing <|> right = right
left <|> _right = left

-- JSON surfaces -------------------------------------------------------------

instance ToJSON NativePureProgramV2UnitKind where
  toJSON = Aeson.String . renderUnitKind

instance FromJSON NativePureProgramV2UnitKind where
  parseJSON = Aeson.withText "NativePureProgramV2UnitKind" $ \value ->
    maybe (fail ("invalid NativePure v2 unit kind: " <> T.unpack value)) pure (parseUnitKind value)

renderUnitKind :: NativePureProgramV2UnitKind -> Text
renderUnitKind = \case
  NativePureV2Effect -> "effect"
  NativePureV2PureRegion -> "pure_region"
  NativePureV2SelectGuard -> "select_guard"
  NativePureV2Rejoin -> "rejoin"

parseUnitKind :: Text -> Maybe NativePureProgramV2UnitKind
parseUnitKind = \case
  "effect" -> Just NativePureV2Effect
  "pure_region" -> Just NativePureV2PureRegion
  "select_guard" -> Just NativePureV2SelectGuard
  "rejoin" -> Just NativePureV2Rejoin
  _ -> Nothing

instance ToJSON NativePureProgramV2Unit where
  toJSON unit =
    Aeson.object
      [ "id" .= unit.nativePureProgramV2UnitId
      , "ref" .= unit.nativePureProgramV2UnitRef
      , "kind" .= unit.nativePureProgramV2UnitKind
      , "sources" .= fmap (.unCircuitNodeRef) unit.nativePureProgramV2UnitSources
      ]

instance FromJSON NativePureProgramV2Unit where
  parseJSON = Aeson.withObject "NativePureProgramV2Unit" $ \objectValue ->
    NativePureProgramV2Unit
      <$> objectValue .: "id"
      <*> objectValue .: "ref"
      <*> objectValue .: "kind"
      <*> (fmap CircuitNodeRef <$> objectValue .: "sources")

instance ToJSON NativePureProgramV2Edge where
  toJSON edge = Aeson.object ["from" .= edge.nativePureProgramV2EdgeFrom, "to" .= edge.nativePureProgramV2EdgeTo]

instance FromJSON NativePureProgramV2Edge where
  parseJSON = Aeson.withObject "NativePureProgramV2Edge" $ \objectValue ->
    NativePureProgramV2Edge <$> objectValue .: "from" <*> objectValue .: "to"

instance ToJSON NativePureSelectPlanV2 where
  toJSON selection =
    Aeson.object
      [ "guard" .= selection.nativePureSelectPlanV2Guard
      , "variants" .= selection.nativePureSelectPlanV2Variants
      , "rejoin" .= selection.nativePureSelectPlanV2Rejoin
      ]

instance FromJSON NativePureSelectPlanV2 where
  parseJSON = Aeson.withObject "NativePureSelectPlanV2" $ \objectValue ->
    NativePureSelectPlanV2
      <$> objectValue .: "guard"
      <*> objectValue .: "variants"
      <*> objectValue .: "rejoin"

instance ToJSON NativePureProgramV2 where
  toJSON program =
    Aeson.object
      [ "schema" .= nativePureStaticProgramV2Schema
      , "program_id" .= program.nativePureProgramV2Id
      , "program_identity" .= program.nativePureProgramV2Identity
      , "native_pure_plan_digest" .= program.nativePureProgramV2PlanDigest
      , "units" .= program.nativePureProgramV2Units
      , "edges" .= program.nativePureProgramV2Edges
      , "selects" .= program.nativePureProgramV2Selects
      ]

instance FromJSON NativePureProgramV2 where
  parseJSON = Aeson.withObject "NativePureProgramV2" $ \objectValue -> do
    schema <- objectValue .: "schema"
    unless (schema == nativePureStaticProgramV2Schema) $
      fail ("unsupported NativePure static program schema: " <> T.unpack schema)
    NativePureProgramV2
      <$> objectValue .: "program_id"
      <*> objectValue .: "program_identity"
      <*> objectValue .: "native_pure_plan_digest"
      <*> objectValue .: "units"
      <*> objectValue .: "edges"
      <*> objectValue .: "selects"

instance ToJSON NativePureV2Status where
  toJSON = Aeson.String . renderV2Status

instance FromJSON NativePureV2Status where
  parseJSON = Aeson.withText "NativePureV2Status" $ \value ->
    maybe (fail ("invalid NativePure v2 status: " <> T.unpack value)) pure (parseV2Status value)

renderV2Status :: NativePureV2Status -> Text
renderV2Status = \case
  NativePureV2Pending -> "pending"
  NativePureV2RunningEffect -> "running_effect"
  NativePureV2Completed -> "completed"
  NativePureV2Failed -> "failed"
  NativePureV2Skipped -> "skipped"

parseV2Status :: Text -> Maybe NativePureV2Status
parseV2Status = \case
  "pending" -> Just NativePureV2Pending
  "running_effect" -> Just NativePureV2RunningEffect
  "completed" -> Just NativePureV2Completed
  "failed" -> Just NativePureV2Failed
  "skipped" -> Just NativePureV2Skipped
  _ -> Nothing

instance ToJSON NativePureEngineStateV2 where
  toJSON state =
    Aeson.object
      [ "schema" .= nativePureEngineStateV2Schema
      , "program_identity" .= state.nativePureEngineStateV2ProgramIdentity
      , "checkpoint_sequence" .= state.nativePureEngineStateV2CheckpointSequence
      , "next_effect_sequence" .= state.nativePureEngineStateV2NextEffectSequence
      , "awaiting_checkpoint" .= state.nativePureEngineStateV2AwaitingCheckpoint
      , "terminal" .= renderEngineTerminalState state.nativePureEngineStateV2Terminal
      , "statuses" .= state.nativePureEngineStateV2Statuses
      , "values" .= state.nativePureEngineStateV2Values
      , "effect_sequences" .= state.nativePureEngineStateV2EffectSequences
      , "selected_tags"
          .= [ Aeson.object ["guard" .= guardId, "tag" .= label]
             | (guardId, label) <- Map.toAscList state.nativePureEngineStateV2SelectedTags
             ]
      , "failure" .= state.nativePureEngineStateV2Failure
      ]

instance FromJSON NativePureEngineStateV2 where
  parseJSON = Aeson.withObject "NativePureEngineStateV2" $ \objectValue -> do
    schema <- objectValue .: "schema"
    unless (schema == nativePureEngineStateV2Schema) $
      fail ("unsupported NativePure engine-state schema: " <> T.unpack schema)
    terminalText <- objectValue .: "terminal"
    terminal <- either (fail . T.unpack) pure (parseEngineTerminalState terminalText)
    selectedRows <- objectValue .: "selected_tags"
    selectedTags <- Map.fromList <$> traverse parseSelectedTag selectedRows
    NativePureEngineStateV2
      <$> objectValue .: "program_identity"
      <*> objectValue .: "checkpoint_sequence"
      <*> objectValue .: "next_effect_sequence"
      <*> objectValue .: "awaiting_checkpoint"
      <*> pure terminal
      <*> objectValue .: "statuses"
      <*> objectValue .: "values"
      <*> objectValue .: "effect_sequences"
      <*> pure selectedTags
      <*> objectValue .:? "failure"
    where
      parseSelectedTag = Aeson.withObject "NativePureSelectedTag" $ \row ->
        (,) <$> row .: "guard" <*> row .: "tag"

data NativePureV2HostCommand
  = NativePureV2HostStart !Text
  | NativePureV2HostRestore !Text !NativePureEngineStateV2
  | NativePureV2HostEffectCompleted !Text !Word64 !Word32 !NativePureV2EffectCompletion
  | NativePureV2HostCheckpointCommitted !Text !Word64
  | NativePureV2HostCancel !Text !Text
  | NativePureV2HostShutdown !Text
  deriving stock (Eq, Show, Generic)

data NativePureV2EngineEvent
  = NativePureV2EngineHello !Text !Text
  | NativePureV2EngineCheckpoint !Text !NativePureEngineStateV2
  | NativePureV2EngineEffectRequested !Text !Word64 !Word32 !Text !(Map Text Aeson.Value)
  | NativePureV2EngineTerminal !Text !EngineTerminalState
  | NativePureV2EngineProtocolError !(Maybe Text) !Text
  deriving stock (Eq, Show, Generic)

instance ToJSON NativePureV2HostCommand where
  toJSON = \case
    NativePureV2HostStart runId -> v2Envelope "start" runId []
    NativePureV2HostRestore runId state -> v2Envelope "restore" runId ["state" .= state]
    NativePureV2HostEffectCompleted runId sequenceNumber unitId completion ->
      let (outcome, value, message) = case completion of
            NativePureV2EffectSucceeded result -> ("success" :: Text, Just result, Nothing)
            NativePureV2EffectSkipped -> ("skipped", Nothing, Nothing)
            NativePureV2EffectFailed reason -> ("failure", Nothing, Just reason)
       in v2Envelope
            "effect_completed"
            runId
            [ "sequence" .= sequenceNumber
            , "unit_id" .= unitId
            , "outcome" .= outcome
            , "value" .= value
            , "message" .= message
            ]
    NativePureV2HostCheckpointCommitted runId sequenceNumber ->
      v2Envelope "checkpoint_committed" runId ["sequence" .= sequenceNumber]
    NativePureV2HostCancel runId reason -> v2Envelope "cancel" runId ["reason" .= reason]
    NativePureV2HostShutdown runId -> v2Envelope "shutdown" runId []

instance FromJSON NativePureV2HostCommand where
  parseJSON = Aeson.withObject "NativePureV2HostCommand" $ \objectValue -> do
    requireV2Protocol objectValue
    commandType <- objectValue .: "type"
    runId <- objectValue .: "run_id"
    case commandType :: Text of
      "start" -> pure (NativePureV2HostStart runId)
      "restore" -> NativePureV2HostRestore runId <$> objectValue .: "state"
      "effect_completed" -> do
        sequenceNumber <- objectValue .: "sequence"
        unitId <- objectValue .: "unit_id"
        outcome <- objectValue .: "outcome"
        value <- objectValue .:? "value"
        message <- objectValue .:? "message"
        completion <- parseV2Completion outcome value message
        pure (NativePureV2HostEffectCompleted runId sequenceNumber unitId completion)
      "checkpoint_committed" ->
        NativePureV2HostCheckpointCommitted runId <$> objectValue .: "sequence"
      "cancel" -> NativePureV2HostCancel runId <$> objectValue .: "reason"
      "shutdown" -> pure (NativePureV2HostShutdown runId)
      _ -> fail ("unknown NativePure v2 host command: " <> T.unpack commandType)

instance ToJSON NativePureV2EngineEvent where
  toJSON = \case
    NativePureV2EngineHello identity abi ->
      Aeson.object
        [ "type" .= ("hello" :: Text)
        , "protocol" .= nativePureHostProcessV2Protocol
        , "program_identity" .= identity
        , "engine_abi" .= abi
        ]
    NativePureV2EngineCheckpoint runId state -> v2Envelope "checkpoint" runId ["state" .= state]
    NativePureV2EngineEffectRequested runId sequenceNumber unitId unitRef inputs ->
      v2Envelope
        "effect_requested"
        runId
        [ "sequence" .= sequenceNumber
        , "unit_id" .= unitId
        , "unit_ref" .= unitRef
        , "inputs" .= inputs
        ]
    NativePureV2EngineTerminal runId terminal ->
      v2Envelope "terminal" runId ["terminal" .= renderEngineTerminalState terminal]
    NativePureV2EngineProtocolError runId message ->
      Aeson.object
        [ "type" .= ("protocol_error" :: Text)
        , "protocol" .= nativePureHostProcessV2Protocol
        , "run_id" .= runId
        , "message" .= message
        ]

instance FromJSON NativePureV2EngineEvent where
  parseJSON = Aeson.withObject "NativePureV2EngineEvent" $ \objectValue -> do
    requireV2Protocol objectValue
    eventType <- objectValue .: "type"
    case eventType :: Text of
      "hello" ->
        NativePureV2EngineHello <$> objectValue .: "program_identity" <*> objectValue .: "engine_abi"
      "checkpoint" ->
        NativePureV2EngineCheckpoint <$> objectValue .: "run_id" <*> objectValue .: "state"
      "effect_requested" ->
        NativePureV2EngineEffectRequested
          <$> objectValue .: "run_id"
          <*> objectValue .: "sequence"
          <*> objectValue .: "unit_id"
          <*> objectValue .: "unit_ref"
          <*> objectValue .: "inputs"
      "terminal" -> do
        runId <- objectValue .: "run_id"
        terminalText <- objectValue .: "terminal"
        terminal <- either (fail . T.unpack) pure (parseEngineTerminalState terminalText)
        pure (NativePureV2EngineTerminal runId terminal)
      "protocol_error" ->
        NativePureV2EngineProtocolError <$> objectValue .:? "run_id" <*> objectValue .: "message"
      _ -> fail ("unknown NativePure v2 engine event: " <> T.unpack eventType)

encodeNativePureV2HostCommand
  :: NativePureV2HostCommand -> Either NativePureProgramV2Error BS.ByteString
encodeNativePureV2HostCommand = encodeBounded

decodeNativePureV2HostCommand
  :: BS.ByteString -> Either NativePureProgramV2Error NativePureV2HostCommand
decodeNativePureV2HostCommand = decodeBounded

encodeNativePureV2EngineEvent
  :: NativePureV2EngineEvent -> Either NativePureProgramV2Error BS.ByteString
encodeNativePureV2EngineEvent = encodeBounded

decodeNativePureV2EngineEvent
  :: BS.ByteString -> Either NativePureProgramV2Error NativePureV2EngineEvent
decodeNativePureV2EngineEvent = decodeBounded

encodeBounded :: ToJSON value => value -> Either NativePureProgramV2Error BS.ByteString
encodeBounded value =
  let bytes = BSL.toStrict (BSL.snoc (Aeson.encode value) 10)
   in if BS.length bytes <= nativePureHostedMessageCeiling
        then Right bytes
        else Left (NativePureProgramV2MessageTooLarge (BS.length bytes))

decodeBounded :: FromJSON value => BS.ByteString -> Either NativePureProgramV2Error value
decodeBounded bytes
  | BS.length bytes > nativePureHostedMessageCeiling =
      Left (NativePureProgramV2MessageTooLarge (BS.length bytes))
  | otherwise =
      case Aeson.eitherDecodeStrict' bytes of
        Left reason -> Left (NativePureProgramV2Protocol (T.pack reason))
        Right value -> Right value

v2Envelope :: Text -> Text -> [AesonTypes.Pair] -> Aeson.Value
v2Envelope messageType runId fields =
  Aeson.object
    (["type" .= messageType, "protocol" .= nativePureHostProcessV2Protocol, "run_id" .= runId] <> fields)

requireV2Protocol :: Aeson.Object -> AesonTypes.Parser ()
requireV2Protocol objectValue = do
  protocol <- objectValue .: "protocol"
  unless (protocol == nativePureHostProcessV2Protocol) $
    fail ("unsupported NativePure hosted protocol: " <> T.unpack protocol)

parseV2Completion
  :: Text
  -> Maybe Aeson.Value
  -> Maybe Text
  -> AesonTypes.Parser NativePureV2EffectCompletion
parseV2Completion outcome value message = case outcome of
  "success" ->
    maybe
      (fail "successful NativePure v2 effect completion requires a value")
      (pure . NativePureV2EffectSucceeded)
      value
  "skipped"
    | isJust value -> fail "skipped NativePure v2 effect completion must not carry a value"
    | otherwise -> pure NativePureV2EffectSkipped
  "failure"
    | isJust value -> fail "failed NativePure v2 effect completion must not carry a value"
    | otherwise -> pure (NativePureV2EffectFailed (fromMaybe "effect failed" message))
  _ -> fail ("unknown NativePure v2 effect outcome: " <> T.unpack outcome)
