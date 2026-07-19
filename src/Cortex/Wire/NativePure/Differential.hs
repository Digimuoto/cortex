{- |
Module      : Cortex.Wire.NativePure.Differential
Description : NativePure Haskell reference corpus for generated-C closure gates.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

This module owns the small, replayable NativePure differential corpus.  The
Haskell reference computes checked-i64 and structural results directly; the
Lean fixture and generated C replay the same input lines and must emit exactly
the same canonical traces.  Binary64 coverage is intentionally bit-preserving
identity only: f64 arithmetic remains outside the refinement theorem.
-}
module Cortex.Wire.NativePure.Differential
  ( NativePureDifferentialCase (..)
  , nativePureDifferentialCases
  , renderNativePureDifferentialInput
  , renderNativePureDifferentialTrace
  , emitNativePureDifferentialCorpus
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word64)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

data NativePureDifferentialCase
  = NativePureIncrement !Int64
  | NativePureClassify !Int64
  | NativePureProduct !Int64
  | NativePureProjection !Bool !Int64
  | NativePureF64Identity !Word64
  deriving stock (Eq, Show)

nativePureDifferentialCases :: [NativePureDifferentialCase]
nativePureDifferentialCases =
  [ NativePureIncrement (-2)
  , NativePureIncrement (-1)
  , NativePureIncrement 0
  , NativePureIncrement 1
  , NativePureIncrement (maxBound - 1)
  , NativePureIncrement maxBound
  , NativePureClassify (-2)
  , NativePureClassify 0
  , NativePureClassify 9
  , NativePureProduct (-7)
  , NativePureProduct 0
  , NativePureProjection False (-9)
  , NativePureProjection True 42
  , NativePureF64Identity 0x0000000000000000
  , NativePureF64Identity 0x8000000000000000
  , NativePureF64Identity 0x0000000000000001
  , NativePureF64Identity 0x3ff0000000000000
  , NativePureF64Identity 0x7fefffffffffffff
  ]

renderNativePureDifferentialInput :: NativePureDifferentialCase -> Text
renderNativePureDifferentialInput = \case
  NativePureIncrement value -> "increment " <> tshow value
  NativePureClassify value -> "classify " <> tshow value
  NativePureProduct value -> "product " <> tshow value
  NativePureProjection flag score ->
    "projection " <> boolDigit flag <> " " <> tshow score
  NativePureF64Identity bits -> "f64 " <> hex64 bits

renderNativePureDifferentialTrace :: NativePureDifferentialCase -> Text
renderNativePureDifferentialTrace = \case
  NativePureIncrement value
    | value == maxBound -> "increment:" <> tshow value <> " status=2"
    | otherwise ->
        "increment:" <> tshow value <> " status=0 value=" <> tshow (value + 1)
  NativePureClassify value ->
    "classify:"
      <> tshow value
      <> " status=0 tag="
      <> (if value < 0 then "1" else "0")
      <> " value="
      <> tshow value
  NativePureProduct score ->
    "product:" <> tshow score <> " status=0 flag=1 score=" <> tshow score
  NativePureProjection flag score ->
    "projection:"
      <> boolDigit flag
      <> ","
      <> tshow score
      <> " status=0 value="
      <> tshow score
  NativePureF64Identity bits ->
    "f64:" <> hex64 bits <> " status=0 bits=" <> hex64 bits

emitNativePureDifferentialCorpus :: FilePath -> IO Int
emitNativePureDifferentialCorpus outputDirectory = do
  createDirectoryIfMissing True outputDirectory
  TIO.writeFile
    (outputDirectory </> "cases.txt")
    (T.unlines (fmap renderNativePureDifferentialInput nativePureDifferentialCases))
  TIO.writeFile
    (outputDirectory </> "haskell-traces.txt")
    (T.unlines (fmap renderNativePureDifferentialTrace nativePureDifferentialCases))
  pure (length nativePureDifferentialCases)

boolDigit :: Bool -> Text
boolDigit False = "0"
boolDigit True = "1"

hex64 :: Word64 -> Text
hex64 value = T.justifyRight 16 '0' (T.pack (showHex value ""))

tshow :: Show value => value -> Text
tshow = T.pack . show
