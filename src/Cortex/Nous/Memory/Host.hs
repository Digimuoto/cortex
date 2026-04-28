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
