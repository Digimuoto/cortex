{- |
Module      : Cortex.Wire.NativePureSchedulerSpec
Description : NativePure v2 scheduler, checkpoint, and select policy tests.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

These specs pin the additive v2 profile without changing any v1 scheduler or
host-process interface. In particular, every pure transition is synchronous
and checkpointed; only effect units can produce host work.
-}
module Cortex.Wire.NativePureSchedulerSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.List qualified as List
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word32, Word64)
import Test.Hspec

import Cortex.Wire
  ( CircuitNodeRef (..)
  , EngineTerminalState (..)
  , NativePureEngineStateV2 (..)
  , NativePurePlan (..)
  , NativePureProgramV2 (..)
  , NativePureProgramV2Edge (..)
  , NativePureProgramV2Error (..)
  , NativePureProgramV2Unit (..)
  , NativePureProgramV2UnitKind (..)
  , NativePureSelectPlanV2 (..)
  , NativePureSelectV2 (..)
  , NativePureV2Action (..)
  , NativePureV2EffectCompletion (..)
  , NativePureV2EngineEvent (..)
  , NativePureV2HostCommand (..)
  , NativePureV2Result (..)
  , NativePureV2Status (..)
  , NativePureV2Transition (..)
  , RealizationArtifact (..)
  , RealizationRuntimeKind (..)
  , RealizationRuntimeUnit (..)
  , acknowledgeNativePureCheckpointV2
  , completeNativePureEffectV2
  , decodeNativePureV2EngineEvent
  , decodeNativePureV2HostCommand
  , driveNativePureV2
  , encodeNativePureV2EngineEvent
  , encodeNativePureV2HostCommand
  , initialNativePureEngineStateV2
  , nativePureEngineStateV2Schema
  , nativePureEngineV2Abi
  , nativePureHostProcessV2Protocol
  , nativePureHostedLinuxV2Target
  , nativePureHostedMessageCeiling
  , nativePureStaticProgramV2Schema
  , restoreNativePureEngineStateV2
  , specializeNativePureProgramV2
  , validateNativePureProgramV2
  )

spec :: Spec
spec = describe "NativePure v2 scheduler" $ do
  it "specializes witnessed quotient units and select structure without changing the plan" $ do
    program <- requireRight (specializeNativePureProgramV2 quotientPlan [authoredSelect])
    fmap (.nativePureProgramV2UnitKind) program.nativePureProgramV2Units
      `shouldBe` [NativePureV2SelectGuard, NativePureV2Effect, NativePureV2PureRegion, NativePureV2Rejoin]
    program.nativePureProgramV2Edges
      `shouldBe` [ NativePureProgramV2Edge 0 1
                 , NativePureProgramV2Edge 0 2
                 , NativePureProgramV2Edge 1 3
                 , NativePureProgramV2Edge 2 3
                 ]
    program.nativePureProgramV2Selects
      `shouldBe` [NativePureSelectPlanV2 0 (Map.fromList [("accepted", [1]), ("rejected", [2])]) 3]
    quotientPlan.nativePurePlanRealization.realizationArtifactSourceToRuntime
      `shouldBe` Map.fromList
        [ (CircuitNodeRef "classify", "00-guard")
        , (CircuitNodeRef "accepted-effect", "01-accepted")
        , (CircuitNodeRef "rejected-pure", "02-rejected")
        , (CircuitNodeRef "join", "03-rejoin")
        ]

  it "checkpoints effect to pure to effect and never requests host work for pure units" $ do
    let program = effectPureEffectProgram
        initial = initialNativePureEngineStateV2 program
    initial.nativePureEngineStateV2CheckpointSequence `shouldBe` 1
    driveNativePureV2 pureRunner program initial
      `shouldSatisfy` hasCheckpoint 1

    admitted <- requireRight (acknowledgeNativePureCheckpointV2 program 1 initial)
    firstEffect <- requireRight (driveNativePureV2 pureRunner program admitted)
    firstEffect.nativePureV2TransitionAction
      `shouldBe` NativePureV2EffectRequested 1 0 "source" Map.empty

    effectCheckpoint <-
      requireRight
        ( completeNativePureEffectV2
            program
            1
            0
            (NativePureV2EffectSucceeded (Aeson.Number 7))
            firstEffect.nativePureV2TransitionState
        )
    driveNativePureV2 pureRunner program effectCheckpoint
      `shouldSatisfy` hasCheckpoint 2

    afterEffect <- requireRight (acknowledgeNativePureCheckpointV2 program 2 effectCheckpoint)
    pureCheckpoint <- requireRight (driveNativePureV2 pureRunner program afterEffect)
    pureCheckpoint.nativePureV2TransitionAction `shouldSatisfy` \case
      NativePureV2CheckpointRequired state ->
        state.nativePureEngineStateV2CheckpointSequence == 3
          && state.nativePureEngineStateV2Statuses
            == [NativePureV2Completed, NativePureV2Completed, NativePureV2Pending]
      _ -> False
    driveNativePureV2 pureRunner program pureCheckpoint.nativePureV2TransitionState
      `shouldSatisfy` hasCheckpoint 3

    afterPure <-
      requireRight
        ( acknowledgeNativePureCheckpointV2
            program
            3
            pureCheckpoint.nativePureV2TransitionState
        )
    secondEffect <- requireRight (driveNativePureV2 pureRunner program afterPure)
    secondEffect.nativePureV2TransitionAction
      `shouldBe` NativePureV2EffectRequested 2 2 "sink" (Map.singleton "pure" (Aeson.String "pure-result"))

  it "persists an n-way selection, skips latent work, rejoins, and restores the tag" $ do
    let program = selectProgram
        initial = initialNativePureEngineStateV2 program
    admitted <- requireRight (acknowledgeNativePureCheckpointV2 program 1 initial)
    selected <- requireRight (driveNativePureV2 selectRunner program admitted)
    let selectedState = selected.nativePureV2TransitionState
    selected.nativePureV2TransitionAction `shouldSatisfy` \case
      NativePureV2CheckpointRequired _ -> True
      _ -> False
    selectedState.nativePureEngineStateV2SelectedTags `shouldBe` Map.singleton 0 "rejected"
    selectedState.nativePureEngineStateV2Statuses
      `shouldBe` [ NativePureV2Completed
                 , NativePureV2Skipped
                 , NativePureV2Skipped
                 , NativePureV2Pending
                 , NativePureV2Pending
                 , NativePureV2Pending
                 ]

    afterGuard <- requireRight (acknowledgeNativePureCheckpointV2 program 2 selectedState)
    branchPure <- requireRight (driveNativePureV2 selectRunner program afterGuard)
    branchPure.nativePureV2TransitionAction `shouldSatisfy` isCheckpoint
    afterBranch <-
      requireRight
        ( acknowledgeNativePureCheckpointV2
            program
            3
            branchPure.nativePureV2TransitionState
        )
    rejoined <- requireRight (driveNativePureV2 selectRunner program afterBranch)
    rejoined.nativePureV2TransitionAction `shouldSatisfy` isCheckpoint

    restored <-
      requireRight (restoreNativePureEngineStateV2 program rejoined.nativePureV2TransitionState)
    restored.nativePureEngineStateV2SelectedTags `shouldBe` Map.singleton 0 "rejected"
    restored.nativePureEngineStateV2Statuses List.!? 1 `shouldBe` Just NativePureV2Skipped
    restored.nativePureEngineStateV2Values List.!? 4
      `shouldBe` Just (Just (Aeson.String "rejected-value"))
    afterRestore <- requireRight (acknowledgeNativePureCheckpointV2 program 4 restored)
    downstream <- requireRight (driveNativePureV2 selectRunner program afterRestore)
    downstream.nativePureV2TransitionAction
      `shouldBe` NativePureV2EffectRequested
        1
        5
        "downstream"
        (Map.singleton "rejoin" (Aeson.String "rejected-value"))

  it "checkpoints deterministic pure and select failures" $ do
    let program = selectProgram
        initial = initialNativePureEngineStateV2 program
    admitted <- requireRight (acknowledgeNativePureCheckpointV2 program 1 initial)
    failed <-
      requireRight
        ( driveNativePureV2
            (\_unit _inputs -> Right (NativePureV2Result Aeson.Null (Just "unknown")))
            program
            admitted
        )
    let failedState = failed.nativePureV2TransitionState
    failed.nativePureV2TransitionAction `shouldSatisfy` \case
      NativePureV2CheckpointRequired checkpoint ->
        checkpoint.nativePureEngineStateV2CheckpointSequence == 2
      _ -> False
    failedState.nativePureEngineStateV2Terminal `shouldBe` EngineTerminalFailed
    failedState.nativePureEngineStateV2Failure `shouldBe` Just "guard returned an undeclared tag"
    failedState.nativePureEngineStateV2Statuses List.!? 0 `shouldBe` Just NativePureV2Failed

  it "rejects malformed quotient and select topology before execution" $ do
    let cyclic =
          effectPureEffectProgram
            { nativePureProgramV2Edges =
                NativePureProgramV2Edge 1 0
                  : effectPureEffectProgram.nativePureProgramV2Edges
            }
        disconnected =
          selectProgram
            { nativePureProgramV2Edges =
                filter
                  (/= NativePureProgramV2Edge 3 4)
                  selectProgram.nativePureProgramV2Edges
            }
    validateNativePureProgramV2 cyclic `shouldSatisfy` \case
      Left NativePureProgramV2State {} -> True
      _ -> False
    validateNativePureProgramV2 disconnected `shouldSatisfy` \case
      Left NativePureProgramV2InvalidSelect {} -> True
      _ -> False

  it "round-trips v2 hosted messages and enforces the 2 MiB ceiling" $ do
    nativePureStaticProgramV2Schema `shouldBe` "cortex.wire.static-program/v2"
    nativePureEngineV2Abi `shouldBe` "cortex.wire.engine/v2"
    nativePureEngineStateV2Schema `shouldBe` "cortex.wire.engine-state/v2"
    nativePureHostProcessV2Protocol `shouldBe` "cortex.wire.host-process/v2"
    nativePureHostedLinuxV2Target `shouldBe` "cortex.wire.target/x86_64-linux-v2"
    let command = NativePureV2HostCheckpointCommitted "run-1" 17
        event = NativePureV2EngineCheckpoint "run-1" (initialNativePureEngineStateV2 effectPureEffectProgram)
    (encodeNativePureV2HostCommand command >>= decodeNativePureV2HostCommand) `shouldBe` Right command
    (encodeNativePureV2EngineEvent event >>= decodeNativePureV2EngineEvent) `shouldBe` Right event
    let oversized =
          NativePureV2EngineProtocolError
            Nothing
            (T.replicate (nativePureHostedMessageCeiling + 1) "x")
    encodeNativePureV2EngineEvent oversized `shouldSatisfy` \case
      Left NativePureProgramV2MessageTooLarge {} -> True
      _ -> False

effectPureEffectProgram :: NativePureProgramV2
effectPureEffectProgram =
  mkProgram
    [ unit 0 "source" NativePureV2Effect
    , unit 1 "pure" NativePureV2PureRegion
    , unit 2 "sink" NativePureV2Effect
    ]
    [NativePureProgramV2Edge 0 1, NativePureProgramV2Edge 1 2]
    []

selectProgram :: NativePureProgramV2
selectProgram =
  mkProgram
    [ unit 0 "guard" NativePureV2SelectGuard
    , unit 1 "accepted-effect" NativePureV2Effect
    , unit 2 "unused-third-arm" NativePureV2PureRegion
    , unit 3 "rejected-pure" NativePureV2PureRegion
    , unit 4 "rejoin" NativePureV2Rejoin
    , unit 5 "downstream" NativePureV2Effect
    ]
    [ NativePureProgramV2Edge 0 1
    , NativePureProgramV2Edge 0 2
    , NativePureProgramV2Edge 0 3
    , NativePureProgramV2Edge 1 4
    , NativePureProgramV2Edge 2 4
    , NativePureProgramV2Edge 3 4
    , NativePureProgramV2Edge 4 5
    ]
    [ NativePureSelectPlanV2
        0
        (Map.fromList [("accepted", [1]), ("deferred", [2]), ("rejected", [3])])
        4
    ]

mkProgram
  :: [NativePureProgramV2Unit]
  -> [NativePureProgramV2Edge]
  -> [NativePureSelectPlanV2]
  -> NativePureProgramV2
mkProgram units edges selects =
  NativePureProgramV2
    { nativePureProgramV2Id = "program"
    , nativePureProgramV2Identity = "identity"
    , nativePureProgramV2PlanDigest = "plan-digest"
    , nativePureProgramV2Units = units
    , nativePureProgramV2Edges = edges
    , nativePureProgramV2Selects = selects
    }

unit :: Word32 -> T.Text -> NativePureProgramV2UnitKind -> NativePureProgramV2Unit
unit unitId unitRef kind =
  NativePureProgramV2Unit unitId unitRef kind [CircuitNodeRef unitRef]

pureRunner :: NativePureProgramV2Unit -> Map T.Text Aeson.Value -> Either T.Text NativePureV2Result
pureRunner unitValue inputs = case unitValue.nativePureProgramV2UnitRef of
  "pure" ->
    if Map.lookup "source" inputs == Just (Aeson.Number 7)
      then Right (NativePureV2Result (Aeson.String "pure-result") Nothing)
      else Left "pure input was not restored from its predecessor"
  ref -> Left ("unexpected pure runner call for " <> ref)

selectRunner
  :: NativePureProgramV2Unit -> Map T.Text Aeson.Value -> Either T.Text NativePureV2Result
selectRunner unitValue _inputs = case unitValue.nativePureProgramV2UnitRef of
  "guard" -> Right (NativePureV2Result (Aeson.String "decision") (Just "rejected"))
  "rejected-pure" -> Right (NativePureV2Result (Aeson.String "rejected-value") Nothing)
  ref -> Left ("unexpected pure runner call for " <> ref)

hasCheckpoint :: Word64 -> Either NativePureProgramV2Error NativePureV2Transition -> Bool
hasCheckpoint sequenceNumber = \case
  Right transitionValue -> case transitionValue.nativePureV2TransitionAction of
    NativePureV2CheckpointRequired state ->
      state.nativePureEngineStateV2CheckpointSequence == sequenceNumber
    _ -> False
  Left _ -> False

isCheckpoint :: NativePureV2Action -> Bool
isCheckpoint = \case
  NativePureV2CheckpointRequired _ -> True
  _ -> False

requireRight :: (HasCallStack, Show error) => Either error value -> IO value
requireRight = \case
  Left err -> do
    expectationFailure ("expected Right, got " <> show err)
    fail "unreachable after expectationFailure"
  Right value -> pure value

quotientPlan :: NativePurePlan
quotientPlan =
  NativePurePlan
    { nativePurePlanProgramId = "select-program"
    , nativePurePlanProgramIdentity = "identity"
    , nativePurePlanInputDigest = "input-digest"
    , nativePurePlanRealization =
        RealizationArtifact
          { realizationArtifactReferentIdentity = "identity"
          , realizationArtifactInputDigest = "input-digest"
          , realizationArtifactSourceToRuntime =
              Map.fromList
                [ (CircuitNodeRef "classify", "00-guard")
                , (CircuitNodeRef "accepted-effect", "01-accepted")
                , (CircuitNodeRef "rejected-pure", "02-rejected")
                , (CircuitNodeRef "join", "03-rejoin")
                ]
          , realizationArtifactRuntimeUnits =
              Map.fromList
                [ runtimeUnit "00-guard" RealizationPureRegion "classify"
                , runtimeUnit "01-accepted" RealizationPreservedNode "accepted-effect"
                , runtimeUnit "02-rejected" RealizationPureRegion "rejected-pure"
                , runtimeUnit "03-rejoin" RealizationPreservedNode "join"
                ]
          , realizationArtifactRuntimeEdges =
              Set.fromList
                [ ("00-guard", "01-accepted")
                , ("00-guard", "02-rejected")
                , ("01-accepted", "03-rejoin")
                , ("02-rejected", "03-rejoin")
                ]
          , realizationArtifactDigest = "artifact-digest"
          }
    , nativePurePlanRegions = []
    , nativePurePlanDigest = "plan-digest"
    }

runtimeUnit :: T.Text -> RealizationRuntimeKind -> T.Text -> (T.Text, RealizationRuntimeUnit)
runtimeUnit runtimeRef kind source =
  ( runtimeRef
  , RealizationRuntimeUnit runtimeRef kind [CircuitNodeRef source]
  )

authoredSelect :: NativePureSelectV2
authoredSelect =
  NativePureSelectV2
    { nativePureSelectV2GuardRef = "00-guard"
    , nativePureSelectV2Variants =
        Map.fromList [("accepted", ["01-accepted"]), ("rejected", ["02-rejected"])]
    , nativePureSelectV2RejoinRef = "03-rejoin"
    }
