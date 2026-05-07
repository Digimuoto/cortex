{- |
Module      : Cortex.Wire.Include
Description : Compile-time Wire source include expansion.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Rust-style include forms are evaluated before parsing a Wire source file. They
are source-elaboration inputs, not runtime CorePure builtins: a missing file or
directory is a compile-time failure, and the expanded source embeds ordinary
CorePure literals.
-}
module Cortex.Wire.Include
  ( expandWireSourceIncludes
  , wireSourceIncludeNames
  )
where

import Control.Exception (IOException, try)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Char qualified as Char
import Data.List qualified as List
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath
  ( dropExtension
  , isAbsolute
  , normalise
  , takeDirectory
  , takeExtension
  , (</>)
  )

data IncludeKind
  = IncludeString
  | IncludeDirectory
  deriving stock (Eq, Show)

wireSourceIncludeNames :: [Text]
wireSourceIncludeNames =
  fmap fst wireSourceIncludeForms

wireSourceIncludeForms :: [(Text, IncludeKind)]
wireSourceIncludeForms =
  [ ("include_str", IncludeString)
  , ("includeStr", IncludeString)
  , ("include_dir", IncludeDirectory)
  , ("includeDir", IncludeDirectory)
  ]

expandWireSourceIncludes :: FilePath -> Text -> IO (Either Text Text)
expandWireSourceIncludes sourcePath sourceText =
  try @IOException (expandSourceText baseDir sourceText) >>= \case
    Left err -> pure (Left (T.pack (show err)))
    Right expanded -> pure (Right expanded)
  where
    baseDir = takeDirectory sourcePath

expandSourceText :: FilePath -> Text -> IO Text
expandSourceText baseDir sourceText =
  case T.uncons sourceText of
    Nothing ->
      pure ""
    Just ('#', _) ->
      copyPrefixThrough "\n" baseDir sourceText
    Just ('"', _) ->
      copyWireString baseDir sourceText
    Just ('/', _)
      | "/*" `T.isPrefixOf` sourceText ->
          copyPrefixThrough "*/" baseDir sourceText
    Just ('\'', _)
      | "''" `T.isPrefixOf` sourceText ->
          copyPrefixThrough "''" baseDir (T.drop 2 sourceText)
            >>= \rest -> pure ("''" <> rest)
    _ ->
      case parseIncludeCall sourceText of
        Just (kind, pathText, rest) -> do
          replacement <- expandIncludeCall baseDir kind pathText
          (replacement <>) <$> expandSourceText baseDir rest
        Nothing ->
          let (headText, tailText) = T.splitAt 1 sourceText
           in (headText <>) <$> expandSourceText baseDir tailText

copyWireString :: FilePath -> Text -> IO Text
copyWireString baseDir sourceText =
  let (stringText, rest) = spanWireString sourceText
   in (stringText <>) <$> expandSourceText baseDir rest

spanWireString :: Text -> (Text, Text)
spanWireString sourceText =
  let go escaped consumed remaining =
        case T.uncons remaining of
          Nothing ->
            (T.reverse consumed, "")
          Just (charValue, rest)
            | escaped ->
                go False (T.cons charValue consumed) rest
            | charValue == '\\' ->
                go True (T.cons charValue consumed) rest
            | charValue == '"' ->
                (T.reverse (T.cons charValue consumed), rest)
            | otherwise ->
                go False (T.cons charValue consumed) rest
   in go False "" sourceText

copyPrefixThrough :: Text -> FilePath -> Text -> IO Text
copyPrefixThrough marker baseDir sourceText =
  case T.breakOn marker sourceText of
    (prefix, rest)
      | T.null rest ->
          pure prefix
      | otherwise -> do
          let copied = prefix <> marker
              remaining = T.drop (T.length marker) rest
          (copied <>) <$> expandSourceText baseDir remaining

parseIncludeCall :: Text -> Maybe (IncludeKind, Text, Text)
parseIncludeCall sourceText =
  firstJust (fmap (uncurry parseNamedInclude) wireSourceIncludeForms)
  where
    parseNamedInclude name kind
      | name `T.isPrefixOf` sourceText
      , not (identifierContinuationAfter name) = do
          afterOpen <- consumeOpenParen (T.drop (T.length name) sourceText)
          (pathText, afterString) <- parseStringArgument afterOpen
          rest <- consumeCloseParen afterString
          Just (kind, pathText, rest)
      | otherwise =
          Nothing

    identifierContinuationAfter name =
      case T.uncons (T.drop (T.length name) sourceText) of
        Just (charValue, _) -> Char.isAlphaNum charValue || charValue == '_'
        Nothing -> False

firstJust :: [Maybe a] -> Maybe a
firstJust = \case
  [] -> Nothing
  Just value : _ -> Just value
  Nothing : rest -> firstJust rest

consumeOpenParen :: Text -> Maybe Text
consumeOpenParen text =
  case T.uncons (T.dropWhile Char.isSpace text) of
    Just ('(', rest) -> Just (T.dropWhile Char.isSpace rest)
    _ -> Nothing

consumeCloseParen :: Text -> Maybe Text
consumeCloseParen text =
  case T.uncons (T.dropWhile Char.isSpace text) of
    Just (')', rest) -> Just rest
    _ -> Nothing

parseStringArgument :: Text -> Maybe (Text, Text)
parseStringArgument text =
  case T.uncons text of
    Just ('"', rest) ->
      parseChars False "" rest
    _ ->
      Nothing
  where
    parseChars escaped acc remaining =
      case T.uncons remaining of
        Nothing ->
          Nothing
        Just (charValue, rest)
          | escaped ->
              parseEscaped charValue rest acc
          | charValue == '\\' ->
              parseChars True acc rest
          | charValue == '"' ->
              Just (T.reverse acc, rest)
          | otherwise ->
              parseChars False (T.cons charValue acc) rest

    parseEscaped charValue rest acc =
      let decoded =
            case charValue of
              'n' -> '\n'
              't' -> '\t'
              '"' -> '"'
              '\\' -> '\\'
              other -> other
       in parseChars False (T.cons decoded acc) rest

expandIncludeCall :: FilePath -> IncludeKind -> Text -> IO Text
expandIncludeCall baseDir kind pathText =
  case kind of
    IncludeString ->
      includeString baseDir pathText
    IncludeDirectory ->
      includeDirectory baseDir pathText

includeString :: FilePath -> Text -> IO Text
includeString baseDir pathText = do
  let path = resolveIncludePath baseDir pathText
  exists <- doesFileExist path
  if exists
    then wireStringLiteral <$> TIO.readFile path
    else fail ("include_str file does not exist: " <> path)

includeDirectory :: FilePath -> Text -> IO Text
includeDirectory baseDir pathText = do
  let directory = resolveIncludePath baseDir pathText
  exists <- doesDirectoryExist directory
  if exists
    then do
      names <- List.sort <$> listDirectory directory
      entries <- traverse (directoryEntry pathText directory) names
      pure ("[" <> T.intercalate ", " entries <> "]")
    else fail ("include_dir directory does not exist: " <> directory)

directoryEntry :: Text -> FilePath -> FilePath -> IO Text
directoryEntry includePath directory name = do
  let fullPath = directory </> name
      relativePath = slashPath (T.unpack includePath </> name)
      extension = T.pack (takeExtension name)
      stem = T.pack (dropExtension name)
      label = sanitizeLabel stem
  fileExists <- doesFileExist fullPath
  directoryExists <- doesDirectoryExist fullPath
  let kind
        | directoryExists = "directory" :: Text
        | fileExists = "file"
        | otherwise = "other"
  pure $
    "{ "
      <> "name = "
      <> wireStringLiteral (T.pack name)
      <> "; path = "
      <> wireStringLiteral (T.pack relativePath)
      <> "; stem = "
      <> wireStringLiteral stem
      <> "; extension = "
      <> wireStringLiteral extension
      <> "; label = "
      <> wireStringLiteral label
      <> "; entryType = "
      <> wireStringLiteral kind
      <> "; }"

resolveIncludePath :: FilePath -> Text -> FilePath
resolveIncludePath baseDir pathText =
  let path = T.unpack pathText
   in normalise $
        if isAbsolute path
          then path
          else baseDir </> path

slashPath :: FilePath -> FilePath
slashPath =
  fmap (\charValue -> if charValue == '\\' then '/' else charValue) . normalise

sanitizeLabel :: Text -> Text
sanitizeLabel text =
  let mapped =
        T.map
          ( \charValue ->
              if Char.isAlphaNum charValue || charValue == '_'
                then charValue
                else '_'
          )
          text
      stripped = T.dropWhile (== '_') mapped
   in case T.uncons stripped of
        Just (firstChar, _)
          | Char.isAlpha firstChar || firstChar == '_' ->
              stripped
        _ ->
          "item_" <> stripped

wireStringLiteral :: Text -> Text
wireStringLiteral =
  TE.decodeUtf8 . BSL.toStrict . Aeson.encode
