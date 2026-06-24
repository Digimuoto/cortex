{- |
Module      : Cortex.Quantum.BraketRunnerSpec
Description : End-to-end hardware run against a faked AWS transport.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Drives the full submit/poll/fetch/decode orchestration through a fixture
'BraketAws' — no network, no credentials, no subprocess — confirming the realized
distance-3 repetition code decodes into the expected correlated outcome.
-}
module Cortex.Quantum.BraketRunnerSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Timeout (timeout)
import Test.Hspec

import Cortex.Capability.BindingPack.Braket (BraketConfig (..), braketBindingPack)
import Cortex.Pulse.Lowering.Circuit (lrIdempotencyKey)
import Cortex.Quantum.Braket
  ( BraketAws (..)
  , BraketSettings (..)
  , CircuitResult (..)
  , CreateTaskRequest (..)
  , ExecMode (..)
  , braketCreateTaskClientToken
  , buildActionPayload
  , executeCircuit
  , resolveDeviceArn
  )
import Cortex.Quantum.Cost (noCostOverrides)
import Cortex.Quantum.Plan (RealizeLowering (..), lowerCompiledRealize, renderRealizeError)
import Cortex.Quantum.Result (matchingShots)
import Cortex.Quantum.TestSupport (compileReturn, loadTestEnv)
import Cortex.Wire.Contract (WireCompileEnv)
import Cortex.Wire.Executor (WireExecutorId (..))

deviceValue :: Value
deviceValue = object ["deviceStatus" .= ("ONLINE" :: Text), "deviceName" .= ("SV1" :: Text)]

taskValue :: Value
taskValue =
  object
    [ "status" .= ("COMPLETED" :: Text)
    , "outputS3Bucket" .= ("b" :: Text)
    , "outputS3Directory" .= ("d/task" :: Text)
    , "numSuccessfulShots" .= (2 :: Int)
    ]

-- Braket returns per-shot rows ordered by qubit index (measuredQubits), not by
-- classical bit. For x1 (X on d1): q0=d0=0, q1=d1=1, q2=d2=0, q3=a01=1, q4=a12=1.
resultValue :: Value
resultValue =
  object
    [ "measuredQubits" .= ([0, 1, 2, 3, 4] :: [Int])
    , "measurements" .= ([[0, 1, 0, 1, 1], [0, 1, 0, 1, 1]] :: [[Int]])
    ]

fakeAws :: BraketAws
fakeAws =
  BraketAws
    { awsGetDevice = \_ -> pure (Right deviceValue)
    , awsCreateTask = \_ -> pure (Right "arn:aws:braket:us-east-1:000000000000:quantum-task/test")
    , awsGetTask = \_ -> pure (Right taskValue)
    , awsFetchResult = \_ -> pure (Right resultValue)
    }

settings :: BraketSettings
settings =
  BraketSettings
    { bsDeviceArn = "arn:aws:braket:::device/quantum-simulator/amazon/sv1"
    , bsRegion = "us-east-1"
    , bsBucket = Just "b"
    , bsPrefix = "cortex/dev"
    , bsProfile = Nothing
    , bsShots = 2
    , bsPollInterval = 0
    , bsTimeout = 1
    , bsOverrides = noCostOverrides
    }

{- | Run the full x1 pipeline against the fixture transport, returning the shot
count that landed on the expected corrected outcome.
-}
runX1 :: WireCompileEnv -> IO (Either Text Int)
runX1 env = do
  loweringE <- lowerX1 env
  case loweringE of
    Left err -> pure (Left err)
    Right lowering -> do
      outcome <- executeCircuit fakeAws settings Hardware "x1" lowering
      pure $ case outcome >>= maybe (Left "no decoded result") Right . crResult of
        Left err -> Left err
        Right decoded -> Right (matchingShots decoded "final_d0=0,final_d1=1,final_d2=0,s01=1,s12=1")

lowerX1 :: WireCompileEnv -> IO (Either Text RealizeLowering)
lowerX1 env = do
  source <- TIO.readFile "examples/wire/qec-repetition-realize.wire"
  case compileReturn env "qec_repetition_x1" source of
    Left err -> pure (Left err)
    Right circuit -> pure (either (Left . renderRealizeError) Right (lowerCompiledRealize pack realizeId circuit))
  where
    pack =
      braketBindingPack
        (BraketConfig "us-east-1" "arn:aws:braket:::device/quantum-simulator/amazon/sv1" "b" Nothing)
    realizeId = WireExecutorId "quantum.realize"

spec :: Spec
spec = do
  describe "Braket settings resolution" $ do
    it "defaults to SV1 only when no backend or device ARN is supplied" $
      resolveDeviceArn Nothing Nothing Nothing
        `shouldBe` Right "arn:aws:braket:::device/quantum-simulator/amazon/sv1"

    it "rejects unknown logical backend names" $
      resolveDeviceArn Nothing (Just "sv11") Nothing
        `shouldSatisfy` either (T.isInfixOf "unknown Braket backend") (const False)

  describe "Braket create-task client tokens" $ do
    it "are scoped to concrete create-task request parameters" $ do
      let planKey = "plan-digest"
          action = buildActionPayload "OPENQASM 3;\nqubit[1] q;\n"
          token =
            braketCreateTaskClientToken
              planKey
              "us-east-1"
              "arn:aws:braket:::device/quantum-simulator/amazon/sv1"
              100
              "bucket"
              "cortex/dev/run-a"
              action
          tokenAgain =
            braketCreateTaskClientToken
              planKey
              "us-east-1"
              "arn:aws:braket:::device/quantum-simulator/amazon/sv1"
              100
              "bucket"
              "cortex/dev/run-a"
              action
          changedShots =
            braketCreateTaskClientToken
              planKey
              "us-east-1"
              "arn:aws:braket:::device/quantum-simulator/amazon/sv1"
              101
              "bucket"
              "cortex/dev/run-a"
              action
      token `shouldBe` tokenAgain
      token `shouldNotBe` planKey
      token `shouldNotBe` changedShots
      T.length token `shouldBe` 64

  beforeAll loadTestEnv
    . describe "Braket runner against a fixture transport"
    $ do
      it "submits, polls, fetches, and decodes the x1 repetition code outcome" $ \env ->
        runX1 env `shouldReturn` Right 2

      it "submits the request-scoped Braket client token" $ \env -> do
        requestRef <- newIORef Nothing
        loweringE <- lowerX1 env
        case loweringE of
          Left err -> expectationFailure (T.unpack err)
          Right lowering -> do
            let planKey = lrIdempotencyKey (realizeLowered lowering)
                aws =
                  fakeAws
                    { awsCreateTask = \request -> do
                        writeIORef requestRef (Just request)
                        pure (Right "arn:aws:braket:us-east-1:000000000000:quantum-task/test")
                    }
            outcome <- executeCircuit aws settings Hardware "x1" lowering
            case outcome of
              Left err -> expectationFailure (T.unpack err)
              Right _ -> do
                request <- readIORef requestRef
                case request of
                  Nothing -> expectationFailure "expected a Braket create-task request"
                  Just req -> do
                    let expected =
                          braketCreateTaskClientToken
                            planKey
                            (bsRegion settings)
                            (ctrDeviceArn req)
                            (ctrShots req)
                            (ctrS3Bucket req)
                            (ctrS3Prefix req)
                            (ctrAction req)
                    ctrClientToken req `shouldBe` expected
                    ctrClientToken req `shouldNotBe` planKey

      it "does not sleep past the configured polling timeout" $ \env -> do
        loweringE <- lowerX1 env
        case loweringE of
          Left err -> expectationFailure (T.unpack err)
          Right lowering -> do
            let runningTask = object ["status" .= ("RUNNING" :: Text)]
                longPollSettings = settings {bsPollInterval = 300, bsTimeout = 0}
                aws = fakeAws {awsGetTask = \_ -> pure (Right runningTask)}
            outcome <- timeout 500000 (executeCircuit aws longPollSettings Hardware "x1" lowering)
            case outcome of
              Nothing -> expectationFailure "polling slept past the configured timeout"
              Just (Left err) ->
                err `shouldSatisfy` T.isInfixOf "timed out waiting for Braket task"
              Just (Right _) ->
                expectationFailure "expected polling to time out"
