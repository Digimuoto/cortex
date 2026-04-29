{- |
Module      : Logos.Memory.Host
Description : Logos reasoning-library support for host.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Memory.Host
  ( LogosMemoryHost (..)
  )
where

import Data.UUID (UUID)
import Logos.Memory.Query
  ( LogosMemoryQuery
  )
import Logos.Memory.Types
  ( LogosMemoryCandidate
  , LogosMemoryPassage
  )

data LogosMemoryHost m = LogosMemoryHost
  { logosMemoryLoadSessionPassages :: UUID -> Int -> m [LogosMemoryPassage]
  , logosMemorySearchLexical :: LogosMemoryQuery -> Int -> m [LogosMemoryCandidate]
  , logosMemorySearchFuzzy :: LogosMemoryQuery -> Int -> m [LogosMemoryCandidate]
  , logosMemorySearchSemantic :: LogosMemoryQuery -> Int -> m [LogosMemoryCandidate]
  , logosMemoryLoadItemPassages :: [UUID] -> m [LogosMemoryPassage]
  }
