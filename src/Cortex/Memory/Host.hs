module Cortex.Memory.Host
  ( CortexMemoryHost (..),
  )
where

import Cortex.Memory.Query
  ( CortexMemoryQuery,
  )
import Cortex.Memory.Types
  ( CortexMemoryCandidate,
    CortexMemoryPassage,
  )
import Data.UUID (UUID)

data CortexMemoryHost m = CortexMemoryHost
  { cortexMemoryLoadSessionPassages :: UUID -> Int -> m [CortexMemoryPassage],
    cortexMemorySearchLexical :: CortexMemoryQuery -> Int -> m [CortexMemoryCandidate],
    cortexMemorySearchFuzzy :: CortexMemoryQuery -> Int -> m [CortexMemoryCandidate],
    cortexMemorySearchSemantic :: CortexMemoryQuery -> Int -> m [CortexMemoryCandidate],
    cortexMemoryLoadItemPassages :: [UUID] -> m [CortexMemoryPassage]
  }
