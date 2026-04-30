{- |
Module      : Cortex.Pulse.GraphStateRevision
Description : Durable graph-state revision token.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Pulse uses the graph-state row's @updated_at@ value as an optimistic
compare-and-swap revision token.  The newtype keeps revision comparisons
distinct from ordinary timestamps at Haskell call sites.
-}
module Cortex.Pulse.GraphStateRevision
  ( GraphStateRevision (..)
  )
where

import Data.Time (UTCTime)

-- | Opaque graph-state compare-and-swap revision.
newtype GraphStateRevision = GraphStateRevision {unGraphStateRevision :: UTCTime}
  deriving stock (Eq, Ord, Show)
