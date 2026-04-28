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
