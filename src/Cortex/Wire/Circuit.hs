{- |
Module      : Cortex.Wire.Circuit
Description : Wire support for circuit.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.Circuit
  ( module Cortex.Wire.Circuit.Artifact
  , module Cortex.Wire.Circuit.Compile
  , module Cortex.Wire.Circuit.IR
  , module Cortex.Wire.Circuit.Lower
  , module Cortex.Wire.Circuit.Node
  )
where

import Cortex.Wire.Circuit.Artifact
import Cortex.Wire.Circuit.Compile
import Cortex.Wire.Circuit.IR
import Cortex.Wire.Circuit.Lower
import Cortex.Wire.Circuit.Node
