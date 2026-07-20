{- |
Module      : Cortex.Wire.NativePure.Lean
Description : Render normalized NativePure plans as checked Lean compiler modules.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

The Haskell compiler owns Wire elaboration, strict-registry admission, region
fusion, and typed ANF.  This module is the narrow production hand-off to the
Lean-owned certified kernel and structured C emitter.  It does not render C:
it renders intrinsically typed Lean terms from a validated 'NativePurePlan'.
Lean then checks the terms and derives region and engine artifacts.
-}
module Cortex.Wire.NativePure.Lean
  ( NativePureLeanError (..)
  , renderNativePureLeanError
  , renderNativePurePlanModule
  )
where

import Control.Monad (unless, when)
import Data.ByteString qualified as BS
import Data.Char (isAscii, isAsciiLower, isAsciiUpper, isDigit)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Cortex.Wire.Circuit.IR (CircuitNodeRef (..))
import Cortex.Wire.NativePure.Admission (NativePureBounds (..))
import Cortex.Wire.NativePure.Artifact
  ( NativePureAnfBinding (..)
  , NativePureAnfBlock (..)
  , NativePureAnfOp (..)
  , NativePureArtifactError
  , NativePureFusedRegion (..)
  , NativePureNormalizedInput
  , NativePurePlan (..)
  , NativePureRegionBoundary (..)
  , NativePureRegionOutput (..)
  , NativePureRegionSumBoundary (..)
  , NativePureSsaEquation (..)
  , NativePureSsaStep (..)
  , NativePureSsaValueRef (..)
  , renderNativePureArtifactError
  , validateNativePurePlan
  )
import Cortex.Wire.NativePure.Shape
  ( NativeLayout (..)
  , NativeShape (..)
  , NativeShapeError
  , nativeShapeLayout
  , renderNativeShapeError
  )
import Cortex.Wire.Syntax
  ( CorePureBinOp (..)
  , CorePureLiteral (..)
  , EndpointRef (..)
  )

data NativePureLeanError
  = NativePureLeanInvalidPlan !NativePureArtifactError
  | NativePureLeanInvalidModuleName !Text
  | NativePureLeanUnknownValue !NativePureSsaValueRef
  | NativePureLeanShapeMismatch !NativePureSsaValueRef !NativeShape !NativeShape
  | NativePureLeanInvalidOperation !Text
  | NativePureLeanShapeError !NativeShapeError
  deriving stock (Eq, Show)

renderNativePureLeanError :: NativePureLeanError -> Text
renderNativePureLeanError = \case
  NativePureLeanInvalidPlan err -> renderNativePureArtifactError err
  NativePureLeanInvalidModuleName name -> "invalid generated Lean module name: " <> name
  NativePureLeanUnknownValue valueRef ->
    "NativePure Lean lowering cannot resolve SSA value " <> valueRef.unNativePureSsaValueRef
  NativePureLeanShapeMismatch valueRef actual expected ->
    "NativePure Lean lowering found shape "
      <> T.pack (show actual)
      <> " for "
      <> valueRef.unNativePureSsaValueRef
      <> ", expected "
      <> T.pack (show expected)
  NativePureLeanInvalidOperation reason -> "NativePure Lean lowering rejected operation: " <> reason
  NativePureLeanShapeError err -> renderNativeShapeError err

type LeanEnv = [(NativePureSsaValueRef, NativeShape)]

data RegionOutput = RegionOutput
  { regionOutputLabel :: !Text
  , regionOutputValue :: !NativePureSsaValueRef
  , regionOutputShape :: !NativeShape
  }

data RenderedRegion = RenderedRegion
  { renderedRegionDefinitions :: ![Text]
  , renderedRegionArtifactName :: !Text
  , renderedRegionDispatchName :: !Text
  }

renderNativePurePlanModule
  :: Text
  -> NativePureNormalizedInput
  -> NativePurePlan
  -> Either NativePureLeanError Text
renderNativePurePlanModule moduleName normalized plan = do
  unless (validModuleName moduleName) (Left (NativePureLeanInvalidModuleName moduleName))
  either (Left . NativePureLeanInvalidPlan) pure (validateNativePurePlan normalized plan)
  rendered <- traverse (uncurry renderRegion) (zip [0 :: Int ..] plan.nativePurePlanRegions)
  let namespaceName = T.replace "." "_" moduleName
      engineRegions =
        [ "        { unitId := "
            <> tshow index
            <> ", dispatchName := "
            <> leanString region.renderedRegionDispatchName
            <> " }"
        | (index, region) <- zip [0 :: Int ..] rendered
        ]
      renderedArtifacts = fmap (.renderedRegionArtifactName) rendered
      artifactWrites =
        [ "  writeArtifacts directory "
            <> leanString ("native_pure_region_" <> T.justifyRight 4 '0' (tshow index))
            <> " "
            <> region.renderedRegionArtifactName
        | (index, region) <- zip [0 :: Int ..] rendered
        ]
      engineStem = "cortex_np_engine_" <> T.take 16 plan.nativePurePlanDigest
  pure . T.unlines $
    [ "import Cortex.Wire.NativePure.C.Engine"
    , ""
    , "/-!"
    , "Generated from `cortex.wire.native-pure-plan/v1` by"
    , "`Cortex.Wire.NativePure.Lean`. The Haskell compiler owns the normalized"
    , "plan; Lean checks these intrinsically typed terms before C rendering."
    , "Plan digest: `" <> plan.nativePurePlanDigest <> "`."
    , "GENERATED FILE - do not edit by hand."
    , "-/"
    , ""
    , "namespace Cortex.Wire.NativePure.Generated"
    , "namespace " <> namespaceName
    , ""
    , "open Cortex.Wire.NativePure"
    , "open Cortex.Wire.NativePure.C"
    , ""
    , "private def checkedI64 (value : Int) (valid : (I64.checked value).isSome = true) : I64 :="
    , "  (I64.checked value).get (by simpa [Option.isSome_iff_exists] using valid)"
    , ""
    ]
      <> concatMap ((<> [""]) . (.renderedRegionDefinitions)) rendered
      <> [ "def engineProgram : Engine.Program :="
         , "  { identity := " <> leanString plan.nativePurePlanProgramIdentity
         , "  , planDigest := " <> leanString plan.nativePurePlanDigest
         , "  , regions :="
         , if null engineRegions
             then "      []"
             else "      [\n" <> T.intercalate ",\n" engineRegions <> "\n      ]"
         , "  }"
         , ""
         , "private def engineRenderedResult := Engine.render engineProgram"
         , "#guard engineRenderedResult.toOption.isSome"
         , ""
         , "def engineRendered : Cortex.Wire.C11.RenderedArtifacts :="
         , "  engineRenderedResult.toOption.get (by native_decide)"
         , ""
         , "def regionArtifacts : List Cortex.Wire.C11.RenderedArtifacts :="
         , "  [" <> T.intercalate ", " renderedArtifacts <> "]"
         , ""
         , "private def writeArtifacts"
         , "    (directory stem : String) (artifacts : Cortex.Wire.C11.RenderedArtifacts) : IO Unit := do"
         , "  IO.FS.writeFile (directory ++ \"/\" ++ stem ++ \".c\") artifacts.source"
         , "  IO.FS.writeFile (directory ++ \"/\" ++ stem ++ \".h\") artifacts.header"
         , "  IO.FS.writeFile (directory ++ \"/\" ++ stem ++ \".exports.txt\") artifacts.exports"
         , "  IO.FS.writeFile (directory ++ \"/\" ++ stem ++ \".manifest.json\") artifacts.manifest"
         , ""
         , "def writeAllArtifacts (directory : String) : IO Unit := do"
         , "  IO.FS.createDirAll directory"
         ]
      <> artifactWrites
      <> [ "  writeArtifacts directory " <> leanString engineStem <> " engineRendered"
         , ""
         , "end " <> namespaceName
         , "end Cortex.Wire.NativePure.Generated"
         ]
renderRegion :: Int -> NativePureFusedRegion -> Either NativePureLeanError RenderedRegion
renderRegion index region = do
  let baseName = "native_pure_region_" <> T.justifyRight 4 '0' (tshow index)
      bodyName = baseName <> "Body"
      kernelName = baseName <> "Kernel"
      regionName = baseName <> "Region"
      resultName = baseName <> "RenderedResult"
      artifactName = baseName <> "Rendered"
      dispatchName = baseName <> "_dispatch"
      inputEntries =
        [ ( boundaryRef region.nativePureFusedRegionRef boundary.nativePureRegionBoundaryEndpoint
          , boundary.nativePureRegionBoundaryShape
          )
        | boundary <- region.nativePureFusedRegionInputs
        ]
      outputs = regionOutputs region
  (outputShape, outputExpr) <-
    renderFinalOutput inputEntries (regionBindings region) outputs
  outputLayout <- either (Left . NativePureLeanShapeError) pure (nativeShapeLayout outputShape)
  let bindings = regionBindings region
      bounds = region.nativePureFusedRegionBounds
      checkpointBytes = bounds.nativePureBoundCheckpointBytes
      outputBytes = bounds.nativePureBoundOutputBytes
  renderedBody <- renderBindings inputEntries bindings outputExpr
  let inputTypes = "[" <> T.intercalate ", " (fmap (renderTy . snd) inputEntries) <> "]"
      inputLabels =
        "["
          <> T.intercalate
            ", "
            [ leanString (inputBoundaryLabel inputIndex)
            | inputIndex <- [0 .. length region.nativePureFusedRegionInputs - 1]
            ]
          <> "]"
      inputRegions =
        [ renderMemoryRegion
            ("input." <> tshow inputIndex)
            ".read"
            boundary.nativePureRegionBoundaryLayout
        | (inputIndex, boundary) <- zip [0 :: Int ..] region.nativePureFusedRegionInputs
        ]
      outputRegion = renderMemoryRegion "output.value" ".write" outputLayout
      memoryRegions = inputRegions <> [outputRegion]
      sourceName = T.intercalate "+" (fmap (.unCircuitNodeRef) region.nativePureFusedRegionSources)
      inputWellFormedTactic = renderWellFormedTactic (fmap snd inputEntries)
      outputWellFormedTactic = renderWellFormedTactic [outputShape]
      definitions =
        [ "private def " <> bodyName <> " : Expr " <> inputTypes <> " " <> renderTy outputShape <> " :="
        , indent 2 renderedBody
        , ""
        , "private def " <> kernelName <> " : CertifiedKernel :="
        , "  { sourceNode := " <> leanString sourceName
        , "  , inputs := " <> inputTypes
        , "  , output := " <> renderTy outputShape
        , "  , body := " <> bodyName
        , "  , bounds :="
        , "      { stackBytes := " <> tshow bounds.nativePureBoundStackBytes
        , "      , staticBytes := " <> tshow bounds.nativePureBoundStaticBytes
        , "      , outputBytes := " <> tshow outputBytes
        , "      , checkpointBytes := " <> tshow checkpointBytes
        , "      , maxSteps := " <> tshow bounds.nativePureBoundSteps
        , "      , checkpointWithinHostedCeiling := by native_decide"
        , "      }"
        , "  , regions :="
        , "      [ " <> T.intercalate "\n      , " memoryRegions
        , "      ]"
        , "  , regionsWellFormed := by simp [RegionsWellFormed] <;> native_decide"
        , "  , inputsWellFormed := by"
        , "      " <> inputWellFormedTactic
        , "  , outputWellFormed := by"
        , "      " <> outputWellFormedTactic
        , "  , stepsSound := by native_decide"
        , "  , outputSound := by native_decide"
        , "  }"
        , ""
        , "private def " <> regionName <> " : C.Region :="
        , "  { name := " <> leanString baseName
        , "  , inputLabels := " <> inputLabels
        , "  , kernel := " <> kernelName
        , "  }"
        , ""
        , "private def " <> resultName <> " :="
        , "  C.renderDispatchable "
            <> leanString region.nativePureFusedRegionRef
            <> " "
            <> regionName
        , "#guard " <> resultName <> ".toOption.isSome"
        , ""
        , "def " <> artifactName <> " : Cortex.Wire.C11.RenderedArtifacts :="
        , "  " <> resultName <> ".toOption.get (by native_decide)"
        ]
  pure
    RenderedRegion
      { renderedRegionDefinitions = definitions
      , renderedRegionArtifactName = artifactName
      , renderedRegionDispatchName = dispatchName
      }
  where
    inputBoundaryLabel inputIndex = "input_" <> T.justifyRight 4 '0' (tshow inputIndex)

renderMemoryRegion :: Text -> Text -> NativeLayout -> Text
renderMemoryRegion name access layout =
  "{ name := "
    <> leanString name
    <> ", access := "
    <> access
    <> ", capacity := "
    <> tshow layout.nativeLayoutSize
    <> ", alignment := "
    <> tshow layout.nativeLayoutAlignment
    <> " }"

regionBindings :: NativePureFusedRegion -> [NativePureAnfBinding]
regionBindings region =
  concatMap
    ( \step ->
        step.nativePureSsaStepPrelude
          <> concatMap
            ( \equation ->
                equation.nativePureSsaEquationAnf.nativePureAnfBlockBindings
                  <> [ NativePureAnfBinding
                         equation.nativePureSsaEquationValue
                         equation.nativePureSsaEquationShape
                         (NativePureAnfAlias equation.nativePureSsaEquationAnf.nativePureAnfBlockResult)
                     | equation.nativePureSsaEquationAnf.nativePureAnfBlockResult
                         /= equation.nativePureSsaEquationValue
                     ]
            )
            step.nativePureSsaStepEquations
    )
    region.nativePureFusedRegionSsa

regionOutputs :: NativePureFusedRegion -> [RegionOutput]
regionOutputs region =
  zipWith toOutput [0 :: Int ..] region.nativePureFusedRegionOutputs
  where
    toOutput outputIndex = \case
      NativePureRegionProductField boundary ->
        let endpoint = boundary.nativePureRegionBoundaryEndpoint
            label = fromMaybe "_" endpoint.endpointPortName
         in RegionOutput
              ("output_" <> T.justifyRight 4 '0' (tshow outputIndex))
              (NativePureSsaValueRef (endpoint.endpointNodeRef.unCircuitNodeRef <> ".output." <> label))
              boundary.nativePureRegionBoundaryShape
      NativePureRegionExclusiveSum boundary ->
        RegionOutput
          ("output_" <> T.justifyRight 4 '0' (tshow outputIndex))
          ( NativePureSsaValueRef
              (boundary.nativePureRegionSumSource.unCircuitNodeRef <> ".output.__variant")
          )
          boundary.nativePureRegionSumShape

renderFinalOutput
  :: LeanEnv
  -> [NativePureAnfBinding]
  -> [RegionOutput]
  -> Either NativePureLeanError (NativeShape, Text)
renderFinalOutput initial bindings outputs = do
  let finalEnv =
        foldl
          (\env binding -> (binding.nativePureAnfBindingValue, binding.nativePureAnfBindingShape) : env)
          initial
          bindings
  case outputs of
    [] -> pure (NativeUnit, ".unit")
    [output] -> do
      variable <- renderVar finalEnv output.regionOutputValue output.regionOutputShape
      pure (output.regionOutputShape, variable)
    _ -> do
      fields <- traverse (renderOutputField finalEnv) outputs
      pure
        ( NativeRecord
            (Map.fromList [(output.regionOutputLabel, output.regionOutputShape) | output <- outputs])
        , renderRecord fields
        )
  where
    renderOutputField env output =
      (output.regionOutputLabel,) <$> renderVar env output.regionOutputValue output.regionOutputShape

renderBindings :: LeanEnv -> [NativePureAnfBinding] -> Text -> Either NativePureLeanError Text
renderBindings _env [] result = pure result
renderBindings env (binding : rest) result = do
  operation <- renderOperation env binding.nativePureAnfBindingShape binding.nativePureAnfBindingOp
  body <-
    renderBindings
      ((binding.nativePureAnfBindingValue, binding.nativePureAnfBindingShape) : env)
      rest
      result
  pure . T.intercalate "\n" $
    [ ".letE"
    , indent 2 ("(" <> operation <> ")")
    , indent 2 ("(" <> body <> ")")
    ]

renderOperation :: LeanEnv -> NativeShape -> NativePureAnfOp -> Either NativePureLeanError Text
renderOperation env expected = \case
  NativePureAnfLiteral literal -> renderLiteral expected literal
  NativePureAnfAlias valueRef -> renderVar env valueRef expected
  NativePureAnfRecord fields ->
    case expected of
      NativeRecord expectedFields -> do
        rendered <-
          traverse
            ( \(fieldName, fieldShape) -> do
                valueRef <-
                  maybe (invalid ("missing record field " <> fieldName)) pure (Map.lookup fieldName fields)
                (fieldName,) <$> renderVar env valueRef fieldShape
            )
            (Map.toAscList expectedFields)
        pure (renderRecord rendered)
      _ -> invalid "record operation has non-record result shape"
  NativePureAnfProject valueRef fieldName -> do
    baseShape <- lookupShape env valueRef
    case baseShape of
      NativeRecord fields -> do
        fieldShape <-
          maybe (invalid ("unknown projected field " <> fieldName)) pure (Map.lookup fieldName fields)
        unless (fieldShape == expected) (Left (NativePureLeanShapeMismatch valueRef fieldShape expected))
        record <- renderVar env valueRef baseShape
        member <- renderMember fieldName (Map.keys fields)
        pure (".project (" <> record <> ") (" <> member <> ")")
      _ -> invalid "projection base is not a record"
  NativePureAnfNot valueRef -> unary ".not" valueRef NativeBool
  NativePureAnfBinary operator left right -> do
    -- Admission (Admission.hs) rejects every operator not covered by the
    -- certified kernel basis before a plan can reach this decoder, so the
    -- six excluded constructors are unreachable here; they are named
    -- explicitly rather than wildcarded so a newly admitted operator forces
    -- a decision at this call site too.
    let (constructor, operandShape) = case operator of
          CorePureAdd -> (".add", NativeI64)
          CorePureSubtract -> (".sub", NativeI64)
          CorePureMultiply -> (".mul", NativeI64)
          CorePureEqual -> (".eqI64", NativeI64)
          CorePureLessThan -> (".ltI64", NativeI64)
          CorePureAnd -> (".and", NativeBool)
          CorePureOr -> (".or", NativeBool)
          CorePureDivide -> ("", NativeUnit)
          CorePureMerge -> ("", NativeUnit)
          CorePureNotEqual -> ("", NativeUnit)
          CorePureLessThanOrEqual -> ("", NativeUnit)
          CorePureGreaterThan -> ("", NativeUnit)
          CorePureGreaterThanOrEqual -> ("", NativeUnit)
    when
      (T.null constructor)
      (invalid ("unsupported binary operator " <> T.pack (show operator)))
    leftExpr <- renderVar env left operandShape
    rightExpr <- renderVar env right operandShape
    pure (constructor <> " (" <> leftExpr <> ") (" <> rightExpr <> ")")
  NativePureAnfIf condition thenBlock elseBlock -> do
    conditionExpr <- renderVar env condition NativeBool
    thenExpr <- renderBlock env thenBlock expected
    elseExpr <- renderBlock env elseBlock expected
    pure (".ifE (" <> conditionExpr <> ") (" <> thenExpr <> ") (" <> elseExpr <> ")")
  NativePureAnfInject label payload ->
    case expected of
      NativeSum variants -> do
        payloadShape <-
          maybe (invalid ("unknown injected variant " <> label)) pure (Map.lookup label variants)
        payloadExpr <- renderVar env payload payloadShape
        member <- renderMember label (Map.keys variants)
        pure (".inject (" <> member <> ") (" <> payloadExpr <> ")")
      _ -> invalid "sum injection has non-sum result shape"
  where
    unary constructor valueRef operandShape = do
      value <- renderVar env valueRef operandShape
      pure (constructor <> " (" <> value <> ")")
    invalid = Left . NativePureLeanInvalidOperation

renderBlock :: LeanEnv -> NativePureAnfBlock -> NativeShape -> Either NativePureLeanError Text
renderBlock env block expected = do
  let blockEnv =
        foldl
          (\built binding -> (binding.nativePureAnfBindingValue, binding.nativePureAnfBindingShape) : built)
          env
          block.nativePureAnfBlockBindings
  result <- renderVar blockEnv block.nativePureAnfBlockResult expected
  renderBindings env block.nativePureAnfBlockBindings result

renderLiteral :: NativeShape -> CorePureLiteral -> Either NativePureLeanError Text
renderLiteral expected = \case
  CorePureNull
    | expected == NativeUnit -> pure ".unit"
  CorePureBool value
    | expected == NativeBool -> pure (".bool " <> if value then "true" else "false")
  CorePureString value ->
    case expected of
      NativeText capacity
        | fromIntegral (BS.length (TE.encodeUtf8 value)) <= capacity ->
            pure (".text " <> leanString value <> " (by native_decide)")
      _ -> invalid "text literal does not fit its declared native shape"
  CorePureNumber number ->
    case (expected, floatingOrInteger number :: Either Double Integer) of
      (NativeI64, Right integer)
        | integer >= -(2 ^ (63 :: Integer)) && integer < 2 ^ (63 :: Integer) ->
            pure (".i64 (checkedI64 " <> tshow integer <> " (by native_decide))")
      (NativeF64, Left _value) ->
        invalid "binary64 literal emission is not admitted by native-pure/v1"
      _ -> invalid "numeric literal does not fit its declared native shape"
  literal -> invalid ("literal " <> T.pack (show literal) <> " does not fit " <> T.pack (show expected))
  where
    invalid = Left . NativePureLeanInvalidOperation

renderVar :: LeanEnv -> NativePureSsaValueRef -> NativeShape -> Either NativePureLeanError Text
renderVar env valueRef expected = do
  (index, (_resolvedRef, actual)) <-
    maybe
      (Left (NativePureLeanUnknownValue valueRef))
      pure
      (List.find ((== valueRef) . fst . snd) (zip [0 :: Int ..] env))
  unless (actual == expected) (Left (NativePureLeanShapeMismatch valueRef actual expected))
  pure (".var (" <> renderVarIndex index <> ")")

lookupShape :: LeanEnv -> NativePureSsaValueRef -> Either NativePureLeanError NativeShape
lookupShape env valueRef =
  maybe
    (Left (NativePureLeanUnknownValue valueRef))
    (pure . snd)
    (List.find ((== valueRef) . fst) env)

-- `.succ` nests right-associatively (`Var.succ : Var context ty -> Var (bound
-- :: context) ty`), so index >= 2 needs explicit parens around each level; a
-- flat `.succ .succ .zero` parses as left-associative application instead.
renderVarIndex :: Int -> Text
renderVarIndex 0 = ".zero"
renderVarIndex index = ".succ (" <> renderVarIndex (index - 1) <> ")"

renderMember :: Text -> [Text] -> Either NativePureLeanError Text
renderMember target labels =
  case List.elemIndex target labels of
    Nothing -> Left (NativePureLeanInvalidOperation ("unknown member " <> target))
    Just index -> pure (T.replicate index ".tail " <> ".head")

renderRecord :: [(Text, Text)] -> Text
renderRecord = (".record (" <>) . (<> ")") . go
  where
    go [] = ".nil"
    go ((name, value) : rest) =
      ".cons " <> leanString name <> " (" <> value <> ") (" <> go rest <> ")"

renderTy :: NativeShape -> Text
renderTy = \case
  NativeUnit -> ".unit"
  NativeBool -> ".bool"
  NativeI64 -> ".i64"
  NativeU64 -> ".u64"
  NativeF64 -> ".f64"
  NativeText capacity -> ".text " <> tshow capacity
  NativeVector capacity element -> ".vector " <> tshow capacity <> " (" <> renderTy element <> ")"
  NativeRecord fields -> ".record " <> renderFields fields
  NativeSum variants -> ".sum " <> renderFields variants
  where
    renderFields fields =
      "["
        <> T.intercalate
          ", "
          ["(" <> leanString name <> ", " <> renderTy shape <> ")" | (name, shape) <- Map.toAscList fields]
        <> "]"

renderWellFormedTactic :: [NativeShape] -> Text
renderWellFormedTactic shapes
  | any shapeNeedsFields shapes =
      "simp [WellFormedTy, WellFormedFields, LabelsCanonical] <;> native_decide"
  | otherwise = "simp [WellFormedTy] <;> native_decide"

shapeNeedsFields :: NativeShape -> Bool
shapeNeedsFields = \case
  NativeVector _ element -> shapeNeedsFields element
  NativeRecord {} -> True
  NativeSum {} -> True
  NativeUnit -> False
  NativeBool -> False
  NativeI64 -> False
  NativeU64 -> False
  NativeF64 -> False
  NativeText {} -> False

boundaryRef :: Text -> EndpointRef -> NativePureSsaValueRef
boundaryRef regionRef endpoint =
  NativePureSsaValueRef
    ( regionRef
        <> ".input."
        <> endpoint.endpointNodeRef.unCircuitNodeRef
        <> "."
        <> fromMaybe "_" endpoint.endpointPortName
    )

leanString :: Text -> Text
leanString value = "\"" <> T.concatMap escape value <> "\""
  where
    escape = \case
      '\\' -> "\\\\"
      '"' -> "\\\""
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      char
        | fromEnum char < 32 -> "\\u{" <> T.pack (showHex (fromEnum char)) <> "}"
        | otherwise -> T.singleton char

showHex :: Int -> String
showHex value
  | value < 16 = [digits !! value]
  | otherwise = showHex (value `div` 16) <> [digits !! (value `mod` 16)]
  where
    digits = "0123456789abcdef"

validModuleName :: Text -> Bool
validModuleName value =
  not (T.null value)
    && all validSegment (T.splitOn "." value)
  where
    validSegment segment =
      case T.uncons segment of
        Nothing -> False
        Just (first, rest) -> validStart first && T.all validRest rest
    validStart char = char == '_' || isAsciiLetter char
    validRest char = validStart char || (isAscii char && isDigit char)
    isAsciiLetter char = isAsciiLower char || isAsciiUpper char

indent :: Int -> Text -> Text
indent amount = T.intercalate "\n" . fmap (T.replicate amount " " <>) . T.lines

tshow :: Show value => value -> Text
tshow = T.pack . show
