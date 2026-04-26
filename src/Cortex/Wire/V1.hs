-- | Wire v1 public surface.
--
-- Re-exports the parts of the v1 language implementation that consumers
-- and tests legitimately depend on. Internal helpers stay behind
-- 'Cortex.Wire.V1.AST' and 'Cortex.Wire.V1.Parser' (hidden under the
-- @cortex-runtime@ library).
module Cortex.Wire.V1
  ( -- * AST (re-exports)
    module Cortex.Wire.V1.AST,

    -- * Parser (re-exports)
    parseWireFile,
    parseWireExpr,
    ParseError,
    renderParseError,

    -- * Compiler (re-exports)
    compileWireFile,
    compileWireFileWithEnv,
    compileWireFragmentFile,
    compileWireFragmentFileWithEnv,
    compileWireText,
    compileWireTextWithEnv,
    compileWireFragmentText,
    compileWireFragmentTextWithEnv,
  )
where

import Cortex.Wire.V1.AST
import Cortex.Wire.V1.Compiler
import Cortex.Wire.V1.Parser
