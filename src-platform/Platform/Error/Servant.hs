{- |
Module      : Platform.Error.Servant
Description : Server error handling utilities
Copyright   : (c) 2026
License     : MIT

Re-exports from Platform.Error for use in server handlers.
-}
module Platform.Error.Servant
  ( -- * Unified error handling
    AppError (..)
  , ErrorContext (..)
  , LogLevel (..)

    -- ** Construction
  , dbError
  , validationError
  , validationErrorWithField
  , notFoundError
  , notFoundWithId
  , authError
  , authzError
  , rateLimitError
  , externalError
  , internalError
  , configError

    -- ** Context
  , withContext
  , addContext

    -- ** Throwing
  , throwAppError
  , logError

    -- ** Classification
  , logLevel
  , isRetryable
  , shouldLog
  )
where

import Platform.Error
  ( AppError (..)
  , ErrorContext (..)
  , LogLevel (..)
  , addContext
  , authError
  , authzError
  , configError
  , dbError
  , externalError
  , internalError
  , isRetryable
  , logError
  , logLevel
  , notFoundError
  , notFoundWithId
  , rateLimitError
  , shouldLog
  , throwAppError
  , validationError
  , validationErrorWithField
  , withContext
  )
