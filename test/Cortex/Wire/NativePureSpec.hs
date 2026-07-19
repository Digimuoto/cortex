{- |
Module      : Cortex.Wire.NativePureSpec
Description : NativePure representation and plan tests.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

These specs exercise strict native-shape decoding, layout bounds, pure sum
realization, and normalized NativePure plan provenance.
-}
module Cortex.Wire.NativePureSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec

import Cortex.Wire
  ( CircuitNodeRef (..)
  , NativeLayout (..)
  , NativePureAccess (..)
  , NativePureBoundary (..)
  , NativePureBounds (..)
  , NativePureError (..)
  , NativePureKernel (..)
  , NativePureOutputBoundary (..)
  , NativePurePlan (..)
  , NativePureRegion (..)
  , NativePureVariant (..)
  , NativeShape (..)
  , NativeShapeError (..)
  , NativeShapeProjection (..)
  , RealizationArtifact (..)
  , WireCompileEnv
  , WireContractRegistry
  , WireContractSpec (..)
  , WireExecutorArgumentShape (..)
  , WireExecutorEffect (..)
  , WireExecutorId (..)
  , WireExecutorPortPolicy (..)
  , WireExecutorProjection (..)
  , WirePayloadKind (..)
  , WirePorts (..)
  , compileWireTextWithEnv
  , lowerCompiledCircuitToNativePurePlan
  , nativePurePlanSchema
  , nativeShapeLayout
  , pureWireExecutorProjection
  , realizationArtifactSchema
  , strictWireCompileEnv
  , wireContractRegistryFromList
  , wireExecutorRegistryFromList
  )

spec :: Spec
spec = do
  describe "native_shape layouts" $ do
    it "uses fixed padding for bounded text, records, and tagged sums" $ do
      nativeShapeLayout (NativeText 5) `shouldBe` Right (NativeLayout 12 4)
      nativeShapeLayout (NativeRecord (Map.fromList [("flag", NativeBool), ("score", NativeI64)]))
        `shouldBe` Right (NativeLayout 16 8)
      nativeShapeLayout (NativeSum (Map.fromList [("none", NativeUnit), ("some", NativeI64)]))
        `shouldBe` Right (NativeLayout 16 8)

    it "rejects layout overflow instead of wrapping alignment arithmetic" $ do
      -- Nested vectors approach 2^64 through checked multiplications; the
      -- final record padding step must reject rather than wrap to a tiny
      -- bogus layout.
      let hugeVector = NativeVector 4294967295 (NativeVector 536870911 NativeU64)
          overflowRecord =
            NativeRecord
              (Map.fromList [("a", hugeVector), ("b", NativeText 4294967279), ("c", NativeU64)])
      nativeShapeLayout overflowRecord `shouldBe` Left NativeShapeLayoutOverflow

  describe "native-pure-plan/v1" $ do
    it "keeps one source pure node per certified kernel and assigns read/write regions" $ do
      compiled <- requireRight (compileWireTextWithEnv nativeEnv pureProgram)
      plan <- requireRight (lowerCompiledCircuitToNativePurePlan nativeRegistry compiled)
      kernel <- case plan.nativePurePlanKernels of
        [onlyKernel] -> pure onlyKernel
        kernels ->
          expectationFailure ("expected one kernel, got " <> show (length kernels))
            >> fail "expected one kernel"
      kernel.nativePureKernelRef.unCircuitNodeRef `shouldBe` "increment"
      fmap (.nativePureRegionAccess) kernel.nativePureKernelRegions
        `shouldBe` [NativePureRead, NativePureWrite]
      fmap (.nativePureRegionName) kernel.nativePureKernelRegions
        `shouldBe` ["input.score", "output.result"]
      Aeson.toJSON kernel `shouldSatisfy` \case
        Aeson.Object objectValue ->
          KeyMap.member "outputs" objectValue && not (KeyMap.member "variant" objectValue)
        _ -> False
      Map.keys plan.nativePurePlanRealization.realizationSourceMembers
        `shouldBe` [CircuitNodeRef "increment"]
      Aeson.toJSON plan `shouldSatisfy` \case
        Aeson.Object objectValue ->
          KeyMap.lookup "schema" objectValue == Just (Aeson.String nativePurePlanSchema)
            && case KeyMap.lookup "realization" objectValue of
              Just (Aeson.Object realization) ->
                KeyMap.lookup "schema" realization == Just (Aeson.String realizationArtifactSchema)
              _ -> False
        _ -> False

    it "rejects a crossing contract without native_shape" $ do
      compiled <- requireRight (compileWireTextWithEnv unshapedEnv pureProgram)
      lowerCompiledCircuitToNativePurePlan unshapedRegistry compiled
        `shouldSatisfy` \case
          Left NativePureMissingShape {} -> True
          _ -> False

    it "preserves a declared pure sum as one tagged kernel result" $ do
      compiled <- requireRight (compileWireTextWithEnv sumEnv sumProgram)
      plan <- requireRight (lowerCompiledCircuitToNativePurePlan sumRegistry compiled)
      case plan.nativePurePlanKernels of
        [kernel] -> do
          kernel.nativePureKernelOutput `shouldSatisfy` \case
            NativePureSum _ variants ->
              fmap (.nativePureBoundaryLabel) variants == ["accepted", "rejected"]
            _ -> False
          fmap (.nativePureVariantLabels) kernel.nativePureKernelVariant
            `shouldBe` Just ["accepted", "rejected"]
          fmap (.nativePureRegionName) kernel.nativePureKernelRegions
            `shouldBe` ["input.score", "output.variant"]
          fmap (.nativePureRegionCapacity) kernel.nativePureKernelRegions
            `shouldBe` [8, 16]
          Aeson.toJSON kernel `shouldSatisfy` \case
            Aeson.Object objectValue ->
              KeyMap.member "variant" objectValue && not (KeyMap.member "outputs" objectValue)
            _ -> False
        kernels -> expectationFailure ("expected one sum kernel, got " <> show (length kernels))

    it "rejects a pure sum branch that does not return a declared constructor" $
      compileWireTextWithEnv sumEnv invalidSumProgram
        `shouldSatisfy` \case
          Left err -> "Every pure sum control-flow path must return" `T.isInfixOf` T.pack (show err)
          Right _ -> False

    it "rejects a pure sum constructor with the wrong arity" $
      compileWireTextWithEnv sumEnv invalidSumArityProgram
        `shouldSatisfy` \case
          Left err -> "requires exactly one payload" `T.isInfixOf` T.pack (show err)
          Right _ -> False

    it "rejects a local binding that shadows a pure sum constructor" $
      compileWireTextWithEnv sumEnv invalidSumShadowProgram
        `shouldSatisfy` \case
          Left err -> "shadowed by a local binding" `T.isInfixOf` T.pack (show err)
          Right _ -> False

    it "binds only realized kernels into the witness for a mixed program" $ do
      compiled <- requireRight (compileWireTextWithEnv mixedEnv mixedProgram)
      plan <- requireRight (lowerCompiledCircuitToNativePurePlan nativeRegistry compiled)
      fmap (.nativePureKernelRef) plan.nativePurePlanKernels
        `shouldBe` [CircuitNodeRef "increment"]
      Map.keys plan.nativePurePlanRealization.realizationSourceMembers
        `shouldBe` [CircuitNodeRef "increment"]
      Map.keys plan.nativePurePlanRealization.realizationRuntimeMembers
        `shouldBe` [CircuitNodeRef "increment"]

    it "rejects expressions outside the certified kernel basis" $ do
      compiled <- requireRight (compileWireTextWithEnv nativeEnv divisionProgram)
      lowerCompiledCircuitToNativePurePlan nativeRegistry compiled
        `shouldSatisfy` \case
          Left (NativePureUnsupportedExpression _ reason) -> "division" `T.isInfixOf` reason
          _ -> False

    it "rejects builtin calls in kernel bodies" $ do
      compiled <- requireRight (compileWireTextWithEnv nativeEnv builtinCallProgram)
      lowerCompiledCircuitToNativePurePlan nativeRegistry compiled
        `shouldSatisfy` \case
          Left (NativePureUnsupportedExpression _ reason) -> "builtin calls" `T.isInfixOf` reason
          _ -> False

    it "rejects kernels whose worst-case checkpoint exceeds 2 MiB" $ do
      compiled <- requireRight (compileWireTextWithEnv bigTextEnv bigTextProgram)
      lowerCompiledCircuitToNativePurePlan bigTextRegistry compiled
        `shouldSatisfy` \case
          Left NativePureCheckpointTooLarge {} -> True
          _ -> False

    it "computes exact step and static-byte bounds for the admitted basis" $ do
      compiled <- requireRight (compileWireTextWithEnv nativeEnv pureProgram)
      plan <- requireRight (lowerCompiledCircuitToNativePurePlan nativeRegistry compiled)
      case plan.nativePurePlanKernels of
        [kernel] -> do
          -- score + 1 is: binary(1) + ident(1) + literal(1).
          kernel.nativePureKernelBounds.nativePureBoundSteps `shouldBe` 3
          kernel.nativePureKernelBounds.nativePureBoundStaticBytes `shouldBe` 0
        kernels -> expectationFailure ("expected one kernel, got " <> show (length kernels))

pureProgram :: Text
pureProgram =
  "contract Score;\n\
  \contract Result;\n\
  \node increment <- score: Score -> result: Result = score + 1;\n\
  \increment"

divisionProgram :: Text
divisionProgram =
  "contract Score;\n\
  \contract Result;\n\
  \node halve <- score: Score -> result: Result = score / 2;\n\
  \halve"

builtinCallProgram :: Text
builtinCallProgram =
  "contract Score;\n\
  \contract Result;\n\
  \node total <- score: Score -> result: Result = sum([score]);\n\
  \total"

mixedProgram :: Text
mixedProgram =
  "contract Score;\n\
  \contract Result;\n\
  \node increment <- score: Score -> result: Result = score + 1;\n\
  \node store <- result: Result = @report.store result;\n\
  \increment\n\
  \  => store"

mixedEnv :: WireCompileEnv
mixedEnv =
  strictWireCompileEnv
    (wireExecutorRegistryFromList [pureWireExecutorProjection, storeExecutorProjection])
    nativeRegistry

storeExecutorProjection :: WireExecutorProjection
storeExecutorProjection =
  WireExecutorProjection
    { wireExecutorProjectionId = WireExecutorId "report.store"
    , wireExecutorProjectionPorts = WirePorts {wirePortsInputs = Map.empty, wirePortsOutputs = Map.empty}
    , wireExecutorProjectionVocabulary = Set.empty
    , wireExecutorProjectionEffect = WireExecutorHostEffect
    , wireExecutorProjectionArgumentShape = WireExecutorArgumentUnchecked
    , wireExecutorProjectionPortPolicy = WireExecutorAuthorDeclaredPorts
    }

bigTextProgram :: Text
bigTextProgram =
  "contract Blob;\n\
  \contract BlobCopy;\n\
  \node copy <- blob: Blob -> result: BlobCopy = blob;\n\
  \copy"

bigTextEnv :: WireCompileEnv
bigTextEnv =
  strictWireCompileEnv (wireExecutorRegistryFromList [pureWireExecutorProjection]) bigTextRegistry

{- | Two ~1.5 MiB bounded-text boundaries: each side fits, the combined
worst-case checkpoint exceeds the 2 MiB ceiling.
-}
bigTextRegistry :: WireContractRegistry
bigTextRegistry =
  wireContractRegistryFromList
    [ contract "Blob" (Just (NativeText 1572864))
    , contract "BlobCopy" (Just (NativeText 1572864))
    ]

nativeEnv :: WireCompileEnv
nativeEnv = strictWireCompileEnv (wireExecutorRegistryFromList [pureWireExecutorProjection]) nativeRegistry

unshapedEnv :: WireCompileEnv
unshapedEnv = strictWireCompileEnv (wireExecutorRegistryFromList [pureWireExecutorProjection]) unshapedRegistry

nativeRegistry :: WireContractRegistry
nativeRegistry =
  wireContractRegistryFromList [contract "Score" (Just NativeI64), contract "Result" (Just NativeI64)]

unshapedRegistry :: WireContractRegistry
unshapedRegistry = wireContractRegistryFromList [contract "Score" Nothing, contract "Result" (Just NativeI64)]

sumProgram :: Text
sumProgram =
  "contract Score;\n\
  \contract Decision;\n\
  \contract RejectReason;\n\
  \node classify <- score: Score -> accepted: Decision | rejected: RejectReason = if score >= 0 then accepted score else rejected score;\n\
  \classify"

invalidSumProgram :: Text
invalidSumProgram =
  "contract Score;\n\
  \contract Decision;\n\
  \contract RejectReason;\n\
  \node classify <- score: Score -> accepted: Decision | rejected: RejectReason = if score >= 0 then score else rejected score;\n\
  \classify"

invalidSumArityProgram :: Text
invalidSumArityProgram =
  "contract Score;\n\
  \contract Decision;\n\
  \contract RejectReason;\n\
  \node classify <- score: Score -> accepted: Decision | rejected: RejectReason = if score >= 0 then accepted score score else rejected score;\n\
  \classify"

invalidSumShadowProgram :: Text
invalidSumShadowProgram =
  "contract Score;\n\
  \contract Decision;\n\
  \contract RejectReason;\n\
  \node classify <- score: Score -> accepted: Decision | rejected: RejectReason = let accepted = score; in accepted score;\n\
  \classify"

sumEnv :: WireCompileEnv
sumEnv = strictWireCompileEnv (wireExecutorRegistryFromList [pureWireExecutorProjection]) sumRegistry

sumRegistry :: WireContractRegistry
sumRegistry =
  wireContractRegistryFromList
    [ contract "Score" (Just NativeI64)
    , contract "Decision" (Just NativeI64)
    , contract "RejectReason" (Just NativeI64)
    ]

contract :: Text -> Maybe NativeShape -> WireContractSpec
contract contractId shape =
  WireContractSpec
    { wireContractSpecId = contractId
    , wireContractSpecPayloadKind = WirePayloadJson
    , wireContractSpecDescription = contractId
    , wireContractSpecRecordFields = Nothing
    , wireContractSpecSchema = Nothing
    , wireContractSpecNativeShape = NativeShapeProjection <$> shape
    , wireContractSpecExamples = []
    }

requireRight :: Show error => Either error value -> IO value
requireRight = \case
  Left err -> expectationFailure (show err) >> fail "expected Right"
  Right value -> pure value
