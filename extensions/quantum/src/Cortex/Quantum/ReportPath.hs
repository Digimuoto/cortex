{- |
Module      : Cortex.Quantum.ReportPath
Description : Report output path naming for quantum extension runners.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Report files are named by the runner, not by the caller. The caller supplies an
output directory; the runner supplies the completion timestamp, experiment slug,
and resolved hardware slug so repeated hardware runs cannot accidentally reuse a
stale filename.
-}
module Cortex.Quantum.ReportPath
  ( hardwareSlug
  , qecRepetitionReportPath
  , reportFileName
  , slugify
  )
where

import Data.Char (toLower)
import Data.Text (Text)
import Data.Text qualified as T
import System.FilePath (takeExtension, (</>))

qecRepetitionExperiment :: Text
qecRepetitionExperiment = "qec-repetition"

qecRepetitionReportPath :: String -> Text -> FilePath -> Either Text FilePath
qecRepetitionReportPath stamp deviceArn outputDir
  | null outputDir = Left "--output expects a directory"
  | isMarkdownPath outputDir = Left "--output expects a directory, not a filename"
  | otherwise =
      Right (outputDir </> reportFileName stamp qecRepetitionExperiment (hardwareSlug deviceArn))

reportFileName :: String -> Text -> Text -> FilePath
reportFileName stamp experiment hardware =
  stamp
    <> "-"
    <> T.unpack (slugify experiment)
    <> "-"
    <> T.unpack (slugify hardware)
    <> ".md"

hardwareSlug :: Text -> Text
hardwareSlug arn =
  slugify $
    case deviceSegments arn of
      "qpu" : provider : name : _ -> provider <> "-" <> name
      "quantum-simulator" : provider : name : _ -> provider <> "-" <> name
      segments ->
        case reverse segments of
          name : provider : _ -> provider <> "-" <> name
          name : _ -> name
          [] -> arn

deviceSegments :: Text -> [Text]
deviceSegments arn =
  let marker = "device/"
      (_prefix, suffix) = T.breakOn marker arn
      path =
        if T.null suffix
          then arn
          else T.drop (T.length marker) suffix
   in filter (not . T.null) (T.splitOn "/" path)

slugify :: Text -> Text
slugify text =
  case collapseDashes (T.map slugChar (T.toLower text)) of
    "" -> "unknown"
    slug -> slug
  where
    slugChar c
      | isAsciiLower c || isAsciiDigit c = c
      | otherwise = '-'

    isAsciiLower c = c >= 'a' && c <= 'z'
    isAsciiDigit c = c >= '0' && c <= '9'

collapseDashes :: Text -> Text
collapseDashes =
  T.intercalate "-" . filter (not . T.null) . T.split (== '-')

isMarkdownPath :: FilePath -> Bool
isMarkdownPath path =
  fmap toLower (takeExtension path) == ".md"
