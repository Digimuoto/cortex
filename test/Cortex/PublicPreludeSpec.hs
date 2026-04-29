{- |
Module      : Cortex.PublicPreludeSpec
Description : Tests for Cortex.PublicPrelude.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.PublicPreludeSpec
  ( spec
  )
where

import Test.Hspec

import Cortex qualified

import Platform qualified

spec :: Spec
spec =
  describe "public preludes" $ do
    it "exposes representative Cortex substrate types" $ do
      Cortex.unNodeId (Cortex.NodeId "root") `shouldBe` "root"

    it "exposes representative Platform runtime helpers" $ do
      Platform.runStatusToText Platform.Pending `shouldBe` "pending"
      Platform.stripNonEmptyText "  cortex  " `shouldBe` Just "cortex"
      Platform.toolValidationError "field" "missing" "value"
        `shouldBe` "Error: missing: value"
