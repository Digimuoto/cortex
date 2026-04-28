{- |
Module      : Cortex.Artifact
Description : Generic durable output and provenance substrate.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex substrate modules stay consumer-neutral and keep downstream product policy out of this repo.
-}
module Cortex.Artifact
  ( module Cortex.Artifact.Host
  , module Cortex.Artifact.IR
  , module Cortex.Artifact.Metadata
  )
where

import Cortex.Artifact.Host
import Cortex.Artifact.IR
import Cortex.Artifact.Metadata
