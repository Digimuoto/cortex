{- |
Module      : Cortex.Algebra
Description : Law-bearing graph and relation algebra.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex substrate modules stay consumer-neutral and keep downstream product policy out of this repo.
-}
module Cortex.Algebra
  ( module Cortex.Algebra.Graph
  , module Cortex.Algebra.Graph.Mokhov
  )
where

import Cortex.Algebra.Graph
import Cortex.Algebra.Graph.Mokhov
