{-# LANGUAGE OverloadedStrings #-}

module Platform.DurableTask.CronSpec (spec) where

import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Time
  ( Day (ModifiedJulianDay)
  , DayOfWeek (..)
  , UTCTime (..)
  , dayOfWeek
  , fromGregorian
  , secondsToDiffTime
  , toGregorian
  , utctDay
  )
import Test.Hspec
import Test.QuickCheck

import Platform.DurableTask.Cron
  ( CronSchedule (..)
  , computeNextCronTime
  , nextCronTime
  , parseCron
  )

-- | Helper: create a UTCTime from components
mkTime :: Integer -> Int -> Int -> Int -> Int -> UTCTime
mkTime y m d h mn =
  UTCTime
    (fromGregorian y m d)
    (secondsToDiffTime $ fromIntegral (h * 3600 + mn * 60))

spec :: Spec
spec = do
  describe "parseCron" $ do
    it "parses a simple 5-field expression" $ do
      parseCron "0 22 * * 1-5" `shouldSatisfy` isJust

    it "parses wildcard expression" $ do
      case parseCron "* * * * *" of
        Nothing -> expectationFailure "expected Just"
        Just sched -> do
          cronMinutes sched `shouldBe` [0 .. 59]
          cronHours sched `shouldBe` [0 .. 23]
          cronDaysOfMonth sched `shouldBe` [1 .. 31]
          cronMonths sched `shouldBe` [1 .. 12]
          cronDaysOfWeek sched `shouldBe` [0 .. 6]

    it "parses step expressions" $ do
      case parseCron "*/15 * * * *" of
        Nothing -> expectationFailure "expected Just"
        Just sched -> cronMinutes sched `shouldBe` [0, 15, 30, 45]

    it "parses list expressions" $ do
      case parseCron "0,30 * * * *" of
        Nothing -> expectationFailure "expected Just"
        Just sched -> cronMinutes sched `shouldBe` [0, 30]

    it "parses range expressions" $ do
      case parseCron "* * * * 1-5" of
        Nothing -> expectationFailure "expected Just"
        Just sched -> cronDaysOfWeek sched `shouldBe` [1, 2, 3, 4, 5]

    it "normalizes day-of-week 7 to 0 (both mean Sunday)" $ do
      case parseCron "0 0 * * 7" of
        Nothing -> expectationFailure "expected Just"
        Just sched -> cronDaysOfWeek sched `shouldBe` [0]

    it "rejects empty input" $
      parseCron "" `shouldSatisfy` isNothing

    it "rejects too few fields" $
      parseCron "0 22 * *" `shouldSatisfy` isNothing

    it "rejects too many fields" $
      parseCron "0 22 * * 1 extra" `shouldSatisfy` isNothing

    it "rejects invalid range (start > end)" $
      parseCron "* * * * 5-1" `shouldSatisfy` isNothing

    it "parses hourly cron" $ do
      case parseCron "0 * * * *" of
        Nothing -> expectationFailure "expected Just"
        Just sched -> do
          cronMinutes sched `shouldBe` [0]
          cronHours sched `shouldBe` [0 .. 23]

  describe "nextCronTime" $ do
    it "finds the next minute for every-minute cron" $ do
      case parseCron "* * * * *" of
        Nothing -> expectationFailure "parse failed"
        Just sched ->
          nextCronTime sched (mkTime 2026 3 28 10 30)
            `shouldBe` Just (mkTime 2026 3 28 10 31)

    it "finds the next hour for hourly cron" $ do
      case parseCron "0 * * * *" of
        Nothing -> expectationFailure "parse failed"
        Just sched ->
          nextCronTime sched (mkTime 2026 3 28 10 30)
            `shouldBe` Just (mkTime 2026 3 28 11 0)

    it "advances to next day when no more matches today" $ do
      case parseCron "0 9 * * *" of
        Nothing -> expectationFailure "parse failed"
        Just sched ->
          nextCronTime sched (mkTime 2026 3 28 10 0)
            `shouldBe` Just (mkTime 2026 3 29 9 0)

    it "skips weekends for weekday-only cron" $ do
      -- 2026-03-28 is a Saturday
      case parseCron "0 22 * * 1-5" of
        Nothing -> expectationFailure "parse failed"
        Just sched -> case nextCronTime sched (mkTime 2026 3 28 23 0) of
          Nothing -> expectationFailure "expected Just"
          Just next -> do
            dayOfWeek (utctDay next) `shouldBe` Monday
            let (_, _, d) = toGregorian (utctDay next)
            d `shouldBe` 30

    it "handles month boundary" $ do
      case parseCron "0 12 * * *" of
        Nothing -> expectationFailure "parse failed"
        Just sched -> case nextCronTime sched (mkTime 2026 3 31 13 0) of
          Nothing -> expectationFailure "expected Just"
          Just next -> do
            let (_, m, d) = toGregorian (utctDay next)
            m `shouldBe` 4
            d `shouldBe` 1

    it "handles year boundary" $ do
      case parseCron "0 0 1 1 *" of
        Nothing -> expectationFailure "parse failed"
        Just sched -> case nextCronTime sched (mkTime 2026 12 31 23 59) of
          Nothing -> expectationFailure "expected Just"
          Just next -> do
            let (y, m, d) = toGregorian (utctDay next)
            y `shouldBe` 2027
            m `shouldBe` 1
            d `shouldBe` 1

    it "returns a time strictly after now" $ do
      let now = mkTime 2026 3 28 10 30
      case parseCron "30 10 * * *" of
        Nothing -> expectationFailure "parse failed"
        Just sched -> case nextCronTime sched now of
          Nothing -> expectationFailure "expected Just"
          Just next -> next `shouldSatisfy` (> now)

  describe "computeNextCronTime" $ do
    it "returns Nothing for empty string" $
      computeNextCronTime "" (mkTime 2026 3 28 10 0) `shouldSatisfy` isNothing

    it "returns Nothing for whitespace-only string" $
      computeNextCronTime "   " (mkTime 2026 3 28 10 0) `shouldSatisfy` isNothing

    it "returns Nothing for invalid cron" $
      computeNextCronTime "not a cron" (mkTime 2026 3 28 10 0) `shouldSatisfy` isNothing

    it "returns Just for valid cron" $
      computeNextCronTime "0 22 * * 1-5" (mkTime 2026 3 27 10 0) `shouldSatisfy` isJust

    it "computes correct next time for daily cron" $
      computeNextCronTime "0 22 * * *" (mkTime 2026 3 28 21 0)
        `shouldBe` Just (mkTime 2026 3 28 22 0)

  describe "nextCronTime properties" $ do
    it "result is strictly after the input time"
      . forAll (elements validCronExprs)
      $ \expr ->
        forAll genUTCTime $ \now ->
          maybe discard (\next -> property (next > now)) $
            parseCron expr >>= \sched -> nextCronTime sched now

    it "successive calls are monotonically increasing"
      . forAll (elements validCronExprs)
      $ \expr ->
        forAll genUTCTime $ \now ->
          let result = do
                sched <- parseCron expr
                next1 <- nextCronTime sched now
                next2 <- nextCronTime sched next1
                pure (next1, next2)
           in maybe discard (\(next1, next2) -> property (next2 > next1)) result

-- ============================================================================
-- Generators and helpers for property tests
-- ============================================================================

{- | A representative set of valid cron expressions that always have a next
fire time (no restrictive day-of-month/day-of-week combinations).
-}
validCronExprs :: [Text]
validCronExprs =
  [ "* * * * *"
  , "0 * * * *"
  , "*/5 * * * *"
  , "0 9 * * *"
  , "0 0 1 * *"
  , "30 14 * * *"
  , "0,30 * * * *"
  ]

-- | Generate a UTC time spread over roughly 1995–2023 with varying time-of-day.
genUTCTime :: Gen UTCTime
genUTCTime = do
  day <- ModifiedJulianDay <$> choose (50000, 60000)
  secs <- secondsToDiffTime <$> choose (0, 86399)
  pure (UTCTime day secs)
