{- |
Module      : Cortex.Quantum.Diagram
Description : Render a compiled quantum plan as a Qiskit-style text circuit diagram.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

A pure renderer that draws a 'QuantumPlan' as a monospace circuit diagram with
Unicode box-drawing, for embedding in a Markdown report inside a fenced code
block. It mirrors the OpenQASM lowering's filtering — @\@prepare_zero@ is implicit
(qubits start in @|0>@) and identity @\@rz@ carries are dropped — then lays the
remaining gates out left-to-right with an ASAP moment schedule. Two-qubit gates
reserve every wire between control and target, so a vertical connector crossing
intervening wires (drawn @┼@) never collides with another gate. Measurements are
drawn one per column, each dropping a classical line @║@ to a @c:@ register row.

The returned text has no leading blank line and no trailing newline so the caller
controls the fence; every row is right-stripped of trailing spaces.
-}
module Cortex.Quantum.Diagram
  ( renderCircuitDiagram
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Cortex.Quantum.Plan
  ( Measurement (..)
  , PlanOp (..)
  , QuantumPlan (..)
  )

-- | A glyph drawn on a qubit lane row inside one moment column.
data LaneGlyph = GBox !Text | GControl | GTarget | GCross

{- | Keep only the operations the OpenQASM lowering keeps: drop @prepare_zero@
(implicit @|0>@) and identity @rz@ carries (@|angle| < 1e-15@).
-}
keepOp :: PlanOp -> Bool
keepOp = \case
  OpPrepareZero {} -> False
  OpRz _ _ angle -> abs angle >= 1e-15
  _ -> True

isMeasureOp :: PlanOp -> Bool
isMeasureOp = \case
  OpMeasureZ {} -> True
  _ -> False

gateLabel :: Text -> Text
gateLabel = \case
  "h" -> "H"
  "sx" -> "√X"
  "x" -> "X"
  other -> T.toUpper other

-- | Render a compiled quantum plan as a Qiskit-style Unicode circuit diagram.
renderCircuitDiagram :: QuantumPlan -> Text
renderCircuitDiagram plan
  | null wires = ""
  | otherwise = T.intercalate "\n" [renderRow r | r <- [0 .. maxRow]]
  where
    wires = quantumPlanQubits plan
    numLanes = length wires
    laneMap = Map.fromList (zip wires [0 ..])
    wireMap = Map.fromList (zip [0 :: Int ..] wires)
    lane w = Map.findWithDefault 0 w laneMap

    measures = quantumPlanMeasurements plan
    hasMeasures = not (null measures)
    classicalRow = 2 * numLanes

    keptGates = [op | op <- quantumPlanOps plan, keepOp op, not (isMeasureOp op)]
    placements = scheduleGates lane keptGates
    gateCols = if null placements then 0 else 1 + maximum (map fst placements)
    gateColumns = Map.fromListWith (++) [(c, [op]) | (c, op) <- placements]
    measureColumns = Map.fromList (zip [gateCols ..] measures)
    totalCols = gateCols + length measures

    -- Cell geometry: a fixed width with the vertical connector at @mid@.
    boxLabels =
      [gateLabel g | OpGate1 _ g _ <- keptGates]
        <> ["Rz" | OpRz {} <- keptGates]
        <> ["M" | hasMeasures]
    cellWidth = 4 + maximum (1 : map T.length boxLabels)
    mid = cellWidth `div` 2

    maxRow = if hasMeasures then classicalRow else 2 * numLanes - 2
    isLaneRow r = even r && r >= 0 && r < 2 * numLanes
    laneOfRow r = r `div` 2
    isClassicalRow r = hasMeasures && r == classicalRow

    labelWidth = maximum (T.length classicalLabel : map (T.length . laneLabel) wires)
    laneLabel w = "q_" <> tshow w <> ": "
    classicalLabel = "c: "
    rowLabel r
      | isLaneRow r =
          T.justifyRight labelWidth ' ' (laneLabel (Map.findWithDefault 0 (laneOfRow r) wireMap))
      | isClassicalRow r = T.justifyRight labelWidth ' ' classicalLabel
      | otherwise = T.replicate labelWidth " "

    renderRow r = T.stripEnd (rowLabel r <> T.concat [cellAt r c | c <- [0 .. totalCols - 1]])

    cellAt r c =
      case (Map.lookup c gateColumns, Map.lookup c measureColumns) of
        (Just ops, _) -> gateCell ops r
        (_, Just m) -> measureCell m r
        _ -> if isLaneRow r then wireCell else spaceCell

    gateCell ops r
      | isLaneRow r =
          case [g | op <- ops, Just g <- [laneGlyph lane op (laneOfRow r)]] of
            (g : _) -> renderGlyph g
            [] -> wireCell
      | any (gate2Connects lane r) ops = vbarCell "│"
      | otherwise = spaceCell

    measureCell m r
      | isLaneRow r =
          let l = lane (measurementWire m)
              lr = laneOfRow r
           in if lr == l then boxCell "M" else if lr > l then onWire "╫" else wireCell
      | isClassicalRow r = labelCell (tshow (measurementClassicalBit m))
      | r > 2 * lane (measurementWire m) && r < classicalRow = vbarCell "║"
      | otherwise = spaceCell

    renderGlyph = \case
      GBox label -> boxCell label
      GControl -> onWire "●"
      GTarget -> onWire "X"
      GCross -> onWire "┼"

    -- Cell builders (all @cellWidth@ wide).
    wireCell = T.replicate cellWidth "─"
    spaceCell = T.replicate cellWidth " "
    onWire g = T.replicate mid "─" <> g <> T.replicate (cellWidth - mid - 1) "─"
    vbarCell g = T.replicate mid " " <> g <> T.replicate (cellWidth - mid - 1) " "
    boxCell label =
      let inner = "┤" <> label <> "├"
          pad = cellWidth - T.length inner
          lp = pad `div` 2
       in T.replicate lp "─" <> inner <> T.replicate (pad - lp) "─"
    labelCell s =
      let pad = max 0 (cellWidth - T.length s)
          lp = pad `div` 2
       in T.replicate lp " " <> s <> T.replicate (pad - lp) " "

-- ASAP greedy schedule; a two-qubit gate reserves every lane in its span.
scheduleGates :: (Int -> Int) -> [PlanOp] -> [(Int, PlanOp)]
scheduleGates lane = go Map.empty
  where
    go _ [] = []
    go nextFree (op : rest) =
      let lanes = spanLanes lane op
          col = maximum (0 : map (\l -> Map.findWithDefault 0 l nextFree) lanes)
          nextFree' = foldr (\l m -> Map.insert l (col + 1) m) nextFree lanes
       in (col, op) : go nextFree' rest

spanLanes :: (Int -> Int) -> PlanOp -> [Int]
spanLanes lane = \case
  OpGate1 _ _ w -> [lane w]
  OpRz _ w _ -> [lane w]
  OpGate2 _ _ c t -> [min (lane c) (lane t) .. max (lane c) (lane t)]
  OpMeasureZ m -> [lane (measurementWire m)]
  OpPrepareZero _ w _ -> [lane w]

laneGlyph :: (Int -> Int) -> PlanOp -> Int -> Maybe LaneGlyph
laneGlyph lane op l = case op of
  OpGate1 _ g w | lane w == l -> Just (GBox (gateLabel g))
  OpRz _ w _ | lane w == l -> Just (GBox "Rz")
  OpGate2 _ g c t ->
    let lc = lane c
        lt = lane t
     in if l == lc
          then Just GControl
          else
            if l == lt
              then Just (if g == "cnot" then GTarget else GControl)
              else if l > min lc lt && l < max lc lt then Just GCross else Nothing
  _ -> Nothing

gate2Connects :: (Int -> Int) -> Int -> PlanOp -> Bool
gate2Connects lane r = \case
  OpGate2 _ _ c t -> let pair = [2 * lane c, 2 * lane t] in r > minimum pair && r < maximum pair
  _ -> False

tshow :: Show a => a -> Text
tshow = T.pack . show
