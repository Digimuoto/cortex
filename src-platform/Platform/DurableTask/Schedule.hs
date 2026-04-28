{-# LANGUAGE OverloadedRecordDot #-}

module Platform.DurableTask.Schedule
  ( ScheduleKind (..)
  , ExecutionOrigin (..)
  , ScheduleConfig (..)
  , ScheduleDecision (..)
  , decideScheduleAction
  )
where

import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)

import Platform.DurableTask.Cron qualified as Cron
import Platform.DurableTask.Types (RunOutcome (..))

data ScheduleKind
  = OneOff
  | Recurring Text
  deriving stock (Eq, Show)

data ExecutionOrigin
  = ScheduledExecution
  | OtherExecution
  deriving stock (Eq, Show)

data ScheduleConfig = ScheduleConfig
  { scOneOffFailureBackoff :: NominalDiffTime
  , scCronParseBackoff :: NominalDiffTime
  }
  deriving stock (Eq, Show)

data ScheduleDecision
  = NoScheduleChange
  | RecordOutcomeOnly
  | CompleteOneOff
  | RestoreOneOffAt UTCTime
  | AdvanceRecurringTo UTCTime
  | RestoreRecurringAfterCronErrorAt UTCTime
  deriving stock (Eq, Show)

{- | Shared schedule-finalization policy:
 - one-off work completes only on explicit success
 - manual/retry one-off executions record terminal failure outcomes but do
   not auto-restore themselves into a fresh background run
 - scheduled recurring work always advances to the next cron fire time,
   regardless of run outcome
 - manual/retry recurring work records outcome only and does not advance cron
-}
decideScheduleAction
  :: ScheduleConfig
  -> ExecutionOrigin
  -> ScheduleKind
  -> UTCTime
  -> RunOutcome
  -> ScheduleDecision
decideScheduleAction _ _ _ _ OutcomeShutdown =
  NoScheduleChange
decideScheduleAction _ _ _ _ OutcomeSuspended =
  NoScheduleChange
decideScheduleAction _ _ OneOff _ OutcomeCompleted =
  CompleteOneOff
decideScheduleAction _ OtherExecution OneOff _ OutcomeFailed =
  RecordOutcomeOnly
decideScheduleAction _ OtherExecution OneOff _ OutcomeCancelled =
  RecordOutcomeOnly
decideScheduleAction _ OtherExecution OneOff _ OutcomeTimedOut =
  RecordOutcomeOnly
decideScheduleAction config ScheduledExecution OneOff finishedAt OutcomeFailed =
  RestoreOneOffAt (addUTCTime config.scOneOffFailureBackoff finishedAt)
decideScheduleAction config ScheduledExecution OneOff finishedAt OutcomeCancelled =
  RestoreOneOffAt (addUTCTime config.scOneOffFailureBackoff finishedAt)
decideScheduleAction config ScheduledExecution OneOff finishedAt OutcomeTimedOut =
  RestoreOneOffAt (addUTCTime config.scOneOffFailureBackoff finishedAt)
decideScheduleAction _ OtherExecution (Recurring _) _ _ =
  RecordOutcomeOnly
decideScheduleAction config ScheduledExecution (Recurring cronExpression) finishedAt _ =
  case Cron.computeNextCronTime cronExpression finishedAt of
    Just nextTime -> AdvanceRecurringTo nextTime
    Nothing -> RestoreRecurringAfterCronErrorAt (addUTCTime config.scCronParseBackoff finishedAt)
