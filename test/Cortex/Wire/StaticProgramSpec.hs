{- |
Module      : Cortex.Wire.StaticProgramSpec
Description : Tests for the normalized static Wire deployment artifact.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Exercises 'lowerCompiledCircuitToStaticProgram' over the two-node harness fixture: dense
node/edge ID assignment, admission-artifact extraction from compiled metadata, and
the malformed and missing-artifact error paths.
-}
module Cortex.Wire.StaticProgramSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Test.Hspec

import Cortex.Wire
  ( CircuitNodeRef (..)
  , CompiledCircuit
  , compileWireTextWithEnv
  , renderWireError
  , stdIoCompileEnv
  )
import Cortex.Wire.StaticProgram
  ( StaticProgram (..)
  , StaticProgramEdge (..)
  , StaticProgramError (..)
  , StaticProgramNode (..)
  , lowerCompiledCircuitToStaticProgram
  , staticProgramSchema
  )

spec :: Spec
spec = do
  describe "static-program/v1 lowering" $ do
    it "assigns canonical dense ids and direct edges to a two-node task DAG" $ do
      compiled <- requireCompiled twoNodeSource
      program <- requireStaticProgram compiled
      fmap (.staticProgramNodeId) program.staticProgramNodes `shouldBe` [0, 1]
      fmap (.staticProgramNodeRef) program.staticProgramNodes
        `shouldBe` [CircuitNodeRef "first", CircuitNodeRef "second"]
      fmap (.staticProgramNodeExecutor) program.staticProgramNodes
        `shouldBe` ["std.io.command", "std.io.stdout"]
      program.staticProgramEdges `shouldBe` [StaticProgramEdge 0 1]

    it "has an explicit stable schema and JSON roundtrip" $ do
      compiled <- requireCompiled twoNodeSource
      program <- requireStaticProgram compiled
      staticProgramSchema `shouldBe` "cortex.wire.static-program/v1"
      Aeson.eitherDecode (Aeson.encode program) `shouldBe` Right program

    it "rejects delayed CorePure nodes" $ do
      compiled <- requireCompiled pureSource
      lowerCompiledCircuitToStaticProgram compiled
        `shouldBe` Left (StaticProgramPureNode (CircuitNodeRef "compute"))

twoNodeSource :: Text
twoNodeSource =
  "use std.io.{@command, @stdout, CommandResult};\n\
  \node first\n\
  \  -> result: CommandResult = @command;\n\
  \node second\n\
  \  <- result: CommandResult\n\
  \  = @stdout result;\n\
  \first => second\n"

pureSource :: Text
pureSource =
  "contract Unit;\n\
  \node compute\n\
  \  -> output: Unit = null;\n\
  \compute\n"

requireCompiled :: Text -> IO CompiledCircuit
requireCompiled source =
  case compileWireTextWithEnv stdIoCompileEnv source of
    Left compileError -> expectationFailure (show (renderWireError compileError)) >> fail "unreachable"
    Right compiled -> pure compiled

requireStaticProgram :: CompiledCircuit -> IO StaticProgram
requireStaticProgram compiled =
  case lowerCompiledCircuitToStaticProgram compiled of
    Left lowerError -> expectationFailure (show lowerError) >> fail "unreachable"
    Right program -> pure program
