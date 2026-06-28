{- |
Module      : Cortex.Pulse.Lowering.ExternalCallPayloadSpec
Description : Tests for the canonical external-call payload serializer.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The digest is deterministic, independent of output input order (sorted), and
sensitive to step order. This is the idempotency-key stability property the
submit/park/resume protocol relies on.
-}
module Cortex.Pulse.Lowering.ExternalCallPayloadSpec (spec) where

import Test.Hspec

import Cortex.Pulse.Lowering.ExternalCallPayload

steps :: [ExternalCallStep]
steps =
  [ ExternalCallStep "prepare_zero" ["wire:0"] []
  , ExternalCallStep "x" ["wire:0"] []
  , ExternalCallStep "cnot" ["wire:0", "wire:1"] []
  ]

outputs :: [ExternalCallOutput]
outputs = [ExternalCallOutput (Just "wire:1") "s12", ExternalCallOutput (Just "wire:0") "s01"]

spec :: Spec
spec = describe "externalCallPayloadDigest" $ do
  it "is deterministic for the same payload" $
    externalCallPayloadDigest (externalCallPayload steps outputs)
      `shouldBe` externalCallPayloadDigest (externalCallPayload steps outputs)

  it "is independent of output input order (outputs are sorted)" $
    externalCallPayloadDigest (externalCallPayload steps outputs)
      `shouldBe` externalCallPayloadDigest (externalCallPayload steps (reverse outputs))

  it "is sensitive to step order" $
    externalCallPayloadDigest (externalCallPayload steps outputs)
      `shouldNotBe` externalCallPayloadDigest (externalCallPayload (reverse steps) outputs)

  it "sorts outputs canonically in the payload" $
    fmap ecoLabel (ecpOutputs (externalCallPayload steps outputs)) `shouldBe` ["s01", "s12"]
