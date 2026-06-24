{- |
Module      : Cortex.Quantum.Cost
Description : Embedded Amazon Braket quantum-task cost estimates.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

A pure, exact-decimal estimate of an Amazon Braket quantum-task cost, ported from
the standalone bridge's embedded public pricing. QPU tasks are priced per-task plus
per-shot; managed simulators are priced by billed wall-clock duration (with a
three-second floor). Both prices can be overridden through environment values;
device ARNs with no embedded rule yield an explicit @unavailable@ estimate rather
than a guess. All arithmetic is 'Rational' so the reported figure does not drift.
-}
module Cortex.Quantum.Cost
  ( TaskMeta (..)
  , CostOverrides (..)
  , noCostOverrides
  , CostEstimate (..)
  , CostStatus (..)
  , estimateTaskCost
  , estimatedCostDouble
  , costEstimateAmount
  , costEstimateText
  , costEstimateToJSON
  , formatUsd
  )
where

import Control.Applicative ((<|>))
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.List (find)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T

-- | Task metadata required for completion-time pricing.
data TaskMeta = TaskMeta
  { taskSuccessfulShots :: !(Maybe Int)
  , taskWallClockSeconds :: !(Maybe Rational)
  }
  deriving stock (Eq, Show)

-- | Environment-supplied price overrides (all optional).
data CostOverrides = CostOverrides
  { overrideTaskPrice :: !(Maybe Rational)
  , overrideShotPrice :: !(Maybe Rational)
  , overrideSimMinutePrice :: !(Maybe Rational)
  }
  deriving stock (Eq, Show)

noCostOverrides :: CostOverrides
noCostOverrides = CostOverrides Nothing Nothing Nothing

data CostStatus = Estimated | Unavailable
  deriving stock (Eq, Show)

{- | A cost estimate. A single constructor (not a sum of records) keeps the field
selectors total under @-Wpartial-fields@.
-}
data CostEstimate = CostEstimate
  { costStatus :: !CostStatus
  , costAmount :: !(Maybe Rational)
  , costText :: !(Maybe Text)
  , costModel :: !(Maybe Text)
  , costSource :: !(Maybe Text)
  , costReason :: !(Maybe Text)
  , costDetail :: ![(Text, Value)]
  , costNotes :: ![Text]
  }
  deriving stock (Eq, Show)

-- Embedded public pricing (USD). Substring-ordered: the first ARN match wins.
qpuTaskPrice :: Rational
qpuTaskPrice = 0.30

qpuShotPrices :: [(Text, Rational)]
qpuShotPrices =
  [ ("qpu/aqt/ibex", 0.02350)
  , ("qpu/aqt/ibex-q1", 0.02350)
  , ("qpu/ionq/forte", 0.08000)
  , ("qpu/iqm/emerald", 0.00160)
  , ("qpu/iqm/garnet", 0.00145)
  , ("qpu/quera/aquila", 0.01000)
  , ("qpu/rigetti/cepheus", 0.000425)
  ]

simulatorMinutePrices :: [(Text, Rational)]
simulatorMinutePrices =
  [("quantum-simulator/amazon/sv1", 0.075)]

minSimulatorBillingSeconds :: Rational
minSimulatorBillingSeconds = 3

scopeNote :: Text
scopeNote =
  "estimate excludes S3, taxes, discounts, credits, reservations, and later AWS billing adjustments"

{- | Estimate a quantum-task cost from device ARN, requested shots, and (when
available) completed-task metadata.
-}
estimateTaskCost :: CostOverrides -> Text -> Int -> Maybe TaskMeta -> CostEstimate
estimateTaskCost overrides deviceArn shots task =
  case (overrideTaskPrice overrides, overrideShotPrice overrides) of
    (Just taskPrice, Just shotPrice) ->
      qpuCostEstimate taskPrice shotPrice shots "environment_override"
    (Just _, Nothing) -> incompleteOverride
    (Nothing, Just _) -> incompleteOverride
    (Nothing, Nothing)
      | "device/qpu/" `T.isInfixOf` lowerArn -> estimateQpuTaskCost deviceArn shots task
      | "quantum-simulator/amazon/" `T.isInfixOf` lowerArn ->
          estimateSimulatorTaskCost overrides deviceArn task
      | otherwise ->
          unavailable "unknown_device_pricing" "No embedded Braket pricing rule matched this device ARN."
  where
    lowerArn = T.toLower deviceArn
    incompleteOverride =
      unavailable
        "incomplete_price_override"
        "Set both CORTEX_BRAKET_TASK_PRICE_USD and CORTEX_BRAKET_SHOT_PRICE_USD."

estimateQpuTaskCost :: Text -> Int -> Maybe TaskMeta -> CostEstimate
estimateQpuTaskCost deviceArn shots task =
  case firstMatch (T.toLower deviceArn) qpuShotPrices of
    Nothing ->
      unavailable "unknown_qpu_pricing" "No embedded per-shot price is available for this QPU."
    Just (_, shotPrice) ->
      let pricedShots = fromMaybe shots (task >>= taskSuccessfulShots)
       in qpuCostEstimate qpuTaskPrice shotPrice pricedShots "embedded_public_braket_qpu_pricing"

qpuCostEstimate :: Rational -> Rational -> Int -> Text -> CostEstimate
qpuCostEstimate taskPrice shotPrice pricedShots source =
  estimated amount "qpu_task_and_shot" source detail [scopeNote]
  where
    amount = taskPrice + shotPrice * fromIntegral pricedShots
    detail =
      [ ("task_count", toJSON (1 :: Int))
      , ("priced_shots", toJSON pricedShots)
      , ("task_price_usd", String (formatUsd taskPrice))
      , ("shot_price_usd", String (formatUsd shotPrice))
      ]

estimateSimulatorTaskCost :: CostOverrides -> Text -> Maybe TaskMeta -> CostEstimate
estimateSimulatorTaskCost overrides deviceArn task =
  case minutePrice of
    Nothing ->
      unavailable
        "unknown_simulator_pricing"
        "No embedded per-minute price is available for this managed simulator."
    Just price ->
      case task of
        Nothing ->
          unavailable
            "simulator_duration_unavailable_before_completion"
            "Managed simulator estimates require task start/end metadata after completion."
        Just meta ->
          case taskWallClockSeconds meta of
            Nothing ->
              unavailable
                "simulator_duration_unavailable"
                "The Braket task metadata did not include parseable createdAt and endedAt values."
            Just duration ->
              let billed = max duration minSimulatorBillingSeconds
                  amount = price * billed / 60
                  source =
                    if isJust (overrideSimMinutePrice overrides)
                      then "environment_override"
                      else "embedded_public_braket_" <> simulatorKey <> "_pricing"
                  detail =
                    [ ("duration_seconds", String (formatUsd duration))
                    , ("billed_duration_seconds", String (formatUsd billed))
                    , ("minute_price_usd", String (formatUsd price))
                    ]
               in estimated amount "managed_simulator_duration" source detail [scopeNote]
  where
    matched = firstMatch (T.toLower deviceArn) simulatorMinutePrices
    minutePrice = overrideSimMinutePrice overrides <|> fmap snd matched
    simulatorKey = maybe "simulator" (leafName . fst) matched

-- Estimate constructors.

estimated :: Rational -> Text -> Text -> [(Text, Value)] -> [Text] -> CostEstimate
estimated amount model source detail notes =
  CostEstimate
    { costStatus = Estimated
    , costAmount = Just amount
    , costText = Just (formatUsd amount)
    , costModel = Just model
    , costSource = Just source
    , costReason = Nothing
    , costDetail = detail
    , costNotes = notes
    }

unavailable :: Text -> Text -> CostEstimate
unavailable reason note =
  CostEstimate
    { costStatus = Unavailable
    , costAmount = Nothing
    , costText = Nothing
    , costModel = Nothing
    , costSource = Nothing
    , costReason = Just reason
    , costDetail = []
    , costNotes = [note]
    }

-- | The estimated amount as a JSON-friendly @Double@, or 'Nothing' if unavailable.
estimatedCostDouble :: CostEstimate -> Maybe Double
estimatedCostDouble = fmap fromRational . costAmount

-- | The exact estimated amount, or 'Nothing' if unavailable.
costEstimateAmount :: CostEstimate -> Maybe Rational
costEstimateAmount = costAmount

-- | The estimated amount as a plain decimal string, or 'Nothing' if unavailable.
costEstimateText :: CostEstimate -> Maybe Text
costEstimateText = costText

-- | Serialise a cost estimate to the runner's @cost_estimate@ JSON object.
costEstimateToJSON :: CostEstimate -> Value
costEstimateToJSON estimate =
  object $
    [ "status" .= statusText (costStatus estimate)
    , "currency" .= ("USD" :: Text)
    , "estimated_cost_usd" .= estimatedCostDouble estimate
    , "estimated_cost_usd_text" .= costText estimate
    , "pricing_model" .= costModel estimate
    , "pricing_source" .= costSource estimate
    , "notes" .= costNotes estimate
    ]
      <> [(Key.fromText key, value) | (key, value) <- costDetail estimate]
      <> ["reason" .= reason | Just reason <- [costReason estimate]]
  where
    statusText Estimated = "estimated" :: Text
    statusText Unavailable = "unavailable"

-- Helpers.

firstMatch :: Text -> [(Text, Rational)] -> Maybe (Text, Rational)
firstMatch lowerArn = find (\(substr, _) -> substr `T.isInfixOf` lowerArn)

leafName :: Text -> Text
leafName = T.takeWhileEnd (/= '/')

{- | Quantise to ten decimal places (round half up) and render as a trimmed plain
decimal, e.g. @0.445@.
-}
formatUsd :: Rational -> Text
formatUsd amount =
  let scaled = roundHalfUp (amount * (10 ^ (10 :: Int)))
   in formatScaled scaled 10

roundHalfUp :: Rational -> Integer
roundHalfUp r = floor (r + 0.5)

formatScaled :: Integer -> Int -> Text
formatScaled n places =
  let (q, r) = n `divMod` (10 ^ places)
      fracDigits = T.justifyRight places '0' (T.pack (show r))
      trimmed = T.dropWhileEnd (== '0') fracDigits
   in if T.null trimmed then T.pack (show q) else T.pack (show q) <> "." <> trimmed
