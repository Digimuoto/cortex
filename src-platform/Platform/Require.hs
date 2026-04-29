{- |
Module      : Platform.Require
Description : This module provides combinators for common error-handling patterns in.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

HTTP handlers, such as converting Maybe/Either values to HTTP errors.

Platform modules provide generic runtime substrate utilities and do not import Cortex or consumers.
-}
module Platform.Require
  ( -- * Basic require combinators
    requireMaybe
  , requireEither
  , requireEitherWith

    -- * Re-exports from Servant for convenience
  , Handler
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Servant.Server (Handler)

import Platform.Error
  ( internalError
  , notFoundError
  , throwAppError
  , withContext
  )

{- | Require a Maybe value or throw a 404 Not Found error.

@
requireMaybe "Asset" (Just asset)
requireMaybe "Asset" Nothing
@
-}
requireMaybe :: Text -> Maybe a -> Handler a
requireMaybe resource = maybe (throwAppError $ notFoundError resource) pure

{- | Require an Either value or throw a 500 Internal Server Error.

The Left value is converted to a string using the provided function,
logged internally via AppError, and a safe message is sent to the client.

@
requireEither id (Right asset)
requireEither show (Left "Parse error")
@
-}
requireEither :: (e -> String) -> Either e a -> Handler a
requireEither toMsg = either handleError pure
  where
    handleError e =
      throwAppError
        . withContext "requireEither" Nothing
        $ internalError (T.pack $ toMsg e)

{- | Require an Either value or throw a 500 Internal Server Error with custom body.

Similar to 'requireEither', but includes the error message as context.
The message is logged internally; the client sees a safe generic error.

@
requireEitherWith id (Right asset)
requireEitherWith id (Left "Invalid asset type")
@
-}
requireEitherWith :: (e -> String) -> Either e a -> Handler a
requireEitherWith toMsg = either handleError pure
  where
    handleError e =
      throwAppError
        . withContext "requireEitherWith" Nothing
        $ internalError (T.pack $ toMsg e)
