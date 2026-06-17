{- |
Module      : Cortex.Pulse.FrontierContractionSpec
Description : Tests for the ADR 0059 §2 decidable frontier-contraction admission check.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Admits a homogeneous backend frontier; rejects (never splits) a mixed authority, a
mixed await strategy, an intervening non-backend node, and an empty set.
-}
module Cortex.Pulse.FrontierContractionSpec (spec) where

import Data.Text (Text)
import Test.Hspec

import Cortex.Capability.Catalog.AwaitStrategy (AwaitStrategy (..))
import Cortex.Pulse.Rewrite.Contract

backend :: Text -> Text -> AwaitStrategy -> CollectedNode Text Text AwaitStrategy
backend node authority strat = CollectedNode node (Just (authority, strat))

classical :: Text -> CollectedNode Text Text AwaitStrategy
classical node = CollectedNode node Nothing

spec :: Spec
spec = describe "admitFrontierContraction" $ do
  it "admits a homogeneous same-authority, same-strategy frontier" $
    admitFrontierContraction
      [ backend "g0" "quantum.braket" SubmitParkResume
      , backend "g1" "quantum.braket" SubmitParkResume
      , backend "m0" "quantum.braket" SubmitParkResume
      ]
      `shouldBe` Right ()

  it "rejects a mixed-authority frontier (does not split)" $
    admitFrontierContraction
      [ backend "g0" "quantum.braket" SubmitParkResume
      , backend "g1" "quantum.iqm" SubmitParkResume
      ]
      `shouldBe` Left (FrontierMixedAuthority ["g0", "g1"])

  it "rejects a mixed await-strategy frontier" $
    admitFrontierContraction
      [ backend "g0" "quantum.braket" SubmitParkResume
      , backend "g1" "quantum.braket" Synchronous
      ]
      `shouldBe` Left (FrontierMixedAwaitStrategy ["g0", "g1"])

  it "rejects an intervening non-backend node" $
    admitFrontierContraction
      [ backend "g0" "quantum.braket" SubmitParkResume
      , classical "decode"
      ]
      `shouldBe` Left (FrontierNonBackendIntervening "decode")

  it "rejects an empty collected set" $
    admitFrontierContraction ([] :: [CollectedNode Text Text AwaitStrategy])
      `shouldBe` Left FrontierEmpty
