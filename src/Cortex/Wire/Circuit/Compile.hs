{- |
Module      : Cortex.Wire.Circuit.Compile
Description : Wire support for compile.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.Circuit.Compile
  ( module Cortex.Wire.Circuit.Compiler
  )
where

import Cortex.Wire.Circuit.Compiler
