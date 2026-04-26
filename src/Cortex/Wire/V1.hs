-- | Compatibility surface for the current Wire grammar implementation.
--
-- New code should prefer the unversioned canonical modules:
-- 'Cortex.Wire.Syntax', 'Cortex.Wire.Parser', and 'Cortex.Wire.Compile'.
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
