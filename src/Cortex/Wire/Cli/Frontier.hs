{- |
Module      : Cortex.Wire.Cli.Frontier
Description : Parser surface for the wire frontier inspection command.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Small, testable parser for @wire frontier@. The executable owns IO and
compilation; this module owns the stable command surface.
-}
module Cortex.Wire.Cli.Frontier
  ( FrontierClosure (..)
  , FrontierCommand (..)
  , FrontierFormat (..)
  , FrontierScope (..)
  , frontierUsage
  , parseFrontierCommand
  )
where

import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

-- | Closure projection used by frontier inspection.
data FrontierClosure
  = FrontierClosed
  | FrontierOpen
  deriving stock (Eq, Show)

-- | Which slice of the endpoint-use report @wire frontier@ should print.
data FrontierScope
  = FrontierGraph
  | FrontierNode !Text
  deriving stock (Eq, Show)

-- | Whether @wire frontier@ prints human text or the stable JSON surface.
data FrontierFormat
  = FrontierText
  | FrontierJson
  deriving stock (Eq, Show)

-- | Parsed command arguments for @wire frontier@.
data FrontierCommand = FrontierCommand
  { frontierCommandClosure :: !FrontierClosure
  , frontierCommandScope :: !FrontierScope
  , frontierCommandFormat :: !FrontierFormat
  , frontierCommandSelectedReturn :: !(Maybe Text)
  , frontierCommandFile :: !FilePath
  }
  deriving stock (Eq, Show)

frontierUsage :: Text
frontierUsage = "usage: wire frontier [--return NAME] [--closure | --open] [--node NODE] [--json] FILE"

parseFrontierCommand :: [String] -> Either Text FrontierCommand
parseFrontierCommand = collect Nothing Nothing Nothing FrontierText []
  where
    collect maybeClosure maybeScope maybeReturn format files = \case
      [] -> finish maybeClosure maybeScope maybeReturn format files
      ("--json" : rest) -> collect maybeClosure maybeScope maybeReturn FrontierJson files rest
      ("--closure" : rest) -> do
        closure <- setClosure FrontierClosed maybeClosure
        collect (Just closure) maybeScope maybeReturn format files rest
      ("--open" : rest) -> do
        closure <- setClosure FrontierOpen maybeClosure
        collect (Just closure) maybeScope maybeReturn format files rest
      ("--return" : selectedReturn : rest)
        | "-" `isPrefixOf` selectedReturn -> Left frontierUsage
        | otherwise -> do
            selected <- setReturn (T.pack selectedReturn) maybeReturn
            collect maybeClosure maybeScope (Just selected) format files rest
      ("--node" : nodeName : rest)
        | "-" `isPrefixOf` nodeName -> Left frontierUsage
        | otherwise -> do
            scope <- setScope (FrontierNode (T.pack nodeName)) maybeScope
            collect maybeClosure (Just scope) maybeReturn format files rest
      ["--return"] -> Left frontierUsage
      ["--node"] -> Left frontierUsage
      (('-' : _) : _) -> Left frontierUsage
      (path : rest) -> collect maybeClosure maybeScope maybeReturn format (path : files) rest

    setClosure newClosure = \case
      Nothing -> Right newClosure
      Just oldClosure
        | oldClosure == newClosure -> Right oldClosure
        | otherwise -> Left "wire frontier accepts only one of --closure or --open."

    setScope newScope = \case
      Nothing -> Right newScope
      Just oldScope
        | oldScope == newScope -> Right oldScope
        | otherwise -> Left "wire frontier accepts only one --node selection."

    setReturn newReturn = \case
      Nothing -> Right newReturn
      Just oldReturn
        | oldReturn == newReturn -> Right oldReturn
        | otherwise -> Left "wire frontier accepts only one --return selection."

    finish maybeClosure maybeScope maybeReturn format files =
      case reverse files of
        [path] ->
          Right
            FrontierCommand
              { frontierCommandClosure = fromMaybe FrontierClosed maybeClosure
              , frontierCommandScope = fromMaybe FrontierGraph maybeScope
              , frontierCommandFormat = format
              , frontierCommandSelectedReturn = maybeReturn
              , frontierCommandFile = path
              }
        _ -> Left frontierUsage
