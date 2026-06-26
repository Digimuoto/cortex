{- |
Module      : Cortex.Wire.Pure.Bounds
Description : Typed boundary enforcing the CorePure bounded-iteration policy.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

This module is the single place that enforces CorePure's termination and cost
policy for the bounded-iteration builtins (@fold@, @foldRight@, @range@) and the
clamped index builtins (@take@, @drop@, @substring@).

The result types have hidden constructors, so the only way to obtain a
'FoldAccumulator', 'ClampedIndex', or 'RangePlan' is through the smart
constructors here, which apply the cost cap, JSON value cost, and
integer/magnitude rules. "Cortex.Wire.Pure" interprets the typed results into
the evaluator's error type. Keeping the policy behind these constructors stops it
from being re-implemented with ad-hoc local conditionals at each call site.
-}
module Cortex.Wire.Pure.Bounds
  ( -- * Cap
    IterationCap
  , corePureBoundedIterationCap
  , iterationCapValue

    -- * Value cost
  , CostCheck (..)
  , checkValueCost

    -- * Fold accumulators
  , FoldAccumulator
  , foldAccumulatorValue
  , mkFoldAccumulator

    -- * Clamped indices
  , ClampedIndex
  , clampedIndexValue
  , clampIndex

    -- * Range planning
  , RangePlan
  , planRange
  , foldRangePlan
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bits (countLeadingZeros, finiteBitSize, shiftR)
import Data.Scientific (Scientific, toBoundedInteger)
import Data.Scientific qualified as Scientific
import Data.Text qualified as T
import Data.Vector qualified as Vector

{- | The fixed deterministic ceiling for scalar-driven CorePure iteration. It is
a totality guard, not an operator-tunable budget (ADR 0056); it is not
authored, configured, or per-run.
-}
newtype IterationCap = IterationCap Int
  deriving stock (Eq, Show)

corePureBoundedIterationCap :: IterationCap
corePureBoundedIterationCap = IterationCap 1000000

iterationCapValue :: IterationCap -> Int
iterationCapValue (IterationCap limit) = limit

{- | Result of a value-cost check. Returning a type rather than the raw count
stops callers from comparing the number incorrectly or forgetting what it
means.
-}
data CostCheck = WithinLimit | OverLimit
  deriving stock (Eq, Show)

{- | Whether a JSON value's cost is within the cap. Cost is one per node plus
string lengths, number magnitudes, and object key lengths, so structural
nesting, string concatenation, numeric growth, and key growth are all bounded.
-}
checkValueCost :: IterationCap -> Aeson.Value -> CostCheck
checkValueCost (IterationCap limit) value
  | valueCostAtMost limit value > limit = OverLimit
  | otherwise = WithinLimit

{- | A fold accumulator that has passed the cost guard. The constructor is
hidden, so 'mkFoldAccumulator' is the only way to build one; @fold@/@foldRight@
therefore cannot iterate from an unchecked seed or step result.
-}
newtype FoldAccumulator = FoldAccumulator Aeson.Value
  deriving stock (Eq, Show)

foldAccumulatorValue :: FoldAccumulator -> Aeson.Value
foldAccumulatorValue (FoldAccumulator value) = value

{- | Admit a JSON value as a fold accumulator iff its cost is within the cap.
Callers reject non-JSON (function) accumulators before reaching here, so a
'FoldAccumulator' is always a within-cap JSON value.
-}
mkFoldAccumulator :: IterationCap -> Aeson.Value -> Maybe FoldAccumulator
mkFoldAccumulator cap value =
  case checkValueCost cap value of
    WithinLimit -> Just (FoldAccumulator value)
    OverLimit -> Nothing

{- | An index clamped into a valid @[0, upper]@ range. The constructor is hidden,
so a 'ClampedIndex' is always usable directly with @Vector.take@/@Data.Text@
slicing without a further bounds check.
-}
newtype ClampedIndex = ClampedIndex Int
  deriving stock (Eq, Show)

clampedIndexValue :: ClampedIndex -> Int
clampedIndexValue (ClampedIndex value) = value

{- | Clamp a finite number to a @[0, upper]@ index. 'Nothing' for non-integers.
Out-of-Int-range integers clamp to the nearer bound rather than failing,
matching the documented index semantics, and never materialise a huge integer.
-}
clampIndex :: Int -> Scientific -> Maybe ClampedIndex
clampIndex upper number =
  fmap (ClampedIndex . clampToBound) (spanEndpoint number)
  where
    clampToBound = \case
      SpanValue value -> fromInteger (max 0 (min (toInteger upper) value))
      SpanAbove -> upper
      SpanBelow -> 0

{- | A range reduced to a plan before any enumeration: empty, an explicit
@[start, end)@ Integer enumeration within the cap, or over the cap. Separating
the plan from the enumeration keeps the span/cap decision distinct from the
machine narrowing that follows it.

The constructors are not exported: a 'RangePlan' is built only by 'planRange' and
consumed only through 'foldRangePlan', so it acts as a proof that the range bounds
were checked. A caller cannot forge an @EnumerateRange@ with an over-cap span.
-}
data RangePlan = EmptyRange | EnumerateRange !Integer !Integer | RangeOverCap
  deriving stock (Eq, Show)

{- | Decide a range plan from its endpoints. 'Nothing' for non-integer endpoints.
Direction is decided first by a safe magnitude comparison, so a backwards or
equal range (for example @range(10^2000000, 10^2000000)@) is an empty half-open
range regardless of endpoint magnitude. A forward range enumerates when both
endpoints are within the 'maxSpanDigits' endpoint bound and their exact span is
within the cap; a forward range whose endpoint exceeds the endpoint bound is
over-cap (this keeps emitted elements bounded, since output is the span times the
endpoint width). No enormous integer is ever materialised or emitted.
-}
planRange :: IterationCap -> Scientific -> Scientific -> Maybe RangePlan
planRange (IterationCap cap) startNumber endNumber = do
  start <- spanEndpoint startNumber
  end <- spanEndpoint endNumber
  Just $ case safeIntCompare endNumber startNumber of
    LT -> EmptyRange
    EQ -> EmptyRange
    GT -> case (start, end) of
      (SpanValue startValue, SpanValue endValue)
        | endValue - startValue > toInteger cap -> RangeOverCap
        | otherwise -> EnumerateRange startValue endValue
      -- Forward, but an endpoint exceeds the documented endpoint-magnitude bound;
      -- reject so emitted elements stay bounded.
      _ -> RangeOverCap

{- | Eliminate a 'RangePlan'. Because the constructors are hidden, this is the
only way to interpret a plan, and a plan is only produced by 'planRange', so the
@onEnumerate@ start/end always denote a within-cap forward range.
-}
foldRangePlan :: a -> (Integer -> Integer -> a) -> a -> RangePlan -> a
foldRangePlan onEmpty onEnumerate onOverCap = \case
  EmptyRange -> onEmpty
  EnumerateRange start end -> onEnumerate start end
  RangeOverCap -> onOverCap

-- Internal --------------------------------------------------------------------

{- | Order two integer-valued numbers without materialising an astronomically
large integer: by sign, then decimal width, then by the values aligned to a
common exponent. Equal values compare EQ without scaling, so a backwards or equal
huge-endpoint range is recognised without building either integer; alignment only
materialises when two values share a decimal width, which is bounded by that
width.
-}
safeIntCompare :: Scientific -> Scientific -> Ordering
safeIntCompare left right =
  let a = Scientific.normalize left
      b = Scientific.normalize right
      coefficientA = Scientific.coefficient a
      coefficientB = Scientific.coefficient b
   in case compare (signum coefficientA) (signum coefficientB) of
        EQ
          | coefficientA == 0 -> EQ
          | otherwise ->
              -- Widths are computed in Integer: a Scientific exponent near the Int
              -- bounds would otherwise overflow the addition and misorder the range.
              let widthA = toInteger (decimalWidth coefficientA) + toInteger (Scientific.base10Exponent a)
                  widthB = toInteger (decimalWidth coefficientB) + toInteger (Scientific.base10Exponent b)
               in case compare widthA widthB of
                    EQ -> compareAligned a b
                    widthOrdering
                      | coefficientA > 0 -> widthOrdering
                      | otherwise -> flipOrdering widthOrdering
        signOrdering -> signOrdering
  where
    compareAligned a b =
      let exponentFloor = min (Scientific.base10Exponent a) (Scientific.base10Exponent b)
          valueA = Scientific.coefficient a * 10 ^ (Scientific.base10Exponent a - exponentFloor)
          valueB = Scientific.coefficient b * 10 ^ (Scientific.base10Exponent b - exponentFloor)
       in compare valueA valueB

-- | Decimal-digit width of @abs n@.
decimalWidth :: Integer -> Int
decimalWidth n = length (show (abs n))

flipOrdering :: Ordering -> Ordering
flipOrdering LT = GT
flipOrdering EQ = EQ
flipOrdering GT = LT

{- | A range/index endpoint: an exact Integer when its magnitude is small enough
to materialise cheaply (covering values at and just past the Int bounds), or a
sign flag for integers whose magnitude is too large to materialise.
-}
data SpanEnd = SpanValue !Integer | SpanAbove | SpanBelow

{- | Largest decimal width of a @range@ endpoint we still materialise (and so the
largest magnitude @range@ will enumerate). This is the documented endpoint bound:
endpoints up to this many digits are measured and enumerated by their exact span,
while a forward range with a wider endpoint is rejected as over-cap so emitted
elements stay bounded (worst-case output is the cap times this width). The bound
is far above the Int range, so any ordinary index range materialises; only
astronomically large endpoints are classified by sign instead.
-}
maxSpanDigits :: Int
maxSpanDigits = 40

spanEndpoint :: Scientific -> Maybe SpanEnd
spanEndpoint number =
  case toBoundedInteger number :: Maybe Int of
    Just value -> Just (SpanValue (toInteger value))
    Nothing
      | not (Scientific.isInteger number) -> Nothing
      | otherwise ->
          let normalized = Scientific.normalize number
              exponent10 = Scientific.base10Exponent normalized
              coefficient = Scientific.coefficient normalized
           in Just $
                if exponent10 < maxSpanDigits && abs coefficient < 10 ^ (maxSpanDigits - exponent10)
                  then SpanValue (coefficient * 10 ^ exponent10)
                  else if coefficient < 0 then SpanBelow else SpanAbove

{- | Worklist item for the value-cost traversal: a JSON node still to measure, or
a flat number of cost units. Object key lengths enter as 'CostUnits'
interleaved with their values, so the traversal can stop at the limit instead
of summing every key of a large object first.
-}
data CostItem = CostNode !Aeson.Value | CostUnits !Int

{- | Cost of a JSON value: one per node, plus string lengths, number magnitudes,
and object key lengths, so structural nesting, string concatenation, numeric
growth, and key growth are all bounded. Every contribution (including each object
key) flows through one lazily generated worklist and the traversal short-circuits
once the running cost passes @limit@, so even an object with far more than @limit@
entries is only partially measured before the cap is noticed.
-}
valueCostAtMost :: Int -> Aeson.Value -> Int
valueCostAtMost limit root =
  go 0 [CostNode root]
  where
    go cost _ | cost > limit = cost
    go cost [] = cost
    go cost (CostUnits units : rest) = go (cost + units) rest
    go cost (CostNode value : rest) =
      case value of
        Aeson.String text -> go (cost + 1 + T.length text) rest
        Aeson.Number number -> go (cost + numberCost limit number) rest
        Aeson.Array items -> go (cost + 1) (fmap CostNode (Vector.toList items) <> rest)
        Aeson.Object object -> go (cost + 1) (objectCostItems object <> rest)
        Aeson.Bool _ -> go (cost + 1) rest
        Aeson.Null -> go (cost + 1) rest

{- | Lazily interleave each object entry's key-length cost with its value, so a
large object stops being measured once the running cost passes the limit.
-}
objectCostItems :: KeyMap.KeyMap Aeson.Value -> [CostItem]
objectCostItems object =
  concatMap
    (\(key, value) -> [CostUnits (T.length (Key.toText key)), CostNode value])
    (KeyMap.toList object)

{- | Approximate footprint of a number: coefficient bit-length plus exponent
magnitude. A fold that grows a numeric accumulator by squaring or scaling is then
bounded the same way string growth is, instead of counting as one node. Both
terms are capped so the measurement stays bounded on an already-huge value.
-}
numberCost :: Int -> Scientific -> Int
numberCost limit number =
  1
    + boundedBitLength limit (Scientific.coefficient number)
    + exponentCost
  where
    -- The exponent magnitude is taken in Integer first: abs (minBound :: Int)
    -- overflows back to a negative value, which would let a number with a huge
    -- negative exponent slip under the cap.
    exponentCost =
      fromInteger (min (toInteger limit + 1) (abs (toInteger (Scientific.base10Exponent number))))

{- | Bit-length of @abs value@, exact for word-sized integers and counted in
64-bit chunks above that, stopping once it passes @cap@ so the count stays
bounded even when the integer is enormous.
-}
boundedBitLength :: Int -> Integer -> Int
boundedBitLength cap = go 0 . abs
  where
    go cost magnitude
      | cost > cap = cost
      | magnitude == 0 = cost
      | magnitude <= maxWord = cost + wordBitLength (fromInteger magnitude)
      | otherwise = go (cost + 64) (magnitude `shiftR` 64)
    maxWord = toInteger (maxBound :: Word)
    wordBitLength :: Word -> Int
    wordBitLength word = finiteBitSize word - countLeadingZeros word
