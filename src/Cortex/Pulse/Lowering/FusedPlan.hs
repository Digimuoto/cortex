{- |
Module      : Cortex.Pulse.Lowering.FusedPlan
Description : Canonical fused sub-plan + idempotency key for a realize frontier (ADR 0059 §2/§3).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The fused sub-plan is the backend-neutral payload a realize stage carries (the
operation/measurement list the standalone bridge's @build_quantum_plan@ builds
today). ADR 0059 §2 requires its emission to be a __deterministic, canonical__
function of the frozen frontier: the lowering supplies operations in topological
order, and this module serialises them and the measurements (sorted by output name)
so the same topology yields the same JSON and the same SHA-256 digest across
replays. The digest is the stable idempotency key the crash-safe submit protocol
(§3) keys on, so it must not drift between attempts.
-}
module Cortex.Pulse.Lowering.FusedPlan
  ( FusedOp (..)
  , FusedMeasurement (..)
  , FusedPlan (..)
  , fusedPlan
  , fusedPlanValue
  , fusedPlanDigest
  )
where

import Crypto.Hash (SHA256, hashlazy)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

{- | One backend-neutral operation: a gate name, its qubit wire indices in order,
and named scalar parameters (e.g. a rotation angle).
-}
data FusedOp = FusedOp
  { foGate :: !Text
  , foWires :: ![Int]
  , foParams :: ![(Text, Value)]
  }
  deriving stock (Eq, Show, Generic)

-- | A terminal measurement: the qubit wire and the output port name it produces.
data FusedMeasurement = FusedMeasurement
  { fmWire :: !Int
  , fmOutput :: !Text
  }
  deriving stock (Eq, Show, Generic)

{- | The canonical fused plan: operations in topological order, measurements sorted
by output name so the encoding is order-stable.
-}
data FusedPlan = FusedPlan
  { fpOperations :: ![FusedOp]
  , fpMeasurements :: ![FusedMeasurement]
  }
  deriving stock (Eq, Show, Generic)

{- | Build the canonical plan: operations are kept in the supplied (topological)
order; measurements are sorted by output name.
-}
fusedPlan :: [FusedOp] -> [FusedMeasurement] -> FusedPlan
fusedPlan operations measurements =
  FusedPlan
    { fpOperations = operations
    , fpMeasurements = sortOn fmOutput measurements
    }

-- | The canonical JSON payload the realize stage carries.
fusedPlanValue :: FusedPlan -> Value
fusedPlanValue plan =
  object
    [ "operations" .= fmap opValue (fpOperations plan)
    , "measurements" .= fmap measurementValue (fpMeasurements plan)
    ]
  where
    opValue op =
      object
        [ "gate" .= foGate op
        , "wires" .= foWires op
        , "params" .= object [Key.fromText k .= v | (k, v) <- foParams op]
        ]
    measurementValue m = object ["wire" .= fmWire m, "output" .= fmOutput m]

{- | The deterministic SHA-256 digest of the canonical plan — the idempotency key
the submit/park/resume protocol keys on. Taken over a canonical tuple (not the JSON
object) so object key ordering cannot perturb it.
-}
fusedPlanDigest :: FusedPlan -> Text
fusedPlanDigest plan =
  let canonical =
        Aeson.encode
          ( [(foGate op, foWires op, [(k, v) | (k, v) <- foParams op]) | op <- fpOperations plan]
          , [(fmWire m, fmOutput m) | m <- fpMeasurements plan]
          )
   in T.pack (show (hashlazy @SHA256 canonical))
