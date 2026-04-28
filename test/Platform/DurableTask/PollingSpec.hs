module Platform.DurableTask.PollingSpec (spec) where

import Test.Hspec

import Platform.DurableTask.Polling (jitterInterval)

spec :: Spec
spec = describe "Platform.DurableTask.Polling" $ do
  describe "jitterInterval" $ do
    it "returns correct bounds with 20% jitter" $ do
      let (lo, hi) = jitterInterval 5_000_000 0.2
      lo `shouldBe` 4_000_000
      hi `shouldBe` 6_000_000

    it "returns identity bounds with 0% jitter" $ do
      let (lo, hi) = jitterInterval 5_000_000 0.0
      lo `shouldBe` 5_000_000
      hi `shouldBe` 5_000_000

    it "returns identity bounds with negative jitter" $ do
      let (lo, hi) = jitterInterval 5_000_000 (-0.1)
      lo `shouldBe` 5_000_000
      hi `shouldBe` 5_000_000

    it "clamps lower bound to 0 for large jitter fractions" $ do
      let (lo, _hi) = jitterInterval 100 1.5
      lo `shouldBe` 0

    it "handles small intervals" $ do
      let (lo, hi) = jitterInterval 200_000 0.2
      lo `shouldBe` 160_000
      hi `shouldBe` 240_000
