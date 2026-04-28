{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Minimal cron schedule parser and next-fire-time computation.

Supports standard 5-field cron expressions:
 minute hour day-of-month month day-of-week

Field syntax:
 *        = any value
 N        = exact value
 N-M      = range (inclusive)
 N,M,...  = list
 *\/N     = step (every Nth from start of range)

Day-of-week: 0 = Sunday, 1 = Monday, ..., 6 = Saturday (also 7 = Sunday)

This does NOT support:
 - @yearly, @monthly, @weekly, @daily, @hourly aliases
 - L, W, # modifiers
 - Seconds or year fields
-}
module Platform.DurableTask.Cron
  ( CronSchedule (..)
  , parseCron
  , nextCronTime
  , computeNextCronTime
  )
where

import Data.Char (isDigit)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
  ( DayOfWeek (..)
  , LocalTime (..)
  , TimeOfDay (..)
  , TimeZone
  , UTCTime
  , addDays
  , dayOfWeek
  , diffDays
  , fromGregorian
  , localTimeToUTC
  , midnight
  , toGregorian
  , utc
  , utcToLocalTime
  )

-- | Parsed cron schedule. Each field is a sorted list of valid values.
data CronSchedule = CronSchedule
  { cronMinutes :: ![Int]
  , cronHours :: ![Int]
  , cronDaysOfMonth :: ![Int]
  , cronMonths :: ![Int]
  , cronDaysOfWeek :: ![Int]
  , cronDomIsWildcard :: !Bool
  -- ^ True if day-of-month was specified as '*' (affects OR/AND semantics)
  , cronDowIsWildcard :: !Bool
  -- ^ True if day-of-week was specified as '*' (affects OR/AND semantics)
  }
  deriving (Show, Eq)

-- | Parse a 5-field cron expression. Returns Nothing on invalid input.
parseCron :: Text -> Maybe CronSchedule
parseCron expr =
  case T.words (T.strip expr) of
    [minF, hourF, domF, monF, dowF] -> do
      mins <- parseField 0 59 minF
      hours <- parseField 0 23 hourF
      doms <- parseField 1 31 domF
      mons <- parseField 1 12 monF
      dows <- parseField 0 7 dowF
      -- Normalize day-of-week: 7 -> 0 (both mean Sunday)
      let normalizedDows = sort . nub $ fmap (\d -> if d == 7 then 0 else d) dows
      Just
        CronSchedule
          { cronMinutes = mins
          , cronHours = hours
          , cronDaysOfMonth = doms
          , cronMonths = mons
          , cronDaysOfWeek = normalizedDows
          , cronDomIsWildcard = domF == "*"
          , cronDowIsWildcard = dowF == "*"
          }
    _ -> Nothing

{- | Compute the next fire time after the given UTC time.
Returns Nothing if no valid time exists within ~4 years (safety bound).
-}
nextCronTime :: CronSchedule -> UTCTime -> Maybe UTCTime
nextCronTime = nextCronTimeIn utc

-- | Compute the next fire time in a given timezone.
nextCronTimeIn :: TimeZone -> CronSchedule -> UTCTime -> Maybe UTCTime
nextCronTimeIn tz sched now =
  let local = utcToLocalTime tz now
      -- Start searching from the next minute
      startLocal = advanceOneMinute local
   in fmap (localTimeToUTC tz) (searchNext sched startLocal 0)

{- | Convenience: parse a cron expression and compute next fire time.
Returns Nothing if the expression is empty, unparseable, or has no match.
-}
computeNextCronTime :: Text -> UTCTime -> Maybe UTCTime
computeNextCronTime expr now
  | T.null (T.strip expr) = Nothing
  | otherwise = do
      sched <- parseCron expr
      nextCronTime sched now

-- ============================================================================
-- Internal
-- ============================================================================

{- | Search for the next matching local time, with a safety bound.
Searches up to ~1500 days (~4 years) to handle leap year edge cases.
-}
searchNext :: CronSchedule -> LocalTime -> Int -> Maybe LocalTime
searchNext sched candidate daysTried
  | daysTried > 1500 = Nothing
  | otherwise =
      let (yr, mn, dy) = toGregorian (localDay candidate)
          dow = dayOfWeekToInt (dayOfWeek (localDay candidate))
          TimeOfDay h m _ = localTimeOfDay candidate
          -- Standard cron: when both DOM and DOW are restricted (non-wildcard),
          -- the day matches if EITHER condition is true (OR semantics).
          -- When one is wildcard, only the other is checked.
          dayMatches
            | cronDomIsWildcard sched && cronDowIsWildcard sched = True
            | cronDomIsWildcard sched = dow `elem` cronDaysOfWeek sched
            | cronDowIsWildcard sched = dy `elem` cronDaysOfMonth sched
            | otherwise = dy `elem` cronDaysOfMonth sched || dow `elem` cronDaysOfWeek sched
       in if mn `elem` cronMonths sched
            && dayMatches
            && h `elem` cronHours sched
            && m `elem` cronMinutes sched
            then Just candidate
            else -- Try to skip efficiently
              if mn `notElem` cronMonths sched
                then
                  let nextMonth = firstMinuteOfNextMonth sched yr mn
                      jumped = fromIntegral $ diffDays (localDay nextMonth) (localDay candidate)
                   in searchNext sched nextMonth (daysTried + max 1 jumped)
                else
                  if not dayMatches
                    then -- Skip to start of next day
                      searchNext sched (firstMinuteOfNextDay candidate) (daysTried + 1)
                    else
                      if h `notElem` cronHours sched
                        then -- Skip to start of next hour
                          searchNext sched (firstMinuteOfNextHour candidate) daysTried
                        else -- Advance one minute
                          searchNext sched (advanceOneMinute candidate) daysTried

-- | Convert DayOfWeek to cron integer (Sunday = 0)
dayOfWeekToInt :: DayOfWeek -> Int
dayOfWeekToInt = \case
  Sunday -> 0
  Monday -> 1
  Tuesday -> 2
  Wednesday -> 3
  Thursday -> 4
  Friday -> 5
  Saturday -> 6

advanceOneMinute :: LocalTime -> LocalTime
advanceOneMinute (LocalTime day (TimeOfDay h m _))
  | m < 59 = LocalTime day (TimeOfDay h (m + 1) 0)
  | h < 23 = LocalTime day (TimeOfDay (h + 1) 0 0)
  | otherwise = LocalTime (addDays 1 day) midnight

firstMinuteOfNextDay :: LocalTime -> LocalTime
firstMinuteOfNextDay (LocalTime day _) =
  LocalTime (addDays 1 day) midnight

firstMinuteOfNextHour :: LocalTime -> LocalTime
firstMinuteOfNextHour (LocalTime day (TimeOfDay h _ _))
  | h < 23 = LocalTime day (TimeOfDay (h + 1) 0 0)
  | otherwise = LocalTime (addDays 1 day) midnight

firstMinuteOfNextMonth :: CronSchedule -> Integer -> Int -> LocalTime
firstMinuteOfNextMonth sched yr mn =
  let nextMn = case filter (> mn) (cronMonths sched) of
        (m : _) -> (yr, m)
        [] -> case cronMonths sched of
          (m : _) -> (yr + 1, m)
          [] -> (yr + 1, 1) -- shouldn't happen with valid schedule
      (nextYr, nextMonth) = nextMn
   in LocalTime (fromGregorian nextYr nextMonth 1) midnight

-- | Parse a single cron field (e.g., "1,5,10" or "*/15" or "1-5")
parseField :: Int -> Int -> Text -> Maybe [Int]
parseField lo hi field =
  case T.splitOn "," field of
    parts -> do
      vals <- sort . nub . concat <$> mapM (parsePart lo hi) parts
      -- Reject if any value is out of range (don't silently filter)
      if null vals || any (\v -> v < lo || v > hi) vals
        then Nothing
        else Just vals

parsePart :: Int -> Int -> Text -> Maybe [Int]
parsePart lo hi part
  | part == "*" = Just [lo .. hi]
  | Just stepStr <- T.stripPrefix "*/" part =
      case readInt stepStr of
        Just step | step > 0 -> Just [lo, lo + step .. hi]
        _ -> Nothing
  | T.isInfixOf "-" part =
      case T.splitOn "-" part of
        [aStr, rest] ->
          case T.splitOn "/" rest of
            [bStr] -> do
              a <- readInt aStr
              b <- readInt bStr
              if a <= b then Just [a .. b] else Nothing
            [bStr, stepStr] -> do
              a <- readInt aStr
              b <- readInt bStr
              step <- readInt stepStr
              if a <= b && step > 0
                then Just [a, a + step .. b]
                else Nothing
            _ -> Nothing
        _ -> Nothing
  | otherwise = do
      v <- readInt part
      Just [v]

readInt :: Text -> Maybe Int
readInt t =
  let s = T.unpack t
   in if all isDigit s && not (null s)
        then Just (read s)
        else Nothing
