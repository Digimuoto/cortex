{- |
Module      : Cortex.Artifact.Host
Description : Cortex substrate support for host.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex substrate modules stay consumer-neutral and keep downstream product policy out of this repo.
-}
module Cortex.Artifact.Host
  ( CortexDocumentArtifactHost (..)
  )
where

import Data.Text (Text)

import Cortex.Artifact.IR (ReportIR)
import Cortex.Capability.Tool.Record (CortexToolCallRecord)

data CortexDocumentArtifactHost m artifact = CortexDocumentArtifactHost
  { cortexDocumentBuildArtifact :: ReportIR -> [CortexToolCallRecord] -> Either Text artifact
  , cortexDocumentPersistArtifact :: artifact -> m artifact
  }
