{- |
Module      : Cortex.Wire.RealizeCompileSpec
Description : The realize collect-node compiles with the quantum Wire packages (ADR 0059 / 0054).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

A circuit authored against @use quantum.core.{…}@ / @use quantum.braket.{@realize}@,
collecting the gate frontier into a @\@realize@ node whose outputs are the named
measurements, compiles through the normal path — the package `use` resolves and the
realize node is admitted. This is the ADR 0054 invariant (compile succeeds with no
host binding pack present; only runnable lowering needs one).
-}
module Cortex.Wire.RealizeCompileSpec (spec) where

import Data.Either (isRight)
import Data.Foldable (traverse_)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Test.Hspec

import Cortex.Wire.Compile (compileWireTextWithEnv, compileWireTextWithReturnAndEnv)
import Cortex.Wire.Contract (WireCompileEnv, emptyWireCompileEnv)
import Cortex.Wire.Package (wireCompileEnvWithPackages)
import Cortex.Wire.Package.Manifest (loadWirePackageManifests, renderWirePackageManifestError)

realizeCircuit :: Text
realizeCircuit =
  "use quantum.core.{@prepare_zero, @cnot};\n\
  \use quantum.braket.{@realize};\n\
  \\n\
  \contract Qubit;\n\
  \contract Bit;\n\
  \\n\
  \node prep_c -> control: Qubit = @prepare_zero { index = 0; } (null);\n\
  \node prep_t -> target: Qubit = @prepare_zero { index = 1; } (null);\n\
  \node entangle\n\
  \  <- control: Qubit;\n\
  \  <- target: Qubit;\n\
  \  -> control: Qubit;\n\
  \  -> target: Qubit;\n\
  \  = @cnot ({ inherit control; inherit target; });\n\
  \node collect\n\
  \  <- control: Qubit;\n\
  \  <- target: Qubit;\n\
  \  -> s0: Bit;\n\
  \  -> s1: Bit;\n\
  \  = @realize ({ inherit control; inherit target; });\n\
  \\n\
  \(prep_c <> prep_t) => entangle => collect\n"

spec :: Spec
spec =
  beforeAll
    loadQuantumCompileEnv
    ( describe "realize collect-node compilation" $ do
        it "compiles a circuit collected into @realize using the quantum packages" $ \compileEnv ->
          compileWireTextWithEnv compileEnv realizeCircuit `shouldSatisfy` isRight

        it "compiles the native QEC repetition-code realize catalog" $ \compileEnv -> do
          source <- TIO.readFile "examples/wire/qec-repetition-realize.wire"
          traverse_
            (\selected -> compileWireTextWithReturnAndEnv compileEnv selected source `shouldSatisfy` isRight)
            [ "qec_repetition_none"
            , "qec_repetition_x0"
            , "qec_repetition_x1"
            , "qec_repetition_x2"
            ]
    )

loadQuantumCompileEnv :: IO WireCompileEnv
loadQuantumCompileEnv = do
  loaded <- loadWirePackageManifests quantumManifestPaths
  packages <- either (fail . T.unpack . renderWirePackageManifestError) pure loaded
  pure (wireCompileEnvWithPackages packages emptyWireCompileEnv)

quantumManifestPaths :: [FilePath]
quantumManifestPaths =
  [ "extensions/quantum/packages/quantum-core/cortex.toml"
  , "extensions/quantum/packages/quantum-qec/cortex.toml"
  , "extensions/quantum/packages/quantum-braket/cortex.toml"
  ]
