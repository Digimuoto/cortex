{- |
Module      : Cortex.Wire.EndpointUseSpec
Description : Tests for the ADR 0081 endpoint-use projection over admission artifacts.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Unit tests for 'endpointUseReportFromArtifact', exercising the persisted
endpoint-use witness projection over hand-built admission artifacts: an
edge-matched producer/consumer pair, a zero-output terminating node, a
closed-graph host return, and an open-fragment exported boundary.
-}
module Cortex.Wire.EndpointUseSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Test.Hspec

import Cortex.Wire (CircuitNodeRef (..), Connection (..), EndpointRef (..))
import Cortex.Wire.AdmissionArtifact
  ( AdmissionBoundaryPort (..)
  , AdmissionPortLabel (..)
  , PrimitiveGraphStep (..)
  , WireAdmissionArtifact (..)
  , WireAdmissionClosureMode (..)
  , emptyWireAdmissionArtifact
  , finalizeWireAdmissionArtifact
  )
import Cortex.Wire.EndpointUse

nodeA, nodeB :: CircuitNodeRef
nodeA = CircuitNodeRef "A"
nodeB = CircuitNodeRef "B"

-- An output port "o" of contract "C" on a node.
outPort :: CircuitNodeRef -> AdmissionBoundaryPort
outPort node =
  AdmissionBoundaryPort
    { admissionBoundaryNode = node
    , admissionBoundaryPort = "o"
    , admissionBoundaryContract = "C"
    , admissionBoundaryLabel = AdmissionNoLabel
    , admissionBoundaryExclusiveGroup = Nothing
    }

-- An input port "i" of contract "C" on a node.
inPort :: CircuitNodeRef -> AdmissionBoundaryPort
inPort node =
  AdmissionBoundaryPort
    { admissionBoundaryNode = node
    , admissionBoundaryPort = "i"
    , admissionBoundaryContract = "C"
    , admissionBoundaryLabel = AdmissionNoLabel
    , admissionBoundaryExclusiveGroup = Nothing
    }

artifactWith
  :: [PrimitiveGraphStep]
  -> [Connection]
  -> [AdmissionBoundaryPort]
  -> [AdmissionBoundaryPort]
  -> WireAdmissionArtifact
artifactWith steps connections entries exits =
  emptyWireAdmissionArtifact
    { wireAdmissionNodes = [nodeA, nodeB]
    , wireAdmissionEntries = entries
    , wireAdmissionExits = exits
    , wireAdmissionConnections = connections
    , wireAdmissionPrimitiveSteps = steps
    }

finalizedArtifactWith
  :: WireAdmissionClosureMode
  -> [PrimitiveGraphStep]
  -> [Connection]
  -> [AdmissionBoundaryPort]
  -> [AdmissionBoundaryPort]
  -> WireAdmissionArtifact
finalizedArtifactWith closure steps connections entries exits =
  finalizeWireAdmissionArtifact closure (artifactWith steps connections entries exits)

spec :: Spec
spec = describe "Cortex.Wire.EndpointUse.endpointUseReportFromArtifact" $ do
  it "classifies an edge-matched producer and consumer, and flags the terminating node" $ do
    let artifact =
          finalizedArtifactWith
            AdmissionClosedExecutable
            [ PrimitiveNode nodeA [] [outPort nodeA]
            , PrimitiveNode nodeB [inPort nodeB] []
            ]
            [Connection (EndpointRef nodeA (Just "o")) (EndpointRef nodeB (Just "i"))]
            []
            []
        report = endpointUseReportFromArtifact artifact

    case lookupNodeFrontier nodeA report of
      Just frontier -> do
        nodeFrontierTerminating frontier `shouldBe` False
        fmap outputFrontierUse frontier.nodeFrontierOutputs
          `shouldBe` [ConsumedByEdge (EndpointId nodeB "i")]
      Nothing -> expectationFailure "node A missing from report"

    case lookupNodeFrontier nodeB report of
      Just frontier -> do
        nodeFrontierTerminating frontier `shouldBe` True
        fmap inputFrontierUse frontier.nodeFrontierInputs
          `shouldBe` [ProducedByEdge (EndpointId nodeA "o")]
      Nothing -> expectationFailure "node B missing from report"

    reportUnaccounted report `shouldBe` ([], [])

  it "renders the stable graph JSON surface" $ do
    let artifact =
          finalizedArtifactWith
            AdmissionClosedExecutable
            [ PrimitiveNode nodeA [] [outPort nodeA]
            , PrimitiveNode nodeB [inPort nodeB] []
            ]
            [Connection (EndpointRef nodeA (Just "o")) (EndpointRef nodeB (Just "i"))]
            []
            []
        report = endpointUseReportFromArtifact artifact
        expected =
          Aeson.object
            [ "closure" Aeson..= ("closed_executable" :: Text)
            , "nodes"
                Aeson..= [ Aeson.object
                             [ "node" Aeson..= ("A" :: Text)
                             , "terminating" Aeson..= False
                             , "inputs" Aeson..= ([] :: [Aeson.Value])
                             , "outputs"
                                 Aeson..= [ Aeson.object
                                              [ "port" Aeson..= ("o" :: Text)
                                              , "contract" Aeson..= ("C" :: Text)
                                              , "accounting"
                                                  Aeson..= Aeson.object
                                                    [ "use" Aeson..= ("consumed_by_edge" :: Text)
                                                    , "to"
                                                        Aeson..= Aeson.object
                                                          [ "node" Aeson..= ("B" :: Text)
                                                          , "port" Aeson..= ("i" :: Text)
                                                          ]
                                                    ]
                                              ]
                                          ]
                             ]
                         , Aeson.object
                             [ "node" Aeson..= ("B" :: Text)
                             , "terminating" Aeson..= True
                             , "inputs"
                                 Aeson..= [ Aeson.object
                                              [ "port" Aeson..= ("i" :: Text)
                                              , "contract" Aeson..= ("C" :: Text)
                                              , "accounting"
                                                  Aeson..= Aeson.object
                                                    [ "use" Aeson..= ("produced_by_edge" :: Text)
                                                    , "from"
                                                        Aeson..= Aeson.object
                                                          [ "node" Aeson..= ("A" :: Text)
                                                          , "port" Aeson..= ("o" :: Text)
                                                          ]
                                                    ]
                                              ]
                                          ]
                             , "outputs" Aeson..= ([] :: [Aeson.Value])
                             ]
                         ]
            , "hostInputs" Aeson..= ([] :: [Text])
            , "importedObligations" Aeson..= ([] :: [Text])
            , "terminalDischarges" Aeson..= ([] :: [Aeson.Value])
            ]

    Aeson.toJSON report `shouldBe` expected

  it "classifies a closed-graph carried output as a host_return terminal discharge" $ do
    let artifact =
          finalizedArtifactWith
            AdmissionClosedExecutable
            [PrimitiveNode nodeA [] [outPort nodeA]]
            []
            []
            [outPort nodeA]
        report = endpointUseReportFromArtifact artifact

    case lookupNodeFrontier nodeA report of
      Just frontier ->
        fmap outputFrontierUse frontier.nodeFrontierOutputs
          `shouldBe` [TerminalDischarge HostReturn]
      Nothing -> expectationFailure "node A missing from report"

    reportUnaccounted report `shouldBe` ([], [])

  it "classifies the same carried output as an exported_boundary on an open fragment" $ do
    let artifact =
          finalizedArtifactWith
            AdmissionOpenFragment
            [PrimitiveNode nodeA [] [outPort nodeA]]
            []
            []
            [outPort nodeA]
        report = endpointUseReportFromArtifact artifact

    case lookupNodeFrontier nodeA report of
      Just frontier ->
        fmap outputFrontierUse frontier.nodeFrontierOutputs
          `shouldBe` [TerminalDischarge ExportedBoundary]
      Nothing -> expectationFailure "node A missing from report"

  it "reports an input with no producer and no import as unaccounted" $ do
    let artifact =
          finalizedArtifactWith
            AdmissionClosedExecutable
            [PrimitiveNode nodeB [inPort nodeB] []]
            []
            []
            []
        report = endpointUseReportFromArtifact artifact

    reportUnaccounted report `shouldBe` ([EndpointId nodeB "i"], [])

  it "classifies an open imported input obligation" $ do
    let artifact =
          finalizedArtifactWith
            AdmissionOpenFragment
            [PrimitiveNode nodeB [inPort nodeB] []]
            []
            [inPort nodeB]
            []
        report = endpointUseReportFromArtifact artifact

    case lookupNodeFrontier nodeB report of
      Just frontier ->
        fmap inputFrontierUse frontier.nodeFrontierInputs `shouldBe` [ImportedObligation]
      Nothing -> expectationFailure "node B missing from report"

    reportUnaccounted report `shouldBe` ([], [])

  it "classifies top-level inputs as host_input in a closed executable report" $ do
    let artifact =
          finalizedArtifactWith
            AdmissionClosedExecutable
            [PrimitiveNode nodeB [inPort nodeB] []]
            []
            [inPort nodeB]
            []
        report = endpointUseReportFromArtifact artifact

    case lookupNodeFrontier nodeB report of
      Just frontier ->
        fmap inputFrontierUse frontier.nodeFrontierInputs `shouldBe` [HostInput]
      Nothing -> expectationFailure "node B missing from report"

    reportUnaccounted report `shouldBe` ([], [])
