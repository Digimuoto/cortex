{-# LANGUAGE OverloadedStrings #-}

module Cortex.Capability.Tool.Definition
  ( toolDefinitionName,
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
