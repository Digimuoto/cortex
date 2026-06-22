{- |
Module      : Cortex.Wire.QuantumPackageSpec
Description : Tests for the quantum Wire packages (ADR 0059 / ADR 0054).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The manifest-backed quantum package registry resolves @use quantum.core/qec/braket@ leaves
and contracts to their canonical ids, and exposes the @quantum.realize@ projection —
all inert, with no host binding pack present (the ADR 0054 invariant).
-}
module Cortex.Wire.QuantumPackageSpec (spec) where

import Data.List (find)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Cortex.Wire.Executor (WireExecutorId (..), WireExecutorProjection (..))
import Cortex.Wire.Package (WirePackage (..), packageNamespaceRegistry)
import Cortex.Wire.Package.Manifest (loadWirePackageManifests, renderWirePackageManifestError)
import Cortex.Wire.Syntax (QName (..), UseItem (..), UseSpec (..))
import Cortex.Wire.Use

notTaken :: Text -> Bool
notTaken = const False

useSpec :: [Text] -> [UseItem] -> UseSpec
useSpec ns (i : is) = UseSpec {useSpecNamespace = qn ns, useSpecItems = i :| is}
  where
    qn (x : xs) = QName (x :| xs)
    qn [] = error "empty namespace"
useSpec _ [] = error "empty items"

spec :: Spec
spec =
  beforeAll
    loadQuantumPackages
    ( describe "quantum Wire package manifests" $ do
        it "resolves quantum.core gate leaves and contracts" $ \quantumPackages -> do
          let registry = packageNamespaceRegistry quantumPackages

          case applyWireUseSpecs
            registry
            notTaken
            [ useSpec
                ["quantum", "core"]
                [UseExecutor "prepare_zero" Nothing, UseExecutor "cnot" Nothing, UseContract "Qubit" Nothing]
            ] of
            Left err -> expectationFailure (show err)
            Right scope -> do
              Map.lookup "prepare_zero" (wireUseExecutors scope) `shouldBe` Just "quantum.prepare_zero"
              Map.lookup "cnot" (wireUseExecutors scope) `shouldBe` Just "quantum.cnot"
              Map.lookup "Qubit" (wireUseContracts scope) `shouldBe` Just "quantum.Qubit"

        it "resolves quantum.braket.@realize to the realize executor id" $ \quantumPackages -> do
          let registry = packageNamespaceRegistry quantumPackages
          case applyWireUseSpecs registry notTaken [useSpec ["quantum", "braket"] [UseExecutor "realize" Nothing]] of
            Left err -> expectationFailure (show err)
            Right scope ->
              Map.lookup "realize" (wireUseExecutors scope) `shouldBe` Just realizeExecutorId

        it "resolves quantum.qec contracts" $ \quantumPackages -> do
          let registry = packageNamespaceRegistry quantumPackages
          case applyWireUseSpecs registry notTaken [useSpec ["quantum", "qec"] [UseContract "Syndrome" Nothing]] of
            Left err -> expectationFailure (show err)
            Right scope ->
              Map.lookup "Syndrome" (wireUseContracts scope) `shouldBe` Just "quantum.Syndrome"

        it "exposes a realize executor projection in the braket package" $ \quantumPackages ->
          case find ((== "quantum.braket") . wpId) quantumPackages of
            Nothing -> expectationFailure "missing quantum.braket package"
            Just quantumBraketPackage ->
              fmap (unWireExecutorId . wireExecutorProjectionId) (wpExecutorProjections quantumBraketPackage)
                `shouldBe` ["quantum.realize"]
    )

realizeExecutorId :: Text
realizeExecutorId = "quantum.realize"

loadQuantumPackages :: IO [WirePackage]
loadQuantumPackages = do
  loaded <- loadWirePackageManifests quantumManifestPaths
  either (fail . T.unpack . renderWirePackageManifestError) pure loaded

quantumManifestPaths :: [FilePath]
quantumManifestPaths =
  [ "extensions/quantum/packages/quantum-core/cortex.toml"
  , "extensions/quantum/packages/quantum-qec/cortex.toml"
  , "extensions/quantum/packages/quantum-braket/cortex.toml"
  ]
