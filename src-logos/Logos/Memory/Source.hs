{- |
Module      : Logos.Memory.Source
Description : Logos reasoning-library support for source.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Memory.Source
  ( LogosMemoryIndexedPassage (..)
  , LogosMemorySource (..)
  , indexMemorySource
  )
where

import Data.UUID (UUID)
import GHC.Generics (Generic)
import Logos.Memory.Document
  ( LogosMemoryDocument
  , LogosMemoryPassageDraft
  , indexMarkdownDocument
  )
import Logos.Memory.Types (LogosMemoryEntityConfig)

data LogosMemorySource = LogosMemorySource
  { logosMemorySourceVersionId :: UUID
  , logosMemorySourceItemId :: Maybe UUID
  , logosMemorySourceCheckpointId :: Maybe UUID
  , logosMemorySourceChatSessionId :: Maybe UUID
  , logosMemorySourceDocument :: LogosMemoryDocument
  }
  deriving stock (Eq, Show, Generic)

data LogosMemoryIndexedPassage = LogosMemoryIndexedPassage
  { logosMemoryIndexedVersionId :: UUID
  , logosMemoryIndexedSourceItemId :: Maybe UUID
  , logosMemoryIndexedSourceCheckpointId :: Maybe UUID
  , logosMemoryIndexedChatSessionId :: Maybe UUID
  , logosMemoryIndexedPassageDraft :: LogosMemoryPassageDraft
  }
  deriving stock (Eq, Show, Generic)

indexMemorySource :: LogosMemoryEntityConfig -> LogosMemorySource -> [LogosMemoryIndexedPassage]
indexMemorySource entityConfig source =
  fmap
    ( \draft ->
        LogosMemoryIndexedPassage
          { logosMemoryIndexedVersionId = source.logosMemorySourceVersionId
          , logosMemoryIndexedSourceItemId = source.logosMemorySourceItemId
          , logosMemoryIndexedSourceCheckpointId = source.logosMemorySourceCheckpointId
          , logosMemoryIndexedChatSessionId = source.logosMemorySourceChatSessionId
          , logosMemoryIndexedPassageDraft = draft
          }
    )
    (indexMarkdownDocument entityConfig source.logosMemorySourceDocument)
