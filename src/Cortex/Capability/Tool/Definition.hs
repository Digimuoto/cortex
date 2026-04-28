{- |
Module      : Cortex.Capability.Tool.Definition
Description : Cortex substrate support for definition.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Cortex substrate modules stay consumer-neutral and keep downstream product policy out of this repo.
-}
module Cortex.Capability.Tool.Definition
  ( toolDefinitionName
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Text (Text)

toolDefinitionName :: Aeson.Value -> Maybe Text
toolDefinitionName =
  parseMaybe . Aeson.withObject "ToolDefinition" $ \outer -> do
    fn <- outer Aeson..: "function"
    fn Aeson..: "name"
