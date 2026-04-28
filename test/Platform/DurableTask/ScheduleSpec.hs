{-# LANGUAGE OverloadedStrings #-}

module Platform.DurableTask.ScheduleSpec (spec) where

import Data.Time (Day (ModifiedJulianDay), UTCTime (..), fromGregorian, secondsToDiffTime)
import Test.Hspec
import Test.QuickCheck

import Platform.DurableTask.Schedule
  ( ExecutionOrigin (..)
  , ScheduleConfig (..)
  , ScheduleDecision (..)
  , ScheduleKind (..)
  , decideScheduleAction
  )
import Platform.DurableTask.Types (RunOutcome (..))

spec :: Spec
spec = do
  describe "decideScheduleAction" $ do
    it "does not finalize schedule state for shutdown outcomes" $ do
      decideScheduleAction testConfig ScheduledExecution OneOff testTime OutcomeShutdown
        `shouldBe` NoScheduleChange

    it "records manual cron outcomes without advancing cron state" $ do
      decideScheduleAction testConfig OtherExecution (Recurring "0 * * * *") testTime OutcomeCompleted
        `shouldBe` RecordOutcomeOnly

    it "completes one-off work only on explicit success" $ do
      decideScheduleAction testConfig ScheduledExecution OneOff testTime OutcomeCompleted
        `shouldBe` CompleteOneOff

    it "records manual one-off failures without auto-restoring the task" $ do
      decideScheduleAction testConfig OtherExecution OneOff testTime OutcomeFailed
        `shouldBe` RecordOutcomeOnly

    it "restores one-off work using the configured failure backoff" $ do
      decideScheduleAction testConfig ScheduledExecution OneOff testTime OutcomeFailed
        `shouldBe` RestoreOneOffAt testTimePlus300

    it "treats zero-backoff scheduled one-off failure as immediate re-visibility" $ do
      decideScheduleAction immediateRetryConfig ScheduledExecution OneOff testTime OutcomeCancelled
        `shouldBe` RestoreOneOffAt testTime

    it "treats scheduled timeouts as retryable one-off terminal outcomes" $ do
      decideScheduleAction testConfig ScheduledExecution OneOff testTime OutcomeTimedOut
        `shouldBe` RestoreOneOffAt testTimePlus300

    it "backs recurring work off when the cron expression is invalid" $ do
      decideScheduleAction
        testConfig
        ScheduledExecution
        (Recurring "not a cron")
        testTime
        OutcomeCompleted
        `shouldBe` RestoreRecurringAfterCronErrorAt testTimePlus300

    it "advances scheduled recurring work even after failed outcomes" $ do
      decideScheduleAction testConfig ScheduledExecution (Recurring "*/5 * * * *") testTime OutcomeFailed
        `shouldBe` AdvanceRecurringTo recurringNextRunAt

    it "advances scheduled recurring work even after timed out outcomes" $ do
      decideScheduleAction
        testConfig
        ScheduledExecution
        (Recurring "*/5 * * * *")
        testTime
        OutcomeTimedOut
        `shouldBe` AdvanceRecurringTo recurringNextRunAt

  describe "decideScheduleAction properties" $ do
    it "OutcomeShutdown always produces NoScheduleChange regardless of other arguments"
      . forAll genScheduleConfig
      $ \config ->
        forAll (elements [ScheduledExecution, OtherExecution]) $ \origin ->
          forAll genScheduleKind $ \kind ->
            forAll genUTCTime $ \time ->
              decideScheduleAction config origin kind time OutcomeShutdown === NoScheduleChange

    it "manual or retry triggers never advance cron state for recurring tasks"
      . forAll genScheduleConfig
      $ \config ->
        forAll (elements validCronExprs) $ \kind ->
          forAll genNonShutdownOutcome $ \outcome ->
            forAll genUTCTime $ \time ->
              decideScheduleAction config OtherExecution kind time outcome === RecordOutcomeOnly

    it "scheduled recurring tasks with valid cron always advance to next fire time"
      . forAll genScheduleConfig
      $ \config ->
        forAll (elements validCronExprs) $ \kind ->
          forAll genNonShutdownOutcome $ \outcome ->
            forAll genUTCTime $ \time ->
              case decideScheduleAction config ScheduledExecution kind time outcome of
                AdvanceRecurringTo _ -> property True
                other -> counterexample (show other) False

    it "manual or retry one-off failures never auto-restore in the background"
      . forAll genScheduleConfig
      $ \config ->
        forAll (elements [OutcomeFailed, OutcomeCancelled, OutcomeTimedOut]) $ \outcome ->
          forAll genUTCTime $ \time ->
            decideScheduleAction config OtherExecution OneOff time outcome === RecordOutcomeOnly

    it "scheduled recurring tasks never produce RecordOutcomeOnly"
      . forAll genScheduleConfig
      $ \config ->
        forAll (elements validCronExprs) $ \kind ->
          forAll genRunOutcome $ \outcome ->
            forAll genUTCTime $ \time ->
              decideScheduleAction config ScheduledExecution kind time outcome /= RecordOutcomeOnly

testConfig :: ScheduleConfig
testConfig =
  ScheduleConfig
    { scOneOffFailureBackoff = 300
    , scCronParseBackoff = 300
    }

immediateRetryConfig :: ScheduleConfig
immediateRetryConfig =
  ScheduleConfig
    { scOneOffFailureBackoff = 0
    , scCronParseBackoff = 300
    }

testTime :: UTCTime
testTime =
  UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)

testTimePlus300 :: UTCTime
testTimePlus300 =
  UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 300)

recurringNextRunAt :: UTCTime
recurringNextRunAt = testTimePlus300

-- ============================================================================
-- Generators
-- ============================================================================

genUTCTime :: Gen UTCTime
genUTCTime = do
  day <- ModifiedJulianDay <$> choose (50000, 60000)
  secs <- secondsToDiffTime <$> choose (0, 86399)
  pure (UTCTime day secs)

genRunOutcome :: Gen RunOutcome
genRunOutcome =
  elements
    [ OutcomeCompleted
    , OutcomeFailed
    , OutcomeCancelled
    , OutcomeTimedOut
    , OutcomeShutdown
    ]

genNonShutdownOutcome :: Gen RunOutcome
genNonShutdownOutcome =
  elements [OutcomeCompleted, OutcomeFailed, OutcomeCancelled, OutcomeTimedOut]

genScheduleConfig :: Gen ScheduleConfig
genScheduleConfig = do
  backoff <- fromIntegral <$> choose (0 :: Int, 3600)
  pure ScheduleConfig {scOneOffFailureBackoff = backoff, scCronParseBackoff = backoff}

genScheduleKind :: Gen ScheduleKind
genScheduleKind =
  elements
    [ OneOff
    , Recurring "* * * * *"
    , Recurring "0 9 * * 1-5"
    , Recurring "*/30 * * * *"
    ]

validCronExprs :: [ScheduleKind]
validCronExprs =
  [ Recurring "* * * * *"
  , Recurring "0 9 * * *"
  , Recurring "*/5 * * * *"
  ]
