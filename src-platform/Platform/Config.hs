{- |
Module      : Platform.Config
Description : Environment variable reading utilities.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Helpers for reading typed configuration from environment variables
with defaults. Used across worker and server modules.

Platform modules provide generic runtime substrate utilities and do not import Cortex or consumers.
-}
module Platform.Config
  ( readEnvWithDefault
  , readEnvInt
  , readEnvText
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | Read an environment variable with a default, parsing via 'Read'.
readEnvWithDefault :: Read a => String -> a -> IO a
readEnvWithDefault envVar def = do
  val <- lookupEnv envVar
  pure $ maybe def (fromMaybe def . readMaybe) val

-- | Read an environment variable as 'Int' with a default.
readEnvInt :: String -> Int -> IO Int
readEnvInt = readEnvWithDefault

-- | Read an environment variable as 'Text' with a default.
readEnvText :: String -> Text -> IO Text
readEnvText envVar def = do
  val <- lookupEnv envVar
  pure $ maybe def T.pack val
