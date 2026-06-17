{- |
Module      : Cortex.Wire.Quantum
Description : The quantum Wire packages (ADR 0059 first downstream consumer of ADR 0054).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The quantum surface as inert Wire packages (ADR 0054): @quantum.core@ (generic
circuit vocabulary — prepare_zero / x / cnot / measure_z and the data contracts),
@quantum.qec@ (reusable QEC contracts), and @quantum.braket@ (the @realize@
collect-node projection). These carry no runtime authority; a host binding pack
(Capability layer, e.g. the Braket pack) resolves @quantum.realize@ to a runnable
stage. Canonical executor ids match the structurally-admitted @\@quantum.*@ surface
the existing examples use (namespace @quantum.core@, leaf @prepare_zero@ →
@quantum.prepare_zero@), so packaging is additive, not a rename.
-}
module Cortex.Wire.Quantum
  ( quantumCorePackage
  , quantumQecPackage
  , quantumBraketPackage
  , quantumPackages
  , realizeExecutorId
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)

import Cortex.Wire.AST (WirePorts (..))
import Cortex.Wire.Contract (WireContractSpec (..))
import Cortex.Wire.Executor
  ( WireExecutorConfigShape (..)
  , WireExecutorEffect (..)
  , WireExecutorId (..)
  , WireExecutorPortPolicy (..)
  , WireExecutorProjection (..)
  )
import Cortex.Wire.Package (NamespaceEntry (..), WirePackage (..))
import Cortex.Wire.Value (WirePayloadKind (..))

-- | The canonical id of the realize collect node (ADR 0059 §2).
realizeExecutorId :: Text
realizeExecutorId = "quantum.realize"

coreExecutors :: Map Text Text
coreExecutors =
  Map.fromList
    [ ("prepare_zero", "quantum.prepare_zero")
    , ("x", "quantum.x")
    , ("cnot", "quantum.cnot")
    , ("measure_z", "quantum.measure_z")
    , ("rz", "quantum.rz")
    , ("h", "quantum.h")
    ]

coreContracts :: Map Text Text
coreContracts =
  Map.fromList
    [ ("Qubit", "quantum.Qubit")
    , ("Bit", "quantum.Bit")
    , ("QuantumResult", "quantum.QuantumResult")
    , ("MeasurementCounts", "quantum.MeasurementCounts")
    , ("ShotCount", "quantum.ShotCount")
    , ("BackendConfig", "quantum.BackendConfig")
    ]

qecContracts :: Map Text Text
qecContracts =
  Map.fromList
    [ ("RepetitionResult", "quantum.RepetitionResult")
    , ("Syndrome", "quantum.Syndrome")
    ]

braketExecutors :: Map Text Text
braketExecutors = Map.fromList [("realize", realizeExecutorId)]

mapEntry :: Text -> Map Text Text -> Map Text Text -> NamespaceEntry
mapEntry namespace execs contracts =
  NamespaceEntry
    { nsNamespace = namespace
    , nsResolveExecutorLeaf = (`Map.lookup` execs)
    , nsResolveContract = (`Map.lookup` contracts)
    }

{- | An author-declared-ports, host-effecting executor projection over the quantum
contract vocabulary. The author declares concrete ports per node (gates are
single-qubit/two-qubit; @realize@ declares one output per named measurement).
-}
quantumProjection :: Text -> WireExecutorProjection
quantumProjection executorId =
  WireExecutorProjection
    { wireExecutorProjectionId = WireExecutorId executorId
    , wireExecutorProjectionPorts = WirePorts Map.empty Map.empty
    , wireExecutorProjectionVocabulary = Set.fromList (Map.elems coreContracts)
    , wireExecutorProjectionEffect = WireExecutorHostEffect
    , wireExecutorProjectionConfigShape = WireExecutorConfigUnchecked
    , wireExecutorProjectionPortPolicy = WireExecutorAuthorDeclaredPorts
    }

contractSpec :: Text -> Text -> WireContractSpec
contractSpec contractId description =
  WireContractSpec
    { wireContractSpecId = contractId
    , wireContractSpecPayloadKind = WirePayloadJson
    , wireContractSpecDescription = description
    , wireContractSpecRecordFields = Nothing
    , wireContractSpecSchema = Nothing
    , wireContractSpecExamples = []
    }

quantumCorePackage :: WirePackage
quantumCorePackage =
  WirePackage
    { wpId = "quantum.core"
    , wpNamespaceEntries = [mapEntry "quantum.core" coreExecutors coreContracts]
    , wpExecutorProjections = fmap quantumProjection (Map.elems coreExecutors)
    , wpContractSpecs =
        [ contractSpec cid ("Quantum core contract " <> cid)
        | cid <- Map.elems coreContracts
        ]
    }

quantumQecPackage :: WirePackage
quantumQecPackage =
  WirePackage
    { wpId = "quantum.qec"
    , wpNamespaceEntries = [mapEntry "quantum.qec" Map.empty qecContracts]
    , wpExecutorProjections = []
    , wpContractSpecs =
        [ contractSpec cid ("Quantum QEC contract " <> cid)
        | cid <- Map.elems qecContracts
        ]
    }

quantumBraketPackage :: WirePackage
quantumBraketPackage =
  WirePackage
    { wpId = "quantum.braket"
    , wpNamespaceEntries = [mapEntry "quantum.braket" braketExecutors Map.empty]
    , wpExecutorProjections = [quantumProjection realizeExecutorId]
    , wpContractSpecs = []
    }

-- | All quantum Wire packages, composed by a host's package set (ADR 0054).
quantumPackages :: [WirePackage]
quantumPackages = [quantumCorePackage, quantumQecPackage, quantumBraketPackage]
