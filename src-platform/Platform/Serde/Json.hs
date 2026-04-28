{- |
Module      : Platform.Serde.Json
Description : Platform runtime support for json.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Platform modules provide generic runtime substrate utilities and do not import Cortex or consumers.
-}
module Platform.Serde.Json
  ( module Platform.Serde.Json.Object
  , module Platform.Serde.Json.Preview
  , module Platform.Serde.Json.Text
  )
where

import Platform.Serde.Json.Object
import Platform.Serde.Json.Preview
import Platform.Serde.Json.Text
