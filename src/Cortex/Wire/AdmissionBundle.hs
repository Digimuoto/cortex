{- |
Module      : Cortex.Wire.AdmissionBundle
Description : Unified Wire admission bundle gate.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

`Cortex.Wire.AdmissionArtifact` validates the internal proof-witness artifact,
and `Cortex.Wire.AdmissionBinding` checks that the artifact travels with the
compiled circuit it describes. This module is the named join between those two
surfaces: a `WireAdmissionBundle` is only constructed after both gates pass.

The first implementation slice is still Haskell-side. Its purpose is to make
the boundary explicit and replaceable: a later Lean runtime checker can become
the authority behind this module without every compiler call site having to
remember the individual predicates and their ordering.
-}
module Cortex.Wire.AdmissionBundle
  ( AdmissionBundleError (..)
  , WireAdmissionBundle (..)
  , admitWireAdmissionBundle
  , renderAdmissionBundleError
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

import Cortex.Wire.AdmissionArtifact
  ( WireAdmissionArtifact (..)
  , wireAdmissionArtifactValidatorReady
  , wireAdmissionCurrentSchemaVersion
  )
import Cortex.Wire.AdmissionBinding
  ( AdmissionBindingError
  , admissionArtifactBindsCompiledCircuit
  , renderAdmissionBindingError
  )
import Cortex.Wire.Circuit.Compiled (CompiledCircuit)

{- | Why a candidate artifact/circuit pair did not form a unified admission
bundle. The validator-ready check runs first because circuit binding is only
meaningful for an internally sound artifact.
-}
data AdmissionBundleError
  = AdmissionBundleArtifactNotValidatorReady
  | AdmissionBundleCircuitBindingFailed !AdmissionBindingError
  deriving stock (Eq, Show)

renderAdmissionBundleError :: AdmissionBundleError -> Text
renderAdmissionBundleError = \case
  AdmissionBundleArtifactNotValidatorReady ->
    "artifact failed validator-ready checks"
  AdmissionBundleCircuitBindingFailed bindingError ->
    "artifact does not bind to the compiled circuit: " <> renderAdmissionBindingError bindingError

{- | A proof-witness artifact that has passed the current Haskell-side unified
admission gate for the compiled circuit it travels with.

The bundle deliberately stores the artifact, not the full circuit. The binding
checker validates the circuit relationship at construction time; consumers that
need to re-check a transported pair should call `admitWireAdmissionBundle`
again with the current circuit.
-}
data WireAdmissionBundle = WireAdmissionBundle
  { wireAdmissionBundleSchemaVersion :: !Natural
  , wireAdmissionBundleArtifact :: !WireAdmissionArtifact
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

admitWireAdmissionBundle
  :: WireAdmissionArtifact
  -> CompiledCircuit
  -> Either AdmissionBundleError WireAdmissionBundle
admitWireAdmissionBundle artifact circuit
  | not (wireAdmissionArtifactValidatorReady artifact) =
      Left AdmissionBundleArtifactNotValidatorReady
  | otherwise =
      case admissionArtifactBindsCompiledCircuit artifact circuit of
        Left bindingError ->
          Left (AdmissionBundleCircuitBindingFailed bindingError)
        Right () ->
          Right
            WireAdmissionBundle
              { wireAdmissionBundleSchemaVersion = wireAdmissionCurrentSchemaVersion
              , wireAdmissionBundleArtifact = artifact
              }
