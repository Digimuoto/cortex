module Cortex.Nous.Thought.Frame
  ( CortexAgentBudget (..)
  , CortexAgentBudgetLimits (..)
  , CortexAgentOverrideConfig (..)
  , CortexAgentProfileConfig (..)
  , CortexResolvedAgentConfig (..)
  , CortexAgentDefinition (..)
  , CortexAgentIdentity (..)
  , combinePromptAppendices
  , emptyCortexAgentBudget
  , emptyCortexAgentOverrideConfig
  , emptyCortexAgentProfileConfig
  , mergeCortexAgentBudget
  , mergeCortexAgentBudgetLayers
  , normalizeCortexAgentBudget
  , normalizeCortexAgentOverrideConfig
  , normalizeCortexAgentProfileConfig
  , validateCortexAgentBudget
  )
where

import Control.Applicative ((<|>))
import Data.Aeson qualified as Aeson
import Data.Maybe (isNothing, maybeToList)
import Data.OpenApi (ToSchema)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

import Cortex.Nous.Thought.Policy (CortexAgentPolicy)

import Platform.Text (stripNonEmptyMaybeText)

data CortexAgentBudget = CortexAgentBudget
  { maxToolSteps :: Maybe Int
  , maxAttempts :: Maybe Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema)

data CortexAgentBudgetLimits = CortexAgentBudgetLimits
  { cortexMaxToolSteps :: Int
  , cortexMaxAttempts :: Int
  }
  deriving stock (Eq, Show, Generic)

data CortexAgentProfileConfig = CortexAgentProfileConfig
  { model :: Maybe Text
  , budget :: Maybe CortexAgentBudget
  , promptAppendix :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema)

data CortexAgentOverrideConfig = CortexAgentOverrideConfig
  { profileId :: Maybe Text
  , model :: Maybe Text
  , budget :: Maybe CortexAgentBudget
  , promptAppendix :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema)

data CortexResolvedAgentConfig = CortexResolvedAgentConfig
  { resolvedSlotId :: Text
  , resolvedProfileId :: Text
  , resolvedExplicitModelOverride :: Bool
  , resolvedModel :: Text
  , resolvedBudget :: CortexAgentBudget
  , resolvedPromptAppendix :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

data CortexAgentIdentity = CortexAgentIdentity
  { cortexAgentId :: Text
  , cortexAgentDisplayName :: Text
  }
  deriving stock (Eq, Show)

data CortexAgentDefinition state = CortexAgentDefinition
  { cortexAgentIdentity :: CortexAgentIdentity
  , cortexAgentDescription :: Maybe Text
  , cortexAgentDefaultModelId :: Maybe Text
  , cortexAgentInitialState :: state
  , cortexAgentPolicy :: CortexAgentPolicy
  }
  deriving stock (Eq, Show)

jsonOptions :: Aeson.Options
jsonOptions =
  Aeson.defaultOptions
    { Aeson.omitNothingFields = True
    }

instance Aeson.ToJSON CortexAgentBudget where
  toJSON = Aeson.genericToJSON jsonOptions

instance Aeson.FromJSON CortexAgentBudget where
  parseJSON = Aeson.genericParseJSON jsonOptions

instance Aeson.ToJSON CortexAgentProfileConfig where
  toJSON = Aeson.genericToJSON jsonOptions

instance Aeson.FromJSON CortexAgentProfileConfig where
  parseJSON = Aeson.genericParseJSON jsonOptions

instance Aeson.ToJSON CortexAgentOverrideConfig where
  toJSON = Aeson.genericToJSON jsonOptions

instance Aeson.FromJSON CortexAgentOverrideConfig where
  parseJSON = Aeson.genericParseJSON jsonOptions

emptyCortexAgentBudget :: CortexAgentBudget
emptyCortexAgentBudget =
  CortexAgentBudget
    { maxToolSteps = Nothing
    , maxAttempts = Nothing
    }

emptyCortexAgentProfileConfig :: CortexAgentProfileConfig
emptyCortexAgentProfileConfig =
  CortexAgentProfileConfig
    { model = Nothing
    , budget = Nothing
    , promptAppendix = Nothing
    }

emptyCortexAgentOverrideConfig :: CortexAgentOverrideConfig
emptyCortexAgentOverrideConfig =
  CortexAgentOverrideConfig
    { profileId = Nothing
    , model = Nothing
    , budget = Nothing
    , promptAppendix = Nothing
    }

mergeCortexAgentBudgetLayers :: [Maybe CortexAgentBudget] -> CortexAgentBudget
mergeCortexAgentBudgetLayers =
  foldl mergeCortexAgentBudget emptyCortexAgentBudget

mergeCortexAgentBudget :: CortexAgentBudget -> Maybe CortexAgentBudget -> CortexAgentBudget
mergeCortexAgentBudget budget Nothing = budget
mergeCortexAgentBudget budget (Just overrideBudget) =
  CortexAgentBudget
    { maxToolSteps = maxToolSteps overrideBudget <|> maxToolSteps budget
    , maxAttempts = maxAttempts overrideBudget <|> maxAttempts budget
    }

normalizeCortexAgentBudget
  :: CortexAgentBudgetLimits -> CortexAgentBudget -> Maybe CortexAgentBudget
normalizeCortexAgentBudget limits rawBudget =
  let normalized =
        CortexAgentBudget
          { maxToolSteps = clampBudgetValue (cortexMaxToolSteps limits) =<< maxToolSteps rawBudget
          , maxAttempts = clampBudgetValue (cortexMaxAttempts limits) =<< maxAttempts rawBudget
          }
   in if normalized == emptyCortexAgentBudget
        then Nothing
        else Just normalized

normalizeCortexAgentProfileConfig
  :: (Maybe Text -> Maybe Text)
  -> CortexAgentBudgetLimits
  -> CortexAgentProfileConfig
  -> Maybe CortexAgentProfileConfig
normalizeCortexAgentProfileConfig normalizeModel limits rawConfig =
  let CortexAgentProfileConfig
        { model = rawModel
        , budget = rawBudget
        , promptAppendix = rawPromptAppendix
        } = rawConfig
      normalized =
        CortexAgentProfileConfig
          { model = normalizeModel rawModel
          , budget = normalizeCortexAgentBudget limits =<< rawBudget
          , promptAppendix = stripNonEmptyMaybeText rawPromptAppendix
          }
   in if isCortexAgentProfileConfigEmpty normalized
        then Nothing
        else Just normalized

normalizeCortexAgentOverrideConfig
  :: (Maybe Text -> Maybe Text)
  -> CortexAgentBudgetLimits
  -> CortexAgentOverrideConfig
  -> Maybe CortexAgentOverrideConfig
normalizeCortexAgentOverrideConfig normalizeModel limits rawConfig =
  let CortexAgentOverrideConfig
        { profileId = rawProfileId
        , model = rawModel
        , budget = rawBudget
        , promptAppendix = rawPromptAppendix
        } = rawConfig
      normalized =
        CortexAgentOverrideConfig
          { profileId = stripNonEmptyMaybeText rawProfileId
          , model = normalizeModel rawModel
          , budget = normalizeCortexAgentBudget limits =<< rawBudget
          , promptAppendix = stripNonEmptyMaybeText rawPromptAppendix
          }
   in if isCortexAgentOverrideConfigEmpty normalized
        then Nothing
        else Just normalized

validateCortexAgentBudget
  :: Text
  -> CortexAgentBudgetLimits
  -> CortexAgentBudget
  -> Either Text ()
validateCortexAgentBudget prefix limits budget = do
  validateBoundedPositive
    (prefix <> ".maxToolSteps")
    (cortexMaxToolSteps limits)
    (maxToolSteps budget)
  validateBoundedPositive (prefix <> ".maxAttempts") (cortexMaxAttempts limits) (maxAttempts budget)

combinePromptAppendices :: [Maybe Text] -> Maybe Text
combinePromptAppendices appendices =
  case filter (not . T.null) (fmap T.strip (foldMap maybeToList appendices)) of
    [] -> Nothing
    parts -> Just (T.intercalate "\n\n" parts)

isCortexAgentProfileConfigEmpty :: CortexAgentProfileConfig -> Bool
isCortexAgentProfileConfigEmpty
  CortexAgentProfileConfig
    { model = maybeModel
    , budget = maybeBudget
    , promptAppendix = maybePromptAppendix
    } =
    isNothing maybeModel
      && isNothing maybeBudget
      && isNothing maybePromptAppendix

isCortexAgentOverrideConfigEmpty :: CortexAgentOverrideConfig -> Bool
isCortexAgentOverrideConfigEmpty
  CortexAgentOverrideConfig
    { profileId = maybeProfileId
    , model = maybeModel
    , budget = maybeBudget
    , promptAppendix = maybePromptAppendix
    } =
    isNothing maybeProfileId
      && isNothing maybeModel
      && isNothing maybeBudget
      && isNothing maybePromptAppendix

validateBoundedPositive :: Text -> Int -> Maybe Int -> Either Text ()
validateBoundedPositive _ _ Nothing = Right ()
validateBoundedPositive fieldName maxValue (Just value)
  | value <= 0 = Left (fieldName <> " must be greater than zero")
  | value > maxValue = Left (fieldName <> " must be less than or equal to " <> T.pack (show maxValue))
  | otherwise = Right ()

clampBudgetValue :: Int -> Int -> Maybe Int
clampBudgetValue maxValue value
  | value <= 0 = Nothing
  | otherwise = Just (min maxValue value)
