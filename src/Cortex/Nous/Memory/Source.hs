{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Cortex.Nous.Memory.Source
  ( CortexMemoryIndexedPassage (..),
    CortexMemorySource (..),
    indexMemorySource,
  )
where

import Cortex.Nous.Memory.Document
  ( CortexMemoryDocument,
    CortexMemoryPassageDraft,
    indexMarkdownDocument,
  )
import Cortex.Nous.Memory.Types (CortexMemoryEntityConfig)
import Data.UUID (UUID)
import GHC.Generics (Generic)

data CortexMemorySource = CortexMemorySource
  { cortexMemorySourceVersionId :: UUID,
    cortexMemorySourceItemId :: Maybe UUID,
    cortexMemorySourceCheckpointId :: Maybe UUID,
    cortexMemorySourceChatSessionId :: Maybe UUID,
    cortexMemorySourceDocument :: CortexMemoryDocument
  }
  deriving stock (Eq, Show, Generic)

data CortexMemoryIndexedPassage = CortexMemoryIndexedPassage
  { cortexMemoryIndexedVersionId :: UUID,
    cortexMemoryIndexedSourceItemId :: Maybe UUID,
    cortexMemoryIndexedSourceCheckpointId :: Maybe UUID,
    cortexMemoryIndexedChatSessionId :: Maybe UUID,
    cortexMemoryIndexedPassageDraft :: CortexMemoryPassageDraft
  }
  deriving stock (Eq, Show, Generic)

indexMemorySource :: CortexMemoryEntityConfig -> CortexMemorySource -> [CortexMemoryIndexedPassage]
indexMemorySource entityConfig source =
  fmap
    ( \draft ->
        CortexMemoryIndexedPassage
          { cortexMemoryIndexedVersionId = source.cortexMemorySourceVersionId,
            cortexMemoryIndexedSourceItemId = source.cortexMemorySourceItemId,
            cortexMemoryIndexedSourceCheckpointId = source.cortexMemorySourceCheckpointId,
            cortexMemoryIndexedChatSessionId = source.cortexMemorySourceChatSessionId,
            cortexMemoryIndexedPassageDraft = draft
          }
    )
    (indexMarkdownDocument entityConfig source.cortexMemorySourceDocument)
