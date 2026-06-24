{- |
Module      : Cortex.Quantum.Compile
Description : In-process compilation of a selected Wire quantum export.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Thin IO helpers the quantum runners share: compose a 'WireCompileEnv' from the
opt-in quantum package manifests (the @CORTEX_WIRE_PACKAGE_MANIFESTS@ search path,
ADR 0060) and compile a selected export of a @.wire@ source to a 'CompiledCircuit'
in-process — the same path @wire build --return@ takes, without a subprocess.
-}
module Cortex.Quantum.Compile
  ( loadQuantumCompileEnv
  , compileExport
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import System.Environment (lookupEnv)

import Cortex.Wire (CompiledCircuit, renderWireError)
import Cortex.Wire.Compile (compileWireModules, compileWireModulesWithReturn)
import Cortex.Wire.Contract (WireCompileEnv, emptyWireCompileEnv)
import Cortex.Wire.Import (loadWireModuleClosure, renderWireImportError)
import Cortex.Wire.Package
  ( packageConflicts
  , renderPackageConflict
  , wireCompileEnvWithPackages
  )
import Cortex.Wire.Package.Manifest
  ( loadWirePackageManifests
  , renderWirePackageManifestError
  )

{- | Compose a compile environment from the @CORTEX_WIRE_PACKAGE_MANIFESTS@
search path. Without it, only Cortex's standard namespaces are known and a
@use quantum.*@ source fails to resolve.
-}
loadQuantumCompileEnv :: IO (Either Text WireCompileEnv)
loadQuantumCompileEnv = do
  manifestPaths <- packageManifestPaths
  loaded <- loadWirePackageManifests manifestPaths
  pure $ case loaded of
    Left err -> Left (renderWirePackageManifestError err)
    Right packages ->
      case packageConflicts packages of
        [] -> Right (wireCompileEnvWithPackages packages emptyWireCompileEnv)
        conflicts ->
          Left ("conflicting Wire packages: " <> T.intercalate "; " (map renderPackageConflict conflicts))

packageManifestPaths :: IO [FilePath]
packageManifestPaths = do
  configured <- lookupEnv "CORTEX_WIRE_PACKAGE_MANIFESTS"
  pure $ case configured of
    Just raw | not (null raw) -> filter (not . null) (map T.unpack (T.splitOn ":" (T.pack raw)))
    _ -> []

{- | Compile a @.wire@ source, optionally selecting a named export, to a
'CompiledCircuit'.
-}
compileExport :: WireCompileEnv -> Maybe Text -> FilePath -> IO (Either Text CompiledCircuit)
compileExport env selectedReturn path = do
  closure <- loadWireModuleClosure path
  pure $ case closure of
    Left err -> Left (renderWireImportError err)
    Right modules ->
      let compile = maybe (compileWireModules env) (compileWireModulesWithReturn env) selectedReturn
       in either (Left . renderWireError) Right (compile modules)
