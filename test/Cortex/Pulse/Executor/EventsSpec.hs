module Cortex.Pulse.Executor.EventsSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.UUID qualified as UUID
import Test.Hspec

import Cortex.Pulse.Event
  ( ExecutorEvent (..)
  , RewriteRejectionInfo (..)
  )

import Platform.Observability.Fields (ToObsEvent (..), toFieldList)

spec :: Spec
spec =
  describe "Cortex.Pulse.Executor.Events"
    . it "includes the rejection message in rewrite rejection observability output"
    $ do
      let event =
            EvtRewriteRejected
              UUID.nil
              "planner"
              RewriteRejectionInfo
                { rrjRejectionType = "invalid_rewrite"
                , rrjMessage = "rewrite anchor missing from snapshot"
                , rrjAttemptNumber = Just 2
                , rrjTopologyChanged = False
                }
      obsMessage event
        `shouldBe` "Rewrite rejected (invalid_rewrite) for planner: rewrite anchor missing from snapshot"
      toFieldList (obsFields event)
        `shouldContain` [ ("rejection_type", Aeson.String "invalid_rewrite")
                        , ("rejection_message", Aeson.String "rewrite anchor missing from snapshot")
                        , ("topology_changed", Aeson.Bool False)
                        , ("attempt_number", Aeson.Number 2)
                        ]
