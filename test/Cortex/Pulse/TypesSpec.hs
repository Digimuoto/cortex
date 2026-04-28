{- |
Module      : Cortex.Pulse.TypesSpec
Description : Tests for Cortex.Pulse.Types.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Pulse.TypesSpec (spec) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Test.Hspec

import Cortex.Pulse.Types

spec :: Spec
spec = describe "Cortex.Pulse.Types" $ do
  describe "TaskKind" $ do
    it "wraps and unwraps text" $ do
      unTaskKind (TaskKind "my_task") `shouldBe` "my_task"

    it "roundtrips through JSON" $ do
      Aeson.fromJSON (Aeson.toJSON (TaskKind "my_task"))
        `shouldBe` Aeson.Success (TaskKind "my_task")

  describe "CortexTaskEnvelope JSON" $ do
    it "decodes a task envelope with an arbitrary task kind" $ do
      let rawEnvelope =
            Aeson.object
              [ "cortexTaskType" .= ("strategy_distillation_cycle" :: String)
              , "cortexTaskVersion" .= (2 :: Int)
              , "cortexTaskConfig" .= Aeson.object []
              ]
      Aeson.fromJSON rawEnvelope
        `shouldBe` Aeson.Success
          CortexTaskEnvelope
            { cortexTaskType = TaskKind "strategy_distillation_cycle"
            , cortexTaskVersion = 2
            , cortexTaskConfig = Aeson.object []
            }

    it "decodes a legacy constructor-style task kind" $ do
      let rawEnvelope =
            Aeson.object
              [ "cortexTaskType" .= ("StrategyDistillationCycle" :: String)
              , "cortexTaskVersion" .= (2 :: Int)
              , "cortexTaskConfig" .= Aeson.object []
              ]
      Aeson.fromJSON rawEnvelope
        `shouldBe` Aeson.Success
          CortexTaskEnvelope
            { cortexTaskType = TaskKind "StrategyDistillationCycle"
            , cortexTaskVersion = 2
            , cortexTaskConfig = Aeson.object []
            }
