module Platform.HTTP.Retry
  ( shouldRetry,
    retryPolicy,
  )
where

import Control.Retry (RetryPolicy, exponentialBackoff, limitRetries)
import Network.HTTP.Client (HttpException (..), HttpExceptionContent (..), responseStatus)
import Network.HTTP.Types.Status (status429, status500, status503, status504)

-- | Retry policy with exponential backoff (1 second base) and max 3 retries.
retryPolicy :: RetryPolicy
retryPolicy = exponentialBackoff 1000000 <> limitRetries 3

-- | Predicate to decide which HTTP errors should be retried.
shouldRetry :: HttpException -> Bool
shouldRetry (HttpExceptionRequest _ content) = case content of
  ResponseTimeout -> True
  ConnectionTimeout -> True
  ConnectionFailure {} -> True
  IncompleteHeaders -> True
  ConnectionClosed -> True
  NoResponseDataReceived -> True
  StatusCodeException response _ ->
    let status = responseStatus response
     in status == status429
          || status == status500
          || status == status503
          || status == status504
  _ -> False
shouldRetry (InvalidUrlException _ _) = False
