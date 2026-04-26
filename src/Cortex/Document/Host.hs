module Cortex.Document.Host
  ( CortexDocumentArtifactHost (..),
  )
where

import Cortex.Capability.Tool.Record (CortexToolCallRecord)
import Cortex.Document.IR (ReportIR)
import Data.Text (Text)

data CortexDocumentArtifactHost m artifact = CortexDocumentArtifactHost
  { cortexDocumentBuildArtifact :: ReportIR -> [CortexToolCallRecord] -> Either Text artifact,
    cortexDocumentPersistArtifact :: artifact -> m artifact
  }
