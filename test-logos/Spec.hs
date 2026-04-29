{-# OPTIONS_GHC -F -pgmF hspec-discover #-}

{- |
Module      : Spec
Description : Tests for Logos.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises Logos behavior through the same Nix-backed test surface used by CI.

Tests may import the Logos surface they exercise, but they do not define downstream product behavior.
-}
