{- |
Module      : Platform.Serde
Description : Platform runtime support for serde.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Platform modules provide generic runtime substrate utilities and do not import Cortex or consumers.
-}
module Platform.Serde
  ( module Platform.Serde.Json
  )
where

import Platform.Serde.Json
