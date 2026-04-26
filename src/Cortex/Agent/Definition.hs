{-# LANGUAGE DerivingStrategies #-}

module Cortex.Agent.Definition
  ( CortexAgentDefinition (..),
    CortexAgentIdentity (..),
  )
where

import Cortex.Agent.Policy (CortexAgentPolicy)
import Data.Text (Text)

data CortexAgentIdentity = CortexAgentIdentity
  { cortexAgentId :: Text,
    cortexAgentDisplayName :: Text
  }
  deriving stock (Eq, Show)

data CortexAgentDefinition state = CortexAgentDefinition
  { cortexAgentIdentity :: CortexAgentIdentity,
    cortexAgentDescription :: Maybe Text,
    cortexAgentDefaultModelId :: Maybe Text,
    cortexAgentInitialState :: state,
    cortexAgentPolicy :: CortexAgentPolicy
  }
  deriving stock (Eq, Show)
