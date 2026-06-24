{- |
Module      : Cortex.Quantum.TestSupport
Description : Shared helpers for the quantum runner specs.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Compile-environment loading and in-process compilation helpers the
@Cortex.Quantum.*@ specs share. Manifest paths are relative to the repository root
(the test runner's working directory).
-}
module Cortex.Quantum.TestSupport
  ( loadTestEnv
  , compileText
  , compileReturn
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as T

import Cortex.Wire (CompiledCircuit, renderWireError)
import Cortex.Wire.Compile (compileWireTextWithEnv, compileWireTextWithReturnAndEnv)
import Cortex.Wire.Contract (WireCompileEnv, emptyWireCompileEnv)
import Cortex.Wire.Package (wireCompileEnvWithPackages)
import Cortex.Wire.Package.Manifest (loadWirePackageManifests, renderWirePackageManifestError)

manifestPaths :: [FilePath]
manifestPaths =
  [ "extensions/quantum/packages/quantum-core/cortex.toml"
  , "extensions/quantum/packages/quantum-qec/cortex.toml"
  , "extensions/quantum/packages/quantum-braket/cortex.toml"
  ]

loadTestEnv :: IO WireCompileEnv
loadTestEnv = do
  loaded <- loadWirePackageManifests manifestPaths
  packages <- either (fail . T.unpack . renderWirePackageManifestError) pure loaded
  pure (wireCompileEnvWithPackages packages emptyWireCompileEnv)

compileText :: WireCompileEnv -> Text -> Either Text CompiledCircuit
compileText env source = first renderWireError (compileWireTextWithEnv env source)

compileReturn :: WireCompileEnv -> Text -> Text -> Either Text CompiledCircuit
compileReturn env selectedReturn source =
  first renderWireError (compileWireTextWithReturnAndEnv env selectedReturn source)
