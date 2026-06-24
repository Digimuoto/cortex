{- |
Module      : Cortex.Quantum.ReportPathSpec
Description : Quantum report output path naming.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Checks the QEC report filename convention used by the native Braket runner: the
caller supplies an output directory and the runner supplies timestamp,
experiment, and hardware components.
-}
module Cortex.Quantum.ReportPathSpec (spec) where

import Data.Either (isLeft)
import Test.Hspec

import Cortex.Quantum.ReportPath

spec :: Spec
spec =
  describe "quantum report paths" $ do
    it "names QEC hardware reports from the IQM device ARN" $
      qecRepetitionReportPath
        "20260623T182217Z"
        "arn:aws:braket:eu-north-1::device/qpu/iqm/Emerald"
        "reports"
        `shouldBe` Right "reports/20260623T182217Z-qec-repetition-iqm-emerald.md"

    it "names QEC simulator reports from the Amazon simulator ARN" $
      qecRepetitionReportPath
        "20260623T182217Z"
        "arn:aws:braket:::device/quantum-simulator/amazon/sv1"
        "reports"
        `shouldBe` Right "reports/20260623T182217Z-qec-repetition-amazon-sv1.md"

    it "sanitizes provider and device labels" $
      hardwareSlug "arn:aws:braket:example::device/qpu/Acme Labs/Chip 01!"
        `shouldBe` "acme-labs-chip-01"

    it "rejects markdown filenames as --output values" $
      qecRepetitionReportPath
        "20260623T182217Z"
        "arn:aws:braket:eu-north-1::device/qpu/iqm/Emerald"
        "reports/manual-name.md"
        `shouldSatisfy` isLeft
