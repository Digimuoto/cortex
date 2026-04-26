-- |
-- Module: Platform.Patch
-- Description: Helpers for applying partial updates to records
--
-- This module provides combinators for applying optional field updates,
-- commonly used in PATCH/PUT HTTP handlers.
module Platform.Patch
  ( -- * Basic patch helpers
    setMaybe,
    setMaybeN,
    setMaybeWith,
  )
where

-- | Apply an optional update to a field.
--
-- If the Maybe value is Just, return the new value.
-- Otherwise, return the current value.
--
-- Example:
-- >>> setMaybe (Just "new-name") "old-name"
-- "new-name"
--
-- >>> setMaybe Nothing "old-name"
-- "old-name"
setMaybe :: Maybe a -> a -> a
setMaybe (Just new) _current = new
setMaybe Nothing current = current

-- | Apply an optional update to a field with newtype unwrapping.
--
-- Similar to 'setMaybe', but automatically unwraps a newtype constructor
-- before applying the update. Useful for fields wrapped in newtypes like
-- Ticker, Exchange, Currency, etc.
--
-- Example:
-- >>> setMaybeN (Just (Ticker "AAPL")) unTicker (Ticker "MSFT")
-- Ticker "AAPL"
--
-- >>> setMaybeN Nothing unTicker (Ticker "MSFT")
-- Ticker "MSFT"
setMaybeN :: Maybe n -> (n -> a) -> a -> a
setMaybeN (Just newWrapped) unwrap _current = unwrap newWrapped
setMaybeN Nothing _unwrap current = current

-- | Apply an optional update to a field with custom transformation.
--
-- Apply a transformation function to the new value before using it.
-- If the Maybe value is Nothing, return the current value.
--
-- Example:
-- >>> setMaybeWith (Just "  spaces  ") Text.strip "original"
-- "spaces"
--
-- >>> setMaybeWith Nothing Text.strip "original"
-- "original"
setMaybeWith :: Maybe a -> (a -> b) -> b -> b
setMaybeWith (Just new) transform _current = transform new
setMaybeWith Nothing _transform current = current
