{- |
Module      : Platform.DurableTask.TypesSpec
Description : Tests for Platform.DurableTask.Types.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Platform.DurableTask.TypesSpec (spec) where

import Data.List (nub)
import Data.Maybe (isNothing)
import Test.Hspec
import Test.QuickCheck

import Platform.DurableTask.Types

genRunOutcome :: Gen RunOutcome
genRunOutcome =
  elements
    [ OutcomeCompleted
    , OutcomeFailed
    , OutcomeCancelled
    , OutcomeTimedOut
    , OutcomeShutdown
    ]

genRunStatus :: Gen RunStatus
genRunStatus = arbitraryBoundedEnum

genTriggerSource :: Gen TriggerSource
genTriggerSource = arbitraryBoundedEnum

spec :: Spec
spec = do
  describe "runOutcomeToFinalStatus" $ do
    it "OutcomeShutdown maps to Nothing" $
      runOutcomeToFinalStatus OutcomeShutdown `shouldBe` Nothing

    it "non-shutdown outcomes always map to Just"
      . forAll (elements [OutcomeCompleted, OutcomeFailed, OutcomeCancelled, OutcomeTimedOut])
      $ \outcome -> case runOutcomeToFinalStatus outcome of
        Just _ -> True
        Nothing -> False

    it "is total: shutdown is exactly the outcome that produces Nothing"
      . forAll genRunOutcome
      $ \outcome ->
        isNothing (runOutcomeToFinalStatus outcome) === (outcome == OutcomeShutdown)

  describe "RunStatus text roundtrip" $ do
    it "runStatusFromText . runStatusToText is identity"
      . forAll genRunStatus
      $ \status ->
        runStatusFromText (runStatusToText status) === Just status

    it "all statuses have unique text representations" $ do
      let texts = fmap runStatusToText [minBound .. maxBound :: RunStatus]
      texts `shouldBe` nub texts

  describe "TriggerSource text roundtrip" $ do
    it "triggerSourceFromText . triggerSourceToText is identity"
      . forAll genTriggerSource
      $ \src ->
        triggerSourceFromText (triggerSourceToText src) === Just src
