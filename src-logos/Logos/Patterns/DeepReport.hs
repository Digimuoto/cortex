{- |
Module      : Logos.Patterns.DeepReport
Description : Reusable DeepReport pattern catalog and staging facades.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Patterns.DeepReport
  ( module Logos.Patterns.DeepReport.Contracts
  , module Logos.Patterns.DeepReport.Gather
  , module Logos.Patterns.DeepReport.LegacyReportTask
  , module Logos.Patterns.DeepReport.Section
  , module Logos.Patterns.DeepReport.Section.Runtime
  )
where

import Logos.Patterns.DeepReport.Contracts
import Logos.Patterns.DeepReport.Gather
import Logos.Patterns.DeepReport.LegacyReportTask
import Logos.Patterns.DeepReport.Section
import Logos.Patterns.DeepReport.Section.Runtime
