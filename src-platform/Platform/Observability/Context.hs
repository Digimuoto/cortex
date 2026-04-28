{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Platform.Observability.Context
  ( -- * Public API (re-exported by Platform.Observability)
    newLinkedRootContext
  , withThreadContext
  , withThreadContextPatch
  , captureCurrentContext
  , currentTraceHeaders
  , forkWithContext
  , forkWithSharedContext

    -- * Internal (used by sibling modules)
  , currentContextForRuntime
  , randomHexText
  , nextRequestId
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (ThreadId, forkIO, myThreadId)
import Control.Concurrent.STM (atomically, modifyTVar', readTVarIO)
import Control.Exception (bracket)
import Crypto.Random (getRandomBytes)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString qualified as BS
import Data.Functor ((<&>))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word16, Word64)
import Network.HTTP.Types (HeaderName)
import Numeric (showHex)

import Platform.Observability.Types

newLinkedRootContext
  :: Maybe ObservabilityContext -> Maybe Text -> Maybe Text -> IO ObservabilityContext
newLinkedRootContext maybeParent maybeRunId maybeOperation = do
  traceTxt <- randomHexText 16
  spanTxt <- randomHexText 8
  pure
    ObservabilityContext
      { requestId = Nothing
      , upstreamRequestId = Nothing
      , traceId = traceTxt
      , spanId = spanTxt
      , runId = maybeRunId
      , userId = maybeParent >>= (.userId)
      , accountId = maybeParent >>= (.accountId)
      , assetId = maybeParent >>= (.assetId)
      , provider = maybeParent >>= (.provider)
      , httpMethod = Nothing
      , route = Nothing
      , operation = maybeOperation
      , stage = Nothing
      , toolName = Nothing
      , assistantPhase = Nothing
      , model = Nothing
      , stepIndex = Nothing
      , linkedTraceId = maybeParent <&> (.traceId)
      , linkedRequestId = maybeParent >>= (.requestId)
      , linkedSpanId = maybeParent <&> (.spanId)
      }

withThreadContext :: ObservabilityRuntime -> ObservabilityContext -> IO a -> IO a
withThreadContext runtime ctx action =
  bracket
    (beginThreadContext runtime ctx)
    endThreadContext
    (const action)

withThreadContextPatch
  :: ObservabilityRuntime -> (ObservabilityContext -> ObservabilityContext) -> IO a -> IO a
withThreadContextPatch runtime patch action = do
  current <- currentContextForRuntime runtime
  next <-
    case current of
      Just ctx -> pure (patch ctx)
      Nothing -> do
        traceTxt <- randomHexText 16
        spanTxt <- randomHexText 8
        pure $
          patch
            ObservabilityContext
              { requestId = Nothing
              , upstreamRequestId = Nothing
              , traceId = traceTxt
              , spanId = spanTxt
              , runId = Nothing
              , userId = Nothing
              , accountId = Nothing
              , assetId = Nothing
              , provider = Nothing
              , httpMethod = Nothing
              , route = Nothing
              , operation = Nothing
              , stage = Nothing
              , toolName = Nothing
              , assistantPhase = Nothing
              , model = Nothing
              , stepIndex = Nothing
              , linkedTraceId = Nothing
              , linkedRequestId = Nothing
              , linkedSpanId = Nothing
              }
  withThreadContext runtime next action

captureCurrentContext :: Maybe ObservabilityRuntime -> IO (Maybe ObservabilityContext)
captureCurrentContext Nothing = pure Nothing
captureCurrentContext (Just runtime) = currentContextForRuntime runtime

currentTraceHeaders :: Maybe ObservabilityRuntime -> IO [(HeaderName, BS.ByteString)]
currentTraceHeaders Nothing = pure []
currentTraceHeaders (Just runtime) = do
  maybeCtx <- currentContextForRuntime runtime
  pure $
    case maybeCtx of
      Nothing -> []
      Just ctx ->
        [ ("traceparent", TE.encodeUtf8 ("00-" <> ctx.traceId <> "-" <> ctx.spanId <> "-01"))
        ]
          <> foldMap (\rid -> [("X-Request-ID", TE.encodeUtf8 rid)]) ctx.requestId

forkWithContext :: Maybe ObservabilityRuntime -> ObservabilityContext -> IO () -> IO ThreadId
forkWithContext Nothing _ action = forkIO action
forkWithContext (Just runtime) ctx action = do
  childSpan <- randomHexText 8
  let childCtx = ctx {spanId = childSpan, linkedSpanId = ctx.linkedSpanId <|> Just ctx.spanId}
  forkIO $ withThreadContext runtime childCtx action

forkWithSharedContext :: Maybe ObservabilityRuntime -> ObservabilityContext -> IO () -> IO ThreadId
forkWithSharedContext Nothing _ action = forkIO action
forkWithSharedContext (Just runtime) ctx action =
  forkIO $ withThreadContext runtime ctx action

-- Internal helpers

beginThreadContext
  :: ObservabilityRuntime
  -> ObservabilityContext
  -> IO (ObservabilityRuntime, ThreadId, Maybe ObservabilityContext)
beginThreadContext runtime ctx = do
  tid <- myThreadId
  previous <- currentContextForRuntime runtime
  atomically $
    modifyTVar'
      runtime.threadContexts
      (Map.insert tid ctx)
  pure (runtime, tid, previous)

endThreadContext :: (ObservabilityRuntime, ThreadId, Maybe ObservabilityContext) -> IO ()
endThreadContext (runtime, tid, maybePrevious) =
  atomically $
    modifyTVar'
      runtime.threadContexts
      ( \contexts ->
          case maybePrevious of
            Nothing -> Map.delete tid contexts
            Just ctx -> Map.insert tid ctx contexts
      )

currentContextForRuntime :: ObservabilityRuntime -> IO (Maybe ObservabilityContext)
currentContextForRuntime runtime = do
  tid <- myThreadId
  contexts <- readTVarIO runtime.threadContexts
  pure (Map.lookup tid contexts)

randomHexText :: Int -> IO Text
randomHexText byteCount = do
  bytes <- getRandomBytes byteCount
  pure $ T.pack (concatMap byteToHex (BS.unpack bytes))
  where
    byteToHex byte =
      let rendered = showHex byte ""
       in if length rendered == 1 then '0' : rendered else rendered

nextRequestId :: IO Text
nextRequestId = do
  nowMs <- floor . (* 1000) <$> getPOSIXTime
  randABytes <- getRandomBytes 2
  randBBytes <- getRandomBytes 8
  let timestamp :: Word64
      timestamp = fromIntegral (nowMs :: Integer) .&. 0xFFFFFFFFFFFF
      randA :: Word16
      randA =
        ((fromIntegral (BS.index randABytes 0) `shiftL` 8) .|. fromIntegral (BS.index randABytes 1))
          .&. 0x0FFF
      randBSource :: Word64
      randBSource =
        foldl
          (\acc byte -> (acc `shiftL` 8) .|. fromIntegral byte)
          0
          (BS.unpack randBBytes)
      randB :: Word64
      randB = (randBSource .&. 0x3FFFFFFFFFFFFFFF) .|. 0x8000000000000000
      group1 = fixedHex 8 (timestamp `shiftR` 16)
      group2 = fixedHex 4 (timestamp .&. 0xFFFF)
      group3 = fixedHex 4 (0x7000 .|. fromIntegral randA)
      group4 = fixedHex 4 (randB `shiftR` 48)
      group5 = fixedHex 12 (randB .&. 0xFFFFFFFFFFFF)
  pure $ T.pack (group1 <> "-" <> group2 <> "-" <> group3 <> "-" <> group4 <> "-" <> group5)
  where
    fixedHex :: Int -> Word64 -> String
    fixedHex width value =
      let rendered = showHex value ""
       in replicate (max 0 (width - length rendered)) '0' <> rendered
