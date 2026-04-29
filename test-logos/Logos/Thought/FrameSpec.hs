{- |
Module      : Logos.Thought.FrameSpec
Description : Tests for Logos.Thought.Frame.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Logos.Thought.FrameSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Logos.Thought.Frame
  ( LogosAgentBudget (..)
  , LogosAgentBudgetLimits (..)
  , LogosAgentOverrideConfig (..)
  , LogosAgentProfileConfig (..)
  , combinePromptAppendices
  , mergeLogosAgentBudgetLayers
  , normalizeLogosAgentBudget
  , normalizeLogosAgentOverrideConfig
  , normalizeLogosAgentProfileConfig
  , validateLogosAgentBudget
  )
import Test.Hspec

spec :: Spec
spec = do
  describe "normalizeLogosAgentBudget" $ do
    it "drops non-positive values and clamps to the configured maxima" $ do
      normalizeLogosAgentBudget
        defaultBudgetLimits
        LogosAgentBudget {maxToolSteps = Just 0, maxAttempts = Just 99}
        `shouldBe` Just LogosAgentBudget {maxToolSteps = Nothing, maxAttempts = Just 5}

    it "returns Nothing when both limits normalize away" $ do
      normalizeLogosAgentBudget
        defaultBudgetLimits
        LogosAgentBudget {maxToolSteps = Just 0, maxAttempts = Just 0}
        `shouldBe` Nothing

  describe "mergeLogosAgentBudgetLayers" $ do
    it "lets later layers override earlier layers field by field" $ do
      mergeLogosAgentBudgetLayers
        [ Just LogosAgentBudget {maxToolSteps = Just 4, maxAttempts = Nothing}
        , Just LogosAgentBudget {maxToolSteps = Nothing, maxAttempts = Just 2}
        , Just LogosAgentBudget {maxToolSteps = Just 8, maxAttempts = Nothing}
        ]
        `shouldBe` LogosAgentBudget {maxToolSteps = Just 8, maxAttempts = Just 2}

  describe "normalizeLogosAgentProfileConfig" $ do
    it "normalizes model, prompt appendix, and bounded budget via the supplied model canonicalizer" $ do
      normalizeLogosAgentProfileConfig
        canonicalizeModel
        defaultBudgetLimits
        LogosAgentProfileConfig
          { model = Just " GPT-5.2 "
          , budget = Just LogosAgentBudget {maxToolSteps = Just 999, maxAttempts = Nothing}
          , promptAppendix = Just "  Keep it tight.  "
          }
        `shouldBe` Just
          LogosAgentProfileConfig
            { model = Just "gpt-5.2"
            , budget = Just LogosAgentBudget {maxToolSteps = Just 20, maxAttempts = Nothing}
            , promptAppendix = Just "Keep it tight."
            }

  describe "normalizeLogosAgentOverrideConfig" $ do
    it "drops fully empty overrides after normalization" $ do
      normalizeLogosAgentOverrideConfig
        canonicalizeModel
        defaultBudgetLimits
        LogosAgentOverrideConfig
          { profileId = Just " "
          , model = Just " "
          , budget = Just LogosAgentBudget {maxToolSteps = Just 0, maxAttempts = Just 0}
          , promptAppendix = Just " "
          }
        `shouldBe` Nothing

  describe "validateLogosAgentBudget" $ do
    it "rejects values above the configured maxima" $ do
      validateLogosAgentBudget
        "agent.budget"
        defaultBudgetLimits
        LogosAgentBudget {maxToolSteps = Just 21, maxAttempts = Nothing}
        `shouldBe` Left "agent.budget.maxToolSteps must be less than or equal to 20"

  describe "combinePromptAppendices" $ do
    it "joins non-empty appendices with blank lines" $ do
      combinePromptAppendices [Nothing, Just "  First. ", Just "", Just "Second."]
        `shouldBe` Just "First.\n\nSecond."

defaultBudgetLimits :: LogosAgentBudgetLimits
defaultBudgetLimits =
  LogosAgentBudgetLimits
    { logosMaxToolSteps = 20
    , logosMaxAttempts = 5
    }

canonicalizeModel :: Maybe Text -> Maybe Text
canonicalizeModel = (>>= (nonEmptyText . T.toLower . T.strip))

nonEmptyText :: Text -> Maybe Text
nonEmptyText text
  | T.null text = Nothing
  | otherwise = Just text
