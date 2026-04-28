module Cortex.Artifact.Host
  ( CortexDocumentArtifactHost (..),
  )
where

import Cortex.Artifact.IR (ReportIR)
import Cortex.Capability.Tool.Record (CortexToolCallRecord)
import Data.Text (Text)

data CortexDocumentArtifactHost m artifact = CortexDocumentArtifactHost
  { cortexDocumentBuildArtifact :: ReportIR -> [CortexToolCallRecord] -> Either Text artifact,
    cortexDocumentPersistArtifact :: artifact -> m artifact
  }
