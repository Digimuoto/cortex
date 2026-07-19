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

import Data.Aeson qualified as Aeson
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.UUID qualified as UUID
import Test.Hspec

import Cortex.Pulse.Node (NodeId (..))
import Cortex.Wire
  ( NativeShape (..)
  , NativeShapeProjection (..)
  , WireContractRegistry
  , WireContractSpec (..)
  , WireExecutorArgumentShape (..)
  , WireOutputPort (..)
  , WirePorts (..)
  , validateWireExecutorArgument
  , wireContractRegistryFromList
  , wireExecutorArgumentIngressShape
  , wireExecutorArgumentStaticFields
  , wireExecutorArgumentStaticShape
  , wireExecutorProjectionArgumentShape
  , wireExecutorProjectionIngressShape
  , wrapWireStageOutput
  )
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

  describe "executor argument manifests" $ do
    let manifest shapeField =
          "[package]\nid = \"shape-test\"\n[[executor]]\nid = \"review\"\neffect = \"model\"\n"
            <> shapeField
            <> "\n"
        decodedShape shapeField = do
          package <- decodeWirePackageManifest "cortex.toml" (manifest shapeField)
          case package.wpExecutorProjections of
            [projection] -> Right (wireExecutorProjectionArgumentShape projection)
            _ -> Left (error "expected one executor projection")

    it "rejects the obsolete config_shape key" $ do
      let source =
            "[package]\n\
            \id = \"legacy\"\n\
            \[[executor]]\n\
            \id = \"legacy.run\"\n\
            \effect = \"host_effect\"\n\
            \config_shape = \"unchecked\"\n"
      case decodeWirePackageManifest "cortex.toml" source of
        Left err ->
          renderWirePackageManifestError err
            `shouldSatisfy` T.isInfixOf "config_shape was removed; use argument_shape"
        Right _ -> expectationFailure "obsolete config_shape unexpectedly decoded"

    it "decodes the argument_shape schema table form" $
      case decodedShape "argument_shape = { schema = { type = \"object\" } }" of
        Right (WireExecutorArgumentSchema _schema) -> pure ()
        other -> expectationFailure ("expected a schema argument shape, got " <> show other)

    it "rejects unknown argument_shape strings" $
      case decodeWirePackageManifest "cortex.toml" (manifest "argument_shape = \"bogus\"") of
        Left err ->
          renderWirePackageManifestError err
            `shouldSatisfy` T.isInfixOf "unknown Wire executor argument shape"
        Right _ -> expectationFailure "unknown argument shape unexpectedly decoded"

    it "derives one total admission/ingress partition from argument_shape" $ do
      let shapeField =
            "argument_shape = { schema = { type = \"object\", required = [\"profile\", \"payload\"], additionalProperties = false, properties = { profile = { type = \"string\", x-cortex-binding-time = \"admission\" }, payload = { type = \"string\" } } } }"
      shape <- requireRight (decodedShape shapeField)
      wireExecutorArgumentStaticFields shape `shouldBe` Right (Set.singleton "profile")
      staticShape <- requireRight (wireExecutorArgumentStaticShape shape)
      ingressShape <- requireRight (wireExecutorArgumentIngressShape shape)
      validateWireExecutorArgument
        staticShape
        (Aeson.object ["profile" Aeson..= ("reasoner" :: Text)])
        `shouldBe` Right (Aeson.object ["profile" Aeson..= ("reasoner" :: Text)])
      validateWireExecutorArgument
        ingressShape
        (Aeson.object ["payload" Aeson..= ("hello" :: Text)])
        `shouldBe` Right (Aeson.object ["payload" Aeson..= ("hello" :: Text)])
      package <- requireRight (decodeWirePackageManifest "cortex.toml" (manifest shapeField))
      case package.wpExecutorProjections of
        [projection] -> wireExecutorProjectionIngressShape projection `shouldBe` Right ingressShape
        _ -> expectationFailure "expected one executor projection"

    it "rejects malformed field binding-time obligations" $
      case decodeWirePackageManifest
        "cortex.toml"
        ( manifest
            "argument_shape = { schema = { type = \"object\", properties = { profile = { type = \"string\", x-cortex-binding-time = \"sometimes\" } } } }"
        ) of
        Left err ->
          renderWirePackageManifestError err
            `shouldSatisfy` T.isInfixOf "unknown x-cortex-binding-time sometimes"
        Right _ -> expectationFailure "invalid executor binding-time unexpectedly decoded"

    it "rejects the obsolete config_shape key in table-header spelling" $ do
      let source =
            "[package]\n\
            \id = \"legacy\"\n\
            \[[executor]]\n\
            \id = \"legacy.run\"\n\
            \effect = \"host_effect\"\n\
            \[executor.config_shape]\n\
            \schema = \"legacy.schema\"\n"
      case decodeWirePackageManifest "cortex.toml" source of
        Left err ->
          renderWirePackageManifestError err
            `shouldSatisfy` T.isInfixOf "config_shape was removed; use argument_shape"
        Right _ -> expectationFailure "obsolete config_shape unexpectedly decoded"

    it "rejects the obsolete config_shape key in dotted-key spelling" $ do
      let source =
            "[package]\n\
            \id = \"legacy\"\n\
            \[[executor]]\n\
            \id = \"legacy.run\"\n\
            \effect = \"host_effect\"\n\
            \config_shape.schema = \"legacy.schema\"\n"
      case decodeWirePackageManifest "cortex.toml" source of
        Left err ->
          renderWirePackageManifestError err
            `shouldSatisfy` T.isInfixOf "config_shape was removed; use argument_shape"
        Right _ -> expectationFailure "obsolete config_shape unexpectedly decoded"

    it "accepts config_shape text inside a multi-line string value" $ do
      let source =
            "[package]\n\
            \id = \"docs\"\n\
            \[[executor]]\n\
            \id = \"docs.run\"\n\
            \effect = \"pure\"\n\
            \[[module]]\n\
            \path = \"example/notes.wire\"\n\
            \source = \"\"\"\n\
            \-- migration note, not a key:\n\
            \config_shape = \"unchecked\"\n\
            \export let value = 1;\n\
            \\"\"\"\n"
      case decodeWirePackageManifest "cortex.toml" source of
        Left err -> expectationFailure (T.unpack (renderWirePackageManifestError err))
        Right package ->
          Map.lookup "example/notes.wire" package.wpModuleSources
            `shouldSatisfy` maybe False (T.isInfixOf "config_shape = \"unchecked\"")

  describe "native contract shape manifests" $ do
    it "decodes scalar and bounded native_shape projections" $ do
      let source =
            "[package]\n\
            \id = \"native\"\n\
            \[[contract]]\n\
            \id = \"Score\"\n\
            \payload_kind = \"json\"\n\
            \native_shape = { schema = \"cortex.wire.native-shape/v1\", shape = \"i64\" }\n\
            \[[contract]]\n\
            \id = \"Name\"\n\
            \payload_kind = \"json\"\n\
            \native_shape = { schema = \"cortex.wire.native-shape/v1\", shape = { kind = \"text\", capacity = 64 } }\n"
      case decodeWirePackageManifest "cortex.toml" source of
        Left err -> expectationFailure (T.unpack (renderWirePackageManifestError err))
        Right package ->
          fmap wireContractSpecNativeShape package.wpContractSpecs
            `shouldBe` [ Just (NativeShapeProjection NativeI64)
                       , Just (NativeShapeProjection (NativeText 64))
                       ]

    it "rejects unknown native_shape fields instead of silently weakening the representation" $ do
      let source =
            "[package]\n\
            \id = \"native\"\n\
            \[[contract]]\n\
            \id = \"Name\"\n\
            \payload_kind = \"json\"\n\
            \native_shape = { schema = \"cortex.wire.native-shape/v1\", shape = { kind = \"text\", capacity = 64, encoding = \"utf16\" } }\n"
      case decodeWirePackageManifest "cortex.toml" source of
        Left err ->
          renderWirePackageManifestError err
            `shouldSatisfy` T.isInfixOf "fields must be exactly: capacity, kind"
        Right _ -> expectationFailure "unknown native_shape field unexpectedly decoded"

    it "rejects unversioned native_shape projections" $ do
      let source =
            "[package]\n\
            \id = \"native\"\n\
            \[[contract]]\n\
            \id = \"Score\"\n\
            \payload_kind = \"json\"\n\
            \native_shape = \"i64\"\n"
      case decodeWirePackageManifest "cortex.toml" source of
        Left err ->
          renderWirePackageManifestError err
            `shouldSatisfy` T.isInfixOf "expected Object"
        Right _ -> expectationFailure "unversioned native_shape unexpectedly decoded"

    it "rejects an unknown native_shape projection version" $ do
      let source =
            "[package]\n\
            \id = \"native\"\n\
            \[[contract]]\n\
            \id = \"Score\"\n\
            \payload_kind = \"json\"\n\
            \native_shape = { schema = \"cortex.wire.native-shape/v2\", shape = \"i64\" }\n"
      case decodeWirePackageManifest "cortex.toml" source of
        Left err ->
          renderWirePackageManifestError err
            `shouldSatisfy` T.isInfixOf "unsupported native_shape schema"
        Right _ -> expectationFailure "unknown native_shape schema unexpectedly decoded"

  describe "ADR 0085 manifest schema end-to-end" $ do
    it "enforces a manifest-declared contract schema at runtime egress" $ do
      registry' <- schemaManifestRegistry
      wrapWireStageOutput
        (Just registry')
        (NodeId "reporter")
        (UUID.fromWords 0 0 0 0)
        reportPorts
        (Aeson.object [])
        `shouldSatisfy` \case
          Left err -> "missing required property title" `T.isInfixOf` err
          Right _ -> False

    it "accepts a schema-satisfying payload from the same manifest registry" $ do
      registry' <- schemaManifestRegistry
      wrapWireStageOutput
        (Just registry')
        (NodeId "reporter")
        (UUID.fromWords 0 0 0 0)
        reportPorts
        (Aeson.object ["title" Aeson..= ("Q1" :: Text)])
        `shouldSatisfy` \case
          Left _ -> False
          Right _ -> True

reportPorts :: WirePorts
reportPorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs = Map.singleton "report" (WireOutputPort "Report" Nothing)
    }

{- | Decodes a manifest whose @[[contract]]@ stanza declares a @schema@ and
projects it into the runtime contract registry, proving the TOML->registry
plumbing end-to-end (ADR 0085).
-}
schemaManifestRegistry :: IO WireContractRegistry
schemaManifestRegistry =
  case decodeWirePackageManifest "cortex.toml" manifestSource of
    Left err -> fail (T.unpack (renderWirePackageManifestError err))
    Right package -> pure (wireContractRegistryFromList package.wpContractSpecs)
  where
    manifestSource =
      "[package]\n\
      \id = \"reports\"\n\
      \\n\
      \[[contract]]\n\
      \id = \"Report\"\n\
      \payload_kind = \"json\"\n\
      \description = \"Report payload\"\n\
      \schema = { type = \"object\", required = [\"title\"], properties = { title = { type = \"string\" } } }\n"

requireRight :: Show e => Either e a -> IO a
requireRight = \case
  Left err -> expectationFailure (show err) >> fail "unreachable"
  Right value -> pure value
