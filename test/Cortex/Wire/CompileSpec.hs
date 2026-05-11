{- |
Module      : Cortex.Wire.CompileSpec
Description : Tests for Cortex.Wire.Compile.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The spec exercises public behavior through the same Nix-backed test surface used by CI.

Tests may import the surface they exercise, but they do not define downstream product behavior.
-}
module Cortex.Wire.CompileSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable qualified as Foldable
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Numeric.Natural (Natural)
import Test.Hspec

import Cortex.Algebra.Graph (successors)
import Cortex.Wire (Connection (..), EndpointRef (..), WirePayloadKind (..))
import Cortex.Wire.AdmissionArtifact
  ( AdmissionBoundaryPort (..)
  , AdmissionConnection (..)
  , AdmissionPortLabel (..)
  , AdmissionStaticField (..)
  , AdmissionStaticValue (..)
  , GeneratedChildArtifact (..)
  , GeneratedChildSourceArtifact (..)
  , GeneratedFormArtifact (..)
  , GeneratedFormKind (..)
  , PhantomAdapterArtifact (..)
  , PhantomAdapterDirection (..)
  , PrimitiveGraphStep (..)
  , ProductShapeArtifact (..)
  , SelectAdmissionArtifact (..)
  , SelectArmAdmissionArtifact (..)
  , SelectResolutionMode (..)
  , SelectVariantArtifact (..)
  , WireAdmissionArtifact (..)
  , combineWireAdmissionArtifacts
  , emptyWireAdmissionArtifact
  , wireAdmissionArtifactValidatorReady
  , wireAdmissionCurrentSchemaVersion
  , wireAdmissionMetadataKey
  , wireAdmissionMetadataValue
  )
import Cortex.Wire.Circuit.Artifact
  ( CircuitConditionNode (..)
  , CompiledCircuit (..)
  , CompiledCircuitFragment (..)
  , CompiledCircuitNode (..)
  )
import Cortex.Wire.Circuit.IR (CircuitNodeRef (..), CircuitTaskNode (..))
import Cortex.Wire.Compile
  ( compileWireFragmentText
  , compileWireText
  , compileWireTextWithEnv
  , compileWireTextWithReturn
  )
import Cortex.Wire.Contract
  ( WireCompileEnv (..)
  , WireContractSpec (..)
  , WireProjectionMode (..)
  , emptyWireCompileEnv
  , wireContractRegistryFromList
  )
import Cortex.Wire.Executor
  ( WireExecutorConfigShape (..)
  , WireExecutorEffect (..)
  , WireExecutorId (..)
  , WireExecutorPortPolicy (..)
  , WireExecutorProjection (..)
  , wireExecutorProjectionFromPorts
  , wireExecutorRegistryFromList
  )
import Cortex.Wire.Include (expandWireSourceIncludes)
import Cortex.Wire.Pure (pureWireExecutorProjection)
import Cortex.Wire.Std
  ( stdIoReadFileShapeMessage
  , stdIoStdoutShapeMessage
  , stdIoWriteFileShapeMessage
  )
import Cortex.Wire.Syntax (ContractId (..), WireError (..), WireOutputPort (..), WirePorts (..))
import Cortex.Wire.Syntax qualified as Syntax

spec :: Spec
spec = describe "Cortex.Wire.Compile" $ do
  it "compiles a labeled Wire chain through the compiled circuit backend" $ do
    compiled <- requireRight (compileWireText simpleChainSourceText)
    compiled.compiledCircuitEntryNodes `shouldBe` [CircuitNodeRef "planner"]
    compiled.compiledCircuitExitNodes `shouldBe` [CircuitNodeRef "analyst"]
    successors compiled.compiledCircuitTopology (CircuitNodeRef "planner")
      `shouldBe` Set.singleton (CircuitNodeRef "analyst")
    expectWireAdmissionArtifact compiled $ \artifact ->
      fmap Aeson.toJSON artifact.wireAdmissionConnections
        `shouldBe` [ simpleChainConnectionJson
                   ]
    expectWireAdmissionArtifact compiled assertSimpleChainPrimitiveConnectArtifact
    wireAdmissionArrayAny
      "wireAdmissionPrimitiveSteps"
      primitiveConnectMatchesSimpleChain
      compiled
      `shouldBe` True

  it "rejects unsupported Wire admission artifact schema versions" $ do
    compiled <- requireRight (compileWireText simpleChainSourceText)
    case wireAdmissionValue compiled of
      Nothing ->
        expectationFailure "wire admission metadata missing"
      Just admission -> do
        let unsupportedAdmission =
              case admission of
                Aeson.Object obj ->
                  Aeson.Object
                    ( KeyMap.insert
                        "wireAdmissionSchemaVersion"
                        (Aeson.Number 0)
                        obj
                    )
                other ->
                  other
        case Aeson.fromJSON unsupportedAdmission :: Aeson.Result WireAdmissionArtifact of
          Aeson.Success _artifact ->
            expectationFailure "unsupported wire admission schema version decoded"
          Aeson.Error message ->
            message `shouldContain` "unsupported wire admission schema version"

  it "rejects negative indexed product artifact counts" $
    case Aeson.fromJSON negativeIndexedProductShapeJson :: Aeson.Result ProductShapeArtifact of
      Aeson.Success _productShape ->
        expectationFailure "negative indexed product artifact count decoded"
      Aeson.Error message ->
        message `shouldContain` "indexed product count must be non-negative"

  it "rejects negative boundary exclusive group artifact indexes" $
    case Aeson.fromJSON negativeExclusiveGroupBoundaryJson :: Aeson.Result AdmissionBoundaryPort of
      Aeson.Success _boundary ->
        expectationFailure "negative exclusive group artifact index decoded"
      Aeson.Error message ->
        message `shouldContain` "exclusive group index must be non-negative"

  it "rejects negative select arm source artifact indexes" $
    case Aeson.fromJSON negativeSelectArmSourceIndexJson :: Aeson.Result SelectArmAdmissionArtifact of
      Aeson.Success _arm ->
        expectationFailure "negative select arm source artifact index decoded"
      Aeson.Error message ->
        message `shouldContain` "select arm source index must be non-negative"

  it "normalizes combined Wire admission artifacts to the current schema version" $ do
    let staleArtifact =
          emptyWireAdmissionArtifact {wireAdmissionSchemaVersion = wireAdmissionCurrentSchemaVersion + 1}
        combinedArtifact = combineWireAdmissionArtifacts staleArtifact emptyWireAdmissionArtifact
    combinedArtifact.wireAdmissionSchemaVersion `shouldBe` wireAdmissionCurrentSchemaVersion

  it "rejects stale Wire admission artifacts at the validator boundary" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionSchemaVersion = wireAdmissionCurrentSchemaVersion + 1
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects top-level admission summaries with duplicate identities" $ do
    let duplicatedNode = CircuitNodeRef "duplicated"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [duplicatedNode, duplicatedNode]
            , wireAdmissionBindingRefs = ["shared", "shared"]
            , wireAdmissionEntries = [plannerBoundary, plannerBoundary]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects generated component rows with duplicate bindings" $ do
    let validArtifact = minimalGeneratedAdmissionArtifact
        generatedRows = validArtifact.wireAdmissionGeneratedForms
        malformedArtifact =
          validArtifact {wireAdmissionGeneratedForms = generatedRows <> generatedRows}
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects empty generated component rows without binding references" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren = []
                    , generatedFormUsedChildren = []
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects non-empty generated source rows without used children" $ do
    let generatedNode = CircuitNodeRef "workers_0"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionBindingRefs = ["workers"]
            , wireAdmissionPrimitiveSteps = [PrimitiveBindingRef "workers"]
            , wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren =
                        [GeneratedChildSourceArtifact generatedNode "0" Nothing]
                    , generatedFormUsedChildren = []
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter component rows with duplicate nodes" $ do
    let validArtifact = minimalPhantomAdmissionArtifact
        phantomRows = validArtifact.wireAdmissionPhantomAdapters
        malformedArtifact =
          validArtifact {wireAdmissionPhantomAdapters = phantomRows <> phantomRows}
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts whose singular contract does not match the product" $ do
    let validArtifact = minimalPhantomAdmissionArtifact
        wrongSingular = admissionTestBoundary (CircuitNodeRef "sink") "plans" "[Other;1]"
        wrongPhantomSingular =
          admissionTestBoundary (CircuitNodeRef "__star:gather:planner:sink") "plans" "[Other;1]"
        malformedArtifact =
          validArtifact
            { wireAdmissionPrimitiveSteps =
                [ PrimitiveNode (CircuitNodeRef "planner") [] [plannerBoundary]
                , PrimitiveNode
                    (CircuitNodeRef "__star:gather:planner:sink")
                    [admissionTestBoundary (CircuitNodeRef "__star:gather:planner:sink") "item_0" "PlannerOutput"]
                    [wrongPhantomSingular]
                , PrimitiveConnect
                    [plannerBoundary]
                    [admissionTestBoundary (CircuitNodeRef "__star:gather:planner:sink") "item_0" "PlannerOutput"]
                    [ AdmissionConnection
                        plannerBoundary
                        (admissionTestBoundary (CircuitNodeRef "__star:gather:planner:sink") "item_0" "PlannerOutput")
                    ]
                    []
                    []
                , PrimitiveNode (CircuitNodeRef "sink") [wrongSingular] []
                , PrimitiveConnect
                    [wrongPhantomSingular]
                    [wrongSingular]
                    [AdmissionConnection wrongPhantomSingular wrongSingular]
                    []
                    []
                ]
            , wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = CircuitNodeRef "__star:gather:planner:sink"
                    , phantomAdapterProductShape = ProductIndexed "PlannerOutput" 1
                    , phantomAdapterSingular = wrongSingular
                    , phantomAdapterMulti = [plannerBoundary]
                    , phantomAdapterLeftBulk =
                        [ AdmissionConnection
                            plannerBoundary
                            ( admissionTestBoundary
                                (CircuitNodeRef "__star:gather:planner:sink")
                                "item_0"
                                "PlannerOutput"
                            )
                        ]
                    , phantomAdapterRightBulk =
                        [AdmissionConnection wrongPhantomSingular wrongSingular]
                    }
                ]
            }
    validArtifact `shouldSatisfy` wireAdmissionArtifactValidatorReady
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts with indexed-product-shaped elements" $ do
    let planner = CircuitNodeRef "planner"
        analyst = CircuitNodeRef "analyst"
        sink = CircuitNodeRef "sink"
        phantomNode = CircuitNodeRef "__star:gather:nested"
        rawConnection fromBoundary toBoundary =
          Connection
            { connectionFrom =
                EndpointRef
                  fromBoundary.admissionBoundaryNode
                  (Just fromBoundary.admissionBoundaryPort)
            , connectionTo =
                EndpointRef
                  toBoundary.admissionBoundaryNode
                  (Just toBoundary.admissionBoundaryPort)
            }
        malformedArtifact elementContract aggregateContract =
          let firstMulti = admissionTestBoundary planner "plan0" elementContract
              secondMulti = admissionTestBoundary analyst "plan1" elementContract
              phantomFirst = admissionTestBoundary phantomNode "item_0" elementContract
              phantomSecond = admissionTestBoundary phantomNode "item_1" elementContract
              singular = admissionTestBoundary sink "plans" aggregateContract
              phantomSingular = admissionTestBoundary phantomNode "plans" aggregateContract
           in emptyWireAdmissionArtifact
                { wireAdmissionNodes = [planner, analyst, sink, phantomNode]
                , wireAdmissionConnections =
                    [ rawConnection firstMulti phantomFirst
                    , rawConnection secondMulti phantomSecond
                    , rawConnection phantomSingular singular
                    ]
                , wireAdmissionPrimitiveSteps =
                    [ PrimitiveNode planner [] [firstMulti]
                    , PrimitiveNode analyst [] [secondMulti]
                    , PrimitiveNode phantomNode [phantomFirst, phantomSecond] [phantomSingular]
                    , PrimitiveConnect
                        [firstMulti, secondMulti]
                        [phantomFirst, phantomSecond]
                        [ AdmissionConnection firstMulti phantomFirst
                        , AdmissionConnection secondMulti phantomSecond
                        ]
                        []
                        []
                    , PrimitiveNode sink [singular] []
                    , PrimitiveConnect
                        [phantomSingular]
                        [singular]
                        [AdmissionConnection phantomSingular singular]
                        []
                        []
                    ]
                , wireAdmissionPhantomAdapters =
                    [ PhantomAdapterArtifact
                        { phantomAdapterDirection = PhantomGather
                        , phantomAdapterNode = phantomNode
                        , phantomAdapterProductShape = ProductIndexed elementContract 2
                        , phantomAdapterSingular = singular
                        , phantomAdapterMulti = [firstMulti, secondMulti]
                        , phantomAdapterLeftBulk =
                            [ AdmissionConnection firstMulti phantomFirst
                            , AdmissionConnection secondMulti phantomSecond
                            ]
                        , phantomAdapterRightBulk = [AdmissionConnection phantomSingular singular]
                        }
                    ]
                }
    minimalPhantomAdmissionArtifact `shouldSatisfy` wireAdmissionArtifactValidatorReady
    malformedArtifact "[PlannerOutput;1]" "[[PlannerOutput;1];2]"
      `shouldNotSatisfy` wireAdmissionArtifactValidatorReady
    malformedArtifact "[PlannerOutput" "[[PlannerOutput;2]"
      `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select component rows with duplicate condition nodes" $ do
    let validArtifact = minimalSelectAdmissionArtifact
        selectRows = validArtifact.wireAdmissionSelects
        malformedArtifact =
          validArtifact {wireAdmissionSelects = selectRows <> selectRows}
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects primitive nodes claimed by multiple component roles" $ do
    let planner = CircuitNodeRef "planner"
        sink = CircuitNodeRef "sink"
        sharedNode = CircuitNodeRef "workers_0"
        singular = admissionTestBoundary sink "plans" "[PlannerOutput; 1]"
        multi = admissionTestBoundary planner "plan" "PlannerOutput"
        phantomMulti = admissionTestBoundary sharedNode "item_0" "PlannerOutput"
        phantomSingular = admissionTestBoundary sharedNode "plans" "[PlannerOutput; 1]"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner, sink, sharedNode]
            , wireAdmissionEntries = [singular, phantomMulti]
            , wireAdmissionExits = [multi, phantomSingular]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode planner [] [multi]
                , PrimitiveNode sink [singular] []
                , PrimitiveNode sharedNode [phantomMulti] [phantomSingular]
                ]
            , wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "worker"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren =
                        [GeneratedChildSourceArtifact sharedNode "0" Nothing]
                    , generatedFormUsedChildren =
                        [GeneratedChildArtifact sharedNode "0" [phantomSingular] [phantomMulti]]
                    }
                ]
            , wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = sharedNode
                    , phantomAdapterProductShape = ProductIndexed "PlannerOutput" 1
                    , phantomAdapterSingular = singular
                    , phantomAdapterMulti = [multi]
                    , phantomAdapterLeftBulk = [AdmissionConnection multi phantomMulti]
                    , phantomAdapterRightBulk = [AdmissionConnection phantomSingular singular]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects admission artifacts with empty row identities" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef ""]
            , wireAdmissionBindingRefs = [""]
            , wireAdmissionEntries =
                [admissionTestBoundary (CircuitNodeRef "") "" ""]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects top-level summary boundaries outside the node summary" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "planner"]
            , wireAdmissionEntries =
                [admissionTestBoundary (CircuitNodeRef "external") "plan" "PlannerOutput"]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects boundary exclusive groups outside the node summary" $ do
    let malformedBoundary =
          plannerBoundary
            { admissionBoundaryExclusiveGroup =
                Just (CircuitNodeRef "external-selector", 0)
            }
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "planner"]
            , wireAdmissionExits = [malformedBoundary]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects boundary exclusive groups owned by another node" $ do
    let malformedBoundary =
          plannerBoundary
            { admissionBoundaryExclusiveGroup =
                Just (CircuitNodeRef "selector", 0)
            }
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "planner", CircuitNodeRef "selector"]
            , wireAdmissionExits = [malformedBoundary]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects top-level summary connections outside the node summary" $ do
    let malformedJson =
          wireAdmissionJsonWith
            [
              ( "wireAdmissionNodes"
              , Aeson.toJSON [CircuitNodeRef "planner"]
              )
            ,
              ( "wireAdmissionConnections"
              , Aeson.toJSON [simpleChainConnectionJson]
              )
            ]
    case Aeson.fromJSON malformedJson :: Aeson.Result WireAdmissionArtifact of
      Aeson.Success malformedArtifact ->
        malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady
      Aeson.Error message ->
        expectationFailure ("expected WireAdmissionArtifact JSON to decode: " <> message)

  it "rejects top-level raw connections not backed by primitive connect rows" $ do
    let malformedJson =
          wireAdmissionJsonWith
            [
              ( "wireAdmissionNodes"
              , Aeson.toJSON [CircuitNodeRef "planner", CircuitNodeRef "analyst"]
              )
            ,
              ( "wireAdmissionConnections"
              , Aeson.toJSON [simpleChainConnectionJson]
              )
            ]
    case Aeson.fromJSON malformedJson :: Aeson.Result WireAdmissionArtifact of
      Aeson.Success malformedArtifact ->
        malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady
      Aeson.Error message ->
        expectationFailure ("expected WireAdmissionArtifact JSON to decode: " <> message)

  it "rejects top-level node summaries not backed by primitive node rows" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "orphan"]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects top-level binding summaries not backed by primitive binding rows" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionBindingRefs = ["orphan"]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects primitive artifact rows outside the top-level summaries" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "planner"]
            , wireAdmissionPrimitiveSteps =
                [PrimitiveNode (CircuitNodeRef "external") [] []]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects top-level entries not backed by primitive node frontiers" $ do
    let planner =
          CircuitNodeRef "planner"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner]
            , wireAdmissionEntries = [plannerBoundary]
            , wireAdmissionPrimitiveSteps = [PrimitiveNode planner [] []]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects primitive residual frontiers omitted from the top-level summary" $ do
    let planner =
          CircuitNodeRef "planner"
        plannerInput =
          admissionTestBoundary planner "request" "PlannerInput"
        plannerOutput =
          admissionTestBoundary planner "plan" "PlannerOutput"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner]
            , wireAdmissionPrimitiveSteps =
                [PrimitiveNode planner [plannerInput] [plannerOutput]]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects top-level exits already consumed by primitive connect rows" $ do
    let planner =
          CircuitNodeRef "planner"
        analyst =
          CircuitNodeRef "analyst"
        plannerPlan =
          admissionTestBoundary planner "plan" "PlannerOutput"
        analystPlan =
          admissionTestBoundary analyst "plan" "PlannerOutput"
        consumed =
          AdmissionConnection
            { admissionConnectionFrom = plannerPlan
            , admissionConnectionTo = analystPlan
            }
        malformedJson =
          wireAdmissionJsonWith
            [
              ( "wireAdmissionNodes"
              , Aeson.toJSON [planner, analyst]
              )
            ,
              ( "wireAdmissionExits"
              , Aeson.toJSON [plannerPlan]
              )
            ,
              ( "wireAdmissionPrimitiveSteps"
              , Aeson.toJSON
                  [ PrimitiveNode planner [] [plannerPlan]
                  , PrimitiveNode analyst [analystPlan] []
                  , PrimitiveConnect [plannerPlan] [analystPlan] [consumed] [] []
                  ]
              )
            ,
              ( "wireAdmissionConnections"
              , Aeson.toJSON [simpleChainConnectionJson]
              )
            ]
    case Aeson.fromJSON malformedJson :: Aeson.Result WireAdmissionArtifact of
      Aeson.Success malformedArtifact ->
        malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady
      Aeson.Error message ->
        expectationFailure ("expected WireAdmissionArtifact JSON to decode: " <> message)

  it "rejects primitive overlay artifacts with overlapping ledgers" $ do
    let sharedNode =
          CircuitNodeRef "planner"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [sharedNode]
            , wireAdmissionBindingRefs = ["shared"]
            , wireAdmissionPrimitiveSteps =
                [PrimitiveOverlay [sharedNode] [sharedNode] ["shared"] ["shared"]]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects primitive overlay artifacts with duplicated side ledgers" $ do
    let duplicatedNode =
          CircuitNodeRef "planner"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [duplicatedNode]
            , wireAdmissionBindingRefs = ["shared"]
            , wireAdmissionPrimitiveSteps =
                [PrimitiveOverlay [duplicatedNode, duplicatedNode] [] ["shared", "shared"] []]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects primitive overlay ledgers introduced after the overlay row" $ do
    let planner =
          CircuitNodeRef "planner"
        analyst =
          CircuitNodeRef "analyst"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner, analyst]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveOverlay [planner] [analyst] [] []
                , PrimitiveNode planner [] []
                , PrimitiveNode analyst [] []
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects generated used children outside the node summary" $ do
    let generatedNode = CircuitNodeRef "workers_0"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "planner"]
            , wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "worker"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren =
                        [GeneratedChildSourceArtifact generatedNode "0" Nothing]
                    , generatedFormUsedChildren =
                        [GeneratedChildArtifact generatedNode "0" [] []]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts outside the node summary" $ do
    let phantomNode = CircuitNodeRef "__star:domain"
        sinkNode = CircuitNodeRef "sink"
        singular = admissionTestBoundary sinkNode "samples" "[Sample; 0]"
        phantomSingular = admissionTestBoundary phantomNode "samples" "[Sample; 0]"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [sinkNode]
            , wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = phantomNode
                    , phantomAdapterProductShape = ProductIndexed "Sample" 0
                    , phantomAdapterSingular = singular
                    , phantomAdapterMulti = []
                    , phantomAdapterLeftBulk = []
                    , phantomAdapterRightBulk =
                        [AdmissionConnection phantomSingular singular]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select variant artifacts outside the node summary" $ do
    let selectorNode = CircuitNodeRef "__select:choice"
        externalVariant =
          admissionTestLabeledBoundary
            (CircuitNodeRef "external")
            "ok"
            "Choice"
            "ok"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [selectorNode]
            , wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = selectorNode
                    , selectAdmissionConditionNode = selectorNode
                    , selectAdmissionVariants =
                        [SelectVariantArtifact "ok" externalVariant]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select variants not backed by primitive node exits" $ do
    let selectorNode =
          CircuitNodeRef "__select:choice"
        okVariant =
          admissionTestLabeledBoundary selectorNode "ok" "Choice" "ok"
        issueVariant =
          admissionTestLabeledBoundary selectorNode "issue" "Choice" "issue"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [selectorNode]
            , wireAdmissionPrimitiveSteps = [PrimitiveNode selectorNode [] []]
            , wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = selectorNode
                    , selectAdmissionConditionNode = selectorNode
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" okVariant
                        , SelectVariantArtifact "issue" issueVariant
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select condition nodes without primitive bridge frontiers" $ do
    let planner =
          CircuitNodeRef "planner"
        conditionNode =
          CircuitNodeRef "__select:choice"
        okPort =
          admissionTestLabeledBoundary planner "ok" "ResearchPlan" "ok"
        issuePort =
          admissionTestLabeledBoundary planner "issue" "PlanIssue" "issue"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner, conditionNode]
            , wireAdmissionExits = [okPort, issuePort]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode planner [] [okPort, issuePort]
                , PrimitiveNode conditionNode [] []
                ]
            , wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = conditionNode
                    , selectAdmissionConditionNode = conditionNode
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" okPort
                        , SelectVariantArtifact "issue" issuePort
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select condition nodes with duplicate compatible internal exits" $ do
    let planner =
          CircuitNodeRef "planner"
        conditionNode =
          CircuitNodeRef "__select:choice"
        okPort =
          admissionTestLabeledBoundary planner "ok" "ResearchPlan" "ok"
        issuePort =
          admissionTestLabeledBoundary planner "issue" "PlanIssue" "issue"
        okEntry =
          admissionTestLabeledBoundary conditionNode "ok_in" "ResearchPlan" "ok"
        issueEntry =
          admissionTestLabeledBoundary conditionNode "issue_in" "PlanIssue" "issue"
        okInternalA =
          (admissionTestLabeledBoundary conditionNode "ok_a" "ResearchPlan" "ok")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
            }
        okInternalB =
          (admissionTestLabeledBoundary conditionNode "ok_b" "ResearchPlan" "ok")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 1)
            }
        issueInternal =
          (admissionTestLabeledBoundary conditionNode "issue_a" "PlanIssue" "issue")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 2)
            }
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner, conditionNode]
            , wireAdmissionEntries = [okEntry, issueEntry]
            , wireAdmissionExits = [okPort, issuePort]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode planner [] [okPort, issuePort]
                , PrimitiveNode
                    conditionNode
                    [okEntry, issueEntry]
                    [okInternalA, okInternalB, issueInternal]
                ]
            , wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = conditionNode
                    , selectAdmissionConditionNode = conditionNode
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" okPort
                        , SelectVariantArtifact "issue" issuePort
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select bridge entries exposed in the final summary" $ do
    let planner =
          CircuitNodeRef "planner"
        conditionNode =
          CircuitNodeRef "__select:choice"
        okBody =
          CircuitNodeRef "__select:ok_body"
        issueBody =
          CircuitNodeRef "__select:issue_body"
        okPort =
          admissionTestLabeledBoundary planner "ok" "ResearchPlan" "ok"
        issuePort =
          admissionTestLabeledBoundary planner "issue" "PlanIssue" "issue"
        okEntry =
          admissionTestLabeledBoundary conditionNode "ok_in" "ResearchPlan" "ok"
        issueEntry =
          admissionTestLabeledBoundary conditionNode "issue_in" "PlanIssue" "issue"
        okInternal =
          (admissionTestLabeledBoundary conditionNode "ok_choice" "ResearchPlan" "ok")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
            }
        issueInternal =
          (admissionTestLabeledBoundary conditionNode "issue_choice" "PlanIssue" "issue")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 1)
            }
        bridgeExit =
          admissionTestLabeledBoundary conditionNode "result" "SelectedPlan" "result"
        okBodyEntry =
          admissionTestLabeledBoundary okBody "ok_in" "ResearchPlan" "ok"
        okBodyExit =
          admissionTestLabeledBoundary okBody "result" "SelectedPlan" "result"
        issueBodyEntry =
          admissionTestLabeledBoundary issueBody "issue_in" "PlanIssue" "issue"
        issueBodyExit =
          admissionTestLabeledBoundary issueBody "result" "SelectedPlan" "result"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner, conditionNode]
            , wireAdmissionEntries = [okEntry, issueEntry]
            , wireAdmissionExits = [okPort, issuePort, bridgeExit]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode planner [] [okPort, issuePort]
                , PrimitiveNode
                    conditionNode
                    [okEntry, issueEntry]
                    [okInternal, issueInternal, bridgeExit]
                , PrimitiveOverlay [planner] [conditionNode] [] []
                ]
            , wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = conditionNode
                    , selectAdmissionConditionNode = conditionNode
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" okPort
                        , SelectVariantArtifact "issue" issuePort
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = [okBody]
                            , selectArmBodyEntries = [okBodyEntry]
                            , selectArmBodyExits = [okBodyExit]
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = [issueBody]
                            , selectArmBodyEntries = [issueBodyEntry]
                            , selectArmBodyExits = [issueBodyExit]
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select bridge entries consumed by a non-variant source" $ do
    let planner =
          CircuitNodeRef "planner"
        decoy =
          CircuitNodeRef "decoy"
        conditionNode =
          CircuitNodeRef "__select:choice"
        okBody =
          CircuitNodeRef "__select:ok_body"
        issueBody =
          CircuitNodeRef "__select:issue_body"
        okPort =
          admissionTestLabeledBoundary planner "ok" "ResearchPlan" "ok"
        issuePort =
          admissionTestLabeledBoundary planner "issue" "PlanIssue" "issue"
        decoyOk =
          admissionTestLabeledBoundary decoy "ok" "ResearchPlan" "ok"
        decoyIssue =
          admissionTestLabeledBoundary decoy "issue" "PlanIssue" "issue"
        okEntry =
          admissionTestLabeledBoundary conditionNode "ok_in" "ResearchPlan" "ok"
        issueEntry =
          admissionTestLabeledBoundary conditionNode "issue_in" "PlanIssue" "issue"
        okInternal =
          (admissionTestLabeledBoundary conditionNode "ok_choice" "ResearchPlan" "ok")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
            }
        issueInternal =
          (admissionTestLabeledBoundary conditionNode "issue_choice" "PlanIssue" "issue")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 1)
            }
        bridgeExit =
          admissionTestLabeledBoundary conditionNode "result" "SelectedPlan" "result"
        okBodyEntry =
          admissionTestLabeledBoundary okBody "ok_in" "ResearchPlan" "ok"
        okBodyExit =
          admissionTestLabeledBoundary okBody "result" "SelectedPlan" "result"
        issueBodyEntry =
          admissionTestLabeledBoundary issueBody "issue_in" "PlanIssue" "issue"
        issueBodyExit =
          admissionTestLabeledBoundary issueBody "result" "SelectedPlan" "result"
        decoyOkPair =
          AdmissionConnection decoyOk okEntry
        decoyIssuePair =
          AdmissionConnection decoyIssue issueEntry
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [decoy, conditionNode, planner]
            , wireAdmissionExits = [bridgeExit, okPort, issuePort]
            , wireAdmissionConnections =
                [ Connection
                    { connectionFrom = EndpointRef decoy (Just "ok")
                    , connectionTo = EndpointRef conditionNode (Just "ok_in")
                    }
                , Connection
                    { connectionFrom = EndpointRef decoy (Just "issue")
                    , connectionTo = EndpointRef conditionNode (Just "issue_in")
                    }
                ]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode decoy [] [decoyOk, decoyIssue]
                , PrimitiveNode
                    conditionNode
                    [okEntry, issueEntry]
                    [okInternal, issueInternal, bridgeExit]
                , PrimitiveConnect
                    [decoyOk, decoyIssue]
                    [okEntry, issueEntry]
                    [decoyOkPair, decoyIssuePair]
                    []
                    []
                , PrimitiveNode planner [] [okPort, issuePort]
                , PrimitiveOverlay [decoy, conditionNode] [planner] [] []
                ]
            , wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = conditionNode
                    , selectAdmissionConditionNode = conditionNode
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" okPort
                        , SelectVariantArtifact "issue" issuePort
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = [okBody]
                            , selectArmBodyEntries = [okBodyEntry]
                            , selectArmBodyExits = [okBodyExit]
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = [issueBody]
                            , selectArmBodyEntries = [issueBodyEntry]
                            , selectArmBodyExits = [issueBodyExit]
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects primitive connect frontiers not backed by primitive node frontiers" $ do
    let pair =
          AdmissionConnection plannerBoundary analystBoundary
        malformedJson =
          wireAdmissionJsonWith
            [
              ( "wireAdmissionNodes"
              , Aeson.toJSON [CircuitNodeRef "planner", CircuitNodeRef "analyst"]
              )
            ,
              ( "wireAdmissionPrimitiveSteps"
              , Aeson.toJSON
                  [ PrimitiveNode (CircuitNodeRef "planner") [] []
                  , PrimitiveNode (CircuitNodeRef "analyst") [] []
                  , PrimitiveConnect [plannerBoundary] [analystBoundary] [pair] [] []
                  ]
              )
            ,
              ( "wireAdmissionConnections"
              , Aeson.toJSON [simpleChainConnectionJson]
              )
            ]
    case Aeson.fromJSON malformedJson :: Aeson.Result WireAdmissionArtifact of
      Aeson.Success malformedArtifact ->
        malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady
      Aeson.Error message ->
        expectationFailure ("expected WireAdmissionArtifact JSON to decode: " <> message)

  it "rejects primitive connect frontiers introduced after the connect row" $ do
    let pair =
          AdmissionConnection plannerBoundary analystBoundary
        malformedJson =
          wireAdmissionJsonWith
            [
              ( "wireAdmissionNodes"
              , Aeson.toJSON [CircuitNodeRef "planner", CircuitNodeRef "analyst"]
              )
            ,
              ( "wireAdmissionPrimitiveSteps"
              , Aeson.toJSON
                  [ PrimitiveConnect [plannerBoundary] [analystBoundary] [pair] [] []
                  , PrimitiveNode (CircuitNodeRef "planner") [] [plannerBoundary]
                  , PrimitiveNode (CircuitNodeRef "analyst") [analystBoundary] []
                  ]
              )
            ,
              ( "wireAdmissionConnections"
              , Aeson.toJSON [simpleChainConnectionJson]
              )
            ]
    case Aeson.fromJSON malformedJson :: Aeson.Result WireAdmissionArtifact of
      Aeson.Success malformedArtifact ->
        malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady
      Aeson.Error message ->
        expectationFailure ("expected WireAdmissionArtifact JSON to decode: " <> message)

  it "rejects primitive connect artifacts that omit operand frontiers" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "planner", CircuitNodeRef "analyst"]
            , wireAdmissionEntries = [analystBoundary]
            , wireAdmissionExits = [plannerBoundary]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode (CircuitNodeRef "planner") [] [plannerBoundary]
                , PrimitiveNode (CircuitNodeRef "analyst") [analystBoundary] []
                , PrimitiveConnect [] [] [] [] []
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects primitive artifacts whose postorder rows leave multiple frames" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "planner", CircuitNodeRef "analyst"]
            , wireAdmissionEntries = [analystBoundary]
            , wireAdmissionExits = [plannerBoundary]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode (CircuitNodeRef "planner") [] [plannerBoundary]
                , PrimitiveNode (CircuitNodeRef "analyst") [analystBoundary] []
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects primitive artifacts whose matched pair is outside the row frontier" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionPrimitiveSteps =
                [ PrimitiveConnect
                    [plannerBoundary]
                    []
                    [AdmissionConnection plannerBoundary analystBoundary]
                    []
                    []
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects primitive artifacts whose unmatched endpoints are outside the row frontier" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionPrimitiveSteps =
                [ PrimitiveConnect
                    [plannerBoundary]
                    [analystBoundary]
                    []
                    [sinkBoundary]
                    [plannerBoundary]
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects primitive artifacts whose matched pairs reuse endpoints" $ do
    let pair = AdmissionConnection plannerBoundary analystBoundary
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionPrimitiveSteps =
                [ PrimitiveConnect
                    [plannerBoundary]
                    [analystBoundary]
                    [pair, pair]
                    []
                    []
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects primitive artifacts whose matched pairs have incompatible boundaries" $ do
    let incompatibleAnalyst =
          admissionTestBoundary (CircuitNodeRef "analyst") "plan" "OtherOutput"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "planner", CircuitNodeRef "analyst"]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveConnect
                    [plannerBoundary]
                    [incompatibleAnalyst]
                    [AdmissionConnection plannerBoundary incompatibleAnalyst]
                    []
                    []
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects primitive artifacts that leave compatible endpoints unmatched" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "planner", CircuitNodeRef "analyst"]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveConnect
                    [plannerBoundary]
                    [analystBoundary]
                    []
                    [plannerBoundary]
                    [analystBoundary]
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects primitive artifacts whose matched and unmatched endpoints do not partition frontiers" $ do
    let pair = AdmissionConnection plannerBoundary analystBoundary
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionPrimitiveSteps =
                [ PrimitiveConnect
                    [plannerBoundary, sinkBoundary]
                    [analystBoundary]
                    [pair]
                    []
                    []
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects generated artifacts whose used child lacks source backing" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren =
                        [GeneratedChildSourceArtifact (CircuitNodeRef "workers_0") "0" Nothing]
                    , generatedFormUsedChildren =
                        [GeneratedChildArtifact (CircuitNodeRef "workers_1") "1" [] []]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects generated artifacts whose source child keys are duplicated" $ do
    let sourceChild = GeneratedChildSourceArtifact (CircuitNodeRef "workers_0") "0" Nothing
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren = [sourceChild, sourceChild]
                    , generatedFormUsedChildren =
                        [GeneratedChildArtifact (CircuitNodeRef "workers_0") "0" [] []]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects generated artifacts whose used child keys are duplicated" $ do
    let sourceChild = GeneratedChildSourceArtifact (CircuitNodeRef "workers_0") "0" Nothing
        usedChild = GeneratedChildArtifact (CircuitNodeRef "workers_0") "0" [] []
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren = [sourceChild]
                    , generatedFormUsedChildren = [usedChild, usedChild]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects generated artifacts whose child nodes do not follow the binding label policy" $ do
    let sourceChild = GeneratedChildSourceArtifact (CircuitNodeRef "other_0") "0" Nothing
        usedChild = GeneratedChildArtifact (CircuitNodeRef "other_0") "0" [] []
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "other_0"]
            , wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren = [sourceChild]
                    , generatedFormUsedChildren = [usedChild]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects generated artifacts whose used child frontier is not primitive-backed" $ do
    let childNode =
          CircuitNodeRef "workers_0"
        childOutput =
          admissionTestBoundary childNode "result" "Sample"
        sourceChild =
          GeneratedChildSourceArtifact childNode "0" Nothing
        usedChild =
          GeneratedChildArtifact childNode "0" [childOutput] []
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [childNode]
            , wireAdmissionPrimitiveSteps = [PrimitiveNode childNode [] []]
            , wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren = [sourceChild]
                    , generatedFormUsedChildren = [usedChild]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects generated artifacts whose used child omits primitive frontiers" $ do
    let childNode =
          CircuitNodeRef "workers_0"
        childOutput =
          admissionTestBoundary childNode "result" "Sample"
        sourceChild =
          GeneratedChildSourceArtifact childNode "0" Nothing
        usedChild =
          GeneratedChildArtifact childNode "0" [] []
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [childNode]
            , wireAdmissionExits = [childOutput]
            , wireAdmissionPrimitiveSteps = [PrimitiveNode childNode [] [childOutput]]
            , wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren = [sourceChild]
                    , generatedFormUsedChildren = [usedChild]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects make artifacts whose source labels are not count-derived" $ do
    let sourceChild = GeneratedChildSourceArtifact (CircuitNodeRef "workers_alpha") "alpha" Nothing
        usedChild = GeneratedChildArtifact (CircuitNodeRef "workers_alpha") "alpha" [] []
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "workers_alpha"]
            , wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren = [sourceChild]
                    , generatedFormUsedChildren = [usedChild]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects make artifacts whose source rows carry makeEach value payloads" $ do
    let sourceChild =
          GeneratedChildSourceArtifact
            (CircuitNodeRef "workers_0")
            "0"
            (Just (AdmissionStaticString "alpha"))
        usedChild = GeneratedChildArtifact (CircuitNodeRef "workers_0") "0" [] []
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "workers_0"]
            , wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren = [sourceChild]
                    , generatedFormUsedChildren = [usedChild]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects generated artifacts whose used child frontier rows are duplicated" $ do
    let sourceChild = GeneratedChildSourceArtifact (CircuitNodeRef "workers_0") "0" Nothing
        outputBoundary = admissionTestBoundary (CircuitNodeRef "workers_0") "out" "Sample"
        usedChild =
          GeneratedChildArtifact
            (CircuitNodeRef "workers_0")
            "0"
            [outputBoundary, outputBoundary]
            []
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren = [sourceChild]
                    , generatedFormUsedChildren = [usedChild]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects generated artifacts whose used child frontier belongs to another node" $ do
    let sourceChild = GeneratedChildSourceArtifact (CircuitNodeRef "workers_0") "0" Nothing
        outputBoundary = admissionTestBoundary (CircuitNodeRef "other_worker") "out" "Sample"
        usedChild =
          GeneratedChildArtifact
            (CircuitNodeRef "workers_0")
            "0"
            [outputBoundary]
            []
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMake
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren = [sourceChild]
                    , generatedFormUsedChildren = [usedChild]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects generated artifacts whose static record fields are duplicated" $ do
    let sourceChild =
          GeneratedChildSourceArtifact
            (CircuitNodeRef "workers_0")
            "0"
            ( Just
                ( AdmissionStaticRecord
                    [ AdmissionStaticField "priority" (AdmissionStaticNat 1)
                    , AdmissionStaticField "priority" (AdmissionStaticNat 2)
                    ]
                )
            )
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMakeEach
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren = [sourceChild]
                    , generatedFormUsedChildren =
                        [GeneratedChildArtifact (CircuitNodeRef "workers_0") "0" [] []]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects generated artifacts whose static record field labels are empty" $ do
    let sourceChild =
          GeneratedChildSourceArtifact
            (CircuitNodeRef "workers_0")
            "0"
            ( Just
                ( AdmissionStaticRecord
                    [AdmissionStaticField "" (AdmissionStaticNat 1)]
                )
            )
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionGeneratedForms =
                [ GeneratedFormArtifact
                    { generatedFormKind = GeneratedMakeEach
                    , generatedFormKindName = "sample"
                    , generatedFormBinding = "workers"
                    , generatedFormSourceChildren = [sourceChild]
                    , generatedFormUsedChildren =
                        [GeneratedChildArtifact (CircuitNodeRef "workers_0") "0" [] []]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts whose multi-side arity does not match" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = CircuitNodeRef "__star:gather:bad"
                    , phantomAdapterProductShape = ProductIndexed "Sample" 2
                    , phantomAdapterSingular = sinkBoundary
                    , phantomAdapterMulti = [plannerBoundary]
                    , phantomAdapterLeftBulk = []
                    , phantomAdapterRightBulk = []
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts with empty row identities" $ do
    let phantomNode = CircuitNodeRef ""
        singular = admissionTestBoundary (CircuitNodeRef "sink") "samples" "[Sample; 1]"
        phantomMulti = admissionTestBoundary phantomNode "item_0" "Sample"
        phantomSingular = admissionTestBoundary phantomNode "samples" "[Sample; 1]"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = phantomNode
                    , phantomAdapterProductShape = ProductIndexed "Sample" 1
                    , phantomAdapterSingular = singular
                    , phantomAdapterMulti = [plannerBoundary]
                    , phantomAdapterLeftBulk =
                        [AdmissionConnection plannerBoundary phantomMulti]
                    , phantomAdapterRightBulk =
                        [AdmissionConnection phantomSingular singular]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts whose record product fields are duplicated" $ do
    let phantomNode = CircuitNodeRef "__star:gather:record-duplicate"
        singular = admissionTestBoundary (CircuitNodeRef "sink") "samples" "Samples"
        phantomMulti0 = admissionTestBoundary phantomNode "sample_0" "Sample"
        phantomMulti1 = admissionTestBoundary phantomNode "sample_1" "Sample"
        phantomSingular = admissionTestBoundary phantomNode "samples" "Samples"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = phantomNode
                    , phantomAdapterProductShape =
                        ProductRecord "Samples" [("sample", "Sample"), ("sample", "Sample")]
                    , phantomAdapterSingular = singular
                    , phantomAdapterMulti = [plannerBoundary, analystBoundary]
                    , phantomAdapterLeftBulk =
                        [ AdmissionConnection plannerBoundary phantomMulti0
                        , AdmissionConnection analystBoundary phantomMulti1
                        ]
                    , phantomAdapterRightBulk =
                        [AdmissionConnection phantomSingular singular]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts whose source frontier is not primitive-backed" $ do
    let phantomNode =
          CircuitNodeRef "__star:gather:planner:sink"
        phantomMulti =
          admissionTestBoundary phantomNode "item_0" "PlannerOutput"
        phantomSingular =
          admissionTestBoundary phantomNode "samples" "[Sample; 2]"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes =
                [ CircuitNodeRef "planner"
                , CircuitNodeRef "sink"
                , phantomNode
                ]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode (CircuitNodeRef "planner") [] []
                , PrimitiveNode (CircuitNodeRef "sink") [sinkBoundary] []
                , PrimitiveNode phantomNode [phantomMulti] [phantomSingular]
                ]
            , wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = phantomNode
                    , phantomAdapterProductShape = ProductIndexed "PlannerOutput" 1
                    , phantomAdapterSingular = sinkBoundary
                    , phantomAdapterMulti = [plannerBoundary]
                    , phantomAdapterLeftBulk =
                        [AdmissionConnection plannerBoundary phantomMulti]
                    , phantomAdapterRightBulk =
                        [AdmissionConnection phantomSingular sinkBoundary]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts whose bridge frontier is not primitive-backed" $ do
    let planner =
          CircuitNodeRef "planner"
        sink =
          CircuitNodeRef "sink"
        phantomNode =
          CircuitNodeRef "__star:gather:planner:sink"
        phantomMulti =
          admissionTestBoundary phantomNode "item_0" "PlannerOutput"
        phantomSingular =
          admissionTestBoundary phantomNode "samples" "[Sample; 2]"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner, sink, phantomNode]
            , wireAdmissionEntries = [sinkBoundary]
            , wireAdmissionExits = [plannerBoundary]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode planner [] [plannerBoundary]
                , PrimitiveNode sink [sinkBoundary] []
                , PrimitiveNode phantomNode [] []
                ]
            , wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = phantomNode
                    , phantomAdapterProductShape = ProductIndexed "PlannerOutput" 1
                    , phantomAdapterSingular = sinkBoundary
                    , phantomAdapterMulti = [plannerBoundary]
                    , phantomAdapterLeftBulk =
                        [AdmissionConnection plannerBoundary phantomMulti]
                    , phantomAdapterRightBulk =
                        [AdmissionConnection phantomSingular sinkBoundary]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts whose primitive bridge frontier has extra endpoints" $ do
    let planner =
          CircuitNodeRef "planner"
        sink =
          CircuitNodeRef "sink"
        phantomNode =
          CircuitNodeRef "__star:gather:planner:sink"
        singular =
          admissionTestBoundary sink "plans" "[PlannerOutput; 1]"
        phantomMulti =
          admissionTestBoundary phantomNode "item_0" "PlannerOutput"
        phantomSingular =
          admissionTestBoundary phantomNode "plans" "[PlannerOutput; 1]"
        extraPhantomExit =
          admissionTestBoundary phantomNode "extra" "[PlannerOutput; 1]"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner, sink, phantomNode]
            , wireAdmissionEntries = [singular, phantomMulti]
            , wireAdmissionExits = [plannerBoundary, phantomSingular, extraPhantomExit]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode planner [] [plannerBoundary]
                , PrimitiveNode sink [singular] []
                , PrimitiveNode phantomNode [phantomMulti] [phantomSingular, extraPhantomExit]
                ]
            , wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = phantomNode
                    , phantomAdapterProductShape = ProductIndexed "PlannerOutput" 1
                    , phantomAdapterSingular = singular
                    , phantomAdapterMulti = [plannerBoundary]
                    , phantomAdapterLeftBulk =
                        [AdmissionConnection plannerBoundary phantomMulti]
                    , phantomAdapterRightBulk =
                        [AdmissionConnection phantomSingular singular]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter bulk rows absent from primitive replay" $ do
    let planner =
          CircuitNodeRef "planner"
        sink =
          CircuitNodeRef "sink"
        phantomNode =
          CircuitNodeRef "__star:gather:planner:sink"
        singular =
          admissionTestBoundary sink "plans" "[PlannerOutput; 1]"
        multi =
          admissionTestBoundary planner "plan" "PlannerOutput"
        phantomMulti =
          admissionTestBoundary phantomNode "item_0" "PlannerOutput"
        phantomSingular =
          admissionTestBoundary phantomNode "plans" "[PlannerOutput; 1]"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner, phantomNode, sink]
            , wireAdmissionEntries = [phantomMulti, singular]
            , wireAdmissionExits = [multi, phantomSingular]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode planner [] [multi]
                , PrimitiveNode phantomNode [phantomMulti] [phantomSingular]
                , PrimitiveOverlay [planner] [phantomNode] [] []
                , PrimitiveNode sink [singular] []
                , PrimitiveOverlay [planner, phantomNode] [sink] [] []
                ]
            , wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = phantomNode
                    , phantomAdapterProductShape = ProductIndexed "PlannerOutput" 1
                    , phantomAdapterSingular = singular
                    , phantomAdapterMulti = [multi]
                    , phantomAdapterLeftBulk =
                        [AdmissionConnection multi phantomMulti]
                    , phantomAdapterRightBulk =
                        [AdmissionConnection phantomSingular singular]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts whose record multi-side shape does not match" $ do
    let sourceLeft = CircuitNodeRef "source_left"
        sourceRight = CircuitNodeRef "source_right"
        sinkNode = CircuitNodeRef "sink"
        phantomNode = CircuitNodeRef "__star:record-shape"
        leftBoundary = admissionTestLabeledBoundary sourceLeft "left" "Left" "left"
        wrongBoundary = admissionTestLabeledBoundary sourceRight "wrong" "Right" "wrong"
        singular = admissionTestBoundary sinkNode "record" "Record"
        phantomLeft = admissionTestBoundary phantomNode "left" "Left"
        phantomRight = admissionTestBoundary phantomNode "right" "Right"
        phantomSingular = admissionTestBoundary phantomNode "record" "Record"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [sourceLeft, sourceRight, sinkNode, phantomNode]
            , wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = phantomNode
                    , phantomAdapterProductShape =
                        ProductRecord "Record" [("left", "Left"), ("right", "Right")]
                    , phantomAdapterSingular = singular
                    , phantomAdapterMulti = [leftBoundary, wrongBoundary]
                    , phantomAdapterLeftBulk =
                        [ AdmissionConnection leftBoundary phantomLeft
                        , AdmissionConnection wrongBoundary phantomRight
                        ]
                    , phantomAdapterRightBulk =
                        [AdmissionConnection phantomSingular singular]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts whose indexed multi-side contracts do not match" $ do
    let sourceLeft = CircuitNodeRef "source_left"
        sourceRight = CircuitNodeRef "source_right"
        sinkNode = CircuitNodeRef "sink"
        phantomNode = CircuitNodeRef "__star:indexed-shape"
        leftBoundary = admissionTestLabeledBoundary sourceLeft "left" "Other" "left"
        rightBoundary = admissionTestLabeledBoundary sourceRight "right" "Sample" "right"
        singular = admissionTestBoundary sinkNode "samples" "[Sample; 2]"
        phantomLeft = admissionTestBoundary phantomNode "left" "Sample"
        phantomRight = admissionTestBoundary phantomNode "right" "Sample"
        phantomSingular = admissionTestBoundary phantomNode "samples" "[Sample; 2]"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [sourceLeft, sourceRight, sinkNode, phantomNode]
            , wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = phantomNode
                    , phantomAdapterProductShape = ProductIndexed "Sample" 2
                    , phantomAdapterSingular = singular
                    , phantomAdapterMulti = [leftBoundary, rightBoundary]
                    , phantomAdapterLeftBulk =
                        [ AdmissionConnection leftBoundary phantomLeft
                        , AdmissionConnection rightBoundary phantomRight
                        ]
                    , phantomAdapterRightBulk =
                        [AdmissionConnection phantomSingular singular]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts whose bulk rows do not match direction" $ do
    let phantomNode = CircuitNodeRef "__star:gather:bad"
        singular = admissionTestBoundary (CircuitNodeRef "sink") "samples" "[Sample; 1]"
        phantomMulti = admissionTestBoundary phantomNode "item_0" "Sample"
        phantomSingular = admissionTestBoundary phantomNode "samples" "[Sample; 1]"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = phantomNode
                    , phantomAdapterProductShape = ProductIndexed "Sample" 1
                    , phantomAdapterSingular = singular
                    , phantomAdapterMulti = [plannerBoundary]
                    , phantomAdapterLeftBulk =
                        [AdmissionConnection analystBoundary phantomMulti]
                    , phantomAdapterRightBulk =
                        [AdmissionConnection phantomSingular singular]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts whose bulk rows connect incompatible boundaries" $ do
    let plannerSample = admissionTestBoundary (CircuitNodeRef "planner") "sample" "Sample"
        phantomNode = CircuitNodeRef "__star:gather:incompatible"
        singular = admissionTestBoundary (CircuitNodeRef "sink") "samples" "[Sample; 1]"
        phantomMulti = admissionTestBoundary phantomNode "item_0" "Other"
        phantomSingular = admissionTestBoundary phantomNode "samples" "[Sample; 1]"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [CircuitNodeRef "planner", CircuitNodeRef "sink", phantomNode]
            , wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = phantomNode
                    , phantomAdapterProductShape = ProductIndexed "Sample" 1
                    , phantomAdapterSingular = singular
                    , phantomAdapterMulti = [plannerSample]
                    , phantomAdapterLeftBulk =
                        [AdmissionConnection plannerSample phantomMulti]
                    , phantomAdapterRightBulk =
                        [AdmissionConnection phantomSingular singular]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts whose multi-side endpoints are duplicated" $ do
    let phantomNode = CircuitNodeRef "__star:gather:duplicate"
        singular = admissionTestBoundary (CircuitNodeRef "sink") "samples" "[Sample; 2]"
        phantomMulti = admissionTestBoundary phantomNode "item_0" "Sample"
        phantomSingular = admissionTestBoundary phantomNode "samples" "[Sample; 2]"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = phantomNode
                    , phantomAdapterProductShape = ProductIndexed "Sample" 2
                    , phantomAdapterSingular = singular
                    , phantomAdapterMulti = [plannerBoundary, plannerBoundary]
                    , phantomAdapterLeftBulk =
                        [ AdmissionConnection plannerBoundary phantomMulti
                        , AdmissionConnection plannerBoundary phantomMulti
                        ]
                    , phantomAdapterRightBulk =
                        [AdmissionConnection phantomSingular singular]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects phantom adapter artifacts whose bulk rows do not partition endpoints" $ do
    let phantomNode = CircuitNodeRef "__star:gather:partition"
        singular = admissionTestBoundary (CircuitNodeRef "sink") "samples" "[Sample; 2]"
        phantomMulti = admissionTestBoundary phantomNode "item_0" "Sample"
        phantomSingular = admissionTestBoundary phantomNode "samples" "[Sample; 2]"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionPhantomAdapters =
                [ PhantomAdapterArtifact
                    { phantomAdapterDirection = PhantomGather
                    , phantomAdapterNode = phantomNode
                    , phantomAdapterProductShape = ProductIndexed "Sample" 2
                    , phantomAdapterSingular = singular
                    , phantomAdapterMulti = [plannerBoundary, analystBoundary]
                    , phantomAdapterLeftBulk =
                        [AdmissionConnection plannerBoundary phantomMulti]
                    , phantomAdapterRightBulk =
                        [AdmissionConnection phantomSingular singular]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose arms do not cover variant keys" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = CircuitNodeRef "__select:choice"
                    , selectAdmissionConditionNode = CircuitNodeRef "__select:choice"
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" plannerBoundary
                        , SelectVariantArtifact "issue" analystBoundary
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose owner does not match the condition node" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = CircuitNodeRef "__select:owner"
                    , selectAdmissionConditionNode = CircuitNodeRef "__select:condition"
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" plannerBoundary
                        , SelectVariantArtifact "issue" analystBoundary
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts with fewer than two variants" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = CircuitNodeRef "__select:choice"
                    , selectAdmissionConditionNode = CircuitNodeRef "__select:choice"
                    , selectAdmissionVariants =
                        [SelectVariantArtifact "ok" plannerBoundary]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose variants are not one exclusive group" $ do
    case minimalSelectAdmissionArtifact.wireAdmissionSelects of
      [selectAdmission] -> do
        let clearGroup variant =
              variant
                { selectVariantPort =
                    variant.selectVariantPort
                      { admissionBoundaryExclusiveGroup = Nothing
                      }
                }
            malformedArtifact =
              minimalSelectAdmissionArtifact
                { wireAdmissionSelects =
                    [ selectAdmission
                        { selectAdmissionVariants =
                            fmap clearGroup selectAdmission.selectAdmissionVariants
                        }
                    ]
                }
        malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady
      other ->
        expectationFailure ("expected one select admission artifact, got: " <> show other)

  it "rejects select artifacts whose variant keys are duplicated" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = CircuitNodeRef "__select:choice"
                    , selectAdmissionConditionNode = CircuitNodeRef "__select:choice"
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" plannerBoundary
                        , SelectVariantArtifact "ok" analystBoundary
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose labeled variant key is not canonical" $ do
    let conditionNode = CircuitNodeRef "__select:choice"
        variantPort =
          admissionTestLabeledBoundary conditionNode "accepted" "Choice" "accepted"
        issuePort =
          admissionTestLabeledBoundary conditionNode "issue" "PlanIssue" "issue"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [conditionNode]
            , wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = conditionNode
                    , selectAdmissionConditionNode = conditionNode
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "wrong" variantPort
                        , SelectVariantArtifact "issue" issuePort
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "accepted"
                            , selectArmCanonicalKey = "wrong"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose contract-fallback variant key is not canonical" $ do
    let conditionNode = CircuitNodeRef "__select:contract-choice"
        variantPort = admissionTestBoundary conditionNode "research_plan" "ResearchPlan"
        issuePort =
          admissionTestLabeledBoundary conditionNode "issue" "PlanIssue" "issue"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [conditionNode]
            , wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = conditionNode
                    , selectAdmissionConditionNode = conditionNode
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "wrong" variantPort
                        , SelectVariantArtifact "issue" issuePort
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ResearchPlan"
                            , selectArmCanonicalKey = "wrong"
                            , selectArmResolutionMode = SelectResolvedByContract
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose source arm indexes are duplicated" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = CircuitNodeRef "__select:choice"
                    , selectAdmissionConditionNode = CircuitNodeRef "__select:choice"
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" plannerBoundary
                        , SelectVariantArtifact "issue" analystBoundary
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose source arm indexes skip source order" $ do
    let malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = CircuitNodeRef "__select:choice"
                    , selectAdmissionConditionNode = CircuitNodeRef "__select:choice"
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" plannerBoundary
                        , SelectVariantArtifact "issue" analystBoundary
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 2
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose label-mode arm was not label-resolved" $ do
    let selectorNode = CircuitNodeRef "__select:choice"
        validBoundary =
          admissionTestLabeledBoundary
            (CircuitNodeRef "selector")
            "valid"
            "ResearchPlan"
            "valid"
        issueBoundary =
          admissionTestLabeledBoundary
            (CircuitNodeRef "selector")
            "issue"
            "PlanIssue"
            "issue"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = selectorNode
                    , selectAdmissionConditionNode = selectorNode
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "valid" validBoundary
                        , SelectVariantArtifact "issue" issueBoundary
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ResearchPlan"
                            , selectArmCanonicalKey = "valid"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose contract fallback is ambiguous" $ do
    let selectorNode = CircuitNodeRef "__select:choice"
        validBoundary =
          admissionTestLabeledBoundary
            (CircuitNodeRef "selector")
            "valid"
            "ResearchPlan"
            "valid"
        acceptedBoundary =
          admissionTestLabeledBoundary
            (CircuitNodeRef "selector")
            "accepted"
            "ResearchPlan"
            "accepted"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = selectorNode
                    , selectAdmissionConditionNode = selectorNode
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "valid" validBoundary
                        , SelectVariantArtifact "accepted" acceptedBoundary
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ResearchPlan"
                            , selectArmCanonicalKey = "valid"
                            , selectArmResolutionMode = SelectResolvedByContract
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "accepted"
                            , selectArmCanonicalKey = "accepted"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose body nodes are duplicated" $ do
    let selectorNode = CircuitNodeRef "__select:choice"
        branchNode = CircuitNodeRef "branch"
        okBoundary =
          admissionTestLabeledBoundary
            (CircuitNodeRef "selector")
            "ok"
            "Choice"
            "ok"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = selectorNode
                    , selectAdmissionConditionNode = selectorNode
                    , selectAdmissionVariants =
                        [SelectVariantArtifact "ok" okBoundary]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = [branchNode, branchNode]
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose exclusive arms share body nodes" $ do
    let planner =
          CircuitNodeRef "planner"
        conditionNode =
          CircuitNodeRef "__select:choice"
        sharedBranch =
          CircuitNodeRef "shared_branch"
        okPort =
          admissionTestLabeledBoundary planner "ok" "ResearchPlan" "ok"
        issuePort =
          admissionTestLabeledBoundary planner "issue" "PlanIssue" "issue"
        okEntry =
          admissionTestLabeledBoundary conditionNode "ok_in" "ResearchPlan" "ok"
        issueEntry =
          admissionTestLabeledBoundary conditionNode "issue_in" "PlanIssue" "issue"
        okInternal =
          (admissionTestLabeledBoundary conditionNode "ok_out" "ResearchPlan" "ok")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
            }
        issueInternal =
          (admissionTestLabeledBoundary conditionNode "issue_out" "PlanIssue" "issue")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 1)
            }
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner, conditionNode, sharedBranch]
            , wireAdmissionEntries = [okEntry, issueEntry]
            , wireAdmissionExits = [okPort, issuePort]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode planner [] [okPort, issuePort]
                , PrimitiveNode conditionNode [okEntry, issueEntry] [okInternal, issueInternal]
                , PrimitiveNode sharedBranch [] []
                ]
            , wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = conditionNode
                    , selectAdmissionConditionNode = conditionNode
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" okPort
                        , SelectVariantArtifact "issue" issuePort
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = [sharedBranch]
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = [sharedBranch]
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose latent body node is already top-level" $ do
    let planner =
          CircuitNodeRef "planner"
        conditionNode =
          CircuitNodeRef "__select:choice"
        leakedBranch =
          CircuitNodeRef "leaked_branch"
        okPort =
          admissionTestLabeledBoundary planner "ok" "ResearchPlan" "ok"
        issuePort =
          admissionTestLabeledBoundary planner "issue" "PlanIssue" "issue"
        okEntry =
          admissionTestLabeledBoundary conditionNode "ok_in" "ResearchPlan" "ok"
        issueEntry =
          admissionTestLabeledBoundary conditionNode "issue_in" "PlanIssue" "issue"
        okInternal =
          (admissionTestLabeledBoundary conditionNode "ok_out" "ResearchPlan" "ok")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
            }
        issueInternal =
          (admissionTestLabeledBoundary conditionNode "issue_out" "PlanIssue" "issue")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 1)
            }
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner, conditionNode, leakedBranch]
            , wireAdmissionEntries = [okEntry, issueEntry]
            , wireAdmissionExits = [okPort, issuePort]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode planner [] [okPort, issuePort]
                , PrimitiveNode conditionNode [okEntry, issueEntry] [okInternal, issueInternal]
                , PrimitiveNode leakedBranch [] []
                ]
            , wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = conditionNode
                    , selectAdmissionConditionNode = conditionNode
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" okPort
                        , SelectVariantArtifact "issue" issuePort
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = [leakedBranch]
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose body boundary is outside the body nodes" $ do
    let selectorNode = CircuitNodeRef "__select:choice"
        branchNode = CircuitNodeRef "branch"
        externalBoundary = admissionTestBoundary (CircuitNodeRef "external") "in" "Choice"
        okBoundary =
          admissionTestLabeledBoundary
            (CircuitNodeRef "selector")
            "ok"
            "Choice"
            "ok"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = selectorNode
                    , selectAdmissionConditionNode = selectorNode
                    , selectAdmissionVariants =
                        [SelectVariantArtifact "ok" okBoundary]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = [branchNode]
                            , selectArmBodyEntries = [externalBoundary]
                            , selectArmBodyExits = []
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select body exclusive groups outside the body nodes" $ do
    let selectorNode = CircuitNodeRef "__select:choice"
        branchNode = CircuitNodeRef "branch"
        branchBoundary =
          (admissionTestBoundary branchNode "out" "Choice")
            { admissionBoundaryExclusiveGroup =
                Just (CircuitNodeRef "external-selector", 0)
            }
        okBoundary =
          admissionTestLabeledBoundary
            (CircuitNodeRef "selector")
            "ok"
            "Choice"
            "ok"
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = selectorNode
                    , selectAdmissionConditionNode = selectorNode
                    , selectAdmissionVariants =
                        [SelectVariantArtifact "ok" okBoundary]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = [branchNode]
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = [branchBoundary]
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "rejects select artifacts whose body entry does not consume its variant" $ do
    let planner =
          CircuitNodeRef "planner"
        conditionNode =
          CircuitNodeRef "__select:choice"
        branchNode =
          CircuitNodeRef "repair_branch"
        okPort =
          admissionTestLabeledBoundary planner "ok" "ResearchPlan" "ok"
        issuePort =
          admissionTestLabeledBoundary planner "issue" "PlanIssue" "issue"
        okEntry =
          admissionTestLabeledBoundary conditionNode "variant_in_1" "ResearchPlan" "ok"
        issueEntry =
          admissionTestLabeledBoundary conditionNode "variant_in_2" "PlanIssue" "issue"
        okInternal =
          (admissionTestLabeledBoundary conditionNode "variant_out_1" "ResearchPlan" "ok")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
            }
        issueInternal =
          (admissionTestLabeledBoundary conditionNode "variant_out_2" "PlanIssue" "issue")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
            }
        bridgeOut =
          admissionTestLabeledBoundary conditionNode "bridge_out_1" "ResearchPlan" "ok"
        wrongBodyEntry =
          admissionTestLabeledBoundary branchNode "wrong_in" "OtherContract" "issue"
        bodyOut =
          admissionTestLabeledBoundary branchNode "repaired" "ResearchPlan" "ok"
        conditionPrimitive =
          PrimitiveNode conditionNode [okEntry, issueEntry] [okInternal, issueInternal, bridgeOut]
        malformedArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner, conditionNode]
            , wireAdmissionEntries = [okEntry, issueEntry]
            , wireAdmissionExits = [okPort, issuePort, bridgeOut]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode planner [] [okPort, issuePort]
                , conditionPrimitive
                , PrimitiveOverlay [planner] [conditionNode] [] []
                ]
            , wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = conditionNode
                    , selectAdmissionConditionNode = conditionNode
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" okPort
                        , SelectVariantArtifact "issue" issuePort
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = []
                            , selectArmBodyEntries = []
                            , selectArmBodyExits = []
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = [branchNode]
                            , selectArmBodyEntries = [wrongBodyEntry]
                            , selectArmBodyExits = [bodyOut]
                            }
                        ]
                    }
                ]
            }
    malformedArtifact `shouldNotSatisfy` wireAdmissionArtifactValidatorReady

  it "accepts select artifacts whose body exits preserve exclusive bridge shapes" $ do
    let planner =
          CircuitNodeRef "planner"
        conditionNode =
          CircuitNodeRef "__select:choice"
        okBranch =
          CircuitNodeRef "ok_branch"
        issueBranch =
          CircuitNodeRef "issue_branch"
        okPort =
          (admissionTestLabeledBoundary planner "ok" "ResearchPlan" "ok")
            { admissionBoundaryExclusiveGroup = Just (planner, 0)
            }
        issuePort =
          (admissionTestLabeledBoundary planner "issue" "PlanIssue" "issue")
            { admissionBoundaryExclusiveGroup = Just (planner, 0)
            }
        okEntry =
          admissionTestLabeledBoundary conditionNode "variant_in_1" "ResearchPlan" "ok"
        issueEntry =
          admissionTestLabeledBoundary conditionNode "variant_in_2" "PlanIssue" "issue"
        okInternal =
          (admissionTestLabeledBoundary conditionNode "variant_out_1" "ResearchPlan" "ok")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
            }
        issueInternal =
          (admissionTestLabeledBoundary conditionNode "variant_out_2" "PlanIssue" "issue")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
            }
        approvedBridge =
          (admissionTestLabeledBoundary conditionNode "bridge_out_1" "Approved" "approved")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
            }
        blockedBridge =
          (admissionTestLabeledBoundary conditionNode "bridge_out_2" "Blocked" "blocked")
            { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
            }
        okBodyEntry =
          admissionTestLabeledBoundary okBranch "selected" "ResearchPlan" "ok"
        issueBodyEntry =
          admissionTestLabeledBoundary issueBranch "selected" "PlanIssue" "issue"
        okApproved =
          (admissionTestLabeledBoundary okBranch "approved" "Approved" "approved")
            { admissionBoundaryExclusiveGroup = Just (okBranch, 0)
            }
        okBlocked =
          (admissionTestLabeledBoundary okBranch "blocked" "Blocked" "blocked")
            { admissionBoundaryExclusiveGroup = Just (okBranch, 0)
            }
        issueApproved =
          (admissionTestLabeledBoundary issueBranch "approved" "Approved" "approved")
            { admissionBoundaryExclusiveGroup = Just (issueBranch, 0)
            }
        issueBlocked =
          (admissionTestLabeledBoundary issueBranch "blocked" "Blocked" "blocked")
            { admissionBoundaryExclusiveGroup = Just (issueBranch, 0)
            }
        conditionPrimitive =
          PrimitiveNode
            conditionNode
            [okEntry, issueEntry]
            [okInternal, issueInternal, approvedBridge, blockedBridge]
        okPair =
          AdmissionConnection okPort okEntry
        issuePair =
          AdmissionConnection issuePort issueEntry
        okRawConnection =
          Connection
            { connectionFrom = EndpointRef planner (Just "ok")
            , connectionTo = EndpointRef conditionNode (Just "variant_in_1")
            }
        issueRawConnection =
          Connection
            { connectionFrom = EndpointRef planner (Just "issue")
            , connectionTo = EndpointRef conditionNode (Just "variant_in_2")
            }
        validArtifact =
          emptyWireAdmissionArtifact
            { wireAdmissionNodes = [planner, conditionNode]
            , wireAdmissionEntries = []
            , wireAdmissionExits = [approvedBridge, blockedBridge]
            , wireAdmissionConnections = [okRawConnection, issueRawConnection]
            , wireAdmissionPrimitiveSteps =
                [ PrimitiveNode planner [] [okPort, issuePort]
                , conditionPrimitive
                , PrimitiveConnect
                    [okPort, issuePort]
                    [okEntry, issueEntry]
                    [okPair, issuePair]
                    []
                    []
                ]
            , wireAdmissionSelects =
                [ SelectAdmissionArtifact
                    { selectAdmissionOwner = conditionNode
                    , selectAdmissionConditionNode = conditionNode
                    , selectAdmissionVariants =
                        [ SelectVariantArtifact "ok" okPort
                        , SelectVariantArtifact "issue" issuePort
                        ]
                    , selectAdmissionArms =
                        [ SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 0
                            , selectArmSourceKey = "ok"
                            , selectArmCanonicalKey = "ok"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = [okBranch]
                            , selectArmBodyEntries = [okBodyEntry]
                            , selectArmBodyExits = [okApproved, okBlocked]
                            }
                        , SelectArmAdmissionArtifact
                            { selectArmSourceIndex = 1
                            , selectArmSourceKey = "issue"
                            , selectArmCanonicalKey = "issue"
                            , selectArmResolutionMode = SelectResolvedByLabel
                            , selectArmBodyNodes = [issueBranch]
                            , selectArmBodyEntries = [issueBodyEntry]
                            , selectArmBodyExits = [issueApproved, issueBlocked]
                            }
                        ]
                    }
                ]
            }
    validArtifact `shouldSatisfy` wireAdmissionArtifactValidatorReady

  it "compiles explicit overlay with independent entries and exits" $ do
    compiled <- requireRight (compileWireFragmentText overlayFragmentSourceText)
    Set.fromList compiled.compiledCircuitEntryNodes
      `shouldBe` Set.fromList [CircuitNodeRef "stress_alpha", CircuitNodeRef "stress_beta"]
    Set.fromList compiled.compiledCircuitExitNodes
      `shouldBe` Set.fromList [CircuitNodeRef "stress_alpha", CircuitNodeRef "stress_beta"]

  it "rejects repeated graph references in overlay" $
    compileWireFragmentText repeatedGraphReferenceSourceText
      `shouldSatisfy` isWireParseFailureContaining "cannot reuse graph node(s): source"

  it "rejects implicit output fan-out through connect" $
    compileWireFragmentText implicitFanOutSourceText
      `shouldSatisfy` isWireParseFailureContaining "would copy output endpoint"

  it "rejects implicit input fan-in through connect" $
    compileWireFragmentText implicitFanInSourceText
      `shouldSatisfy` isWireParseFailureContaining "would merge multiple output endpoints"

  it "expands make(N, K) into source-stable generated nodes" $ do
    compiled <- requireRight (compileWireFragmentText makeExpansionSourceText)
    Map.keysSet compiled.compiledCircuitNodes
      `shouldBe` Set.fromList
        [ CircuitNodeRef "workers_0"
        , CircuitNodeRef "workers_1"
        , CircuitNodeRef "workers_2"
        ]
    wireAdmissionArrayAny
      "wireAdmissionGeneratedForms"
      ( generatedFormMatches
          "GeneratedMake"
          "sample"
          "workers"
          [ (CircuitNodeRef "workers_0", "0", False)
          , (CircuitNodeRef "workers_1", "1", False)
          , (CircuitNodeRef "workers_2", "2", False)
          ]
          [ (CircuitNodeRef "workers_0", "0")
          , (CircuitNodeRef "workers_1", "1")
          , (CircuitNodeRef "workers_2", "2")
          ]
      )
      compiled
      `shouldBe` True
    wireAdmissionSchemaVersionFromJson compiled `shouldBe` Just wireAdmissionCurrentSchemaVersion
    expectWireAdmissionArtifact compiled $
      assertGeneratedFormArtifact
        ExpectedGeneratedForm
          { expectedGeneratedKind = GeneratedMake
          , expectedGeneratedKindName = "sample"
          , expectedGeneratedBinding = "workers"
          , expectedGeneratedSource =
              [ (CircuitNodeRef "workers_0", "0", False)
              , (CircuitNodeRef "workers_1", "1", False)
              , (CircuitNodeRef "workers_2", "2", False)
              ]
          , expectedGeneratedUsed =
              [ (CircuitNodeRef "workers_0", "0", ["workers_0"], [])
              , (CircuitNodeRef "workers_1", "1", ["workers_1"], [])
              , (CircuitNodeRef "workers_2", "2", ["workers_2"], [])
              ]
          }

  it "expands make(N, K) with a preceding static count binding" $ do
    compiled <- requireRight (compileWireFragmentText makeStaticCountSourceText)
    Map.keysSet compiled.compiledCircuitNodes
      `shouldBe` Set.fromList
        [ CircuitNodeRef "workers_0"
        , CircuitNodeRef "workers_1"
        ]

  it "records make(0, K) as an empty generated family inside topology" $ do
    compiled <- requireRight (compileWireFragmentText makeZeroSourceText)
    Map.keysSet compiled.compiledCircuitNodes `shouldBe` Set.singleton (CircuitNodeRef "sink")
    expectWireAdmissionArtifact compiled $
      assertGeneratedFormArtifact
        ExpectedGeneratedForm
          { expectedGeneratedKind = GeneratedMake
          , expectedGeneratedKindName = "sample"
          , expectedGeneratedBinding = "workers"
          , expectedGeneratedSource = []
          , expectedGeneratedUsed = []
          }

  it "expands form-local make(N, K) with a preceding static count binding" $ do
    compiled <- requireRight (compileWireFragmentText formLocalMakeStaticCountSourceText)
    Map.keysSet compiled.compiledCircuitNodes
      `shouldBe` Set.fromList
        [ CircuitNodeRef "batch/workers_0"
        , CircuitNodeRef "batch/workers_1"
        ]

  it "keeps trusted generated-family provenance for a projected make child" $ do
    compiled <- requireRight (compileWireFragmentText indexedMakeProjectionSourceText)
    Map.keysSet compiled.compiledCircuitNodes
      `shouldBe` Set.singleton (CircuitNodeRef "workers_1")
    wireAdmissionArray
      "wireAdmissionGeneratedForms"
      compiled
      `shouldSatisfy` maybe
        False
        ( (== 1)
            . length
            . filter
              ( generatedFormMatches
                  "GeneratedMake"
                  "sample"
                  "workers"
                  [ (CircuitNodeRef "workers_0", "0", False)
                  , (CircuitNodeRef "workers_1", "1", False)
                  ]
                  [(CircuitNodeRef "workers_1", "1")]
              )
        )
    expectWireAdmissionArtifact compiled $
      assertGeneratedFormArtifact
        ExpectedGeneratedForm
          { expectedGeneratedKind = GeneratedMake
          , expectedGeneratedKindName = "sample"
          , expectedGeneratedBinding = "workers"
          , expectedGeneratedSource =
              [ (CircuitNodeRef "workers_0", "0", False)
              , (CircuitNodeRef "workers_1", "1", False)
              ]
          , expectedGeneratedUsed =
              [(CircuitNodeRef "workers_1", "1", ["workers_1"], [])]
          }

  it "still rejects an entirely unused generated make family" $
    compileWireFragmentText unusedMakeFamilySourceText
      `shouldSatisfy` isWireUnusedNodeRef (CircuitNodeRef "workers_0")

  it "expands makeEach(items, K) into source-labeled generated nodes" $ do
    compiled <- requireRight (compileWireFragmentText makeEachSourceText)
    Map.keysSet compiled.compiledCircuitNodes
      `shouldBe` Set.fromList
        [ CircuitNodeRef "workers_alpha"
        , CircuitNodeRef "workers_beta"
        ]
    wireAdmissionArrayAny
      "wireAdmissionGeneratedForms"
      ( generatedFormMatches
          "GeneratedMakeEach"
          "sample"
          "workers"
          [ (CircuitNodeRef "workers_alpha", "alpha", False)
          , (CircuitNodeRef "workers_beta", "beta", False)
          ]
          [ (CircuitNodeRef "workers_alpha", "alpha")
          , (CircuitNodeRef "workers_beta", "beta")
          ]
      )
      compiled
      `shouldBe` True
    expectWireAdmissionArtifact compiled $
      assertGeneratedFormArtifact
        ExpectedGeneratedForm
          { expectedGeneratedKind = GeneratedMakeEach
          , expectedGeneratedKindName = "sample"
          , expectedGeneratedBinding = "workers"
          , expectedGeneratedSource =
              [ (CircuitNodeRef "workers_alpha", "alpha", False)
              , (CircuitNodeRef "workers_beta", "beta", False)
              ]
          , expectedGeneratedUsed =
              [ (CircuitNodeRef "workers_alpha", "alpha", ["workers_alpha"], [])
              , (CircuitNodeRef "workers_beta", "beta", ["workers_beta"], [])
              ]
          }

  it "records makeEach([], K) as an empty generated family inside topology" $ do
    compiled <- requireRight (compileWireFragmentText makeEachEmptySourceText)
    Map.keysSet compiled.compiledCircuitNodes `shouldBe` Set.singleton (CircuitNodeRef "sink")
    expectWireAdmissionArtifact compiled $
      assertGeneratedFormArtifact
        ExpectedGeneratedForm
          { expectedGeneratedKind = GeneratedMakeEach
          , expectedGeneratedKindName = "sample"
          , expectedGeneratedBinding = "workers"
          , expectedGeneratedSource = []
          , expectedGeneratedUsed = []
          }

  it "emits Lean-shaped makeEach Value payloads" $ do
    compiled <- requireRight (compileWireFragmentText makeEachValueSourceText)
    wireAdmissionArrayAny
      "wireAdmissionGeneratedForms"
      ( generatedFormSourceChildValueMatches
          (CircuitNodeRef "workers_alpha")
          (staticRecordFieldNat "priority" 7)
      )
      compiled
      `shouldBe` True
    wireAdmissionArrayAny
      "wireAdmissionGeneratedForms"
      ( generatedFormSourceChildValueMatches
          (CircuitNodeRef "workers_beta")
          (staticRecordFieldBool "enabled" False)
      )
      compiled
      `shouldBe` True

  it "rejects makeEach Value payloads outside the Lean static-value shape" $
    compileWireFragmentText makeEachFractionalValueSourceText
      `shouldSatisfy` isWireParseFailureContaining "must be a source static value"

  it "rejects makeEach Value payloads with duplicate static record fields" $
    compileWireFragmentText makeEachDuplicateFieldValueSourceText
      `shouldSatisfy` isWireParseFailureContaining "must be a source static value"

  it "lowers record-form * gather through an explicit phantom adapter" $ do
    compiled <- requireRight (compileWireTextWithEnv starContractEnv starGatherSourceText)
    let nodeRefs = Map.keysSet compiled.compiledCircuitNodes
        phantomRefs = Set.filter (("__star:gather:" `T.isPrefixOf`) . (.unCircuitNodeRef)) nodeRefs
    Set.size phantomRefs `shouldBe` 1
    let phantomRef = Set.findMin phantomRefs
    successors compiled.compiledCircuitTopology (CircuitNodeRef "a")
      `shouldBe` Set.singleton phantomRef
    successors compiled.compiledCircuitTopology (CircuitNodeRef "b")
      `shouldBe` Set.singleton phantomRef
    successors compiled.compiledCircuitTopology phantomRef
      `shouldBe` Set.singleton (CircuitNodeRef "sink")
    expectWireAdmissionArtifact compiled $
      assertRecordPhantomArtifact PhantomGather phantomRef

  it "lowers indexed make-family * gather through an explicit product adapter" $ do
    compiled <- requireRight (compileWireText indexedProductGatherSourceText)
    let nodeRefs = Map.keysSet compiled.compiledCircuitNodes
        phantomRefs = Set.filter (("__star:gather:" `T.isPrefixOf`) . (.unCircuitNodeRef)) nodeRefs
    Set.size phantomRefs `shouldBe` 1
    let phantomRef = Set.findMin phantomRefs
    wireAdmissionArrayAny
      "wireAdmissionPhantomAdapters"
      (phantomAdapterMatchesIndexedGather phantomRef 3)
      compiled
      `shouldBe` True
    expectWireAdmissionArtifact compiled $
      assertIndexedGatherPhantomArtifact phantomRef
    successors compiled.compiledCircuitTopology (CircuitNodeRef "workers_0")
      `shouldBe` Set.singleton phantomRef
    successors compiled.compiledCircuitTopology (CircuitNodeRef "workers_1")
      `shouldBe` Set.singleton phantomRef
    successors compiled.compiledCircuitTopology (CircuitNodeRef "workers_2")
      `shouldBe` Set.singleton phantomRef
    successors compiled.compiledCircuitTopology phantomRef
      `shouldBe` Set.singleton (CircuitNodeRef "sink")
    case Map.lookup phantomRef compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        taskNode.circuitTaskNodeMetadata
          `shouldSatisfy` metadataPureOutputEquals
            "samples"
            ( Syntax.CorePureList
                [ Syntax.CorePureIdent "workers_0"
                , Syntax.CorePureIdent "workers_1"
                , Syntax.CorePureIdent "workers_2"
                ]
            )
      other ->
        expectationFailure ("expected indexed gather phantom node, got: " <> show other)

  it "lowers singleton indexed make-family * gather through an explicit product adapter" $ do
    compiled <- requireRight (compileWireText singletonIndexedProductGatherSourceText)
    let nodeRefs = Map.keysSet compiled.compiledCircuitNodes
        phantomRefs = Set.filter (("__star:gather:" `T.isPrefixOf`) . (.unCircuitNodeRef)) nodeRefs
    Set.size phantomRefs `shouldBe` 1
    let phantomRef = Set.findMin phantomRefs
    successors compiled.compiledCircuitTopology (CircuitNodeRef "workers_0")
      `shouldBe` Set.singleton phantomRef
    successors compiled.compiledCircuitTopology phantomRef
      `shouldBe` Set.singleton (CircuitNodeRef "sink")
    case Map.lookup phantomRef compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        taskNode.circuitTaskNodeMetadata
          `shouldSatisfy` metadataPureOutputEquals
            "samples"
            (Syntax.CorePureList [Syntax.CorePureIdent "workers_0"])
      other ->
        expectationFailure ("expected singleton indexed gather phantom node, got: " <> show other)

  it "lowers record-form * scatter through an explicit phantom adapter" $ do
    compiled <- requireRight (compileWireTextWithEnv starContractEnv starScatterSourceText)
    let nodeRefs = Map.keysSet compiled.compiledCircuitNodes
        phantomRefs = Set.filter (("__star:scatter:" `T.isPrefixOf`) . (.unCircuitNodeRef)) nodeRefs
    Set.size phantomRefs `shouldBe` 1
    let phantomRef = Set.findMin phantomRefs
    successors compiled.compiledCircuitTopology (CircuitNodeRef "source")
      `shouldBe` Set.singleton phantomRef
    successors compiled.compiledCircuitTopology phantomRef
      `shouldBe` Set.fromList [CircuitNodeRef "a", CircuitNodeRef "b"]
    expectWireAdmissionArtifact compiled $
      assertRecordPhantomArtifact PhantomScatter phantomRef

  it "lowers indexed product * scatter into an indexed make family" $ do
    compiled <- requireRight (compileWireText indexedProductScatterSourceText)
    let nodeRefs = Map.keysSet compiled.compiledCircuitNodes
        phantomRefs = Set.filter (("__star:scatter:" `T.isPrefixOf`) . (.unCircuitNodeRef)) nodeRefs
    Set.size phantomRefs `shouldBe` 1
    let phantomRef = Set.findMin phantomRefs
    successors compiled.compiledCircuitTopology (CircuitNodeRef "source")
      `shouldBe` Set.singleton phantomRef
    successors compiled.compiledCircuitTopology phantomRef
      `shouldBe` Set.fromList
        [ CircuitNodeRef "workers_0"
        , CircuitNodeRef "workers_1"
        , CircuitNodeRef "workers_2"
        ]
    case Map.lookup phantomRef compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) -> do
        taskNode.circuitTaskNodeMetadata
          `shouldSatisfy` metadataPureOutputEquals "workers_0" (indexedPureExpr "samples" 0)
        taskNode.circuitTaskNodeMetadata
          `shouldSatisfy` metadataPureOutputEquals "workers_1" (indexedPureExpr "samples" 1)
        taskNode.circuitTaskNodeMetadata
          `shouldSatisfy` metadataPureOutputEquals "workers_2" (indexedPureExpr "samples" 2)
      other ->
        expectationFailure ("expected indexed scatter phantom node, got: " <> show other)

  it "lowers singleton indexed product * scatter through an explicit product adapter" $ do
    compiled <- requireRight (compileWireText singletonIndexedProductScatterSourceText)
    let nodeRefs = Map.keysSet compiled.compiledCircuitNodes
        phantomRefs = Set.filter (("__star:scatter:" `T.isPrefixOf`) . (.unCircuitNodeRef)) nodeRefs
    Set.size phantomRefs `shouldBe` 1
    let phantomRef = Set.findMin phantomRefs
    successors compiled.compiledCircuitTopology (CircuitNodeRef "source")
      `shouldBe` Set.singleton phantomRef
    successors compiled.compiledCircuitTopology phantomRef
      `shouldBe` Set.singleton (CircuitNodeRef "workers_0")
    case Map.lookup phantomRef compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        taskNode.circuitTaskNodeMetadata
          `shouldSatisfy` metadataPureOutputEquals "workers_0" (indexedPureExpr "samples" 0)
      other ->
        expectationFailure ("expected singleton indexed scatter phantom node, got: " <> show other)

  it "lowers empty record-form * scatter through a zero-output phantom adapter" $ do
    compiled <- requireRight (compileWireTextWithEnv starContractEnv starEmptyScatterSourceText)
    let nodeRefs = Map.keysSet compiled.compiledCircuitNodes
        phantomRefs = Set.filter (("__star:scatter:" `T.isPrefixOf`) . (.unCircuitNodeRef)) nodeRefs
    Set.size phantomRefs `shouldBe` 1
    let phantomRef = Set.findMin phantomRefs
    successors compiled.compiledCircuitTopology (CircuitNodeRef "source")
      `shouldBe` Set.singleton phantomRef
    successors compiled.compiledCircuitTopology phantomRef
      `shouldBe` Set.empty

  it "rejects flat singleton * and directs authors to =>" $
    compileWireTextWithEnv starContractEnv flatSingletonStarSourceText
      `shouldSatisfy` isWireParseFailureContaining "use `=>`"

  it "rejects indexed product * when arity does not match the generated frontier" $
    compileWireText indexedProductArityMismatchSourceText
      `shouldSatisfy` isWireParseFailureContaining "Expected [Sample; 3]"

  it "compiles a configured executor value applied in a node body" $ do
    compiled <- requireRight (compileWireText configuredExecutorSourceText)
    case Map.lookup (CircuitNodeRef "analyst") compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataConfigHasNumber "temperature" 0.2
      other ->
        expectationFailure ("expected task node, got: " <> show other)

  it "compiles node-body kind applications into ordinary nodes" $ do
    compiled <- requireRight (compileWireText kindApplicationSourceText)
    Map.keysSet compiled.compiledCircuitNodes `shouldBe` Set.singleton (CircuitNodeRef "screen_h")
    case Map.lookup (CircuitNodeRef "screen_h") compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataConfigHasNumber "angle" 1.25
      other ->
        expectationFailure ("expected task node, got: " <> show other)

  it "compiles graph forms with fresh scoped node identities" $ do
    compiled <- requireRight (compileWireText graphFormSourceText)
    Map.keysSet compiled.compiledCircuitNodes
      `shouldBe` Set.fromList [CircuitNodeRef "pipeline/first", CircuitNodeRef "pipeline/second"]
    successors compiled.compiledCircuitTopology (CircuitNodeRef "pipeline/first")
      `shouldBe` Set.singleton (CircuitNodeRef "pipeline/second")

  it "passes graph values into graph forms without cloning captured nodes" $ do
    compiled <- requireRight (compileWireText graphFormGraphParamSourceText)
    Map.keysSet compiled.compiledCircuitNodes
      `shouldBe` Set.fromList [CircuitNodeRef "source", CircuitNodeRef "pipeline/tail"]
    successors compiled.compiledCircuitTopology (CircuitNodeRef "source")
      `shouldBe` Set.singleton (CircuitNodeRef "pipeline/tail")

  it "evaluates top-level pure-data lets in executor config" $ do
    compiled <- requireRight (compileWireText topLevelLetConfigSourceText)
    case Map.lookup (CircuitNodeRef "analyst") compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasInstructions "Audit now"
      other ->
        expectationFailure ("expected task node, got: " <> show other)

  it "compiles graph-valued top-level let bindings" $ do
    compiled <- requireRight (compileWireText graphLetSourceText)
    compiled.compiledCircuitEntryNodes `shouldBe` [CircuitNodeRef "planner"]
    compiled.compiledCircuitExitNodes `shouldBe` [CircuitNodeRef "analyst"]
    successors compiled.compiledCircuitTopology (CircuitNodeRef "planner")
      `shouldBe` Set.singleton (CircuitNodeRef "analyst")

  it "allows exported graph libraries outside the default file return" $ do
    compiled <- requireRight (compileWireText exportedGraphLibrarySourceText)
    compiled.compiledCircuitEntryNodes `shouldBe` [CircuitNodeRef "main"]
    Map.keysSet compiled.compiledCircuitNodes `shouldBe` Set.singleton (CircuitNodeRef "main")

  it "compiles a selected graph-valued return" $ do
    compiled <- requireRight (compileWireTextWithReturn "library_graph" exportedGraphLibrarySourceText)
    compiled.compiledCircuitEntryNodes `shouldBe` [CircuitNodeRef "library"]
    Map.keysSet compiled.compiledCircuitNodes `shouldBe` Set.singleton (CircuitNodeRef "library")

  it "lowers executor where records into executor config" $ do
    compiled <- requireRight (compileWireText executorWhereSourceText)
    case Map.lookup (CircuitNodeRef "analyze") compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataConfigHasKey "where"
      other ->
        expectationFailure ("expected task node, got: " <> show other)

  it "compiles a zero-output executor body as a node with an empty output boundary" $ do
    compiled <- requireRight (compileWireText zeroOutputSourceText)
    case Map.lookup (CircuitNodeRef "log_event") compiled.compiledCircuitNodes of
      Just (CompiledCircuitTask taskNode) ->
        case taskNode.circuitTaskNodeMetadata of
          Aeson.Object obj ->
            case KeyMap.lookup "ports" obj of
              Just (Aeson.Object portsObj) ->
                KeyMap.lookup "outputs" portsObj `shouldBe` Just (Aeson.Array mempty)
              other -> expectationFailure ("unexpected ports metadata: " <> show other)
          other -> expectationFailure ("unexpected metadata: " <> show other)
      other -> expectationFailure ("expected task node, got: " <> show other)

  it "compiles select(...) over a labeled exclusive output boundary" $ do
    compiled <- requireRight (compileWireText selectSourceText)
    let conditionNodes =
          filter
            (\(_, node) -> case node of CompiledCircuitCondition {} -> True; _ -> False)
            (Map.toList compiled.compiledCircuitNodes)
    length conditionNodes `shouldBe` 1
    case conditionNodes of
      [(selectRef, CompiledCircuitCondition conditionNode)] -> do
        successors compiled.compiledCircuitTopology (CircuitNodeRef "validate_plan")
          `shouldBe` Set.singleton selectRef
        conditionNode.circuitConditionNodeElseFragment `shouldBe` Nothing
        wireAdmissionArrayAny
          "wireAdmissionSelects"
          (selectAdmissionMatchesLabelResolution selectRef (Set.fromList ["ok", "issue"]))
          compiled
          `shouldBe` True
        expectWireAdmissionArtifact compiled $
          assertLabeledSelectAdmissionArtifact selectRef
      other ->
        expectationFailure ("expected one condition node, got: " <> show other)

  it "emits select admission arms in source order after variant-order lowering" $ do
    compiled <- requireRight (compileWireText selectReorderedArmsSourceText)
    expectWireAdmissionArtifact compiled $ \artifact ->
      case artifact.wireAdmissionSelects of
        [selectArtifact] -> do
          fmap selectArmSourceIndex selectArtifact.selectAdmissionArms `shouldBe` [0, 1]
          fmap selectArmSourceKey selectArtifact.selectAdmissionArms `shouldBe` ["issue", "ok"]
          fmap selectArmCanonicalKey selectArtifact.selectAdmissionArms `shouldBe` ["issue", "ok"]
        other ->
          expectationFailure ("expected one select admission artifact, got: " <> show other)

  it "records select(...) contract fallback resolution" $ do
    compiled <- requireRight (compileWireText selectContractFallbackSourceText)
    let conditionRefs =
          [ ref
          | (ref, CompiledCircuitCondition {}) <- Map.toList compiled.compiledCircuitNodes
          ]
    case conditionRefs of
      [selectRef] ->
        wireAdmissionArrayAny
          "wireAdmissionSelects"
          (selectAdmissionMatchesResolutionMode selectRef "SelectResolvedByContract")
          compiled
          `shouldBe` True
      other ->
        expectationFailure ("expected one condition node, got: " <> show other)

  it "rejects ambiguous select(...) contract fallback resolution" $
    compileWireText selectAmbiguousContractFallbackSourceText
      `shouldSatisfy` isWireParseFailureContaining "is ambiguous"

  -- Lean correspondence: mirrors `selectActualize_lowers_to_appendAfter` and
  -- `selectActualize_unselected_not_in_selectedFragment` in
  -- `theory/Cortex/Wire/Select.lean`. Compilation places non-empty branch
  -- bodies inside the condition node's latent fragment; only the anchor
  -- condition node and the ambient pipeline are exposed in the outer node
  -- map. This pins the structural exclusion of unselected branches: a branch
  -- that was never selected has zero outer side effects on the compiled
  -- topology, mirroring the proof-side claim that unselected nodes do not
  -- appear in the constructed delta.
  it "keeps select(...) branch bodies confined to the condition fragment" $ do
    compiled <- requireRight (compileWireText selectSourceText)
    let outerNodeRefs = Map.keysSet compiled.compiledCircuitNodes
        ambientRefs =
          Set.fromList
            [ CircuitNodeRef "draft_plan"
            , CircuitNodeRef "validate_plan"
            , CircuitNodeRef "publish_report"
            ]
        conditionEntries =
          [ (ref, conditionNode)
          | (ref, CompiledCircuitCondition conditionNode) <-
              Map.toList compiled.compiledCircuitNodes
          ]
    case conditionEntries of
      [(selectRef, conditionNode)] -> do
        -- Only the ambient stages and the latent select anchor surface in
        -- the outer node map. The branch bodies (`gather_missing_constraints`,
        -- `repair_plan`) must never appear at this level; they live
        -- exclusively inside the latent condition fragment.
        outerNodeRefs `shouldBe` Set.insert selectRef ambientRefs
        outerNodeRefs `shouldSatisfy` Set.notMember (CircuitNodeRef "gather_missing_constraints")
        outerNodeRefs `shouldSatisfy` Set.notMember (CircuitNodeRef "repair_plan")
        let thenFragment = conditionNode.circuitConditionNodeThenFragment
            thenNodeRefs = Map.keysSet thenFragment.compiledCircuitFragmentNodes
        -- The non-empty branch ("issue") lowers its body into the latent
        -- "then" fragment; those node refs are the unselected-branch nodes
        -- whose materialization is gated on a runtime branch decision.
        thenNodeRefs
          `shouldBe` Set.fromList
            [ CircuitNodeRef "gather_missing_constraints"
            , CircuitNodeRef "repair_plan"
            ]
        -- And those branch nodes must not overlap the ambient pipeline,
        -- so unselected-arm execution is structurally excluded from the
        -- ambient run.
        Set.intersection thenNodeRefs ambientRefs `shouldBe` Set.empty
        -- The empty "ok" branch is encoded as `Nothing` in this fixture;
        -- if a future representation materializes it explicitly, the inner
        -- nodes must still stay outside the ambient pipeline.
        case conditionNode.circuitConditionNodeElseFragment of
          Nothing -> pure ()
          Just elseFragment ->
            Set.intersection
              (Map.keysSet elseFragment.compiledCircuitFragmentNodes)
              ambientRefs
              `shouldBe` Set.empty
      other ->
        expectationFailure ("expected one condition node, got: " <> show other)

  describe "contract declarations" $ do
    it "accepts registered contracts under an explicit registry" $
      compileWireTextWithEnv knownContractsEnv simpleChainSourceText
        `shouldSatisfy` isRight

    it "accepts file-local contract declarations under an explicit registry" $
      compileWireTextWithEnv
        knownContractsEnv
        ( T.unlines
            [ "contract LocalOnly;"
            , "node local"
            , "  -> out: LocalOnly = @review.local ({}) ;"
            , "local"
            ]
        )
        `shouldSatisfy` isRight

    it "rejects undeclared contract typos under an explicit registry" $
      compileWireTextWithEnv knownContractsEnv typoContractSourceText
        `shouldBe` Left (WireUnknownContract "node ports" "PlannerOuput")

  describe "executor projections" $ do
    it "allows a strict registered executor projection with matching ports" $
      compileWireTextWithEnv strictExecutorEnv projectedExecutorSourceText
        `shouldSatisfy` isRight

    it "rejects a missing executor in strict projection mode" $
      compileWireTextWithEnv strictExecutorEnv missingExecutorSourceText
        `shouldBe` Left (WireUnknownExecutor (CircuitNodeRef "missing") "review.missing")

    it "rejects mismatched ports in strict projection mode" $
      compileWireTextWithEnv strictExecutorEnv mismatchedExecutorPortsSourceText
        `shouldBe` Left (WireExecutorPortsMismatch (CircuitNodeRef "projected") "review.projected")

    it "allows author-declared ports for the pure executor in strict projection mode" $
      compileWireTextWithEnv strictExecutorEnv pureExecutorSourceText
        `shouldSatisfy` isRight

    it "lowers top-level CorePure helpers into pure node config" $ do
      compiled <-
        requireRight (compileWireTextWithEnv strictExecutorEnv pureExecutorWithSharedHelperSourceText)
      case Map.lookup (CircuitNodeRef "classify") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) ->
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasPureBinding "acceptedItem"
        other ->
          expectationFailure ("expected compiled pure task node, got: " <> show other)

    it "captures top-level pure-data lets into pure node config" $ do
      compiled <-
        requireRight (compileWireTextWithEnv strictExecutorEnv pureExecutorWithScalarLetSourceText)
      case Map.lookup (CircuitNodeRef "classify") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) ->
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasPureBinding "scoreThreshold"
        other ->
          expectationFailure ("expected compiled pure task node, got: " <> show other)

    it "lowers node-local where records and port-keyed output equations" $ do
      compiled <-
        requireRight (compileWireTextWithEnv strictExecutorEnv pureExecutorWithLocalBindingsSourceText)
      case Map.lookup (CircuitNodeRef "classify") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) -> do
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasPureBinding "acceptedItem"
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasPureWhere
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasPureOutput "accepted"
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasPureOutput "rejected"
        other ->
          expectationFailure ("expected compiled pure task node, got: " <> show other)

    it "accepts let-bound where records with statically known fields" $
      compileWireTextWithEnv strictExecutorEnv pureExecutorWithLetBoundWhereSourceText
        `shouldSatisfy` isRight

    it "rejects node-local where lets that shadow statically known records" $
      compileWireTextWithEnv strictExecutorEnv whereLocalLetShadowsStaticSourceText
        `shouldBe` Left
          ( WireInvalidPorts
              (CircuitNodeRef "classify")
              "where-clause local let binding shadows static binding defaults"
          )

    it "rejects where fields that collide with input ports" $
      compileWireTextWithEnv strictExecutorEnv whereInputCollisionSourceText
        `shouldBe` Left (WireInvalidPorts (CircuitNodeRef "classify") "where field collides with input port evidence")

    it "rejects where field sets that are not statically determinable" $
      compileWireTextWithEnv strictExecutorEnv whereDynamicShapeSourceText
        `shouldBe` Left
          (WireInvalidPorts (CircuitNodeRef "classify") "where-clause field set is not statically determinable")

    it "rejects duplicate CorePure record paths during compiler lowering" $
      compileWireTextWithEnv strictExecutorEnv pureExecutorDuplicateRecordPathSourceText
        `shouldBe` Left
          ( WireInvalidPorts
              (CircuitNodeRef "score")
              "Pure record literal declares conflicting field paths a and a."
          )

    it "rejects prefix-conflicting CorePure record paths during compiler lowering" $
      compileWireTextWithEnv strictExecutorEnv pureExecutorPrefixRecordPathSourceText
        `shouldBe` Left
          ( WireInvalidPorts
              (CircuitNodeRef "score")
              "Pure record literal declares conflicting field paths a.b and a."
          )

    it "rejects duplicate names across CorePure helpers and ordinary value lets" $
      compileWireTextWithEnv strictExecutorEnv duplicatePureAndWireLetSourceText
        `shouldBe` Left (WireDuplicateLetBinding "acceptedItem")

    it "rejects authored @pure executor applications" $
      compileWireTextWithEnv strictExecutorEnv legacyPureExecutorSourceText
        `shouldSatisfy` isParseFailure

    it "rejects configured executor values inside CorePure output equations" $
      compileWireText configuredExecutorInPureOutputSourceText
        `shouldSatisfy` isCorePureScopeViolationOf "configured executor analyst_base"

    it "rejects graph values inside CorePure output equations" $
      compileWireText graphBindingInPureOutputSourceText
        `shouldSatisfy` isCorePureScopeViolationOf "graph value workers"

    it "rejects node values inside CorePure output equations" $
      compileWireText nodeBindingInPureOutputSourceText
        `shouldSatisfy` isCorePureScopeViolationOf "node value worker"

    it "rejects imported executors inside CorePure output equations" $
      compileWireText importedExecutorInPureOutputSourceText
        `shouldSatisfy` isCorePureScopeViolationOf "imported executor command"

    it "rejects contracts inside CorePure output equations" $
      compileWireText contractInPureOutputSourceText
        `shouldSatisfy` isCorePureScopeViolationOf "contract AcceptedSet"

    it "rejects non-CorePure captures inside top-level CorePure lets" $
      compileWireText graphBindingInTopLevelCorePureLetSourceText
        `shouldSatisfy` isCorePureScopeViolationOf "graph value workers"

  describe "namespace use imports" $ do
    it "lowers std.io aliases to canonical executor and contract IDs" $ do
      compiled <- requireRight (compileWireText stdIoAliasSourceText)
      case Map.lookup (CircuitNodeRef "run") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) -> do
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasExecutorTarget "std.io.command"
          taskNode.circuitTaskNodeMetadata
            `shouldSatisfy` metadataHasInputContract "spec" "std.io.CommandSpec.v1"
          taskNode.circuitTaskNodeMetadata
            `shouldSatisfy` metadataHasOutputContract "result" "std.io.CommandResult.v1"
        other ->
          expectationFailure ("expected task node, got: " <> show other)

    it "allows canonical std.io executor references after use" $
      compileWireText stdIoCanonicalAfterUseSourceText
        `shouldSatisfy` isRight

    it "rejects bare std.io executor leaves without use" $
      compileWireText stdIoBareWithoutUseSourceText
        `shouldBe` Left (WireExecutorNotInScope "@command")

    it "rejects canonical std.io executor references without use" $
      compileWireText stdIoCanonicalWithoutUseSourceText
        `shouldBe` Left (WireExecutorNotInScope "@std.io.command")

    it "rejects use names that collide with local contracts" $
      compileWireText stdIoUseContractCollisionSourceText
        `shouldBe` Left (WireDuplicateBinding "CommandSpec")

    it "enforces standard stdout port shape" $
      compileWireText stdIoStdoutBadShapeSourceText
        `shouldBe` Left
          ( WireInvalidPorts
              (CircuitNodeRef "bad_stdout")
              stdIoStdoutShapeMessage
          )

    it "lowers std.io file executors" $ do
      compiled <- requireRight (compileWireText stdIoFileExecutorsSourceText)
      case Map.lookup (CircuitNodeRef "read_report") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) ->
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasExecutorTarget "std.io.readFile"
        other ->
          expectationFailure ("expected read_report task node, got: " <> show other)
      case Map.lookup (CircuitNodeRef "write_report") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) ->
          taskNode.circuitTaskNodeMetadata `shouldSatisfy` metadataHasExecutorTarget "std.io.writeFile"
        other ->
          expectationFailure ("expected write_report task node, got: " <> show other)

    it "enforces standard readFile port shape" $
      compileWireText stdIoReadFileBadShapeSourceText
        `shouldBe` Left
          ( WireInvalidPorts
              (CircuitNodeRef "bad_read")
              stdIoReadFileShapeMessage
          )

    it "enforces standard writeFile port shape" $
      compileWireText stdIoWriteFileBadShapeSourceText
        `shouldBe` Left
          ( WireInvalidPorts
              (CircuitNodeRef "bad_write")
              stdIoWriteFileShapeMessage
          )

  describe "fixtures" $ do
    it "compiles the interactive priority planner example" $ do
      source <- TIO.readFile "examples/wire/interactive-priority-planner.wire"
      compileWireText source `shouldSatisfy` isRight

    it "compiles the mini build-system example" $ do
      source <- TIO.readFile "examples/wire/mini-build-system.wire"
      compileWireText source `shouldSatisfy` isRight

    it "compiles the bounded shard analysis example" $ do
      source <- TIO.readFile "examples/wire/bounded-shard-analysis.wire"
      compiled <- requireRight (compileWireText source)
      Set.fromList compiled.compiledCircuitEntryNodes
        `shouldBe` Set.singleton (CircuitNodeRef "slice_corpus")
      Set.fromList compiled.compiledCircuitExitNodes
        `shouldBe` Set.singleton (CircuitNodeRef "reduce_findings")
      let nodeRefs = Map.keysSet compiled.compiledCircuitNodes
          scatterPhantoms = Set.filter (("__star:scatter:" `T.isPrefixOf`) . (.unCircuitNodeRef)) nodeRefs
          gatherPhantoms = Set.filter (("__star:gather:" `T.isPrefixOf`) . (.unCircuitNodeRef)) nodeRefs
      Set.size scatterPhantoms `shouldBe` 1
      Set.size gatherPhantoms `shouldBe` 1
      successors compiled.compiledCircuitTopology (Set.findMin scatterPhantoms)
        `shouldBe` Set.fromList
          [ CircuitNodeRef "workers_0"
          , CircuitNodeRef "workers_1"
          , CircuitNodeRef "workers_2"
          , CircuitNodeRef "workers_3"
          ]
      successors compiled.compiledCircuitTopology (Set.findMin gatherPhantoms)
        `shouldBe` Set.singleton (CircuitNodeRef "reduce_findings")

    it "compiles the C build example" $ do
      source <- TIO.readFile "examples/wire/c-build/c-build.wire"
      expanded <- requireRight =<< expandWireSourceIncludes "examples/wire/c-build/c-build.wire" source
      compileWireText expanded `shouldSatisfy` isRight

    it "compiles the quantum Bell-state example with consumer executor projections" $ do
      source <- TIO.readFile "examples/wire/quantum-bell-state.wire"
      compiled <- requireRight (compileWireTextWithEnv quantumExecutorEnv source)
      Set.fromList compiled.compiledCircuitEntryNodes
        `shouldBe` Set.fromList [CircuitNodeRef "prepare_control", CircuitNodeRef "prepare_target"]
      Set.fromList compiled.compiledCircuitExitNodes
        `shouldBe` Set.fromList [CircuitNodeRef "measure_control", CircuitNodeRef "measure_target"]
      successors compiled.compiledCircuitTopology (CircuitNodeRef "entangle")
        `shouldBe` Set.fromList [CircuitNodeRef "measure_control", CircuitNodeRef "measure_target"]

    it "compiles the IBM REST quantum Bell-state example with a config node" $ do
      source <- TIO.readFile "examples/wire/quantum-bell-state-ibm-rest.wire"
      compiled <- requireRight (compileWireTextWithEnv quantumExecutorEnv source)
      Set.fromList compiled.compiledCircuitEntryNodes
        `shouldBe` Set.fromList
          [ CircuitNodeRef "ibm_runtime_config"
          , CircuitNodeRef "prepare_target"
          ]
      case Map.lookup (CircuitNodeRef "ibm_runtime_config") compiled.compiledCircuitNodes of
        Just (CompiledCircuitTask taskNode) ->
          taskNode.circuitTaskNodeMetadata
            `shouldSatisfy` metadataConfigHasString
              "path"
              "quantum-ibm-runtime.local.json"
        other ->
          expectationFailure ("expected task node, got: " <> show other)

    it "compiles the quantum IPEA round example with primitive executors" $ do
      source <- TIO.readFile "examples/wire/quantum-ipea-round.wire"
      compiled <- requireRight (compileWireTextWithEnv quantumExecutorEnv source)
      Set.fromList compiled.compiledCircuitEntryNodes
        `shouldBe` Set.fromList
          [ CircuitNodeRef "ibm_runtime_config"
          , CircuitNodeRef "prepare_target"
          ]
      Set.fromList compiled.compiledCircuitExitNodes
        `shouldBe` Set.fromList [CircuitNodeRef "measure_phase"]
      successors compiled.compiledCircuitTopology (CircuitNodeRef "phase_rzz")
        `shouldBe` Set.fromList [CircuitNodeRef "feedback_control_rz"]

    it "compiles the quantum eraser round example with primitive executors" $ do
      source <- TIO.readFile "examples/wire/quantum-eraser-round.wire"
      compiled <- requireRight (compileWireTextWithEnv quantumExecutorEnv source)
      Set.fromList compiled.compiledCircuitEntryNodes
        `shouldBe` Set.fromList
          [ CircuitNodeRef "ibm_runtime_config"
          , CircuitNodeRef "prepare_marker"
          ]
      Set.fromList compiled.compiledCircuitExitNodes
        `shouldBe` Set.fromList [CircuitNodeRef "measure_screen", CircuitNodeRef "z_measure_marker"]
      successors compiled.compiledCircuitTopology (CircuitNodeRef "mark_cz")
        `shouldBe` Set.fromList
          [ CircuitNodeRef "recombine_rz_a"
          , CircuitNodeRef "z_mark_post_rz_a"
          ]

    it "compiles the full quantum eraser experiment scaffold" $ do
      source <- TIO.readFile "examples/wire/quantum-eraser-experiment.wire"
      compiled <- requireRight (compileWireText source)
      Set.fromList compiled.compiledCircuitEntryNodes
        `shouldBe` Set.fromList [CircuitNodeRef "start_experiment"]
      Set.fromList compiled.compiledCircuitExitNodes
        `shouldBe` Set.fromList [CircuitNodeRef "print_report", CircuitNodeRef "write_report"]
      let phantomRefs =
            Set.filter
              (("__star:gather:" `T.isPrefixOf`) . (.unCircuitNodeRef))
              (Map.keysSet compiled.compiledCircuitNodes)
      Set.size phantomRefs `shouldBe` 1
      let resultsPhantom = Set.findMin phantomRefs
      successors compiled.compiledCircuitTopology (CircuitNodeRef "run_open_0/run")
        `shouldBe` Set.singleton (CircuitNodeRef "run_open_14/gate")
      successors compiled.compiledCircuitTopology (CircuitNodeRef "run_open_14/gate")
        `shouldBe` Set.fromList [resultsPhantom, CircuitNodeRef "run_open_14/run"]
      successors compiled.compiledCircuitTopology resultsPhantom
        `shouldBe` Set.singleton (CircuitNodeRef "analyze_experiment")
      successors compiled.compiledCircuitTopology (CircuitNodeRef "render_experiment_report")
        `shouldBe` Set.fromList [CircuitNodeRef "print_report", CircuitNodeRef "write_report"]

    it "compiles the quantum eraser sweep circuit examples with primitive executors" $
      mapM_ compileQuantumEraserFixture quantumEraserSweepFixtures

    it "compiles the pure output equations fixture" $ do
      source <- TIO.readFile "test/fixtures/wire/pure-output-equations.wire"
      compileWireText source `shouldSatisfy` isRight

    it "compiles the thesis parallel claim branches fixture" $ do
      source <- TIO.readFile "test/fixtures/wire/thesis-parallel-claim-branches.wire"
      compileWireText source `shouldSatisfy` isRight

simpleChainSourceText :: T.Text
simpleChainSourceText =
  T.unlines
    [ "node planner"
    , "  -> plan: PlannerOutput = @review.planner ({}) ;"
    , "node analyst"
    , "  <- plan: PlannerOutput ;"
    , "  -> analysis: AnalysisFragment = @review.analyst (plan) ;"
    , "planner => analyst"
    ]

overlayFragmentSourceText :: T.Text
overlayFragmentSourceText =
  T.unlines
    [ "node stress_alpha"
    , "  -> fragment: AnalysisFragment = @review.alpha ({}) ;"
    , "node stress_beta"
    , "  -> fragment: AnalysisFragment = @review.beta ({}) ;"
    , "(stress_alpha) <> (stress_beta)"
    ]

repeatedGraphReferenceSourceText :: T.Text
repeatedGraphReferenceSourceText =
  T.unlines
    [ "node source"
    , "  -> out: T = @review.source ({}) ;"
    , "source <> source"
    ]

implicitFanOutSourceText :: T.Text
implicitFanOutSourceText =
  T.unlines
    [ "node source"
    , "  -> plan: T = @review.source ({}) ;"
    , "node audit"
    , "  <- plan: T ;"
    , "  -> audit: U = @review.audit (plan) ;"
    , "node decide"
    , "  <- plan: T ;"
    , "  -> decision: U = @review.decide (plan) ;"
    , "source => (audit <> decide)"
    ]

implicitFanInSourceText :: T.Text
implicitFanInSourceText =
  T.unlines
    [ "node left"
    , "  -> value: T = @review.left ({}) ;"
    , "node right"
    , "  -> value: T = @review.right ({}) ;"
    , "node sink"
    , "  <- value: T ;"
    , "  -> done: U = @review.sink (value) ;"
    , "(left <> right) => sink"
    ]

makeExpansionSourceText :: T.Text
makeExpansionSourceText =
  T.unlines
    [ "kind sample(label: PortLabel) ="
    , "  -> label: Sample = @review.sample ({}) ;"
    , "let workers = make(3, sample);"
    , "workers"
    ]

makeStaticCountSourceText :: T.Text
makeStaticCountSourceText =
  T.unlines
    [ "kind sample(label: PortLabel) ="
    , "  -> label: Sample = @review.sample ({}) ;"
    , "let count = 2;"
    , "let workers = make(count, sample);"
    , "workers"
    ]

makeZeroSourceText :: T.Text
makeZeroSourceText =
  T.unlines
    [ "kind sample(label: PortLabel) ="
    , "  -> label: Sample = @review.sample ({}) ;"
    , "node sink"
    , "  -> done: Done = @review.sink ({}) ;"
    , "let workers = make(0, sample);"
    , "workers <> sink"
    ]

indexedMakeProjectionSourceText :: T.Text
indexedMakeProjectionSourceText =
  T.unlines
    [ "kind sample(label: PortLabel) ="
    , "  -> label: Sample = @review.sample ({}) ;"
    , "let workers[] = make(2, sample);"
    , "workers[1]"
    ]

unusedMakeFamilySourceText :: T.Text
unusedMakeFamilySourceText =
  T.unlines
    [ "kind sample(label: PortLabel) ="
    , "  -> label: Sample = @review.sample ({}) ;"
    , "node sink"
    , "  -> done: Done = @review.sink ({}) ;"
    , "let workers[] = make(2, sample);"
    , "sink"
    ]

formLocalMakeStaticCountSourceText :: T.Text
formLocalMakeStaticCountSourceText =
  T.unlines
    [ "kind sample(label: PortLabel) ="
    , "  -> label: Sample = @review.sample ({}) ;"
    , "form batch_form() = {"
    , "  let count = 2;"
    , "  let workers = make(count, sample);"
    , "  workers;"
    , "};"
    , "let batch = batch_form();"
    , "batch"
    ]

makeEachSourceText :: T.Text
makeEachSourceText =
  T.unlines
    [ "kind sample(label: PortLabel) ="
    , "  -> label: Sample = @review.sample ({}) ;"
    , "let worker_names = [\"alpha\", \"beta\"];"
    , "let workers = makeEach(worker_names, sample);"
    , "workers"
    ]

makeEachEmptySourceText :: T.Text
makeEachEmptySourceText =
  T.unlines
    [ "kind sample(label: PortLabel) ="
    , "  -> label: Sample = @review.sample ({}) ;"
    , "node sink"
    , "  -> done: Done = @review.sink ({}) ;"
    , "let workers = makeEach([], sample);"
    , "workers <> sink"
    ]

makeEachValueSourceText :: T.Text
makeEachValueSourceText =
  T.unlines
    [ "kind sample(label: PortLabel, item: Value) ="
    , "  -> label: Sample = item ;"
    , "let worker_items = ["
    , "  { label = \"alpha\"; priority = 7; enabled = true; },"
    , "  { label = \"beta\"; priority = 3; enabled = false; },"
    , "];"
    , "let workers = makeEach(worker_items, sample);"
    , "workers"
    ]

makeEachFractionalValueSourceText :: T.Text
makeEachFractionalValueSourceText =
  T.unlines
    [ "kind sample(label: PortLabel, item: Value) ="
    , "  -> label: Sample = item ;"
    , "let workers = makeEach([{ label = \"alpha\"; weight = 1.5; }], sample);"
    , "workers"
    ]

makeEachDuplicateFieldValueSourceText :: T.Text
makeEachDuplicateFieldValueSourceText =
  T.unlines
    [ "kind sample(label: PortLabel, item: Value) ="
    , "  -> label: Sample = item ;"
    , "let workers = makeEach([{ label = \"alpha\"; priority = 1; priority = 2; }], sample);"
    , "workers"
    ]

starGatherSourceText :: T.Text
starGatherSourceText =
  T.unlines
    [ "node a"
    , "  -> a: A = @review.a ({}) ;"
    , "node b"
    , "  -> b: B = @review.b ({}) ;"
    , "node sink"
    , "  <- pair: Pair ;"
    , "  -> done: Done = @review.sink (pair) ;"
    , "(a <> b) * sink"
    ]

indexedProductGatherSourceText :: T.Text
indexedProductGatherSourceText =
  T.unlines
    [ "kind sample(label: PortLabel) ="
    , "  -> label: Sample = @review.sample ({}) ;"
    , "node sink"
    , "  <- samples: [Sample; 3] ;"
    , "  -> done: Done = @review.sink (samples) ;"
    , "let workers[] = make(3, sample);"
    , "workers * sink"
    ]

singletonIndexedProductGatherSourceText :: T.Text
singletonIndexedProductGatherSourceText =
  T.unlines
    [ "kind sample(label: PortLabel) ="
    , "  -> label: Sample = @review.sample ({}) ;"
    , "node sink"
    , "  <- samples: [Sample; 1] ;"
    , "  -> done: Done = @review.sink (samples) ;"
    , "let workers[] = make(1, sample);"
    , "workers * sink"
    ]

starScatterSourceText :: T.Text
starScatterSourceText =
  T.unlines
    [ "node source"
    , "  -> pair: Pair = @review.source ({}) ;"
    , "node a"
    , "  <- a: A ;"
    , "  -> done_a: Done = @review.a (a) ;"
    , "node b"
    , "  <- b: B ;"
    , "  -> done_b: Done = @review.b (b) ;"
    , "source * (a <> b)"
    ]

indexedProductScatterSourceText :: T.Text
indexedProductScatterSourceText =
  T.unlines
    [ "node source"
    , "  -> samples: [Sample; 3] = @review.source ({}) ;"
    , "kind consume(label: PortLabel) ="
    , "  <- label: Sample ;"
    , "  -> label: Done = @review.consume (label) ;"
    , "let workers[] = make(3, consume);"
    , "source * workers"
    ]

singletonIndexedProductScatterSourceText :: T.Text
singletonIndexedProductScatterSourceText =
  T.unlines
    [ "node source"
    , "  -> samples: [Sample; 1] = @review.source ({}) ;"
    , "kind consume(label: PortLabel) ="
    , "  <- label: Sample ;"
    , "  -> label: Done = @review.consume (label) ;"
    , "let workers[] = make(1, consume);"
    , "source * workers"
    ]

starEmptyScatterSourceText :: T.Text
starEmptyScatterSourceText =
  T.unlines
    [ "node source"
    , "  -> empty: EmptyRecord = @review.source ({}) ;"
    , "source * ()"
    ]

flatSingletonStarSourceText :: T.Text
flatSingletonStarSourceText =
  T.unlines
    [ "node source"
    , "  -> pair: Pair = @review.source ({}) ;"
    , "node sink"
    , "  <- pair: Pair ;"
    , "  -> done: Done = @review.sink (pair) ;"
    , "source * sink"
    ]

indexedProductArityMismatchSourceText :: T.Text
indexedProductArityMismatchSourceText =
  T.unlines
    [ "kind sample(label: PortLabel) ="
    , "  -> label: Sample = @review.sample ({}) ;"
    , "node sink"
    , "  <- samples: [Sample; 3] ;"
    , "  -> done: Done = @review.sink (samples) ;"
    , "let workers[] = make(2, sample);"
    , "workers * sink"
    ]

configuredExecutorSourceText :: T.Text
configuredExecutorSourceText =
  T.unlines
    [ "let analyst_base = @review.analyst { temperature = 0.2 ; } ;"
    , "node planner"
    , "  -> plan: PlannerOutput = @review.planner ({}) ;"
    , "node analyst"
    , "  <- plan: PlannerOutput ;"
    , "  -> analysis: AnalysisFragment ;"
    , "  = analyst_base (plan) ;"
    , "planner => analyst"
    ]

kindApplicationSourceText :: T.Text
kindApplicationSourceText =
  T.unlines
    [ "kind phase_gate(label: PortLabel, portContract: Contract, angle: Value) ="
    , "  <- label: portContract ;"
    , "  -> label: portContract = @quantum.rz { angle = angle ; } (label) ;"
    , "node screen_h = phase_gate(screen, Qubit, 1.25);"
    , "screen_h"
    ]

graphFormSourceText :: T.Text
graphFormSourceText =
  T.unlines
    [ "kind phase_gate(label: PortLabel, portContract: Contract, angle: Value) ="
    , "  <- label: portContract ;"
    , "  -> label: portContract = @quantum.rz { angle = angle ; } (label) ;"
    , "form two_phases(angle: Value) = {"
    , "  node first = phase_gate(screen, Qubit, angle);"
    , "  node second = phase_gate(screen, Qubit, angle);"
    , "  first => second;"
    , "};"
    , "let pipeline = two_phases(1.25);"
    , "pipeline"
    ]

graphFormGraphParamSourceText :: T.Text
graphFormGraphParamSourceText =
  T.unlines
    [ "node source"
    , "  -> out: T = @review.source ({}) ;"
    , "form append_tail(head: Graph) = {"
    , "  node tail"
    , "    <- out: T ;"
    , "    -> done: U = @review.tail (out) ;"
    , "  head => tail;"
    , "};"
    , "let base = source;"
    , "let pipeline = append_tail(base);"
    , "pipeline"
    ]

topLevelLetConfigSourceText :: T.Text
topLevelLetConfigSourceText =
  T.unlines
    [ "let prefix = \"Audit \" ;"
    , "let suffix = \"now\" ;"
    , "let analyst_instructions = prefix ++ suffix ;"
    , "let analyst_base = @review.analyst { instructions = analyst_instructions ; } ;"
    , "node planner"
    , "  -> plan: PlannerOutput = @review.planner ({}) ;"
    , "node analyst"
    , "  <- plan: PlannerOutput ;"
    , "  -> analysis: AnalysisFragment ;"
    , "  = analyst_base (plan) ;"
    , "planner => analyst"
    ]

graphLetSourceText :: T.Text
graphLetSourceText =
  T.unlines
    [ "node planner"
    , "  -> plan: PlannerOutput = @review.planner ({}) ;"
    , "node analyst"
    , "  <- plan: PlannerOutput ;"
    , "  -> analysis: AnalysisFragment = @review.analyst (plan) ;"
    , "let pipeline = planner => analyst ;"
    , "pipeline"
    ]

exportedGraphLibrarySourceText :: T.Text
exportedGraphLibrarySourceText =
  T.unlines
    [ "node library"
    , "  -> out: LibraryOutput = @review.library ({}) ;"
    , "node main"
    , "  -> out: MainOutput = @review.main ({}) ;"
    , "export let library_graph = library ;"
    , "main"
    ]

zeroOutputSourceText :: T.Text
zeroOutputSourceText =
  T.unlines
    [ "node emit"
    , "  -> event: Event = @review.event ({}) ;"
    , "node log_event"
    , "  <- event: Event ;"
    , "  = @artifact.log (event) ;"
    , "emit => log_event"
    ]

executorWhereSourceText :: T.Text
executorWhereSourceText =
  T.unlines
    [ "node analyze"
    , "  <- evidence: EvidenceSet ;"
    , "  -> analysis: AnalysisRecord ;"
    , "  = @review.analyze (payload) ;"
    , "  where { payload = { items = evidence.items ; } ; } ;"
    , "analyze"
    ]

selectSourceText :: T.Text
selectSourceText =
  T.unlines
    [ "node draft_plan"
    , "  -> draft: DraftPlan = @review.plan ({}) ;"
    , "node validate_plan"
    , "  <- draft: DraftPlan ;"
    , "  -> ok: ResearchPlan | issue: PlanIssue ;"
    , "  = @review.validate_plan (draft) ;"
    , "node gather_missing_constraints"
    , "  <- issue: PlanIssue ;"
    , "  -> issue: PlanIssue = @review.gather_missing_constraints (issue) ;"
    , "node repair_plan"
    , "  <- issue: PlanIssue ;"
    , "  -> ok: ResearchPlan = @review.repair_plan (issue) ;"
    , "node publish_report"
    , "  <- ok: ResearchPlan ;"
    , "  -> report: ReportArtifactRef = @artifact.publish_report (ok) ;"
    , "draft_plan => validate_plan select("
    , "  ok: (),"
    , "  issue: (gather_missing_constraints => repair_plan)"
    , ") => publish_report"
    ]

selectReorderedArmsSourceText :: T.Text
selectReorderedArmsSourceText =
  T.unlines
    [ "node draft_plan"
    , "  -> draft: DraftPlan = @review.plan ({}) ;"
    , "node validate_plan"
    , "  <- draft: DraftPlan ;"
    , "  -> ok: ResearchPlan | issue: PlanIssue ;"
    , "  = @review.validate_plan (draft) ;"
    , "node gather_missing_constraints"
    , "  <- issue: PlanIssue ;"
    , "  -> issue: PlanIssue = @review.gather_missing_constraints (issue) ;"
    , "node repair_plan"
    , "  <- issue: PlanIssue ;"
    , "  -> ok: ResearchPlan = @review.repair_plan (issue) ;"
    , "node publish_report"
    , "  <- ok: ResearchPlan ;"
    , "  -> report: ReportArtifactRef = @artifact.publish_report (ok) ;"
    , "draft_plan => validate_plan select("
    , "  issue: (gather_missing_constraints => repair_plan),"
    , "  ok: ()"
    , ") => publish_report"
    ]

selectContractFallbackSourceText :: T.Text
selectContractFallbackSourceText =
  T.unlines
    [ "node draft_plan"
    , "  -> draft: DraftPlan = @review.plan ({}) ;"
    , "node validate_plan"
    , "  <- draft: DraftPlan ;"
    , "  -> valid: ResearchPlan | issue: PlanIssue ;"
    , "  = @review.validate_plan (draft) ;"
    , "node gather_missing_constraints"
    , "  <- issue: PlanIssue ;"
    , "  -> issue: PlanIssue = @review.gather_missing_constraints (issue) ;"
    , "node repair_plan"
    , "  <- issue: PlanIssue ;"
    , "  -> valid: ResearchPlan = @review.repair_plan (issue) ;"
    , "node publish_report"
    , "  <- valid: ResearchPlan ;"
    , "  -> report: ReportArtifactRef = @artifact.publish_report (valid) ;"
    , "draft_plan => validate_plan select("
    , "  ResearchPlan: (),"
    , "  PlanIssue: (gather_missing_constraints => repair_plan)"
    , ") => publish_report"
    ]

selectAmbiguousContractFallbackSourceText :: T.Text
selectAmbiguousContractFallbackSourceText =
  T.unlines
    [ "node source"
    , "  -> left: Same | right: Same ;"
    , "  = @review.source ({}) ;"
    , "source select("
    , "  Same: ()"
    , ")"
    ]

typoContractSourceText :: T.Text
typoContractSourceText =
  T.unlines
    [ "node planner"
    , "  -> plan: PlannerOuput = @review.planner ({}) ;"
    , "planner"
    ]

projectedExecutorSourceText :: T.Text
projectedExecutorSourceText =
  T.unlines
    [ "node projected"
    , "  -> out: PlannerOutput = @review.projected ({}) ;"
    , "projected"
    ]

missingExecutorSourceText :: T.Text
missingExecutorSourceText =
  T.unlines
    [ "node missing"
    , "  -> out: PlannerOutput = @review.missing ({}) ;"
    , "missing"
    ]

mismatchedExecutorPortsSourceText :: T.Text
mismatchedExecutorPortsSourceText =
  T.unlines
    [ "node projected"
    , "  -> out: AnalysisFragment = @review.projected ({}) ;"
    , "projected"
    ]

pureExecutorSourceText :: T.Text
pureExecutorSourceText =
  T.unlines
    [ "node score"
    , "  <- evidence: Float ;"
    , "  <- recency: Float ;"
    , "  -> out: Float = evidence + recency ;"
    , "score"
    ]

pureExecutorWithSharedHelperSourceText :: T.Text
pureExecutorWithSharedHelperSourceText =
  T.unlines
    [ "let acceptedItem = x: x.score >= 0.7 ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = evidence.items |> filter acceptedItem ;"
    , "classify"
    ]

pureExecutorWithScalarLetSourceText :: T.Text
pureExecutorWithScalarLetSourceText =
  T.unlines
    [ "let scoreThreshold = 0.7 ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = evidence.items |> filter (x: x.score >= scoreThreshold) ;"
    , "classify"
    ]

pureExecutorWithLocalBindingsSourceText :: T.Text
pureExecutorWithLocalBindingsSourceText =
  T.unlines
    [ "let acceptedItem = x: x.score >= 0.7 ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = acceptedItems ;"
    , "  -> rejected: RejectedSet = items |> filter (x: !(acceptedItem x)) ;"
    , "  where let"
    , "    items = evidence.items ;"
    , "    acceptedItems = items |> filter acceptedItem ;"
    , "  in"
    , "  { items = items ; acceptedItems = acceptedItems ; } ;"
    , "classify"
    ]

pureExecutorWithLetBoundWhereSourceText :: T.Text
pureExecutorWithLetBoundWhereSourceText =
  T.unlines
    [ "let defaults = { accepted = [] ; } ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = accepted ;"
    , "  where defaults ;"
    , "classify"
    ]

whereLocalLetShadowsStaticSourceText :: T.Text
whereLocalLetShadowsStaticSourceText =
  T.unlines
    [ "let defaults = { accepted = [] ; rejected = [] ; } ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = accepted ;"
    , "  where let"
    , "    defaults = { accepted = evidence.items ; } ;"
    , "  in"
    , "  defaults ;"
    , "classify"
    ]

whereInputCollisionSourceText :: T.Text
whereInputCollisionSourceText =
  T.unlines
    [ "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = accepted ;"
    , "  where { evidence = evidence.items ; accepted = [] ; } ;"
    , "classify"
    ]

whereDynamicShapeSourceText :: T.Text
whereDynamicShapeSourceText =
  T.unlines
    [ "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = accepted ;"
    , "  where if true then { accepted = [] ; } else { rejected = [] ; } ;"
    , "classify"
    ]

pureExecutorDuplicateRecordPathSourceText :: T.Text
pureExecutorDuplicateRecordPathSourceText =
  T.unlines
    [ "node score"
    , "  -> out: Float = if false then { a = 1 ; a = 2 ; } else 0 ;"
    , "score"
    ]

pureExecutorPrefixRecordPathSourceText :: T.Text
pureExecutorPrefixRecordPathSourceText =
  T.unlines
    [ "node score"
    , "  -> out: Float = if false then { a.b = 1 ; a = 2 ; } else 0 ;"
    , "score"
    ]

duplicatePureAndWireLetSourceText :: T.Text
duplicatePureAndWireLetSourceText =
  T.unlines
    [ "let acceptedItem = x: x.score >= 0.7 ;"
    , "let acceptedItem = @review.analyst { temperature = 0.2 ; } ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = evidence.items |> filter acceptedItem ;"
    , "classify"
    ]

legacyPureExecutorSourceText :: T.Text
legacyPureExecutorSourceText =
  T.unlines
    [ "node score"
    , "  <- evidence: Float ;"
    , "  -> out: Float = @pure (evidence) ;"
    , "score"
    ]

configuredExecutorInPureOutputSourceText :: T.Text
configuredExecutorInPureOutputSourceText =
  T.unlines
    [ "let analyst_base = @review.analyst { temperature = 0.2 ; } ;"
    , "node classify"
    , "  <- evidence: EvidenceSet ;"
    , "  -> accepted: AcceptedSet = analyst_base(evidence) ;"
    , "classify"
    ]

graphBindingInPureOutputSourceText :: T.Text
graphBindingInPureOutputSourceText =
  T.unlines
    [ "node source"
    , "  -> evidence: EvidenceSet = @review.source ({}) ;"
    , "let workers = source ;"
    , "node classify"
    , "  -> accepted: AcceptedSet = workers ;"
    , "classify"
    ]

nodeBindingInPureOutputSourceText :: T.Text
nodeBindingInPureOutputSourceText =
  T.unlines
    [ "node worker"
    , "  -> evidence: EvidenceSet = @review.source ({}) ;"
    , "node classify"
    , "  -> accepted: AcceptedSet = worker ;"
    , "classify"
    ]

importedExecutorInPureOutputSourceText :: T.Text
importedExecutorInPureOutputSourceText =
  T.unlines
    [ "use std.io.{@command};"
    , "node classify"
    , "  -> accepted: AcceptedSet = command({}) ;"
    , "classify"
    ]

contractInPureOutputSourceText :: T.Text
contractInPureOutputSourceText =
  T.unlines
    [ "contract AcceptedSet;"
    , "node classify"
    , "  -> accepted: AcceptedSet = AcceptedSet ;"
    , "classify"
    ]

graphBindingInTopLevelCorePureLetSourceText :: T.Text
graphBindingInTopLevelCorePureLetSourceText =
  T.unlines
    [ "node source"
    , "  -> evidence: EvidenceSet = @review.source ({}) ;"
    , "let workers = source ;"
    , "let accepted = x: workers ;"
    , "node classify"
    , "  -> accepted: AcceptedSet = accepted ;"
    , "classify"
    ]

stdIoAliasSourceText :: T.Text
stdIoAliasSourceText =
  T.unlines
    [ "use std.io.{@command as @shell, CommandSpec as Spec, CommandResult as Result};"
    , "node run"
    , "  <- spec: Spec ;"
    , "  -> result: Result = @shell {} (spec) ;"
    , "run"
    ]

stdIoCanonicalAfterUseSourceText :: T.Text
stdIoCanonicalAfterUseSourceText =
  T.unlines
    [ "use std.io.{@command, CommandResult};"
    , "node run"
    , "  -> result: CommandResult = @std.io.command {} (null) ;"
    , "run"
    ]

stdIoBareWithoutUseSourceText :: T.Text
stdIoBareWithoutUseSourceText =
  T.unlines
    [ "node run"
    , "  -> result: CommandResult = @command {} (null) ;"
    , "run"
    ]

stdIoCanonicalWithoutUseSourceText :: T.Text
stdIoCanonicalWithoutUseSourceText =
  T.unlines
    [ "node run"
    , "  -> result: CommandResult = @std.io.command {} (null) ;"
    , "run"
    ]

stdIoUseContractCollisionSourceText :: T.Text
stdIoUseContractCollisionSourceText =
  T.unlines
    [ "use std.io.{CommandSpec};"
    , "contract CommandSpec;"
    ]

stdIoStdoutBadShapeSourceText :: T.Text
stdIoStdoutBadShapeSourceText =
  T.unlines
    [ "use std.io.{@stdout};"
    , "node bad_stdout"
    , "  -> printed: Printed = @stdout {} (null) ;"
    , "bad_stdout"
    ]

stdIoFileExecutorsSourceText :: T.Text
stdIoFileExecutorsSourceText =
  T.unlines
    [ "use std.io.{@readFile, @writeFile};"
    , "contract Report;"
    , "node read_report"
    , "  -> report: Report = @readFile { path = \"/tmp/wire-report.txt\"; } (null) ;"
    , "node write_report"
    , "  <- report: Report;"
    , "  = @writeFile { path = \"/tmp/wire-report-copy.txt\"; } (report) ;"
    , "read_report => write_report"
    ]

stdIoReadFileBadShapeSourceText :: T.Text
stdIoReadFileBadShapeSourceText =
  T.unlines
    [ "use std.io.{@readFile};"
    , "node bad_read"
    , "  = @readFile { path = \"/tmp/wire-report.txt\"; } (null) ;"
    , "bad_read"
    ]

stdIoWriteFileBadShapeSourceText :: T.Text
stdIoWriteFileBadShapeSourceText =
  T.unlines
    [ "use std.io.{@writeFile};"
    , "contract Report;"
    , "node bad_write"
    , "  <- report: Report;"
    , "  -> written: Report = @writeFile { path = \"/tmp/wire-report.txt\"; } (report) ;"
    , "bad_write"
    ]

requireRight :: Show err => Either err a -> IO a
requireRight = \case
  Left err ->
    expectationFailure ("expected Right, got Left: " <> show err)
      >> fail "unreachable after expectationFailure"
  Right ok -> pure ok

compileQuantumEraserFixture :: FilePath -> Expectation
compileQuantumEraserFixture path = do
  source <- TIO.readFile path
  compileWireTextWithEnv quantumExecutorEnv source `shouldSatisfy` isRight

quantumEraserSweepFixtures :: [FilePath]
quantumEraserSweepFixtures =
  [ "examples/wire/quantum-eraser-open-phase-0.wire"
  , "examples/wire/quantum-eraser-open-phase-1_4.wire"
  , "examples/wire/quantum-eraser-open-phase-1_2.wire"
  , "examples/wire/quantum-eraser-which-path-phase-0.wire"
  , "examples/wire/quantum-eraser-which-path-phase-1_4.wire"
  , "examples/wire/quantum-eraser-which-path-phase-1_2.wire"
  , "examples/wire/quantum-eraser-eraser-phase-1_4.wire"
  , "examples/wire/quantum-eraser-eraser-phase-1_2.wire"
  ]

metadataConfigHasNumber :: Key.Key -> ScientificLiteral -> Aeson.Value -> Bool
metadataConfigHasNumber fieldName expected = \case
  Aeson.Object obj ->
    case KeyMap.lookup "config" obj of
      Just (Aeson.Object configObj) ->
        KeyMap.lookup fieldName configObj == Just (Aeson.Number expected)
      _ -> False
  _ -> False

metadataConfigHasString :: Key.Key -> T.Text -> Aeson.Value -> Bool
metadataConfigHasString fieldName expected = \case
  Aeson.Object obj ->
    case KeyMap.lookup "config" obj of
      Just (Aeson.Object configObj) ->
        KeyMap.lookup fieldName configObj == Just (Aeson.String expected)
      _ -> False
  _ -> False

metadataConfigHasKey :: Key.Key -> Aeson.Value -> Bool
metadataConfigHasKey fieldName = \case
  Aeson.Object obj ->
    case KeyMap.lookup "config" obj of
      Just (Aeson.Object configObj) -> KeyMap.member fieldName configObj
      _ -> False
  _ -> False

type ScientificLiteral = Scientific

metadataHasPureBinding :: T.Text -> Aeson.Value -> Bool
metadataHasPureBinding =
  metadataHasPureBindingIn "bindings"

metadataHasPureWhere :: Aeson.Value -> Bool
metadataHasPureWhere =
  metadataConfigHasKey "where"

wireAdmissionValue :: CompiledCircuit -> Maybe Aeson.Value
wireAdmissionValue compiled =
  case compiled.compiledCircuitMetadata of
    Aeson.Object obj ->
      KeyMap.lookup (Key.fromText wireAdmissionMetadataKey) obj
    _ -> Nothing

wireAdmissionArtifact :: CompiledCircuit -> Maybe WireAdmissionArtifact
wireAdmissionArtifact compiled = do
  admission <- wireAdmissionValue compiled
  case Aeson.fromJSON admission of
    Aeson.Success artifact -> Just artifact
    Aeson.Error _message -> Nothing

expectWireAdmissionArtifact
  :: CompiledCircuit -> (WireAdmissionArtifact -> Expectation) -> Expectation
expectWireAdmissionArtifact compiled check =
  case (wireAdmissionValue compiled, wireAdmissionArtifact compiled) of
    (Just admission, Just artifact) -> do
      Aeson.toJSON artifact `shouldBe` admission
      artifact.wireAdmissionSchemaVersion `shouldBe` wireAdmissionCurrentSchemaVersion
      artifact `shouldSatisfy` wireAdmissionArtifactValidatorReady
      check artifact
    _ -> expectationFailure "wire admission metadata did not decode"

wireAdmissionArray :: T.Text -> CompiledCircuit -> Maybe [Aeson.Value]
wireAdmissionArray fieldName compiled = do
  admission <- wireAdmissionValue compiled
  case admission of
    Aeson.Object obj ->
      case KeyMap.lookup (Key.fromText fieldName) obj of
        Just (Aeson.Array values) -> Just (Foldable.toList values)
        _ -> Nothing
    _ -> Nothing

wireAdmissionArrayAny :: T.Text -> (Aeson.Value -> Bool) -> CompiledCircuit -> Bool
wireAdmissionArrayAny fieldName predicate compiled =
  maybe False (any predicate) (wireAdmissionArray fieldName compiled)

wireAdmissionSchemaVersionFromJson :: CompiledCircuit -> Maybe Natural
wireAdmissionSchemaVersionFromJson compiled = do
  admission <- wireAdmissionValue compiled
  case admission of
    Aeson.Object obj -> do
      Aeson.Number version <- KeyMap.lookup "wireAdmissionSchemaVersion" obj
      case floatingOrInteger version :: Either Double Integer of
        Right intVersion
          | intVersion >= 0 -> Just (fromInteger intVersion)
        Left _ -> Nothing
        Right _negativeVersion -> Nothing
    _ -> Nothing

wireAdmissionJsonWith :: [(T.Text, Aeson.Value)] -> Aeson.Value
wireAdmissionJsonWith fields =
  case wireAdmissionMetadataValue emptyWireAdmissionArtifact of
    Aeson.Object obj ->
      Aeson.Object
        ( foldl
            insertField
            obj
            fields
        )
    other ->
      other
  where
    insertField current (fieldName, fieldValue) =
      KeyMap.insert (Key.fromText fieldName) fieldValue current

simpleChainConnectionJson :: Aeson.Value
simpleChainConnectionJson =
  Aeson.object
    [ "connectionFrom" Aeson..= endpointJson "planner" "plan"
    , "connectionTo" Aeson..= endpointJson "analyst" "plan"
    ]
  where
    endpointJson :: T.Text -> T.Text -> Aeson.Value
    endpointJson node port =
      Aeson.object
        [ "endpointNodeRef" Aeson..= node
        , "endpointPortName" Aeson..= port
        ]

negativeIndexedProductShapeJson :: Aeson.Value
negativeIndexedProductShapeJson =
  Aeson.object
    [ "kind" Aeson..= ("indexed" :: T.Text)
    , "elementContract" Aeson..= ("Sample" :: T.Text)
    , "count" Aeson..= (-1 :: Int)
    ]

negativeExclusiveGroupBoundaryJson :: Aeson.Value
negativeExclusiveGroupBoundaryJson =
  Aeson.object
    [ "admissionBoundaryNode" Aeson..= CircuitNodeRef "selector"
    , "admissionBoundaryPort" Aeson..= ("choice" :: T.Text)
    , "admissionBoundaryContract" Aeson..= ("Choice" :: T.Text)
    , "admissionBoundaryLabel" Aeson..= AdmissionNoLabel
    , "admissionBoundaryExclusiveGroup" Aeson..= (CircuitNodeRef "selector", -1 :: Int)
    ]

negativeSelectArmSourceIndexJson :: Aeson.Value
negativeSelectArmSourceIndexJson =
  Aeson.object
    [ "selectArmSourceIndex" Aeson..= (-1 :: Int)
    , "selectArmSourceKey" Aeson..= ("accepted" :: T.Text)
    , "selectArmCanonicalKey" Aeson..= ("accepted" :: T.Text)
    , "selectArmResolutionMode" Aeson..= SelectResolvedByLabel
    , "selectArmBodyNodes" Aeson..= ([] :: [CircuitNodeRef])
    , "selectArmBodyEntries" Aeson..= ([] :: [AdmissionBoundaryPort])
    , "selectArmBodyExits" Aeson..= ([] :: [AdmissionBoundaryPort])
    ]

plannerBoundary :: AdmissionBoundaryPort
plannerBoundary =
  admissionTestBoundary (CircuitNodeRef "planner") "plan" "PlannerOutput"

analystBoundary :: AdmissionBoundaryPort
analystBoundary =
  admissionTestBoundary (CircuitNodeRef "analyst") "plan" "PlannerOutput"

sinkBoundary :: AdmissionBoundaryPort
sinkBoundary =
  admissionTestBoundary (CircuitNodeRef "sink") "samples" "[Sample; 2]"

admissionTestBoundary :: CircuitNodeRef -> T.Text -> T.Text -> AdmissionBoundaryPort
admissionTestBoundary node port contract =
  AdmissionBoundaryPort
    { admissionBoundaryNode = node
    , admissionBoundaryPort = port
    , admissionBoundaryContract = contract
    , admissionBoundaryLabel = AdmissionNoLabel
    , admissionBoundaryExclusiveGroup = Nothing
    }

admissionTestLabeledBoundary
  :: CircuitNodeRef -> T.Text -> T.Text -> T.Text -> AdmissionBoundaryPort
admissionTestLabeledBoundary node port contract label =
  (admissionTestBoundary node port contract)
    { admissionBoundaryLabel = AdmissionLabel label
    }

minimalGeneratedAdmissionArtifact :: WireAdmissionArtifact
minimalGeneratedAdmissionArtifact =
  emptyWireAdmissionArtifact
    { wireAdmissionNodes = [generatedNode]
    , wireAdmissionPrimitiveSteps = [PrimitiveNode generatedNode [] []]
    , wireAdmissionGeneratedForms = [generatedForm]
    }
  where
    generatedNode =
      CircuitNodeRef "workers_0"

    generatedForm =
      GeneratedFormArtifact
        { generatedFormKind = GeneratedMake
        , generatedFormKindName = "worker"
        , generatedFormBinding = "workers"
        , generatedFormSourceChildren =
            [GeneratedChildSourceArtifact generatedNode "0" Nothing]
        , generatedFormUsedChildren =
            [GeneratedChildArtifact generatedNode "0" [] []]
        }

minimalPhantomAdmissionArtifact :: WireAdmissionArtifact
minimalPhantomAdmissionArtifact =
  emptyWireAdmissionArtifact
    { wireAdmissionNodes = [planner, sink, phantomNode]
    , wireAdmissionEntries = []
    , wireAdmissionExits = []
    , wireAdmissionConnections =
        [ rawConnection multi phantomMulti
        , rawConnection phantomSingular singular
        ]
    , wireAdmissionPrimitiveSteps =
        [ PrimitiveNode planner [] [multi]
        , PrimitiveNode phantomNode [phantomMulti] [phantomSingular]
        , PrimitiveConnect [multi] [phantomMulti] [AdmissionConnection multi phantomMulti] [] []
        , PrimitiveNode sink [singular] []
        , PrimitiveConnect
            [phantomSingular]
            [singular]
            [AdmissionConnection phantomSingular singular]
            []
            []
        ]
    , wireAdmissionPhantomAdapters = [phantomAdapter]
    }
  where
    planner =
      CircuitNodeRef "planner"

    sink =
      CircuitNodeRef "sink"

    phantomNode =
      CircuitNodeRef "__star:gather:planner:sink"

    singular =
      admissionTestBoundary sink "plans" "[PlannerOutput;1]"

    multi =
      admissionTestBoundary planner "plan" "PlannerOutput"

    phantomMulti =
      admissionTestBoundary phantomNode "item_0" "PlannerOutput"

    phantomSingular =
      admissionTestBoundary phantomNode "plans" "[PlannerOutput;1]"

    phantomAdapter =
      PhantomAdapterArtifact
        { phantomAdapterDirection = PhantomGather
        , phantomAdapterNode = phantomNode
        , phantomAdapterProductShape = ProductIndexed "PlannerOutput" 1
        , phantomAdapterSingular = singular
        , phantomAdapterMulti = [multi]
        , phantomAdapterLeftBulk = [AdmissionConnection multi phantomMulti]
        , phantomAdapterRightBulk = [AdmissionConnection phantomSingular singular]
        }

    rawConnection fromBoundary toBoundary =
      Connection
        { connectionFrom =
            EndpointRef
              fromBoundary.admissionBoundaryNode
              (Just fromBoundary.admissionBoundaryPort)
        , connectionTo =
            EndpointRef
              toBoundary.admissionBoundaryNode
              (Just toBoundary.admissionBoundaryPort)
        }

minimalSelectAdmissionArtifact :: WireAdmissionArtifact
minimalSelectAdmissionArtifact =
  emptyWireAdmissionArtifact
    { wireAdmissionNodes = [planner, conditionNode]
    , wireAdmissionEntries = [okEntry, issueEntry]
    , wireAdmissionExits = [okPort, issuePort, approvedBridge, blockedBridge]
    , wireAdmissionPrimitiveSteps =
        [ PrimitiveNode planner [] [okPort, issuePort]
        , PrimitiveNode
            conditionNode
            [okEntry, issueEntry]
            [okInternal, issueInternal, approvedBridge, blockedBridge]
        ]
    , wireAdmissionSelects = [selectAdmission]
    }
  where
    planner =
      CircuitNodeRef "planner"

    conditionNode =
      CircuitNodeRef "__select:choice"

    okBranch =
      CircuitNodeRef "ok_branch"

    issueBranch =
      CircuitNodeRef "issue_branch"

    okPort =
      (admissionTestLabeledBoundary planner "ok" "ResearchPlan" "ok")
        { admissionBoundaryExclusiveGroup = Just (planner, 0)
        }

    issuePort =
      (admissionTestLabeledBoundary planner "issue" "PlanIssue" "issue")
        { admissionBoundaryExclusiveGroup = Just (planner, 0)
        }

    okEntry =
      admissionTestLabeledBoundary conditionNode "variant_in_1" "ResearchPlan" "ok"

    issueEntry =
      admissionTestLabeledBoundary conditionNode "variant_in_2" "PlanIssue" "issue"

    okInternal =
      (admissionTestLabeledBoundary conditionNode "variant_out_1" "ResearchPlan" "ok")
        { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
        }

    issueInternal =
      (admissionTestLabeledBoundary conditionNode "variant_out_2" "PlanIssue" "issue")
        { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
        }

    approvedBridge =
      (admissionTestLabeledBoundary conditionNode "bridge_out_1" "Approved" "approved")
        { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
        }

    blockedBridge =
      (admissionTestLabeledBoundary conditionNode "bridge_out_2" "Blocked" "blocked")
        { admissionBoundaryExclusiveGroup = Just (conditionNode, 0)
        }

    okBodyEntry =
      admissionTestLabeledBoundary okBranch "selected" "ResearchPlan" "ok"

    issueBodyEntry =
      admissionTestLabeledBoundary issueBranch "selected" "PlanIssue" "issue"

    okApproved =
      (admissionTestLabeledBoundary okBranch "approved" "Approved" "approved")
        { admissionBoundaryExclusiveGroup = Just (okBranch, 0)
        }

    okBlocked =
      (admissionTestLabeledBoundary okBranch "blocked" "Blocked" "blocked")
        { admissionBoundaryExclusiveGroup = Just (okBranch, 0)
        }

    issueApproved =
      (admissionTestLabeledBoundary issueBranch "approved" "Approved" "approved")
        { admissionBoundaryExclusiveGroup = Just (issueBranch, 0)
        }

    issueBlocked =
      (admissionTestLabeledBoundary issueBranch "blocked" "Blocked" "blocked")
        { admissionBoundaryExclusiveGroup = Just (issueBranch, 0)
        }

    selectAdmission =
      SelectAdmissionArtifact
        { selectAdmissionOwner = conditionNode
        , selectAdmissionConditionNode = conditionNode
        , selectAdmissionVariants =
            [ SelectVariantArtifact "ok" okPort
            , SelectVariantArtifact "issue" issuePort
            ]
        , selectAdmissionArms =
            [ SelectArmAdmissionArtifact
                { selectArmSourceIndex = 0
                , selectArmSourceKey = "ok"
                , selectArmCanonicalKey = "ok"
                , selectArmResolutionMode = SelectResolvedByLabel
                , selectArmBodyNodes = [okBranch]
                , selectArmBodyEntries = [okBodyEntry]
                , selectArmBodyExits = [okApproved, okBlocked]
                }
            , SelectArmAdmissionArtifact
                { selectArmSourceIndex = 1
                , selectArmSourceKey = "issue"
                , selectArmCanonicalKey = "issue"
                , selectArmResolutionMode = SelectResolvedByLabel
                , selectArmBodyNodes = [issueBranch]
                , selectArmBodyEntries = [issueBodyEntry]
                , selectArmBodyExits = [issueApproved, issueBlocked]
                }
            ]
        }

type BoundarySummary = (T.Text, T.Text, T.Text)

type ConnectionSummary = (BoundarySummary, BoundarySummary)

type ExpectedGeneratedSourceChild = (CircuitNodeRef, T.Text, Bool)

type ExpectedGeneratedUsedChild = (CircuitNodeRef, T.Text, [T.Text], [T.Text])

data ExpectedGeneratedForm = ExpectedGeneratedForm
  { expectedGeneratedKind :: !GeneratedFormKind
  , expectedGeneratedKindName :: !T.Text
  , expectedGeneratedBinding :: !T.Text
  , expectedGeneratedSource :: ![ExpectedGeneratedSourceChild]
  , expectedGeneratedUsed :: ![ExpectedGeneratedUsedChild]
  }
  deriving stock (Eq, Show)

primitiveConnectMatchesSimpleChain :: Aeson.Value -> Bool
primitiveConnectMatchesSimpleChain = \case
  Aeson.Object obj ->
    KeyMap.lookup "tag" obj == Just (Aeson.String "PrimitiveConnect")
      && boundaryArraySummary obj "leftExits" == Just [plannerPlan]
      && boundaryArraySummary obj "rightEntries" == Just [analystPlan]
      && connectionArraySummary obj "matchedPairs" == Just [(plannerPlan, analystPlan)]
      && boundaryArraySummary obj "unmatchedLeftExits" == Just []
      && boundaryArraySummary obj "unmatchedRightEntries" == Just []
  _ -> False
  where
    plannerPlan = ("planner", "plan", "PlannerOutput")
    analystPlan = ("analyst", "plan", "PlannerOutput")

boundaryArraySummary :: KeyMap.KeyMap Aeson.Value -> Key.Key -> Maybe [BoundarySummary]
boundaryArraySummary obj fieldName =
  case KeyMap.lookup fieldName obj of
    Just (Aeson.Array values) ->
      traverse boundarySummary (Foldable.toList values)
    _ ->
      Nothing

connectionArraySummary :: KeyMap.KeyMap Aeson.Value -> Key.Key -> Maybe [ConnectionSummary]
connectionArraySummary obj fieldName =
  case KeyMap.lookup fieldName obj of
    Just (Aeson.Array values) ->
      traverse connectionSummary (Foldable.toList values)
    _ ->
      Nothing

boundarySummary :: Aeson.Value -> Maybe BoundarySummary
boundarySummary = \case
  Aeson.Object obj -> do
    Aeson.String node <- KeyMap.lookup "admissionBoundaryNode" obj
    Aeson.String port <- KeyMap.lookup "admissionBoundaryPort" obj
    Aeson.String contract <- KeyMap.lookup "admissionBoundaryContract" obj
    pure (node, port, contract)
  _ -> Nothing

connectionSummary :: Aeson.Value -> Maybe ConnectionSummary
connectionSummary = \case
  Aeson.Object obj -> do
    fromBoundary <- KeyMap.lookup "admissionConnectionFrom" obj >>= boundarySummary
    toBoundary <- KeyMap.lookup "admissionConnectionTo" obj >>= boundarySummary
    pure (fromBoundary, toBoundary)
  _ -> Nothing

assertSimpleChainPrimitiveConnectArtifact :: WireAdmissionArtifact -> Expectation
assertSimpleChainPrimitiveConnectArtifact artifact =
  case mapMaybe primitiveConnectStep artifact.wireAdmissionPrimitiveSteps of
    [PrimitiveConnect leftExits rightEntries matchedPairs unmatchedLeftExits unmatchedRightEntries] -> do
      fmap admissionBoundaryTypedSummary leftExits
        `shouldBe` [plannerPlan]
      fmap admissionBoundaryTypedSummary rightEntries
        `shouldBe` [analystPlan]
      fmap admissionConnectionTypedSummary matchedPairs
        `shouldBe` [(plannerPlan, analystPlan)]
      unmatchedLeftExits `shouldBe` []
      unmatchedRightEntries `shouldBe` []
    other ->
      expectationFailure ("expected one primitive connect artifact, got: " <> show other)
  where
    plannerPlan = ("planner", "plan", "PlannerOutput")
    analystPlan = ("analyst", "plan", "PlannerOutput")

primitiveConnectStep :: PrimitiveGraphStep -> Maybe PrimitiveGraphStep
primitiveConnectStep = \case
  PrimitiveEmpty -> Nothing
  PrimitiveNode _node _entries _exits -> Nothing
  PrimitiveBindingRef _binding -> Nothing
  PrimitiveOverlay _leftNodes _rightNodes _leftBindings _rightBindings -> Nothing
  step@(PrimitiveConnect {}) -> Just step

admissionBoundaryTypedSummary :: AdmissionBoundaryPort -> BoundarySummary
admissionBoundaryTypedSummary boundary =
  ( (admissionBoundaryNode boundary).unCircuitNodeRef
  , admissionBoundaryPort boundary
  , admissionBoundaryContract boundary
  )

admissionConnectionTypedSummary :: AdmissionConnection -> ConnectionSummary
admissionConnectionTypedSummary connection =
  ( admissionBoundaryTypedSummary connection.admissionConnectionFrom
  , admissionBoundaryTypedSummary connection.admissionConnectionTo
  )

assertGeneratedFormArtifact :: ExpectedGeneratedForm -> WireAdmissionArtifact -> Expectation
assertGeneratedFormArtifact expected artifact =
  case artifact.wireAdmissionGeneratedForms of
    [generated] -> do
      generated.generatedFormKind `shouldBe` expected.expectedGeneratedKind
      generated.generatedFormKindName `shouldBe` expected.expectedGeneratedKindName
      generated.generatedFormBinding `shouldBe` expected.expectedGeneratedBinding
      fmap generatedSourceChildTypedSummary generated.generatedFormSourceChildren
        `shouldBe` expected.expectedGeneratedSource
      fmap generatedUsedChildTypedSummary generated.generatedFormUsedChildren
        `shouldBe` expected.expectedGeneratedUsed
    other ->
      expectationFailure ("expected one generated form artifact, got: " <> show other)

generatedSourceChildTypedSummary
  :: GeneratedChildSourceArtifact -> ExpectedGeneratedSourceChild
generatedSourceChildTypedSummary child =
  ( generatedSourceChildNode child
  , generatedSourceChildLabel child
  , isJust (generatedSourceChildValue child)
  )

generatedUsedChildTypedSummary
  :: GeneratedChildArtifact -> ExpectedGeneratedUsedChild
generatedUsedChildTypedSummary child =
  ( generatedChildNode child
  , generatedChildLabel child
  , fmap admissionBoundaryPort child.generatedChildOutputs
  , fmap admissionBoundaryPort child.generatedChildInputs
  )

assertIndexedGatherPhantomArtifact :: CircuitNodeRef -> WireAdmissionArtifact -> Expectation
assertIndexedGatherPhantomArtifact phantomRef artifact =
  case artifact.wireAdmissionPhantomAdapters of
    [phantom] -> do
      phantom.phantomAdapterDirection `shouldBe` PhantomGather
      phantom.phantomAdapterNode `shouldBe` phantomRef
      phantom.phantomAdapterProductShape `shouldBe` ProductIndexed "Sample" 3
      Set.fromList (fmap admissionBoundaryNode phantom.phantomAdapterMulti)
        `shouldBe` Set.fromList
          [ CircuitNodeRef "workers_0"
          , CircuitNodeRef "workers_1"
          , CircuitNodeRef "workers_2"
          ]
      Set.fromList (fmap (admissionBoundaryNode . admissionConnectionFrom) phantom.phantomAdapterLeftBulk)
        `shouldBe` Set.fromList
          [ CircuitNodeRef "workers_0"
          , CircuitNodeRef "workers_1"
          , CircuitNodeRef "workers_2"
          ]
      Set.fromList (fmap (admissionBoundaryNode . admissionConnectionTo) phantom.phantomAdapterLeftBulk)
        `shouldBe` Set.singleton phantomRef
      Set.fromList
        (fmap (admissionBoundaryNode . admissionConnectionFrom) phantom.phantomAdapterRightBulk)
        `shouldBe` Set.singleton phantomRef
      Set.fromList (fmap (admissionBoundaryNode . admissionConnectionTo) phantom.phantomAdapterRightBulk)
        `shouldBe` Set.singleton (CircuitNodeRef "sink")
    other ->
      expectationFailure ("expected one indexed gather phantom artifact, got: " <> show other)

assertRecordPhantomArtifact
  :: PhantomAdapterDirection -> CircuitNodeRef -> WireAdmissionArtifact -> Expectation
assertRecordPhantomArtifact expectedDirection phantomRef artifact =
  case artifact.wireAdmissionPhantomAdapters of
    [phantom] -> do
      phantom.phantomAdapterDirection `shouldBe` expectedDirection
      phantom.phantomAdapterNode `shouldBe` phantomRef
      phantom.phantomAdapterProductShape
        `shouldBe` ProductRecord "Pair" [("a", "A"), ("b", "B")]
      admissionBoundaryContract phantom.phantomAdapterSingular `shouldBe` "Pair"
      Set.fromList (fmap admissionBoundaryTypedSummary phantom.phantomAdapterMulti)
        `shouldBe` Set.fromList
          [ ("a", "a", "A")
          , ("b", "b", "B")
          ]
    other ->
      expectationFailure ("expected one record phantom artifact, got: " <> show other)

assertLabeledSelectAdmissionArtifact :: CircuitNodeRef -> WireAdmissionArtifact -> Expectation
assertLabeledSelectAdmissionArtifact selectRef artifact =
  case artifact.wireAdmissionSelects of
    [selectArtifact] -> do
      selectArtifact.selectAdmissionOwner `shouldBe` selectRef
      selectArtifact.selectAdmissionConditionNode `shouldBe` selectRef
      Set.fromList (fmap selectVariantKey selectArtifact.selectAdmissionVariants)
        `shouldBe` Set.fromList ["ok", "issue"]
      Set.fromList (fmap selectArmSourceIndex selectArtifact.selectAdmissionArms)
        `shouldBe` Set.fromList [0, 1]
      Foldable.traverse_ assertArm selectArtifact.selectAdmissionArms
    other ->
      expectationFailure ("expected one select admission artifact, got: " <> show other)
  where
    assertArm arm =
      case arm.selectArmCanonicalKey of
        "ok" -> do
          arm.selectArmSourceKey `shouldBe` "ok"
          arm.selectArmResolutionMode `shouldBe` SelectResolvedByLabel
          arm.selectArmBodyNodes `shouldBe` []
          arm.selectArmBodyEntries `shouldBe` []
          arm.selectArmBodyExits `shouldBe` []
        "issue" -> do
          arm.selectArmSourceKey `shouldBe` "issue"
          arm.selectArmResolutionMode `shouldBe` SelectResolvedByLabel
          Set.fromList arm.selectArmBodyNodes
            `shouldBe` Set.fromList
              [ CircuitNodeRef "gather_missing_constraints"
              , CircuitNodeRef "repair_plan"
              ]
        other ->
          expectationFailure ("unexpected select arm key: " <> show other)

generatedFormMatches
  :: T.Text
  -> T.Text
  -> T.Text
  -> [(CircuitNodeRef, T.Text, Bool)]
  -> [(CircuitNodeRef, T.Text)]
  -> Aeson.Value
  -> Bool
generatedFormMatches expectedKind expectedKindName expectedBinding expectedSource expectedUsed = \case
  Aeson.Object obj ->
    KeyMap.lookup "generatedFormKind" obj == Just (Aeson.String expectedKind)
      && KeyMap.lookup "generatedFormKindName" obj == Just (Aeson.String expectedKindName)
      && KeyMap.lookup "generatedFormBinding" obj == Just (Aeson.String expectedBinding)
      && case KeyMap.lookup "generatedFormSourceChildren" obj of
        Just (Aeson.Array children) ->
          traverse generatedSourceChildSummary (Foldable.toList children) == Just expectedSource
        _ -> False
      && case KeyMap.lookup "generatedFormUsedChildren" obj of
        Just (Aeson.Array children) ->
          traverse generatedChildSummary (Foldable.toList children) == Just expectedUsed
        _ -> False
  _ -> False

generatedSourceChildSummary :: Aeson.Value -> Maybe (CircuitNodeRef, T.Text, Bool)
generatedSourceChildSummary = \case
  Aeson.Object obj -> do
    nodeValue <- KeyMap.lookup "generatedSourceChildNode" obj
    labelValue <- KeyMap.lookup "generatedSourceChildLabel" obj
    let hasValue =
          case KeyMap.lookup "generatedSourceChildValue" obj of
            Just Aeson.Null -> False
            Just _ -> True
            Nothing -> False
    case (nodeValue, labelValue) of
      (Aeson.String nodeRef, Aeson.String label) -> Just (CircuitNodeRef nodeRef, label, hasValue)
      _ -> Nothing
  _ -> Nothing

generatedFormSourceChildValueMatches
  :: CircuitNodeRef -> (Aeson.Value -> Bool) -> Aeson.Value -> Bool
generatedFormSourceChildValueMatches expectedNode predicate = \case
  Aeson.Object obj ->
    case KeyMap.lookup "generatedFormSourceChildren" obj of
      Just (Aeson.Array children) ->
        any sourceChildMatches children
      _ -> False
  _ -> False
  where
    sourceChildMatches = \case
      Aeson.Object childObj ->
        KeyMap.lookup "generatedSourceChildNode" childObj
          == Just (Aeson.String expectedNode.unCircuitNodeRef)
          && maybe False predicate (KeyMap.lookup "generatedSourceChildValue" childObj)
      _ -> False

staticRecordFieldNat :: T.Text -> Integer -> Aeson.Value -> Bool
staticRecordFieldNat fieldName expectedValue =
  staticRecordField fieldName $ \case
    Aeson.Object valueObj ->
      KeyMap.lookup "kind" valueObj == Just (Aeson.String "nat")
        && KeyMap.lookup "value" valueObj == Just (Aeson.Number (fromInteger expectedValue))
    _ -> False

staticRecordFieldBool :: T.Text -> Bool -> Aeson.Value -> Bool
staticRecordFieldBool fieldName expectedValue =
  staticRecordField fieldName $ \case
    Aeson.Object valueObj ->
      KeyMap.lookup "kind" valueObj == Just (Aeson.String "bool")
        && KeyMap.lookup "value" valueObj == Just (Aeson.Bool expectedValue)
    _ -> False

staticRecordField :: T.Text -> (Aeson.Value -> Bool) -> Aeson.Value -> Bool
staticRecordField fieldName predicate = \case
  Aeson.Object valueObj ->
    KeyMap.lookup "kind" valueObj == Just (Aeson.String "record")
      && case KeyMap.lookup "fields" valueObj of
        Just (Aeson.Array fields) ->
          any fieldMatches fields
        _ -> False
  _ -> False
  where
    fieldMatches = \case
      Aeson.Object fieldObj ->
        KeyMap.lookup "label" fieldObj == Just (Aeson.String fieldName)
          && maybe False predicate (KeyMap.lookup "value" fieldObj)
      _ -> False

generatedChildSummary :: Aeson.Value -> Maybe (CircuitNodeRef, T.Text)
generatedChildSummary = \case
  Aeson.Object obj -> do
    nodeValue <- KeyMap.lookup "generatedChildNode" obj
    labelValue <- KeyMap.lookup "generatedChildLabel" obj
    case (nodeValue, labelValue) of
      (Aeson.String nodeRef, Aeson.String label) -> Just (CircuitNodeRef nodeRef, label)
      _ -> Nothing
  _ -> Nothing

phantomAdapterMatchesIndexedGather :: CircuitNodeRef -> Int -> Aeson.Value -> Bool
phantomAdapterMatchesIndexedGather expectedNode expectedCount = \case
  Aeson.Object obj ->
    KeyMap.lookup "phantomAdapterDirection" obj == Just (Aeson.String "gather")
      && KeyMap.lookup "phantomAdapterNode" obj == Just (Aeson.toJSON expectedNode)
      && case KeyMap.lookup "phantomAdapterProductShape" obj of
        Just (Aeson.Object productShape) ->
          KeyMap.lookup "kind" productShape == Just (Aeson.String "indexed")
            && KeyMap.lookup "count" productShape == Just (Aeson.Number (fromIntegral expectedCount))
        _ -> False
  _ -> False

selectAdmissionMatchesLabelResolution :: CircuitNodeRef -> Set.Set T.Text -> Aeson.Value -> Bool
selectAdmissionMatchesLabelResolution expectedCondition expectedKeys = \case
  Aeson.Object obj ->
    KeyMap.lookup "selectAdmissionOwner" obj == Just (Aeson.toJSON expectedCondition)
      && KeyMap.lookup "selectAdmissionConditionNode" obj == Just (Aeson.toJSON expectedCondition)
      && case KeyMap.lookup "selectAdmissionArms" obj of
        Just (Aeson.Array arms) ->
          let armSummaries = mapMaybe selectArmSummary (Foldable.toList arms)
           in length armSummaries == Foldable.length arms
                && Set.fromList (fmap selectArmKey armSummaries) == expectedKeys
                && all ((== "SelectResolvedByLabel") . selectArmMode) armSummaries
                && Set.fromList (fmap selectArmIndex armSummaries) == Set.fromList [0, 1]
        _ -> False
  _ -> False
  where
    selectArmSummary = \case
      Aeson.Object armObj -> do
        Aeson.String canonicalKey <- KeyMap.lookup "selectArmCanonicalKey" armObj
        Aeson.String resolutionMode <- KeyMap.lookup "selectArmResolutionMode" armObj
        Aeson.Number sourceIndex <- KeyMap.lookup "selectArmSourceIndex" armObj
        case floatingOrInteger sourceIndex :: Either Double Int of
          Right intIndex -> Just (canonicalKey, resolutionMode, intIndex)
          Left _ -> Nothing
      _ -> Nothing

    selectArmKey (key, _, _) = key
    selectArmMode (_, mode, _) = mode
    selectArmIndex (_, _, indexValue) = indexValue

selectAdmissionMatchesResolutionMode :: CircuitNodeRef -> T.Text -> Aeson.Value -> Bool
selectAdmissionMatchesResolutionMode expectedCondition expectedMode = \case
  Aeson.Object obj ->
    KeyMap.lookup "selectAdmissionConditionNode" obj == Just (Aeson.toJSON expectedCondition)
      && case KeyMap.lookup "selectAdmissionArms" obj of
        Just (Aeson.Array arms) ->
          let armSummaries = mapMaybe selectArmModeSummary (Foldable.toList arms)
           in length armSummaries == Foldable.length arms
                && all ((== expectedMode) . snd) armSummaries
                && Set.fromList (fmap fst armSummaries) == Set.fromList [0, 1]
        _ -> False
  _ -> False
  where
    selectArmModeSummary = \case
      Aeson.Object armObj -> do
        Aeson.Number sourceIndex <- KeyMap.lookup "selectArmSourceIndex" armObj
        Aeson.String mode <- KeyMap.lookup "selectArmResolutionMode" armObj
        case floatingOrInteger sourceIndex :: Either Double Int of
          Right intIndex -> Just (intIndex, mode)
          Left _ -> Nothing
      _ -> Nothing

metadataHasPureBindingIn :: Key.Key -> T.Text -> Aeson.Value -> Bool
metadataHasPureBindingIn bindingField bindingName = \case
  Aeson.Object obj ->
    case KeyMap.lookup "config" obj of
      Just (Aeson.Object configObj) ->
        case KeyMap.lookup bindingField configObj of
          Just (Aeson.Array bindings) ->
            any (bindingHasName bindingName) bindings
          _ -> False
      _ -> False
  _ -> False
  where
    bindingHasName expectedName = \case
      Aeson.Object bindingObj ->
        KeyMap.lookup "corePureBindingName" bindingObj == Just (Aeson.String expectedName)
      _ -> False

metadataHasPureOutput :: T.Text -> Aeson.Value -> Bool
metadataHasPureOutput outputName = \case
  Aeson.Object obj ->
    case KeyMap.lookup "config" obj of
      Just (Aeson.Object configObj) ->
        case KeyMap.lookup "outputs" configObj of
          Just (Aeson.Object outputsObj) ->
            KeyMap.member (Key.fromText outputName) outputsObj
          _ -> False
      _ -> False
  _ -> False

metadataPureOutputEquals :: T.Text -> Syntax.CorePureExpr -> Aeson.Value -> Bool
metadataPureOutputEquals outputName expected = \case
  Aeson.Object obj ->
    case KeyMap.lookup "config" obj of
      Just (Aeson.Object configObj) ->
        case KeyMap.lookup "outputs" configObj of
          Just (Aeson.Object outputsObj) ->
            KeyMap.lookup (Key.fromText outputName) outputsObj == Just (Aeson.toJSON expected)
          _ -> False
      _ -> False
  _ -> False

indexedPureExpr :: T.Text -> Scientific -> Syntax.CorePureExpr
indexedPureExpr inputName indexValue =
  Syntax.CorePureIndex
    (Syntax.CorePureIdent inputName)
    (Syntax.CorePureLit (Syntax.CorePureNumber indexValue))

metadataHasInstructions :: T.Text -> Aeson.Value -> Bool
metadataHasInstructions expected = \case
  Aeson.Object obj ->
    KeyMap.lookup "instructions" obj == Just (Aeson.String expected)
  _ -> False

metadataHasExecutorTarget :: T.Text -> Aeson.Value -> Bool
metadataHasExecutorTarget expected = \case
  Aeson.Object obj ->
    case KeyMap.lookup "executor" obj of
      Just (Aeson.Object executorObj) ->
        KeyMap.lookup "target" executorObj == Just (Aeson.String expected)
      _ -> False
  _ -> False

metadataHasInputContract :: T.Text -> T.Text -> Aeson.Value -> Bool
metadataHasInputContract portName contractName = \case
  Aeson.Object obj ->
    case KeyMap.lookup "ports" obj of
      Just (Aeson.Object portsObj) ->
        case KeyMap.lookup "inputs" portsObj of
          Just (Aeson.Array inputs) ->
            any (inputHasContract portName contractName) inputs
          _ -> False
      _ -> False
  _ -> False
  where
    inputHasContract expectedPort expectedContract = \case
      Aeson.Object inputObj ->
        KeyMap.lookup "name" inputObj == Just (Aeson.String expectedPort)
          && case KeyMap.lookup "accepts" inputObj of
            Just (Aeson.Array contracts) -> Aeson.String expectedContract `elem` contracts
            _ -> False
      _ -> False

metadataHasOutputContract :: T.Text -> T.Text -> Aeson.Value -> Bool
metadataHasOutputContract portName contractName = \case
  Aeson.Object obj ->
    case KeyMap.lookup "ports" obj of
      Just (Aeson.Object portsObj) ->
        case KeyMap.lookup "outputs" portsObj of
          Just (Aeson.Array outputs) ->
            any (outputHasContract portName contractName) outputs
          _ -> False
      _ -> False
  _ -> False
  where
    outputHasContract expectedPort expectedContract = \case
      Aeson.Object outputObj ->
        KeyMap.lookup "name" outputObj == Just (Aeson.String expectedPort)
          && KeyMap.lookup "contract" outputObj == Just (Aeson.String expectedContract)
      _ -> False

isRight :: Either err ok -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False

isParseFailure :: Either WireError ok -> Bool
isParseFailure = \case
  Left WireParseError {} -> True
  _ -> False

isWireParseFailureContaining :: T.Text -> Either WireError ok -> Bool
isWireParseFailureContaining expected = \case
  Left (WireParseError message) -> expected `T.isInfixOf` message
  _ -> False

isWireUnusedNodeRef :: CircuitNodeRef -> Either WireError ok -> Bool
isWireUnusedNodeRef expected = \case
  Left (WireUnusedNodeRef nodeRef) -> nodeRef == expected
  _ -> False

isCorePureScopeViolationOf :: T.Text -> Either WireError ok -> Bool
isCorePureScopeViolationOf capturedBinding = \case
  Left (WireInvalidPorts _ message) -> messageMatches message
  Left (WireParseError message) -> messageMatches message
  _ -> False
  where
    messageMatches message =
      ("cannot capture " <> capturedBinding) `T.isInfixOf` message

knownContractsEnv :: WireCompileEnv
knownContractsEnv =
  emptyWireCompileEnv
    { wireCompileEnvContractRegistry =
        Just $
          wireContractRegistryFromList
            [ jsonContract "PlannerOutput"
            , jsonContract "AnalysisFragment"
            , jsonContract "ResearchPlan"
            , jsonContract "PlanIssue"
            , jsonContract "DraftPlan"
            , jsonContract "ReportArtifactRef"
            ]
    }

starContractEnv :: WireCompileEnv
starContractEnv =
  emptyWireCompileEnv
    { wireCompileEnvContractRegistry =
        Just $
          wireContractRegistryFromList
            [ jsonContract "A"
            , jsonContract "B"
            , jsonContract "Done"
            , recordContract "EmptyRecord" []
            , recordContract "Pair" [("a", "A"), ("b", "B")]
            ]
    }

strictExecutorEnv :: WireCompileEnv
strictExecutorEnv =
  emptyWireCompileEnv
    { wireCompileEnvExecutorRegistry =
        wireExecutorRegistryFromList
          [ wireExecutorProjectionFromPorts
              (WireExecutorId "review.projected")
              projectedExecutorPorts
              WireExecutorModel
          , pureWireExecutorProjection
          ]
    , wireCompileEnvProjectionMode = WireProjectionStrict
    }

quantumExecutorEnv :: WireCompileEnv
quantumExecutorEnv =
  emptyWireCompileEnv
    { wireCompileEnvExecutorRegistry =
        wireExecutorRegistryFromList
          [ quantumExecutorProjection "quantum.prepare_zero"
          , quantumExecutorProjection "quantum.h"
          , quantumExecutorProjection "quantum.rz"
          , quantumExecutorProjection "quantum.sx"
          , quantumExecutorProjection "quantum.x"
          , quantumExecutorProjection "quantum.cnot"
          , quantumExecutorProjection "quantum.cz"
          , quantumExecutorProjection "quantum.rzz"
          , quantumExecutorProjection "quantum.measure_z"
          , quantumExecutorProjection "quantum.ibm_runtime_config"
          ]
    , wireCompileEnvProjectionMode = WireProjectionStrict
    }

quantumExecutorProjection :: T.Text -> WireExecutorProjection
quantumExecutorProjection executorId =
  WireExecutorProjection
    { wireExecutorProjectionId = WireExecutorId executorId
    , wireExecutorProjectionPorts = WirePorts Map.empty Map.empty
    , wireExecutorProjectionVocabulary =
        Set.fromList ["Qubit", "Bit", "RotationAngle", "IBMQuantumConfig"]
    , wireExecutorProjectionEffect = WireExecutorHostEffect
    , wireExecutorProjectionConfigShape = WireExecutorConfigUnchecked
    , wireExecutorProjectionPortPolicy = WireExecutorAuthorDeclaredPorts
    }

projectedExecutorPorts :: WirePorts
projectedExecutorPorts =
  WirePorts
    { wirePortsInputs = Map.empty
    , wirePortsOutputs =
        Map.singleton
          "out"
          WireOutputPort {wireOutputPortContract = "PlannerOutput"}
    }

jsonContract :: T.Text -> WireContractSpec
jsonContract contractId =
  WireContractSpec
    { wireContractSpecId = contractId
    , wireContractSpecPayloadKind = WirePayloadJson
    , wireContractSpecDescription = contractId
    , wireContractSpecRecordFields = Nothing
    , wireContractSpecSchema = Nothing
    , wireContractSpecExamples = []
    }

recordContract :: T.Text -> [(T.Text, T.Text)] -> WireContractSpec
recordContract contractId fields =
  (jsonContract contractId)
    { wireContractSpecRecordFields =
        Just (Map.fromList [(label, ContractId fieldContract) | (label, fieldContract) <- fields])
    }
