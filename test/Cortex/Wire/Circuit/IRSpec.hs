{-# LANGUAGE BlockArguments #-}

{- |
Module      : Cortex.Wire.Circuit.IRSpec
Description : Tests for Cortex.Wire.Circuit.IR.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Wire.Circuit.IRSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty ((:|)))
import Test.Hspec

import Cortex.Wire.Circuit.IR
  ( CircuitArtifactBoundary (..)
  , CircuitCondition (..)
  , CircuitExpr (..)
  , CircuitNodeRef (..)
  , CircuitRewriteBoundary (..)
  , CircuitSignalBoundary (..)
  , CircuitTaskNode (..)
  , circuitNodeRefs
  )

spec :: Spec
spec = do
  describe "circuitNodeRefs" $ do
    it "collects refs across signal, artifact, conditional, and rewrite boundaries" $ do
      let expr =
            CircuitSequence
              ( CircuitAwaitSignal
                  CircuitSignalBoundary
                    { circuitSignalBoundaryRef = CircuitNodeRef "approval_signal"
                    , circuitSignalName = "approval"
                    , circuitSignalDescription = Just "Wait for operator approval"
                    , circuitSignalMetadata = Aeson.object []
                    }
                  :| [ CircuitConditional
                         (CircuitConditionRef "approved")
                         ( CircuitRewriteScope
                             CircuitRewriteBoundary
                               { circuitRewriteBoundaryRef = CircuitNodeRef "repair_boundary"
                               , circuitRewriteIntent = "repair"
                               , circuitRewriteDescription = Nothing
                               , circuitRewriteMetadata = Aeson.object []
                               }
                             ( CircuitArtifact
                                 CircuitArtifactBoundary
                                   { circuitArtifactBoundaryRef = CircuitNodeRef "report_artifact"
                                   , circuitArtifactKind = "report"
                                   , circuitArtifactLabel = "Report"
                                   , circuitArtifactMetadata = Aeson.object []
                                   }
                             )
                         )
                         ( Just
                             (CircuitTask (CircuitTaskNode (CircuitNodeRef "fallback") "Fallback" Nothing (Aeson.object [])))
                         )
                     ]
              )
      circuitNodeRefs expr
        `shouldBe` [ CircuitNodeRef "approval_signal"
                   , CircuitNodeRef "repair_boundary"
                   , CircuitNodeRef "report_artifact"
                   , CircuitNodeRef "fallback"
                   ]
