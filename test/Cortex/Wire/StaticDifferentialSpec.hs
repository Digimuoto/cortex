{- |
Module      : Cortex.Wire.StaticDifferentialSpec
Description : Regression guards for the static Wire C differential corpus and reference driver.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Library-level guards for the ADR 0091 differential suite. The full three-way
agreement between the Haskell reference driver, the Lean interpreter, and the
generated C runs in the @cortex-wire-differential@ Nix check; here we pin the
corpus shape and the corrected v1 lifecycle behaviour (no phantom running node
on sibling failure, terminal-failure latch with post-terminal rejection) that
the reference driver must encode for that check to be meaningful.
-}
module Cortex.Wire.StaticDifferentialSpec (spec) where

import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Cortex.Wire.StaticDifferential
  ( differentialCorpus
  , renderScenarioLine
  , renderTraceLine
  , runScenario
  , scId
  )

-- | The canonical trace line for the scenario with the given identifier.
traceFor :: Text -> Text
traceFor scenarioId =
  case filter ((== scenarioId) . scId) differentialCorpus of
    (sc : _) -> renderTraceLine (runScenario sc)
    [] -> error ("no scenario " <> T.unpack scenarioId)

-- | The trailing final-status field of a canonical trace line.
finalStatusOf :: Text -> Text
finalStatusOf scenarioId =
  case reverse (T.splitOn "\t" (traceFor scenarioId)) of
    (_output : status : _) -> status
    _ -> error "malformed trace line"

-- | The terminal drive-result code of a canonical trace line.
terminalOf :: Text -> Text
terminalOf scenarioId =
  case reverse (T.splitOn "\t" (traceFor scenarioId)) of
    (_output : _status : terminal : _) -> terminal
    _ -> error "malformed trace line"

spec :: Spec
spec = do
  describe "differential corpus" $ do
    it "is non-empty and covers the mandated topologies" $ do
      let ids = fmap scId differentialCorpus
      length differentialCorpus `shouldSatisfy` (> 500)
      -- Empty, singleton, independent-frontier, chain, diamond, and the named
      -- four-node shapes are all present.
      any (T.isPrefixOf "t0-e-") ids `shouldBe` True
      any (T.isPrefixOf "t1-e-") ids `shouldBe` True
      any (T.isPrefixOf "t2-e-") ids `shouldBe` True
      any (T.isPrefixOf "t4-diamond4-") ids `shouldBe` True
      any (T.isPrefixOf "t4-indfrontier4-") ids `shouldBe` True

    it "assigns each scenario a unique identifier" $ do
      let ids = fmap scId differentialCorpus
      length (nub ids) `shouldBe` length ids

    it "emits whitespace-free scenario lines with six fields" $ do
      let badLines =
            [ scId sc
            | sc <- differentialCorpus
            , length (T.splitOn " " (renderScenarioLine sc)) /= 6
            ]
      badLines `shouldBe` []

  describe "corrected v1 lifecycle (reference driver)" $ do
    it "does not strand an undispatched sibling running on synchronous failure" $ do
      -- Two independent nodes; node 0 fails synchronously. Node 1 must remain
      -- pending (status 0), never phantom-marked running (status 1).
      terminalOf "t2-e-sync-failure-0" `shouldBe` "2"
      finalStatusOf "t2-e-sync-failure-0" `shouldBe` "3,0"

    it "latches terminal failure, cancels the running sibling, and rejects post-terminal completions" $ do
      -- Two independent async nodes; node 0 is completed with a failure while
      -- node 1 is still running. The latch moves node 1 to failed (3,3) and the
      -- trailing completion for node 1 is rejected as stale (result 1).
      terminalOf "t2-e-adversarial-post-terminal" `shouldBe` "2"
      finalStatusOf "t2-e-adversarial-post-terminal" `shouldBe` "3,3"
      traceFor "t2-e-adversarial-post-terminal" `shouldSatisfy` T.isInfixOf "C1,1,1101:1"

    it "propagates failure to a chain descendant" $ do
      terminalOf "t2-e0-1-sync-failure-0" `shouldBe` "2"
      finalStatusOf "t2-e0-1-sync-failure-0" `shouldBe` "3,3"

    it "completes an all-success independent frontier with both outputs" $ do
      terminalOf "t2-e-all-sync-success" `shouldBe` "1"
      finalStatusOf "t2-e-all-sync-success" `shouldBe` "2,2"
