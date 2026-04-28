{- |
Module      : Cortex.Nous.Patterns.DeepReport
Description : Reusable DeepReport pattern catalog and staging facades.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex.Nous is layered above the substrate and must not be imported by substrate modules.
-}
module Cortex.Nous.Patterns.DeepReport
  ( module Cortex.Nous.Patterns.DeepReport.Contracts
  , module Cortex.Nous.Patterns.DeepReport.Gather
  , module Cortex.Nous.Patterns.DeepReport.LegacyReportTask
  , module Cortex.Nous.Patterns.DeepReport.Section
  , module Cortex.Nous.Patterns.DeepReport.Section.Runtime
  )
where

import Cortex.Nous.Patterns.DeepReport.Contracts
import Cortex.Nous.Patterns.DeepReport.Gather
import Cortex.Nous.Patterns.DeepReport.LegacyReportTask
import Cortex.Nous.Patterns.DeepReport.Section
import Cortex.Nous.Patterns.DeepReport.Section.Runtime
