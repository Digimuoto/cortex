{- |
Module      : Cortex.Wire.Circuit.IR
Description : Wire support for ir.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire.Circuit.IR
  ( CircuitNodeRef (..)
  , CircuitIR (..)
  , CircuitExpr (..)
  , CircuitTaskNode (..)
  , CircuitSignalBoundary (..)
  , CircuitArtifactBoundary (..)
  , CircuitCondition (..)
  , CircuitRewriteBoundary (..)
  , circuitNodeRefs
  )
where

import Control.Lens ((&), (?~))
import Data.Aeson
  ( FromJSON
  , FromJSONKey
  , ToJSON
  , ToJSONKey
  , Value
  )
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.OpenApi
  ( NamedSchema (..)
  , OpenApiType (..)
  , ToSchema (..)
  , description
  , type_
  )
import Data.Text (Text)
import GHC.Generics (Generic)

import Cortex.Wire.Circuit.Node (CircuitNodeKind)

newtype CircuitNodeRef = CircuitNodeRef
  { unCircuitNodeRef :: Text
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, FromJSONKey, ToJSON, ToJSONKey)

data CircuitIR = CircuitIR
  { circuitIrId :: Text
  , circuitIrLabel :: Text
  , circuitIrRoot :: CircuitExpr
  , circuitIrMetadata :: Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance ToSchema CircuitIR where
  declareNamedSchema _ =
    pure . NamedSchema (Just "CircuitIR") $
      mempty
        & type_ ?~ OpenApiObject
        & description
          ?~ "Typed Cortex circuit integration-layer IR. Exposed as an opaque JSON object because it contains recursive tagged unions and free-form metadata."

data CircuitExpr
  = CircuitSequence (NonEmpty CircuitExpr)
  | CircuitParallel (NonEmpty CircuitExpr)
  | CircuitConditional CircuitCondition CircuitExpr (Maybe CircuitExpr)
  | CircuitTask CircuitTaskNode
  | CircuitAwaitSignal CircuitSignalBoundary
  | CircuitArtifact CircuitArtifactBoundary
  | CircuitRewriteScope CircuitRewriteBoundary CircuitExpr
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CircuitTaskNode = CircuitTaskNode
  { circuitTaskNodeRef :: CircuitNodeRef
  , circuitTaskNodeLabel :: Text
  , circuitTaskNodeKind :: Maybe CircuitNodeKind
  , circuitTaskNodeMetadata :: Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CircuitSignalBoundary = CircuitSignalBoundary
  { circuitSignalBoundaryRef :: CircuitNodeRef
  , circuitSignalName :: Text
  , circuitSignalDescription :: Maybe Text
  , circuitSignalMetadata :: Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CircuitArtifactBoundary = CircuitArtifactBoundary
  { circuitArtifactBoundaryRef :: CircuitNodeRef
  , circuitArtifactKind :: Text
  , circuitArtifactLabel :: Text
  , circuitArtifactMetadata :: Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CircuitCondition
  = CircuitConditionRef Text
  | CircuitConditionValue Value
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data CircuitRewriteBoundary = CircuitRewriteBoundary
  { circuitRewriteBoundaryRef :: CircuitNodeRef
  , circuitRewriteIntent :: Text
  , circuitRewriteDescription :: Maybe Text
  , circuitRewriteMetadata :: Value
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

circuitNodeRefs :: CircuitExpr -> [CircuitNodeRef]
circuitNodeRefs = \case
  CircuitSequence exprs -> NE.toList exprs >>= circuitNodeRefs
  CircuitParallel exprs -> NE.toList exprs >>= circuitNodeRefs
  CircuitConditional _ thenExpr maybeElseExpr ->
    circuitNodeRefs thenExpr <> foldMap circuitNodeRefs maybeElseExpr
  CircuitTask taskNode -> [taskNode.circuitTaskNodeRef]
  CircuitAwaitSignal signalBoundary -> [signalBoundary.circuitSignalBoundaryRef]
  CircuitArtifact artifactBoundary -> [artifactBoundary.circuitArtifactBoundaryRef]
  CircuitRewriteScope rewriteBoundary innerExpr ->
    rewriteBoundary.circuitRewriteBoundaryRef : circuitNodeRefs innerExpr
