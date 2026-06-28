{- |
Module      : Cortex.Pulse.Lowering.ExternalCallPayload
Description : Canonical external-call payload + idempotency key for a collected frontier.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The external-call payload is the substrate-owned frozen value handed to a bound
external-call driver. ADR 0059 requires it to be a __deterministic, canonical__
function of the collected frontier: the lowering supplies ordered steps, and this
module serialises them with sorted outputs so the same topology yields the same
JSON and SHA-256 digest across replays. The digest is the stable idempotency key
the crash-safe submit protocol keys on, so it must not drift between attempts.

The shape is intentionally domain-neutral. A downstream package may encode a
quantum circuit as steps over wire operands, an HTTP batch as request steps, or a
WASM/MCP call as some other ordered operation list. Pulse only stores and hashes
the frozen payload; it does not interpret the step names, operands, or outputs.
-}
module Cortex.Pulse.Lowering.ExternalCallPayload
  ( ExternalCallStep (..)
  , ExternalCallOutput (..)
  , ExternalCallPayload (..)
  , externalCallPayload
  , externalCallPayloadValue
  , externalCallPayloadDigest
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

{- | One ordered step in a collected external-call payload.

The step name, operands, and parameters are opaque to Pulse. Downstream packages
choose their own conventions while preserving the already-admitted frontier order.
-}
data ExternalCallStep = ExternalCallStep
  { ecsName :: !Text
  , ecsOperands :: ![Text]
  , ecsParams :: ![(Text, Value)]
  }
  deriving stock (Eq, Show, Generic)

{- | One output the external-call driver must return.

The optional source is domain-owned metadata (for example a collected operand id).
The label is the Wire output label used when wrapping the completed stage output.
-}
data ExternalCallOutput = ExternalCallOutput
  { ecoSource :: !(Maybe Text)
  , ecoLabel :: !Text
  }
  deriving stock (Eq, Show, Generic)

{- | The canonical external-call payload: steps in admitted frontier order, outputs
sorted by label so the encoding is order-stable.
-}
data ExternalCallPayload = ExternalCallPayload
  { ecpSteps :: ![ExternalCallStep]
  , ecpOutputs :: ![ExternalCallOutput]
  }
  deriving stock (Eq, Show, Generic)

{- | Build the canonical payload: steps are kept in the supplied admitted order;
outputs are sorted by label.
-}
externalCallPayload :: [ExternalCallStep] -> [ExternalCallOutput] -> ExternalCallPayload
externalCallPayload steps outputs =
  ExternalCallPayload
    { ecpSteps = fmap canonicalStep steps
    , ecpOutputs = sortOn ecoLabel outputs
    }
  where
    canonicalStep step = step {ecsParams = sortOn fst step.ecsParams}

-- | The canonical JSON payload the external-call stage carries.
externalCallPayloadValue :: ExternalCallPayload -> Value
externalCallPayloadValue payload =
  object
    [ "steps" .= fmap stepValue (ecpSteps payload)
    , "outputs" .= fmap outputValue (ecpOutputs payload)
    ]
  where
    stepValue step =
      object
        [ "name" .= ecsName step
        , "operands" .= ecsOperands step
        , "params" .= object [Key.fromText k .= v | (k, v) <- ecsParams step]
        ]
    outputValue out = object ["source" .= ecoSource out, "label" .= ecoLabel out]

{- | The deterministic SHA-256 digest of the canonical payload — the idempotency key
the submit/park/resume protocol keys on. Taken over a canonical tuple (not the JSON
object) so object key ordering cannot perturb it.
-}
externalCallPayloadDigest :: ExternalCallPayload -> Text
externalCallPayloadDigest payload =
  let canonical =
        Aeson.encode
          ( [ (ecsName step, ecsOperands step, [(k, v) | (k, v) <- ecsParams step])
            | step <- ecpSteps payload
            ]
          , [(ecoSource out, ecoLabel out) | out <- ecpOutputs payload]
          )
   in T.pack (show (hashlazy @SHA256 canonical))
