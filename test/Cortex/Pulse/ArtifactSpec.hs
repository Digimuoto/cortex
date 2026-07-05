{- |
Module      : Cortex.Pulse.ArtifactSpec
Description : Tests for the ADR 0089 content-addressed run artifact store.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Pure address tests (stability, typing sensitivity, rendered form) and DB tests
for the store: put/get roundtrip, cross-run content dedup, idempotent re-put,
run-scoped listing, and run-deletion semantics (provenance cascades, shared
content survives). Self-skips when PGHOST is unset.
-}
module Cortex.Pulse.ArtifactSpec (spec) where

import Control.Exception (SomeException, try)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.UUID (UUID)
import Hasql.Decoders qualified as D
import Hasql.Statement (Statement (..))
import Hasql.Transaction qualified as Tx
import System.Environment (lookupEnv)
import Test.Hspec

import Cortex.Pulse.Artifact
import Cortex.Pulse.Query qualified as Q
import Cortex.TestSupport.Database (TestDB, createTestDB, runTx)
import Cortex.Wire (WirePayloadKind (..))

import Platform.Database.Encode qualified as Enc
import Platform.DurableTask.Types (TriggerSource (..))

setupTestDb :: IO (Maybe TestDB)
setupTestDb = do
  mHost <- lookupEnv "PGHOST"
  case mHost of
    Nothing -> pure Nothing
    Just _ -> do
      result <- try createTestDB :: IO (Either SomeException TestDB)
      either (\e -> error ("PGHOST set but DB setup failed: " <> show e)) (pure . Just) result

withDb :: Maybe TestDB -> (TestDB -> IO ()) -> IO ()
withDb Nothing _ = pendingWith "PGHOST not set - database not available"
withDb (Just db) action = action db

-- | Seed a task + run so a provenance row's run_id foreign key resolves.
seedRun :: TestDB -> Text -> IO UUID
seedRun db name = do
  now <- getCurrentTime
  taskId <- runTx db (Q.claimTestTaskDef "paper_portfolio_cycle" name now)
  mRunId <- runTx db (Q.claimAndCreateRun taskId "test-owner" TriggerManual now 300)
  maybe (fail "seedRun: claimAndCreateRun returned Nothing") pure mRunId

deleteRun :: TestDB -> UUID -> IO ()
deleteRun db runId =
  runTx db . Tx.statement runId $
    Statement
      "DELETE FROM pulse.runs WHERE run_id = $1"
      (Enc.encode1 (id, Enc.nonNullable Enc.uuid))
      D.noResult
      False

samplePayload :: Aeson.Value
samplePayload =
  Aeson.object
    [ "summary" Aeson..= ("carried context" :: Text)
    , "window" Aeson..= ([1, 2, 3] :: [Int])
    ]

sampleAddress :: ArtifactHash
sampleAddress =
  artifactAddress (Just "logos.turn") WirePayloadJson "application/json" samplePayload

samplePut :: UUID -> Text -> ArtifactPut
samplePut runId nodeId =
  ArtifactPut
    { apHash = unArtifactHash sampleAddress
    , apPayload = samplePayload
    , apContract = Just "logos.turn"
    , apPayloadKind = "json"
    , apMediaType = "application/json"
    , apByteSize = 64
    , apRunId = runId
    , apNodeId = nodeId
    , apKind = "summary"
    , apTarget = Just "artifacts.summaries"
    }

spec :: Spec
spec = describe "content-addressed run artifact store (ADR 0089)" $ do
  addressSpec
  beforeAll setupTestDb storeSpec

addressSpec :: Spec
addressSpec =
  describe "artifactAddress (pure)" $ do
    it "renders a sha256-prefixed 64-hex address" $ do
      let ArtifactHash rendered = sampleAddress
      T.take 7 rendered `shouldBe` "sha256:"
      T.length rendered `shouldBe` 7 + 64
    it "is stable across identical typed inputs" $
      artifactAddress (Just "logos.turn") WirePayloadJson "application/json" samplePayload
        `shouldBe` sampleAddress
    it "is insensitive to object construction order" $ do
      let a = Aeson.object ["a" Aeson..= (1 :: Int), "b" Aeson..= (2 :: Int)]
          b = Aeson.object ["b" Aeson..= (2 :: Int), "a" Aeson..= (1 :: Int)]
      artifactAddress Nothing WirePayloadJson "application/json" a
        `shouldBe` artifactAddress Nothing WirePayloadJson "application/json" b
    it "changes when the payload value changes" $
      artifactAddress (Just "logos.turn") WirePayloadJson "application/json" (Aeson.String "other")
        `shouldNotBe` sampleAddress
    it "changes when the contract changes" $
      artifactAddress (Just "other.contract") WirePayloadJson "application/json" samplePayload
        `shouldNotBe` sampleAddress
    it "changes when the payload kind changes" $
      artifactAddress (Just "logos.turn") WirePayloadMarkdown "application/json" samplePayload
        `shouldNotBe` sampleAddress
    it "changes when the media type changes" $
      artifactAddress (Just "logos.turn") WirePayloadJson "text/plain" samplePayload
        `shouldNotBe` sampleAddress
    it "distinguishes an absent contract from any named contract" $
      artifactAddress Nothing WirePayloadJson "application/json" samplePayload
        `shouldNotBe` sampleAddress

storeSpec :: SpecWith (Maybe TestDB)
storeSpec =
  describe "store CRUD" $ do
    it "roundtrips a put through get, preserving payload and typing" $ \mdb -> withDb mdb $ \db -> do
      runId <- seedRun db "artifact-roundtrip"
      runTx db (putArtifact (samplePut runId "emitter"))
      loaded <- runTx db (getArtifact (unArtifactHash sampleAddress))
      fmap (.arPayload) loaded `shouldBe` Just samplePayload
      fmap (.arContract) loaded `shouldBe` Just (Just "logos.turn")
      fmap (.arPayloadKind) loaded `shouldBe` Just "json"
      fmap (.arMediaType) loaded `shouldBe` Just "application/json"
      fmap (.arByteSize) loaded `shouldBe` Just 64
    it "dedups identical content across runs: one content row, one provenance row each" $ \mdb -> withDb mdb $ \db -> do
      runA <- seedRun db "artifact-dedup-a"
      runB <- seedRun db "artifact-dedup-b"
      runTx db (putArtifact (samplePut runA "emitter"))
      runTx db (putArtifact (samplePut runB "emitter"))
      forA <- runTx db (listArtifactsForRun runA)
      forB <- runTx db (listArtifactsForRun runB)
      fmap (.afrHash) forA `shouldBe` [unArtifactHash sampleAddress]
      fmap (.afrHash) forB `shouldBe` [unArtifactHash sampleAddress]
    it "re-putting the same (run, node, content) is a no-op" $ \mdb -> withDb mdb $ \db -> do
      runId <- seedRun db "artifact-idem"
      runTx db (putArtifact (samplePut runId "emitter"))
      runTx db (putArtifact (samplePut runId "emitter"))
      rows <- runTx db (listArtifactsForRun runId)
      length rows `shouldBe` 1
    it "lists only the requested run's provenance, in emission order" $ \mdb -> withDb mdb $ \db -> do
      runA <- seedRun db "artifact-scope-a"
      runB <- seedRun db "artifact-scope-b"
      let otherPayload = Aeson.String "second artifact"
          ArtifactHash otherHash = artifactAddress Nothing WirePayloadText "text/plain" otherPayload
          otherPut =
            (samplePut runA "later")
              { apHash = otherHash
              , apPayload = otherPayload
              , apContract = Nothing
              , apPayloadKind = "text"
              , apMediaType = "text/plain"
              , apKind = "transcript"
              , apTarget = Nothing
              }
      runTx db (putArtifact (samplePut runA "emitter"))
      runTx db (putArtifact otherPut)
      runTx db (putArtifact (samplePut runB "emitter"))
      forA <- runTx db (listArtifactsForRun runA)
      fmap (.afrNodeId) forA `shouldBe` ["emitter", "later"]
      fmap (.afrKind) forA `shouldBe` ["summary", "transcript"]
      fmap (.afrTarget) forA `shouldBe` [Just "artifacts.summaries", Nothing]
    it "deleting a run cascades its provenance and leaves shared content" $ \mdb -> withDb mdb $ \db -> do
      runA <- seedRun db "artifact-cascade-a"
      runB <- seedRun db "artifact-cascade-b"
      runTx db (putArtifact (samplePut runA "emitter"))
      runTx db (putArtifact (samplePut runB "emitter"))
      deleteRun db runA
      forA <- runTx db (listArtifactsForRun runA)
      forA `shouldBe` []
      forB <- runTx db (listArtifactsForRun runB)
      fmap (.afrHash) forB `shouldBe` [unArtifactHash sampleAddress]
      -- Content rows are never deleted by Cortex, even when unreferenced.
      deleteRun db runB
      stillStored <- runTx db (getArtifact (unArtifactHash sampleAddress))
      fmap (.arHash) stillStored `shouldBe` Just (unArtifactHash sampleAddress)
