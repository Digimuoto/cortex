{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}

module Cortex.Circuit.IRSpec (spec) where

import Cortex.Circuit.IR
  ( CircuitArtifactBoundary (..),
    CircuitCondition (..),
    CircuitExpr (..),
    CircuitNodeRef (..),
    CircuitRewriteBoundary (..),
    CircuitSignalBoundary (..),
    CircuitTaskNode (..),
    circuitNodeRefs,
  )
import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty ((:|)))
import Test.Hspec

spec :: Spec
spec = do
  describe "circuitNodeRefs" $ do
    it "collects refs across signal, artifact, conditional, and rewrite boundaries" $ do
      let expr =
            CircuitSequence
              ( CircuitAwaitSignal
                  CircuitSignalBoundary
                    { circuitSignalBoundaryRef = CircuitNodeRef "approval_signal",
                      circuitSignalName = "approval",
                      circuitSignalDescription = Just "Wait for operator approval",
                      circuitSignalMetadata = Aeson.object []
                    }
                  :| [ CircuitConditional
                         (CircuitConditionRef "approved")
                         ( CircuitRewriteScope
                             CircuitRewriteBoundary
                               { circuitRewriteBoundaryRef = CircuitNodeRef "repair_boundary",
                                 circuitRewriteIntent = "repair",
                                 circuitRewriteDescription = Nothing,
                                 circuitRewriteMetadata = Aeson.object []
                               }
                             ( CircuitArtifact
                                 CircuitArtifactBoundary
                                   { circuitArtifactBoundaryRef = CircuitNodeRef "report_artifact",
                                     circuitArtifactKind = "report",
                                     circuitArtifactLabel = "Report",
                                     circuitArtifactMetadata = Aeson.object []
                                   }
                             )
                         )
                         (Just (CircuitTask (CircuitTaskNode (CircuitNodeRef "fallback") "Fallback" Nothing (Aeson.object []))))
                     ]
              )
      circuitNodeRefs expr
        `shouldBe` [ CircuitNodeRef "approval_signal",
                     CircuitNodeRef "repair_boundary",
                     CircuitNodeRef "report_artifact",
                     CircuitNodeRef "fallback"
                   ]
