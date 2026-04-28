{- |
Module      : Cortex.Nous.Memory.Source
Description : Nous reasoning-library support for source.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex.Nous is layered above the substrate and must not be imported by substrate modules.
-}
module Cortex.Nous.Memory.Source
  ( CortexMemoryIndexedPassage (..)
  , CortexMemorySource (..)
  , indexMemorySource
  )
where

import Data.UUID (UUID)
import GHC.Generics (Generic)

import Cortex.Nous.Memory.Document
  ( CortexMemoryDocument
  , CortexMemoryPassageDraft
  , indexMarkdownDocument
  )
import Cortex.Nous.Memory.Types (CortexMemoryEntityConfig)

data CortexMemorySource = CortexMemorySource
  { cortexMemorySourceVersionId :: UUID
  , cortexMemorySourceItemId :: Maybe UUID
  , cortexMemorySourceCheckpointId :: Maybe UUID
  , cortexMemorySourceChatSessionId :: Maybe UUID
  , cortexMemorySourceDocument :: CortexMemoryDocument
  }
  deriving stock (Eq, Show, Generic)

data CortexMemoryIndexedPassage = CortexMemoryIndexedPassage
  { cortexMemoryIndexedVersionId :: UUID
  , cortexMemoryIndexedSourceItemId :: Maybe UUID
  , cortexMemoryIndexedSourceCheckpointId :: Maybe UUID
  , cortexMemoryIndexedChatSessionId :: Maybe UUID
  , cortexMemoryIndexedPassageDraft :: CortexMemoryPassageDraft
  }
  deriving stock (Eq, Show, Generic)

indexMemorySource :: CortexMemoryEntityConfig -> CortexMemorySource -> [CortexMemoryIndexedPassage]
indexMemorySource entityConfig source =
  fmap
    ( \draft ->
        CortexMemoryIndexedPassage
          { cortexMemoryIndexedVersionId = source.cortexMemorySourceVersionId
          , cortexMemoryIndexedSourceItemId = source.cortexMemorySourceItemId
          , cortexMemoryIndexedSourceCheckpointId = source.cortexMemorySourceCheckpointId
          , cortexMemoryIndexedChatSessionId = source.cortexMemorySourceChatSessionId
          , cortexMemoryIndexedPassageDraft = draft
          }
    )
    (indexMarkdownDocument entityConfig source.cortexMemorySourceDocument)
