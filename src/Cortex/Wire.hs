{- |
Module      : Cortex.Wire
Description : Wire support for wire.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Cortex's upstream runtime and library surface.

Wire modules own authoring and compilation mechanics while host authority stays in typed registries.
-}
module Cortex.Wire
  ( module Cortex.Wire.Syntax
  , module Cortex.Wire.Circuit
  , module Cortex.Wire.Circuit.Engine
  , module Cortex.Wire.Circuit.Hosted
  , module Cortex.Wire.Executor
  , module Cortex.Wire.Include
  , module Cortex.Wire.Format
  , module Cortex.Wire.Pure
  , module Cortex.Wire.Std
  , module Cortex.Wire.Use
  , WireCompileEnv (..)
  , WireProjectionMode (..)
  , WireContractSpec (..)
  , WireContractRegistry (..)
  , WirePayloadKind (..)
  , WireValue (..)
  , WireValueSet (..)
  , WireInputBundle (..)
  , WireAppendHole (..)
  , WireProposalError (..)
  , normalizeWireProposalResponse
  , wireProposalGrammarReference
  , wireProposalSingleNodeExample
  , wireProposalSingleNodeShorthandExample
  , wireProposalInvalidMissingGraphExample
  , wireProposalInvalidOuterReferenceExample
  , unwrapWireStageInputs
  , unwrapWireStageValue
  , wireInputBundleFromStageInputs
  , wireInputBundlePromptSummary
  , wrapWireStageOutput
  , wrapWireStageOutputs
  , wrapWireStageResult
  , wrapWireStageDefinition
  , emptyWireCompileEnv
  , wireCompileEnvWithContractRegistry
  , wireCompileEnvWithExecutorRegistry
  , strictWireCompileEnv
  , emptyWireContractRegistry
  , wireContractRegistryFromList
  , wirePortsFromMetadataValue
  , renderWirePayloadKind
  , parseWirePayloadKindText
  , wirePayloadKindMediaType
  , describeWirePayloadKindShape
  , validateWirePayloadShape
  , mkWireValue
  , singletonWireValueSet
  , wireProposalErrorCategory
  , renderWireProposalError
  , compileWireAppendProposalWithEnv
  , parseWireFile
  , parseWireExpr
  , ParseError
  , renderParseError
  , compileWireFile
  , compileWireFileWithEnv
  , compileWireFileWithReturn
  , compileWireFileWithReturnAndEnv
  , compileWireFragmentFile
  , compileWireFragmentFileWithEnv
  , compileWireText
  , compileWireTextWithEnv
  , compileWireTextWithReturn
  , compileWireTextWithReturnAndEnv
  , compileWireFragmentText
  , compileWireFragmentTextWithEnv
  )
where

import Cortex.Wire.Circuit
import Cortex.Wire.Circuit.Engine
import Cortex.Wire.Circuit.Hosted
import Cortex.Wire.Compile
  ( compileWireFile
  , compileWireFileWithEnv
  , compileWireFileWithReturn
  , compileWireFileWithReturnAndEnv
  , compileWireFragmentFile
  , compileWireFragmentFileWithEnv
  , compileWireFragmentText
  , compileWireFragmentTextWithEnv
  , compileWireText
  , compileWireTextWithEnv
  , compileWireTextWithReturn
  , compileWireTextWithReturnAndEnv
  )
import Cortex.Wire.Contract
  ( WireCompileEnv (..)
  , WireContractRegistry (..)
  , WireContractSpec (..)
  , WireProjectionMode (..)
  , emptyWireCompileEnv
  , emptyWireContractRegistry
  , strictWireCompileEnv
  , wireCompileEnvWithContractRegistry
  , wireCompileEnvWithExecutorRegistry
  , wireContractRegistryFromList
  , wirePortsFromMetadataValue
  )
import Cortex.Wire.Executor
import Cortex.Wire.Format
import Cortex.Wire.Include
import Cortex.Wire.Parser
  ( ParseError
  , parseWireExpr
  , parseWireFile
  , renderParseError
  )
import Cortex.Wire.Proposal
  ( WireAppendHole (..)
  , WireProposalError (..)
  , compileWireAppendProposalWithEnv
  , normalizeWireProposalResponse
  , renderWireProposalError
  , wireProposalErrorCategory
  , wireProposalGrammarReference
  , wireProposalInvalidMissingGraphExample
  , wireProposalInvalidOuterReferenceExample
  , wireProposalSingleNodeExample
  , wireProposalSingleNodeShorthandExample
  )
import Cortex.Wire.Pure
import Cortex.Wire.Runtime
  ( WireInputBundle (..)
  , unwrapWireStageInputs
  , unwrapWireStageValue
  , wireInputBundleFromStageInputs
  , wireInputBundlePromptSummary
  , wrapWireStageDefinition
  , wrapWireStageOutput
  , wrapWireStageOutputs
  , wrapWireStageResult
  )
import Cortex.Wire.Std
import Cortex.Wire.Syntax
import Cortex.Wire.Use
import Cortex.Wire.Value
  ( WirePayloadKind (..)
  , WireValue (..)
  , WireValueSet (..)
  , describeWirePayloadKindShape
  , mkWireValue
  , parseWirePayloadKindText
  , renderWirePayloadKind
  , singletonWireValueSet
  , validateWirePayloadShape
  , wirePayloadKindMediaType
  )
