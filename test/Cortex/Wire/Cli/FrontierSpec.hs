{- |
Module      : Cortex.Wire.Cli.FrontierSpec
Description : Tests for the wire frontier command parser.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Pins the stable @wire frontier@ argument surface without importing the
executable entry point.
-}
module Cortex.Wire.Cli.FrontierSpec (spec) where

import Test.Hspec

import Cortex.Wire.Cli.Frontier

spec :: Spec
spec = describe "Cortex.Wire.Cli.Frontier.parseFrontierCommand" $ do
  it "defaults to closed graph text output" $
    parseFrontierCommand ["workflow.wire"]
      `shouldBe` Right
        FrontierCommand
          { frontierCommandClosure = FrontierClosed
          , frontierCommandScope = FrontierGraph
          , frontierCommandFormat = FrontierText
          , frontierCommandFile = "workflow.wire"
          }

  it "parses the stable JSON graph surface" $
    parseFrontierCommand ["--json", "workflow.wire"]
      `shouldBe` Right
        FrontierCommand
          { frontierCommandClosure = FrontierClosed
          , frontierCommandScope = FrontierGraph
          , frontierCommandFormat = FrontierJson
          , frontierCommandFile = "workflow.wire"
          }

  it "treats --closure as the explicit spelling of the default closed projection" $
    parseFrontierCommand ["workflow.wire", "--closure"]
      `shouldBe` Right
        FrontierCommand
          { frontierCommandClosure = FrontierClosed
          , frontierCommandScope = FrontierGraph
          , frontierCommandFormat = FrontierText
          , frontierCommandFile = "workflow.wire"
          }

  it "parses open node inspection with flags after the file" $
    parseFrontierCommand ["workflow.wire", "--open", "--node", "planner", "--json"]
      `shouldBe` Right
        FrontierCommand
          { frontierCommandClosure = FrontierOpen
          , frontierCommandScope = FrontierNode "planner"
          , frontierCommandFormat = FrontierJson
          , frontierCommandFile = "workflow.wire"
          }

  it "rejects --node when the next token is another flag" $
    parseFrontierCommand ["--node", "--json", "workflow.wire"] `shouldBe` Left frontierUsage

  it "rejects conflicting closure projections" $
    parseFrontierCommand ["--closure", "--open", "workflow.wire"]
      `shouldBe` Left "wire frontier accepts only one of --closure or --open."
