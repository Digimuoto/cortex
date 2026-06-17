{- |
Module      : Cortex.Pulse.Executor.ExternalCallSpec
Description : Tests for the ADR 0059 §3 submit/park/resume protocol.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Drives the protocol state machine over IORef-backed fakes: synchronous complete and
fail, submit→suspend, resume→complete, submit-failure→fail, and the crash-safety
property that a re-entry before the handle is recorded re-submits with the same
idempotency key (no duplicate provider task).
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
import Cortex.Pulse.Query.ExternalCall (ExternalCallAttemptKey (..))

key :: Text -> ExternalCallAttemptKey
key = ExternalCallAttemptKey UUID.nil "realize" "pack"

-- The IORef store is keyed by frontier id (distinct per test).
newStore :: IO (IORef (Map Text AttemptView), AttemptStore IO)
newStore = do
  ref <- newIORef Map.empty
  let setStatus s = modifyIORef' ref . Map.adjust (\v -> v {avStatus = s}) . ecaFrontierId
      store =
        AttemptStore
          { storeLoad = \k -> Map.lookup (ecaFrontierId k) <$> readIORef ref
          , storeReserve = \k _ _ ->
              modifyIORef' ref (Map.insertWith (\_ old -> old) (ecaFrontierId k) (AttemptView Nothing "reserved"))
          , storePersistHandle = \k h _ ->
              modifyIORef' ref (Map.insert (ecaFrontierId k) (AttemptView (Just h) "submitted"))
          , storeSettle = setStatus "settled"
          , storeFail = setStatus "failed"
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
    , driverSubmit = \_ _ -> pure (Right (Aeson.toJSON ("job-1" :: Text)))
    , driverFetch = \_ -> pure (Right outputs)
    , driverIdempotencyKey = const "idem-fixed"
    , driverSignalName = \k -> "ext:" <> ecaFrontierId k
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

  it "submit/park/resume: first entry submits and suspends, recording the handle" $ do
    (ref, store) <- newStore
    r <- runExternalCall SubmitParkResume baseDriver store (key "spr") plan
    r `shouldBe` ExternalCallSuspended "ext:spr"
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

  it "submit/park/resume: a submit failure fails" $ do
    (_, store) <- newStore
    let driver = baseDriver {driverSubmit = \_ _ -> pure (Left "queue rejected")}
    r <- runExternalCall SubmitParkResume driver store (key "spr-fail") plan
    r `shouldBe` ExternalCallFailed "queue rejected"

  it "submit/park/resume: re-entry before the handle is recorded re-submits with the same key" $ do
    (_, store) <- newStore
    submittedKeys <- newIORef ([] :: [Text])
    -- A store that loses the handle (simulating a crash before persist): persistHandle is a no-op.
    let losingStore = store {storePersistHandle = \_ _ _ -> pure ()}
        driver =
          baseDriver
            { driverSubmit = \idem _ -> modifyIORef' submittedKeys (idem :) >> pure (Right (Aeson.toJSON ("job" :: Text)))
            }
    _ <- runExternalCall SubmitParkResume driver losingStore (key "spr-crash") plan
    _ <- runExternalCall SubmitParkResume driver losingStore (key "spr-crash") plan
    ks <- readIORef submittedKeys
    ks `shouldBe` ["idem-fixed", "idem-fixed"]
