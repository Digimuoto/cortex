{- |
Module      : Cortex.Nous.Memory.Host
Description : Nous reasoning-library support for host.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex.Nous is layered above the substrate and must not be imported by substrate modules.
-}
module Cortex.Nous.Memory.Host
  ( CortexMemoryHost (..)
  )
where

import Data.UUID (UUID)

import Cortex.Nous.Memory.Query
  ( CortexMemoryQuery
  )
import Cortex.Nous.Memory.Types
  ( CortexMemoryCandidate
  , CortexMemoryPassage
  )

data CortexMemoryHost m = CortexMemoryHost
  { cortexMemoryLoadSessionPassages :: UUID -> Int -> m [CortexMemoryPassage]
  , cortexMemorySearchLexical :: CortexMemoryQuery -> Int -> m [CortexMemoryCandidate]
  , cortexMemorySearchFuzzy :: CortexMemoryQuery -> Int -> m [CortexMemoryCandidate]
  , cortexMemorySearchSemantic :: CortexMemoryQuery -> Int -> m [CortexMemoryCandidate]
  , cortexMemoryLoadItemPassages :: [UUID] -> m [CortexMemoryPassage]
  }
