{- |
Module      : Logos.Thought.Frame
Description : Logos reasoning-library support for frame.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The module belongs to Logos' downstream reasoning-library surface.

Logos is layered above the substrate and must not be imported by substrate modules.
-}
module Logos.Thought.Frame
  ( LogosAgentBudget (..)
  , LogosAgentBudgetLimits (..)
  , LogosAgentOverrideConfig (..)
  , LogosAgentProfileConfig (..)
  , LogosResolvedAgentConfig (..)
  , LogosAgentDefinition (..)
  , LogosAgentIdentity (..)
  , combinePromptAppendices
  , emptyLogosAgentBudget
  , emptyLogosAgentOverrideConfig
  , emptyLogosAgentProfileConfig
  , mergeLogosAgentBudget
  , mergeLogosAgentBudgetLayers
  , normalizeLogosAgentBudget
  , normalizeLogosAgentOverrideConfig
  , normalizeLogosAgentProfileConfig
  , validateLogosAgentBudget
  )
where

import Control.Applicative ((<|>))
import Data.Aeson qualified as Aeson
import Data.Maybe (isNothing, maybeToList)
import Data.OpenApi (ToSchema)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Logos.Thought.Policy (LogosAgentPolicy)

import Platform.Text (stripNonEmptyMaybeText)

data LogosAgentBudget = LogosAgentBudget
  { maxToolSteps :: Maybe Int
  , maxAttempts :: Maybe Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema)

data LogosAgentBudgetLimits = LogosAgentBudgetLimits
  { logosMaxToolSteps :: Int
  , logosMaxAttempts :: Int
  }
  deriving stock (Eq, Show, Generic)

data LogosAgentProfileConfig = LogosAgentProfileConfig
  { model :: Maybe Text
  , budget :: Maybe LogosAgentBudget
  , promptAppendix :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema)

data LogosAgentOverrideConfig = LogosAgentOverrideConfig
  { profileId :: Maybe Text
  , model :: Maybe Text
  , budget :: Maybe LogosAgentBudget
  , promptAppendix :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToSchema)

data LogosResolvedAgentConfig = LogosResolvedAgentConfig
  { resolvedSlotId :: Text
  , resolvedProfileId :: Text
  , resolvedExplicitModelOverride :: Bool
  , resolvedModel :: Text
  , resolvedBudget :: LogosAgentBudget
  , resolvedPromptAppendix :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)

data LogosAgentIdentity = LogosAgentIdentity
  { logosAgentId :: Text
  , logosAgentDisplayName :: Text
  }
  deriving stock (Eq, Show)

data LogosAgentDefinition state = LogosAgentDefinition
  { logosAgentIdentity :: LogosAgentIdentity
  , logosAgentDescription :: Maybe Text
  , logosAgentDefaultModelId :: Maybe Text
  , logosAgentInitialState :: state
  , logosAgentPolicy :: LogosAgentPolicy
  }
  deriving stock (Eq, Show)

jsonOptions :: Aeson.Options
jsonOptions =
  Aeson.defaultOptions
    { Aeson.omitNothingFields = True
    }

instance Aeson.ToJSON LogosAgentBudget where
  toJSON = Aeson.genericToJSON jsonOptions

instance Aeson.FromJSON LogosAgentBudget where
  parseJSON = Aeson.genericParseJSON jsonOptions

instance Aeson.ToJSON LogosAgentProfileConfig where
  toJSON = Aeson.genericToJSON jsonOptions

instance Aeson.FromJSON LogosAgentProfileConfig where
  parseJSON = Aeson.genericParseJSON jsonOptions

instance Aeson.ToJSON LogosAgentOverrideConfig where
  toJSON = Aeson.genericToJSON jsonOptions

instance Aeson.FromJSON LogosAgentOverrideConfig where
  parseJSON = Aeson.genericParseJSON jsonOptions

emptyLogosAgentBudget :: LogosAgentBudget
emptyLogosAgentBudget =
  LogosAgentBudget
    { maxToolSteps = Nothing
    , maxAttempts = Nothing
    }

emptyLogosAgentProfileConfig :: LogosAgentProfileConfig
emptyLogosAgentProfileConfig =
  LogosAgentProfileConfig
    { model = Nothing
    , budget = Nothing
    , promptAppendix = Nothing
    }

emptyLogosAgentOverrideConfig :: LogosAgentOverrideConfig
emptyLogosAgentOverrideConfig =
  LogosAgentOverrideConfig
    { profileId = Nothing
    , model = Nothing
    , budget = Nothing
    , promptAppendix = Nothing
    }

mergeLogosAgentBudgetLayers :: [Maybe LogosAgentBudget] -> LogosAgentBudget
mergeLogosAgentBudgetLayers =
  foldl mergeLogosAgentBudget emptyLogosAgentBudget

mergeLogosAgentBudget :: LogosAgentBudget -> Maybe LogosAgentBudget -> LogosAgentBudget
mergeLogosAgentBudget budget Nothing = budget
mergeLogosAgentBudget budget (Just overrideBudget) =
  LogosAgentBudget
    { maxToolSteps = maxToolSteps overrideBudget <|> maxToolSteps budget
    , maxAttempts = maxAttempts overrideBudget <|> maxAttempts budget
    }

normalizeLogosAgentBudget
  :: LogosAgentBudgetLimits -> LogosAgentBudget -> Maybe LogosAgentBudget
normalizeLogosAgentBudget limits rawBudget =
  let normalized =
        LogosAgentBudget
          { maxToolSteps = clampBudgetValue (logosMaxToolSteps limits) =<< maxToolSteps rawBudget
          , maxAttempts = clampBudgetValue (logosMaxAttempts limits) =<< maxAttempts rawBudget
          }
   in if normalized == emptyLogosAgentBudget
        then Nothing
        else Just normalized

normalizeLogosAgentProfileConfig
  :: (Maybe Text -> Maybe Text)
  -> LogosAgentBudgetLimits
  -> LogosAgentProfileConfig
  -> Maybe LogosAgentProfileConfig
normalizeLogosAgentProfileConfig normalizeModel limits rawConfig =
  let LogosAgentProfileConfig
        { model = rawModel
        , budget = rawBudget
        , promptAppendix = rawPromptAppendix
        } = rawConfig
      normalized =
        LogosAgentProfileConfig
          { model = normalizeModel rawModel
          , budget = normalizeLogosAgentBudget limits =<< rawBudget
          , promptAppendix = stripNonEmptyMaybeText rawPromptAppendix
          }
   in if isLogosAgentProfileConfigEmpty normalized
        then Nothing
        else Just normalized

normalizeLogosAgentOverrideConfig
  :: (Maybe Text -> Maybe Text)
  -> LogosAgentBudgetLimits
  -> LogosAgentOverrideConfig
  -> Maybe LogosAgentOverrideConfig
normalizeLogosAgentOverrideConfig normalizeModel limits rawConfig =
  let LogosAgentOverrideConfig
        { profileId = rawProfileId
        , model = rawModel
        , budget = rawBudget
        , promptAppendix = rawPromptAppendix
        } = rawConfig
      normalized =
        LogosAgentOverrideConfig
          { profileId = stripNonEmptyMaybeText rawProfileId
          , model = normalizeModel rawModel
          , budget = normalizeLogosAgentBudget limits =<< rawBudget
          , promptAppendix = stripNonEmptyMaybeText rawPromptAppendix
          }
   in if isLogosAgentOverrideConfigEmpty normalized
        then Nothing
        else Just normalized

validateLogosAgentBudget
  :: Text
  -> LogosAgentBudgetLimits
  -> LogosAgentBudget
  -> Either Text ()
validateLogosAgentBudget prefix limits budget = do
  validateBoundedPositive
    (prefix <> ".maxToolSteps")
    (logosMaxToolSteps limits)
    (maxToolSteps budget)
  validateBoundedPositive (prefix <> ".maxAttempts") (logosMaxAttempts limits) (maxAttempts budget)

combinePromptAppendices :: [Maybe Text] -> Maybe Text
combinePromptAppendices appendices =
  case filter (not . T.null) (fmap T.strip (foldMap maybeToList appendices)) of
    [] -> Nothing
    parts -> Just (T.intercalate "\n\n" parts)

isLogosAgentProfileConfigEmpty :: LogosAgentProfileConfig -> Bool
isLogosAgentProfileConfigEmpty
  LogosAgentProfileConfig
    { model = maybeModel
    , budget = maybeBudget
    , promptAppendix = maybePromptAppendix
    } =
    isNothing maybeModel
      && isNothing maybeBudget
      && isNothing maybePromptAppendix

isLogosAgentOverrideConfigEmpty :: LogosAgentOverrideConfig -> Bool
isLogosAgentOverrideConfigEmpty
  LogosAgentOverrideConfig
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
