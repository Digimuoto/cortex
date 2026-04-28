{- |
Module      : Cortex.Wire.Circuit.NodeKind
Description : Semantic classification of circuit nodes (DIG-481).
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

'CircuitNodeKind' captures what a node /represents/ in a circuit — whether it
makes decisions, performs work, waits for external input, or emits
artifacts. This is purely semantic metadata; it does not affect execution
behaviour or confer structural authority (rewrite capability is a separate
contract at the 'StageDefinition' / executor level).

@Await@ and @Emit@ map to distinct IR constructors ('CircuitAwaitSignal',
'CircuitArtifact') that are already structurally typed. 'CircuitNodeKind' is
most useful on 'CircuitTask' nodes where the semantic difference between
e.g. a planner ('Decide') and a gatherer ('Act') is otherwise lost after
lowering.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.Circuit.NodeKind
  ( CircuitNodeKind (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)

-- | Semantic vertex classification for circuit nodes.
data CircuitNodeKind
  = -- | Produces branching or routing decisions (planner, condition evaluator).
    Decide
  | -- | Executes concrete work (gatherer, analyst, reviewer, compiler).
    Act
  | -- | Suspends for external or user input.
    Await
  | -- | Produces durable artifacts or outputs.
    Emit
  deriving stock (Eq, Show, Bounded, Enum, Generic)
  deriving anyclass (FromJSON, ToJSON)
