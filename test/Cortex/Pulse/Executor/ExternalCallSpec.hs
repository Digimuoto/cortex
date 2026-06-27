{- |
Module      : Cortex.Pulse.Executor.ExternalCallSpec
Description : Tests for the ADR 0059 §3 submit/park/resume protocol.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Drives the protocol state machine over IORef-backed fakes: synchronous complete and
fail; submit→suspend on the runtime-owned @external-call:@ wake; resume→complete;
not-ready→re-suspend (no settle/fail); typed fetch failure; a failed attempt
short-circuits to its stored reason without re-fetching; the provider submit token is
the driver's own (decoupled from the Pulse idempotency key); and the crash-safety
property that a re-entry before the handle is recorded re-submits with the same key.
-}
module Cortex.Pulse.Executor.ExternalCallSpec (spec) where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.IORef
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.UUID qualified as UUID
import Test.Hspec

import Cortex.Capability.Catalog.AwaitStrategy (AwaitStrategy (..))
import Cortex.Pulse.Executor.ExternalCall
import Cortex.Pulse.Query.ExternalCall (ExternalCallAttemptKey (..), externalCallSignalSuffix)
import Cortex.Pulse.Signal (externalCallSignalName, unSignalName)

key :: Text -> ExternalCallAttemptKey
key = ExternalCallAttemptKey UUID.nil "realize" "pack"

-- | The runtime-owned wake name the protocol mints for an attempt key.
expectedSignal :: ExternalCallAttemptKey -> Text
expectedSignal = unSignalName . externalCallSignalName . externalCallSignalSuffix

-- The IORef store is keyed by frontier id (distinct per test).
newStore :: IO (IORef (Map Text AttemptView), AttemptStore IO)
newStore = do
  ref <- newIORef Map.empty
  let adjust f = modifyIORef' ref . Map.adjust f . ecaFrontierId
      store =
        AttemptStore
          { storeLoad = \k -> Map.lookup (ecaFrontierId k) <$> readIORef ref
          , storeReserve = \k _ _ ->
              modifyIORef'
                ref
                (Map.insertWith (\_ old -> old) (ecaFrontierId k) (AttemptView Nothing "reserved" Nothing))
          , storePersistHandle = \k h _ ->
              modifyIORef' ref (Map.insert (ecaFrontierId k) (AttemptView (Just h) "submitted" Nothing))
          , storeSettle = adjust (\v -> v {avStatus = "settled"})
          , storeFail = \k reason -> adjust (\v -> v {avStatus = "failed", avFailureReason = Just reason}) k
          }
  pure (ref, store)

plan :: Value
plan = Aeson.object ["op" Aeson..= ("cnot" :: Text)]

outputs :: [(Text, Value)]
outputs = [("s01", Aeson.toJSON (1 :: Int)), ("s12", Aeson.toJSON (0 :: Int))]

baseDriver :: ExternalCallDriver IO
baseDriver =
  ExternalCallDriver
    { driverRunSync = \_ -> pure (Right outputs)
    , driverSubmit = \_ctx -> pure (Right (Aeson.toJSON ("job-1" :: Text)))
    , driverFetch = \_ -> pure (FetchCompleted outputs)
    , driverIdempotencyKey = const "idem-fixed"
    }

spec :: Spec
spec = describe "runExternalCall" $ do
  it "synchronous: runs inline and completes" $ do
    (_, store) <- newStore
    r <- runExternalCall Synchronous baseDriver store (key "sync") plan
    r `shouldBe` ExternalCallCompleted outputs

  it "synchronous: a driver error fails" $ do
    (_, store) <- newStore
    let driver = baseDriver {driverRunSync = \_ -> pure (Left "device offline")}
    r <- runExternalCall Synchronous driver store (key "sync-fail") plan
    r `shouldBe` ExternalCallFailed "device offline"

  it "submit/park/resume: first entry submits and suspends on the runtime-owned wake" $ do
    (ref, store) <- newStore
    r <- runExternalCall SubmitParkResume baseDriver store (key "spr") plan
    r `shouldBe` ExternalCallSuspended (expectedSignal (key "spr"))
    m <- readIORef ref
    fmap avStatus (Map.lookup "spr" m) `shouldBe` Just "submitted"
    (avJobHandle =<< Map.lookup "spr" m) `shouldBe` Just (Aeson.toJSON ("job-1" :: Text))

  it "submit/park/resume: resume with a recorded handle fetches and completes" $ do
    (ref, store) <- newStore
    _ <- runExternalCall SubmitParkResume baseDriver store (key "spr2") plan
    r <- runExternalCall SubmitParkResume baseDriver store (key "spr2") plan
    r `shouldBe` ExternalCallCompleted outputs
    m <- readIORef ref
    fmap avStatus (Map.lookup "spr2" m) `shouldBe` Just "settled"

  it "submit/park/resume: a not-ready fetch re-suspends without settling or failing" $ do
    (ref, store) <- newStore
    let driver = baseDriver {driverFetch = \_ -> pure FetchNotReady}
    _ <- runExternalCall SubmitParkResume driver store (key "spr-wait") plan
    r <- runExternalCall SubmitParkResume driver store (key "spr-wait") plan
    r `shouldBe` ExternalCallSuspended (expectedSignal (key "spr-wait"))
    m <- readIORef ref
    -- still in flight: neither settled nor failed.
    fmap avStatus (Map.lookup "spr-wait" m) `shouldBe` Just "submitted"

  it "submit/park/resume: a typed fetch failure fails and records the reason" $ do
    (ref, store) <- newStore
    let driver = baseDriver {driverFetch = \_ -> pure (FetchFailed "calibration error")}
    _ <- runExternalCall SubmitParkResume driver store (key "spr-bad") plan
    r <- runExternalCall SubmitParkResume driver store (key "spr-bad") plan
    r `shouldBe` ExternalCallFailed "calibration error"
    m <- readIORef ref
    fmap avStatus (Map.lookup "spr-bad" m) `shouldBe` Just "failed"
    (avFailureReason =<< Map.lookup "spr-bad" m) `shouldBe` Just "calibration error"

  it "submit/park/resume: a failed attempt reproduces its reason on resume without re-fetching" $ do
    (_, store) <- newStore
    fetchCount <- newIORef (0 :: Int)
    let driver = baseDriver {driverFetch = \_ -> modifyIORef' fetchCount (+ 1) >> pure (FetchCompleted outputs)}
    -- Seed a failed attempt with a recorded handle (a crash after storeFail).
    storePersistHandle store (key "spr-resume-fail") (Aeson.toJSON ("job" :: Text)) "ignored"
    storeFail store (key "spr-resume-fail") "device rejected"
    r <- runExternalCall SubmitParkResume driver store (key "spr-resume-fail") plan
    r `shouldBe` ExternalCallFailed "device rejected"
    readIORef fetchCount `shouldReturn` 0

  it "submit/park/resume: a submit failure fails" $ do
    (_, store) <- newStore
    let driver = baseDriver {driverSubmit = \_ctx -> pure (Left "queue rejected")}
    r <- runExternalCall SubmitParkResume driver store (key "spr-fail") plan
    r `shouldBe` ExternalCallFailed "queue rejected"

  it "submit/park/resume: the provider token is the driver's own, decoupled from the Pulse key" $ do
    (ref, store) <- newStore
    -- The driver derives its provider token; here it is deliberately NOT the Pulse
    -- idempotency key, and the recorded handle proves Pulse never imposed its key.
    let driver =
          baseDriver
            { driverSubmit = \ctx ->
                pure (Right (Aeson.toJSON ("provider-token:" <> ecIdempotencyKey ctx <> ":v2")))
            }
    _ <- runExternalCall SubmitParkResume driver store (key "spr-token") plan
    m <- readIORef ref
    let handle = avJobHandle =<< Map.lookup "spr-token" m
    handle `shouldBe` Just (Aeson.toJSON ("provider-token:idem-fixed:v2" :: Text))
    handle `shouldNotBe` Just (Aeson.toJSON ("idem-fixed" :: Text))

  it "submit/park/resume: re-entry before the handle is recorded re-submits with the same key" $ do
    (_, store) <- newStore
    submittedKeys <- newIORef ([] :: [Text])
    -- A store that loses the handle (simulating a crash before persist): persistHandle is a no-op.
    let losingStore = store {storePersistHandle = \_ _ _ -> pure ()}
        driver =
          baseDriver
            { driverSubmit = \ctx ->
                modifyIORef' submittedKeys (ecIdempotencyKey ctx :) >> pure (Right (Aeson.toJSON ("job" :: Text)))
            }
    _ <- runExternalCall SubmitParkResume driver losingStore (key "spr-crash") plan
    _ <- runExternalCall SubmitParkResume driver losingStore (key "spr-crash") plan
    ks <- readIORef submittedKeys
    ks `shouldBe` ["idem-fixed", "idem-fixed"]
