{-# LANGUAGE TemplateHaskell #-}

{- |
Module      : Platform.Database.Rel8TH
Description : Template Haskell helpers for Rel8 schema generation.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

This module provides Template Haskell utilities to auto-generate Rel8 TableSchema
definitions from record types, eliminating repetitive column name mappings.

The naming convention is: Haskell @fooBarBaz@ maps to SQL @foo_bar_baz@.

Platform modules provide generic runtime substrate utilities and do not import Cortex or consumers.
-}
module Platform.Database.Rel8TH
  ( -- * Schema Generation
    mkRel8Schema

    -- * Naming Utilities
  , camelToSnake

    -- * Validation
  , checkValidCamelCase
  )
where

import Data.Char (isAlphaNum, isDigit, isLower, isUpper, toLower)
import Language.Haskell.TH
import Rel8 (TableSchema (..))

{- | Validate that a field name follows strict camelCase convention.

Rules:
1. Must start with lowercase letter
2. Must be alphanumeric (no underscores, primes, or punctuation)
3. No consecutive uppercase letters (no acronym runs like @HTTPServer@)

Valid: @userId@, @ibkrFee@, @fxRateToBase@, @s3Bucket@, @oauth2Token@
Invalid: @UserId@, @HTTPServer@, @myUUID@, @ibkrFEE@, @foo_bar@, @foo'bar@

Returns @Right ()@ if valid, @Left errorMessage@ if invalid.
-}
checkValidCamelCase :: String -> Either String ()
checkValidCamelCase [] = Left "empty field name"
checkValidCamelCase (c : cs)
  | not (isLower c) = Left "must start with a lowercase letter"
  | not (all isAlphaNum (c : cs)) =
      Left "must be alphanumeric only (no underscores, primes, or punctuation)"
  | otherwise = noUpperRuns cs
  where
    noUpperRuns [] = Right ()
    noUpperRuns [_] = Right ()
    noUpperRuns (x : y : rest)
      | isUpper x && isUpper y =
          Left "consecutive uppercase letters; use 'httpServer' not 'HTTPServer'"
      | otherwise = noUpperRuns (y : rest)

-- | Returns True for lowercase letters or digits
isLowerOrDigit :: Char -> Bool
isLowerOrDigit c = isLower c || isDigit c

{- | Convert camelCase to snake_case.

IMPORTANT: This assumes field names follow the @xxYyyy@ convention (lowercase start,
no all-caps acronym runs). Use @ibkrFee@ not @IBKRFee@, @httpServer@ not @HTTPServer@.

Numbers are treated as lowercase/continuation characters. They do not trigger a split,
but an uppercase letter following a number DOES trigger a split.

Examples:

>>> camelToSnake "tradeId"
"trade_id"

>>> camelToSnake "ibkrFee"
"ibkr_fee"

>>> camelToSnake "s3Bucket"
"s3_bucket"

>>> camelToSnake "oauth2Token"
"oauth2_token"

>>> camelToSnake "x567Data"
"x567_data"
-}
camelToSnake :: String -> String
camelToSnake = go
  where
    go [] = []
    go [c] = [toLower c]
    go (c1 : c2 : cs)
      -- Word boundary: lowercase/digit followed by uppercase
      | isLowerOrDigit c1 && isUpper c2 = toLower c1 : '_' : go (c2 : cs)
      -- Default: emit c1 lowercased
      | otherwise = toLower c1 : go (c2 : cs)

{- | Generate a Rel8 TableSchema for a record type.

Usage:

@
data MyRow f = MyRow
{ rowId :: Column f UUID
, userName :: Column f Text
, createdAt :: Column f UTCTime
}
deriving stock (Generic)
deriving anyclass (Rel8able)

mySchema :: TableSchema (MyRow Name)
mySchema = $(mkRel8Schema "my_table" ''MyRow)
@

This generates:

@
mySchema :: TableSchema (MyRow Name)
mySchema = TableSchema
{ name = "my_table"
, columns = MyRow
   { rowId = "row_id"
   , userName = "user_name"
   , createdAt = "created_at"
   }
}
@
-}
mkRel8Schema :: String -> Name -> Q Exp
mkRel8Schema tableName typeName = do
  info <- reify typeName
  case info of
    TyConI (DataD _ _ _ _ [RecC conName fields] _) ->
      generateSchema tableName conName fields
    TyConI DataD {} ->
      fail $ "mkRel8Schema: " <> show typeName <> " must have exactly one record constructor"
    _ ->
      fail $ "mkRel8Schema: " <> show typeName <> " is not a data type"

generateSchema :: String -> Name -> [(Name, Bang, Type)] -> Q Exp
generateSchema tableName conName fields = do
  -- Validate all field names at compile time
  mapM_ validateField fields
  let fieldExps = fmap mkFieldExp fields
  let columnsExp = recConE conName fieldExps
  [|
    TableSchema
      { name = $(litE (stringL tableName))
      , columns = $columnsExp
      }
    |]
  where
    validateField :: (Name, Bang, Type) -> Q ()
    validateField (fieldName, _, _) =
      case checkValidCamelCase (nameBase fieldName) of
        Right () -> pure ()
        Left err ->
          fail $
            "mkRel8Schema: field '"
              <> nameBase fieldName
              <> "' in table '"
              <> tableName
              <> "': "
              <> err
              <> " (would map to: "
              <> camelToSnake (nameBase fieldName)
              <> ")"

    mkFieldExp :: (Name, Bang, Type) -> Q (Name, Exp)
    mkFieldExp (fieldName, _, _) = do
      let snakeName = camelToSnake (nameBase fieldName)
      exp' <- litE (stringL snakeName)
      pure (fieldName, exp')
