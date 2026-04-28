module Cortex.Pulse.DIG448Spec (spec) where

import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import GHC.Generics (Generic)
import Test.Hspec

import Cortex.Algebra.Graph
  ( Graph (..)
  , toRelation
  )
import Cortex.Pulse.Executor
  ( RewriteExhaustionPolicy (..)
  , StableStageId (..)
  , StageDefinition (..)
  , StagePlan (..)
  , StageReplaySafety (..)
  , applyRewrite
  , buildStageTemplateRegistry
  , stageActionId
  , stageTemplateId
  )
import Cortex.Pulse.Memory (defaultMemoryStrategy)
import Cortex.Pulse.Node (NodeId (..))
import Cortex.Pulse.Rewrite
  ( ExpansionMode (..)
  , GraphRewrite (..)
  , SubgraphSpec (..)
  )
import Cortex.Pulse.Types (defaultRewriteBudget)

data TestStage = StageA | StageB
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Aeson.FromJSON, Aeson.ToJSON)

instance StableStageId TestStage where
  stageIdToText = \case
    StageA -> "a"
    StageB -> "b"

spec :: Spec
spec = do
  describe "DIG-448: StageTemplateId Uniqueness" $ do
    let mkDef sid tid =
          StageDefinition
            { sdStageId = sid
            , sdTemplateId = tid
            , sdActionId = stageActionId sid
            , sdReplaySafety = SafeToReplay
            , sdReplayPolicyOverride = Nothing
            , sdTimeoutSeconds = Nothing
            , sdRetryPolicy = Nothing
            , sdAction = \_ -> pure (error "not implemented")
            , sdMemoryStrategy = defaultMemoryStrategy
            }
        -- a
        initialTopo = toRelation (Vertex (NodeId "a") :: Graph NodeId)
        initialDefs = Map.fromList [(NodeId "a", mkDef StageA (stageTemplateId StageA))]
        initialPlan =
          StagePlan
            { spInitialState = Aeson.Null
            , spCheckpointRuntimeVersion = 1
            , spReplayPolicy = error "not used"
            , spInitialRewriteBudget = defaultRewriteBudget
            , spRewriteExhaustionPolicy = RewriteExhaustionFail
            , spBudgetExceededExhaustionPolicy = Nothing
            , spMaxRewriteReExecutions = 2
            , spTopology = initialTopo
            , spDefinitions = initialDefs
            , spTemplateRegistry = templateRegistry initialDefs
            }

    it "rejects rewrite if it introduces a conflicting template id" $ do
      -- subgraph inserts "sub1" with the same template id as "a", but different stage id (StageB vs StageA)
      let subTopo = toRelation (Vertex (NodeId "sub1") :: Graph NodeId)
          subDefs = Map.fromList [(NodeId "sub1", mkDef StageB (stageTemplateId StageA))]
          spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub1"]
          rewrite = ExpandNode (NodeId "a") ExpandRetainNodeAsEnvelope spec'

      case applyRewrite rewrite initialPlan of
        Left errs -> show errs `shouldContain` "Duplicate stage template definition found"
        Right _ -> expectationFailure "Should have failed with duplicate template id"

    it "allows rewrite if it introduces an identical template id (idempotent clones)" $ do
      -- subgraph inserts "sub1" with exactly the same template definition as "a"
      let subTopo = toRelation (Vertex (NodeId "sub1") :: Graph NodeId)
          subDefs = Map.fromList [(NodeId "sub1", mkDef StageA (stageTemplateId StageA))]
          spec' = SubgraphSpec subTopo subDefs [NodeId "sub1"] [NodeId "sub1"]
          rewrite = ExpandNode (NodeId "a") ExpandRetainNodeAsEnvelope spec'

      case applyRewrite rewrite initialPlan of
        Left errs -> expectationFailure $ "Should have allowed identical template id, got: " <> show errs
        Right _ -> pure ()
  where
    templateRegistry defs =
      either (error . show) id (buildStageTemplateRegistry defs)
