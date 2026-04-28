module Cortex.Nous.Thought.FrameSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Cortex.Nous.Thought.Frame
  ( CortexAgentBudget (..)
  , CortexAgentBudgetLimits (..)
  , CortexAgentOverrideConfig (..)
  , CortexAgentProfileConfig (..)
  , combinePromptAppendices
  , mergeCortexAgentBudgetLayers
  , normalizeCortexAgentBudget
  , normalizeCortexAgentOverrideConfig
  , normalizeCortexAgentProfileConfig
  , validateCortexAgentBudget
  )

spec :: Spec
spec = do
  describe "normalizeCortexAgentBudget" $ do
    it "drops non-positive values and clamps to the configured maxima" $ do
      normalizeCortexAgentBudget
        defaultBudgetLimits
        CortexAgentBudget {maxToolSteps = Just 0, maxAttempts = Just 99}
        `shouldBe` Just CortexAgentBudget {maxToolSteps = Nothing, maxAttempts = Just 5}

    it "returns Nothing when both limits normalize away" $ do
      normalizeCortexAgentBudget
        defaultBudgetLimits
        CortexAgentBudget {maxToolSteps = Just 0, maxAttempts = Just 0}
        `shouldBe` Nothing

  describe "mergeCortexAgentBudgetLayers" $ do
    it "lets later layers override earlier layers field by field" $ do
      mergeCortexAgentBudgetLayers
        [ Just CortexAgentBudget {maxToolSteps = Just 4, maxAttempts = Nothing}
        , Just CortexAgentBudget {maxToolSteps = Nothing, maxAttempts = Just 2}
        , Just CortexAgentBudget {maxToolSteps = Just 8, maxAttempts = Nothing}
        ]
        `shouldBe` CortexAgentBudget {maxToolSteps = Just 8, maxAttempts = Just 2}

  describe "normalizeCortexAgentProfileConfig" $ do
    it "normalizes model, prompt appendix, and bounded budget via the supplied model canonicalizer" $ do
      normalizeCortexAgentProfileConfig
        canonicalizeModel
        defaultBudgetLimits
        CortexAgentProfileConfig
          { model = Just " GPT-5.2 "
          , budget = Just CortexAgentBudget {maxToolSteps = Just 999, maxAttempts = Nothing}
          , promptAppendix = Just "  Keep it tight.  "
          }
        `shouldBe` Just
          CortexAgentProfileConfig
            { model = Just "gpt-5.2"
            , budget = Just CortexAgentBudget {maxToolSteps = Just 20, maxAttempts = Nothing}
            , promptAppendix = Just "Keep it tight."
            }

  describe "normalizeCortexAgentOverrideConfig" $ do
    it "drops fully empty overrides after normalization" $ do
      normalizeCortexAgentOverrideConfig
        canonicalizeModel
        defaultBudgetLimits
        CortexAgentOverrideConfig
          { profileId = Just " "
          , model = Just " "
          , budget = Just CortexAgentBudget {maxToolSteps = Just 0, maxAttempts = Just 0}
          , promptAppendix = Just " "
          }
        `shouldBe` Nothing

  describe "validateCortexAgentBudget" $ do
    it "rejects values above the configured maxima" $ do
      validateCortexAgentBudget
        "agent.budget"
        defaultBudgetLimits
        CortexAgentBudget {maxToolSteps = Just 21, maxAttempts = Nothing}
        `shouldBe` Left "agent.budget.maxToolSteps must be less than or equal to 20"

  describe "combinePromptAppendices" $ do
    it "joins non-empty appendices with blank lines" $ do
      combinePromptAppendices [Nothing, Just "  First. ", Just "", Just "Second."]
        `shouldBe` Just "First.\n\nSecond."

defaultBudgetLimits :: CortexAgentBudgetLimits
defaultBudgetLimits =
  CortexAgentBudgetLimits
    { cortexMaxToolSteps = 20
    , cortexMaxAttempts = 5
    }

canonicalizeModel :: Maybe Text -> Maybe Text
canonicalizeModel = (>>= (nonEmptyText . T.toLower . T.strip))

nonEmptyText :: Text -> Maybe Text
nonEmptyText text
  | T.null text = Nothing
  | otherwise = Just text
