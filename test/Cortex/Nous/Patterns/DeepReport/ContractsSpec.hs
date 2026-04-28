{- |
Module      : Cortex.Nous.Patterns.DeepReport.ContractsSpec
Description : Tests for Cortex.Nous.Patterns.DeepReport.Contracts.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Nous.Patterns.DeepReport.ContractsSpec
  ( spec
  )
where

import Control.Monad (forM_)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Test.Hspec

import Cortex qualified
import Cortex.Nous.Patterns.DeepReport.Contracts
import Cortex.Wire
  ( WireContractRegistry (..)
  , WireContractSpec (..)
  , WirePayloadKind (..)
  )

spec :: Spec
spec =
  describe "Cortex.Nous.Patterns.DeepReport.Contracts" $ do
    it "registers the expected DeepReport contract ids" $ do
      Map.keys registryContracts `shouldMatchList` fmap fst expectedContracts
      fmap wireContractSpecId deepReportWireContractSpecs `shouldMatchList` fmap fst expectedContracts

    it "preserves the expected payload kind for each contract" $ do
      forM_ expectedContracts $ \(contractId, payloadKind) -> do
        fmap wireContractSpecPayloadKind (Map.lookup contractId registryContracts)
          `shouldBe` Just payloadKind

    it "marks ReportArtifactRef as an artifact reference contract" $ do
      deepReportReportArtifactRefContract.wireContractSpecId `shouldBe` "ReportArtifactRef"
      deepReportReportArtifactRefContract.wireContractSpecPayloadKind `shouldBe` WirePayloadArtifactRef

    it "uses object schemas for every initial contract" $ do
      forM_ deepReportWireContractSpecs assertObjectSchema

    it "preserves the representative planner example" $ do
      deepReportPlannerOutputContract.wireContractSpecExamples
        `shouldBe` [Aeson.object ["request" .= ("Analyze the selected universe." :: Text)]]

    it "is exposed through the public Cortex facade" $ do
      Cortex.deepReportWireContractRegistry `shouldBe` deepReportWireContractRegistry

expectedContracts :: [(Text, WirePayloadKind)]
expectedContracts =
  [ ("PlannerOutput", WirePayloadJson)
  , ("PlannerRewriteNeeded", WirePayloadJson)
  , ("EvidenceBundle", WirePayloadJson)
  , ("EvidenceReady", WirePayloadJson)
  , ("EvidenceRepairNeeded", WirePayloadJson)
  , ("ConditionPassthrough", WirePayloadJson)
  , ("AnalysisFragment", WirePayloadJson)
  , ("ReportFragment", WirePayloadJson)
  , ("ReviewBundle", WirePayloadJson)
  , ("ReviewConcerns", WirePayloadJson)
  , ("ReportArtifactRef", WirePayloadArtifactRef)
  , ("WorkflowAudit", WirePayloadJson)
  , ("AwaitSignal", WirePayloadJson)
  ]

registryContracts :: Map.Map Text WireContractSpec
registryContracts =
  deepReportWireContractRegistry.wireContractRegistryContracts

assertObjectSchema :: WireContractSpec -> Expectation
assertObjectSchema contractSpec =
  case contractSpec.wireContractSpecSchema of
    Just (Aeson.Object schema) -> do
      KeyMap.lookup "type" schema `shouldBe` Just (Aeson.String "object")
      KeyMap.lookup "additionalProperties" schema `shouldBe` Just (Aeson.Bool True)
    _ -> expectationFailure ("missing object schema for " <> show contractSpec.wireContractSpecId)
