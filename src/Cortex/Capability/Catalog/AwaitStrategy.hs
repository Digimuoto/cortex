{- |
Module      : Cortex.Capability.Catalog.AwaitStrategy
Description : Executor await strategy, replay class, and isolation expectation.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Small shared enumerations that ride the ADR 0053 admission projection and runtime
binding record. They are inert catalog metadata: the host binding declares them,
and Pulse never interprets them — it dispatches an opaque @StageAction@ and reacts
only to complete-or-suspend (ADR 0059 §3).

These types stay consumer-neutral; they classify executor authority, not product policy.
-}
module Cortex.Capability.Catalog.AwaitStrategy
  ( AwaitStrategy (..)
  , awaitStrategyText
  , parseAwaitStrategy
  , ReplayClass (..)
  , replayClassText
  , parseReplayClass
  , IsolationExpectation (..)
  , isolationExpectationText
  , parseIsolationExpectation
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Text (Text)
import GHC.Generics (Generic)

{- | Whether a bound stage returns its result inline or submits, suspends, and
resumes on an ordinary durable signal (ADR 0059 §3). The field is declared at the
executor level so it applies equally to a long-running @ModelExecutor@.
-}
data AwaitStrategy
  = -- | The bound action runs the effect inline and completes in one transaction.
    Synchronous
  | {- | The bound action submits, returns a job handle, and suspends until a
    durable completion signal wakes it.
    -}
    SubmitParkResume
  deriving stock (Eq, Show, Generic)

awaitStrategyText :: AwaitStrategy -> Text
awaitStrategyText = \case
  Synchronous -> "synchronous"
  SubmitParkResume -> "submit_park_resume"

parseAwaitStrategy :: Text -> Either Text AwaitStrategy
parseAwaitStrategy = \case
  "synchronous" -> Right Synchronous
  "submit_park_resume" -> Right SubmitParkResume
  other -> Left ("unknown await strategy: " <> other)

instance ToJSON AwaitStrategy where
  toJSON = toJSON . awaitStrategyText

instance FromJSON AwaitStrategy where
  parseJSON = withText "AwaitStrategy" (either (fail . show) pure . parseAwaitStrategy)

{- | How an executor's output is reproduced across a replay (ADR 0053). Recorded
as catalog metadata; the @submit_park_resume@ external-call path requires an
idempotency-keyed or exactly-once class to be admissible (ADR 0059 §3).
-}
data ReplayClass
  = Deterministic
  | ReplayByRerun
  | ReplayByReusingRecordedOutputs
  | IdempotentWithKey
  | ExactlyOnceViaCommitLog
  | NonReplayable
  deriving stock (Eq, Show, Generic)

replayClassText :: ReplayClass -> Text
replayClassText = \case
  Deterministic -> "deterministic"
  ReplayByRerun -> "replay_by_rerun"
  ReplayByReusingRecordedOutputs -> "replay_by_reusing_recorded_outputs"
  IdempotentWithKey -> "idempotent_with_key"
  ExactlyOnceViaCommitLog -> "exactly_once_via_commit_log"
  NonReplayable -> "non_replayable"

parseReplayClass :: Text -> Either Text ReplayClass
parseReplayClass = \case
  "deterministic" -> Right Deterministic
  "replay_by_rerun" -> Right ReplayByRerun
  "replay_by_reusing_recorded_outputs" -> Right ReplayByReusingRecordedOutputs
  "idempotent_with_key" -> Right IdempotentWithKey
  "exactly_once_via_commit_log" -> Right ExactlyOnceViaCommitLog
  "non_replayable" -> Right NonReplayable
  other -> Left ("unknown replay class: " <> other)

instance ToJSON ReplayClass where
  toJSON = toJSON . replayClassText

instance FromJSON ReplayClass where
  parseJSON = withText "ReplayClass" (either (fail . show) pure . parseReplayClass)

{- | The minimum isolation an executor package requests at runtime (ADR 0053).
Inert until a host binding pack honours it.
-}
data IsolationExpectation
  = InProcess
  | WasmSandbox
  | SubprocessSandbox
  | Container
  | BrokeredProcess
  deriving stock (Eq, Show, Generic)

isolationExpectationText :: IsolationExpectation -> Text
isolationExpectationText = \case
  InProcess -> "in_process"
  WasmSandbox -> "wasm_sandbox"
  SubprocessSandbox -> "subprocess_sandbox"
  Container -> "container"
  BrokeredProcess -> "brokered_process"

parseIsolationExpectation :: Text -> Either Text IsolationExpectation
parseIsolationExpectation = \case
  "in_process" -> Right InProcess
  "wasm_sandbox" -> Right WasmSandbox
  "subprocess_sandbox" -> Right SubprocessSandbox
  "container" -> Right Container
  "brokered_process" -> Right BrokeredProcess
  other -> Left ("unknown isolation expectation: " <> other)

instance ToJSON IsolationExpectation where
  toJSON = toJSON . isolationExpectationText

instance FromJSON IsolationExpectation where
  parseJSON =
    withText "IsolationExpectation" (either (fail . show) pure . parseIsolationExpectation)
