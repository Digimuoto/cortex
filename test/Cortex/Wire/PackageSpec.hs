{- |
Module      : Cortex.Wire.PackageSpec
Description : Tests for ADR 0054 Wire packages and namespace `use` resolution.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Resolving @use@ against a composed namespace registry: a non-@std.io@ package
namespace resolves leaves and contracts, unknown namespaces and items are rejected,
and @std.io@ still resolves as one entry among others.
-}
module Cortex.Wire.PackageSpec (spec) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Cortex.Wire.Contract (WireCompileEnv (..), emptyWireCompileEnv)
import Cortex.Wire.Package
import Cortex.Wire.Package.Manifest (decodeWirePackageManifest, renderWirePackageManifestError)
import Cortex.Wire.Syntax (QName (..), UseItem (..), UseSpec (..))
import Cortex.Wire.Use

quantumCore :: NamespaceEntry
quantumCore =
  NamespaceEntry
    { nsNamespace = "quantum.core"
    , nsResolveExecutorLeaf = \leaf ->
        if leaf == "realize" then Just "quantum.realize" else Nothing
    , nsResolveContract = \name ->
        if name == "QuantumResult" then Just "quantum.QuantumResult" else Nothing
    }

registry :: NamespaceRegistry
registry = namespaceRegistryFromEntries [stdNamespaceEntry, quantumCore]

useQuantum :: UseSpec
useQuantum =
  UseSpec
    { useSpecNamespace = QName ("quantum" :| ["core"])
    , useSpecItems = UseExecutor "realize" Nothing :| [UseContract "QuantumResult" Nothing]
    }

useStdOut :: UseSpec
useStdOut =
  UseSpec
    { useSpecNamespace = QName ("std" :| ["io"])
    , useSpecItems = UseExecutor "stdout" Nothing :| []
    }

alphaCore :: NamespaceEntry
alphaCore =
  NamespaceEntry
    { nsNamespace = "alpha.core"
    , nsResolveExecutorLeaf = \leaf ->
        if leaf == "ping" then Just "alpha.ping" else Nothing
    , nsResolveContract = \name ->
        if name == "Token" then Just "alpha.Token" else Nothing
    }

betaCore :: NamespaceEntry
betaCore =
  NamespaceEntry
    { nsNamespace = "beta.core"
    , nsResolveExecutorLeaf = \leaf ->
        if leaf == "pong" then Just "beta.pong" else Nothing
    , nsResolveContract = \name ->
        if name == "BetaToken" then Just "beta.Token" else Nothing
    }

useAlpha :: UseSpec
useAlpha =
  UseSpec
    { useSpecNamespace = QName ("alpha" :| ["core"])
    , useSpecItems = UseExecutor "ping" Nothing :| [UseContract "Token" Nothing]
    }

useBeta :: UseSpec
useBeta =
  UseSpec
    { useSpecNamespace = QName ("beta" :| ["core"])
    , useSpecItems = UseExecutor "pong" Nothing :| [UseContract "BetaToken" Nothing]
    }

notTaken :: Text -> Bool
notTaken = const False

testPackage :: Text -> [NamespaceEntry] -> WirePackage
testPackage packageId namespaceEntries =
  WirePackage
    { wpId = packageId
    , wpNamespaceEntries = namespaceEntries
    , wpExecutorProjections = []
    , wpContractSpecs = []
    , wpModuleSources = Map.empty
    , wpModulePaths = []
    }

spec :: Spec
spec = do
  describe "applyWireUseSpecs against a composed registry" $ do
    it "resolves a non-std package namespace's executor and contract leaves" $
      case applyWireUseSpecs registry notTaken [useQuantum] of
        Left err -> expectationFailure ("unexpected: " <> show err)
        Right scope -> do
          Map.lookup "realize" (wireUseExecutors scope) `shouldBe` Just "quantum.realize"
          Map.lookup "QuantumResult" (wireUseContracts scope) `shouldBe` Just "quantum.QuantumResult"

    it "still resolves std.io as one entry among others" $
      case applyWireUseSpecs registry notTaken [useStdOut] of
        Left err -> expectationFailure ("unexpected: " <> show err)
        Right scope ->
          Map.lookup "stdout" (wireUseExecutors scope) `shouldBe` Just "std.io.stdout"

    it "rejects an unknown namespace" $
      applyWireUseSpecs registry notTaken [useQuantum {useSpecNamespace = QName ("nope" :| [])}]
        `shouldBe` Left (WireUseUnknownNamespace "nope")

    it "rejects an unknown item in a known namespace" $
      applyWireUseSpecs
        registry
        notTaken
        [useQuantum {useSpecItems = UseExecutor "teleport" Nothing :| []}]
        `shouldBe` Left (WireUseUnknownItem "quantum.core" "@teleport")

  describe "packageNamespaceRegistry" . it "composes std.io with package namespaces" $ do
    let reg = packageNamespaceRegistry [testPackage "quantum" [quantumCore]]
    namespaceRegistryNamespaces reg `shouldMatchList` ["std.io", "quantum.core"]

  describe "wireCompileEnvWithPackages"
    . it "preserves existing package namespaces when adding more packages"
    $ do
      let envWithAlpha =
            wireCompileEnvWithPackages
              [testPackage "alpha" [alphaCore]]
              emptyWireCompileEnv
          envWithAlphaBeta =
            wireCompileEnvWithPackages
              [testPackage "beta" [betaCore]]
              envWithAlpha

      case envWithAlphaBeta.wireCompileEnvNamespaceRegistry of
        Nothing -> expectationFailure "missing namespace registry"
        Just reg -> do
          namespaceRegistryNamespaces reg `shouldMatchList` ["std.io", "alpha.core", "beta.core"]

          case applyWireUseSpecs reg notTaken [useAlpha, useBeta] of
            Left err -> expectationFailure ("unexpected: " <> show err)
            Right scope -> do
              Map.lookup "ping" (wireUseExecutors scope) `shouldBe` Just "alpha.ping"
              Map.lookup "pong" (wireUseExecutors scope) `shouldBe` Just "beta.pong"
              Map.lookup "Token" (wireUseContracts scope) `shouldBe` Just "alpha.Token"
              Map.lookup "BetaToken" (wireUseContracts scope) `shouldBe` Just "beta.Token"

  describe "packageConflicts" $ do
    it "is empty for packages with disjoint ids and namespaces" $
      packageConflicts [testPackage "alpha" [alphaCore], testPackage "beta" [betaCore]]
        `shouldBe` []

    it "reports duplicate package ids and namespaces" $ do
      let conflicts =
            packageConflicts [testPackage "dup" [alphaCore], testPackage "dup" [alphaCore]]
      conflicts `shouldContain` [DuplicatePackageId "dup"]
      conflicts `shouldContain` [DuplicateNamespace "alpha.core"]

    it "reports duplicate package module paths" $ do
      let packageWithModule packageId =
            (testPackage packageId [])
              { wpModuleSources = Map.singleton "example/helpers.wire" "export let value = 1;"
              , wpModulePaths = ["example/helpers.wire"]
              }
      packageConflicts [packageWithModule "alpha", packageWithModule "beta"]
        `shouldContain` [DuplicateModulePath "example/helpers.wire"]

    it "reports duplicate package module paths preserved from a single manifest" $ do
      let package =
            (testPackage "alpha" [])
              { wpModuleSources = Map.singleton "example/helpers.wire" "export let value = 1;"
              , wpModulePaths = ["example/helpers.wire", "example/helpers.wire"]
              }
      packageConflicts [package] `shouldContain` [DuplicateModulePath "example/helpers.wire"]

    it "reports duplicate package module paths decoded from one manifest" $ do
      let source =
            "[package]\n\
            \id = \"alpha\"\n\
            \\n\
            \[[module]]\n\
            \path = \"example/helpers.wire\"\n\
            \source = \"export let value = 1;\"\n\
            \\n\
            \[[module]]\n\
            \path = \"example/helpers.wire\"\n\
            \source = \"export let value = 2;\"\n"
      case decodeWirePackageManifest "cortex.toml" source of
        Left err -> expectationFailure (T.unpack (renderWirePackageManifestError err))
        Right package ->
          packageConflicts [package] `shouldContain` [DuplicateModulePath "example/helpers.wire"]
