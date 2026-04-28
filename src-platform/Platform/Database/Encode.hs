{- | Hasql encoder combinators for raw-SQL queries.

Each @encodeN@ takes N @(accessor, encoder)@ pairs, producing a
single 'E.Params' value.  Use record accessors with
'OverloadedRecordDot' for named fields, or positional tuple
destructors for small (2-3 field) tuples.

@
encode3
 (\\p -> p.rfRunId,   E.nonNullable E.uuid)
 (\\p -> p.rfNow,     E.nonNullable E.timestamptz)
 (\\p -> p.rfErrType, E.nonNullable E.text)
@

For queries with more than eight parameters, use 'encodeParams' with
a 'NonEmpty' of 'col' calls instead of chaining @encodeN@ with @(<>)@:

@
encodeParams $
 col (.fieldA) (E.nonNullable E.text)
   :| [ col (.fieldB) (E.nonNullable E.int4)
      , col (.fieldC) (E.nullable E.timestamptz)
      ]
@

Re-exports the most common 'Hasql.Encoders' primitives so query
modules can import this instead of @Hasql.Encoders@ directly.
'E.param' is intentionally not re-exported — use 'encode1' for
single-parameter queries or import @Hasql.Encoders@ directly if
you need raw @>$<@ chains.
-}
module Platform.Database.Encode
  ( -- * Tuple/record encoders
    encode1
  , encode2
  , encode3
  , encode4
  , encode5
  , encode6
  , encode7
  , encode8
  , encodeParams
  , col
  , NonEmpty (..)

    -- * Re-exports from Hasql.Encoders
  , E.Params
  , E.NullableOrNot
  , E.Value
  , E.nonNullable
  , E.nullable
  , E.uuid
  , E.text
  , E.bool
  , E.int2
  , E.int4
  , E.int8
  , E.float4
  , E.float8
  , E.numeric
  , E.timestamptz
  , E.jsonb
  , E.bytea
  , E.foldableArray
  )
where

import Data.Functor.Contravariant ((>$<))
import Data.List.NonEmpty (NonEmpty (..))
import Hasql.Encoders qualified as E

col :: (t -> a) -> E.NullableOrNot E.Value a -> E.Params t
col f e = f >$< E.param e

encode1
  :: (t -> a, E.NullableOrNot E.Value a)
  -> E.Params t
encode1 (fa, ea) =
  col fa ea

encode2
  :: (t -> a, E.NullableOrNot E.Value a)
  -> (t -> b, E.NullableOrNot E.Value b)
  -> E.Params t
encode2 (fa, ea) (fb, eb) =
  col fa ea
    <> col fb eb

encode3
  :: (t -> a, E.NullableOrNot E.Value a)
  -> (t -> b, E.NullableOrNot E.Value b)
  -> (t -> c, E.NullableOrNot E.Value c)
  -> E.Params t
encode3 (fa, ea) (fb, eb) (fc, ec) =
  col fa ea
    <> col fb eb
    <> col fc ec

encode4
  :: (t -> a, E.NullableOrNot E.Value a)
  -> (t -> b, E.NullableOrNot E.Value b)
  -> (t -> c, E.NullableOrNot E.Value c)
  -> (t -> d, E.NullableOrNot E.Value d)
  -> E.Params t
encode4 (fa, ea) (fb, eb) (fc, ec) (fd, ed) =
  col fa ea
    <> col fb eb
    <> col fc ec
    <> col fd ed

encode5
  :: (t -> a, E.NullableOrNot E.Value a)
  -> (t -> b, E.NullableOrNot E.Value b)
  -> (t -> c, E.NullableOrNot E.Value c)
  -> (t -> d, E.NullableOrNot E.Value d)
  -> (t -> e, E.NullableOrNot E.Value e)
  -> E.Params t
encode5 (fa, ea) (fb, eb) (fc, ec) (fd, ed) (fe, ee) =
  col fa ea
    <> col fb eb
    <> col fc ec
    <> col fd ed
    <> col fe ee

encode6
  :: (t -> a, E.NullableOrNot E.Value a)
  -> (t -> b, E.NullableOrNot E.Value b)
  -> (t -> c, E.NullableOrNot E.Value c)
  -> (t -> d, E.NullableOrNot E.Value d)
  -> (t -> e, E.NullableOrNot E.Value e)
  -> (t -> f, E.NullableOrNot E.Value f)
  -> E.Params t
encode6 (fa, ea) (fb, eb) (fc, ec) (fd, ed) (fe, ee) (ff, ef) =
  col fa ea
    <> col fb eb
    <> col fc ec
    <> col fd ed
    <> col fe ee
    <> col ff ef

encode7
  :: (t -> a, E.NullableOrNot E.Value a)
  -> (t -> b, E.NullableOrNot E.Value b)
  -> (t -> c, E.NullableOrNot E.Value c)
  -> (t -> d, E.NullableOrNot E.Value d)
  -> (t -> e, E.NullableOrNot E.Value e)
  -> (t -> f, E.NullableOrNot E.Value f)
  -> (t -> g, E.NullableOrNot E.Value g)
  -> E.Params t
encode7 (fa, ea) (fb, eb) (fc, ec) (fd, ed) (fe, ee) (ff, ef) (fg, eg) =
  col fa ea
    <> col fb eb
    <> col fc ec
    <> col fd ed
    <> col fe ee
    <> col ff ef
    <> col fg eg

encode8
  :: (t -> a, E.NullableOrNot E.Value a)
  -> (t -> b, E.NullableOrNot E.Value b)
  -> (t -> c, E.NullableOrNot E.Value c)
  -> (t -> d, E.NullableOrNot E.Value d)
  -> (t -> e, E.NullableOrNot E.Value e)
  -> (t -> f, E.NullableOrNot E.Value f)
  -> (t -> g, E.NullableOrNot E.Value g)
  -> (t -> h, E.NullableOrNot E.Value h)
  -> E.Params t
encode8 (fa, ea) (fb, eb) (fc, ec) (fd, ed) (fe, ee) (ff, ef) (fg, eg) (fh, eh) =
  col fa ea
    <> col fb eb
    <> col fc ec
    <> col fd ed
    <> col fe ee
    <> col ff ef
    <> col fg eg
    <> col fh eh

{- | Encode any number of columns from a non-empty list of 'E.Params'
values built with 'col'.  Use this instead of chaining @encodeN@ with
@(<>)@ when a query has more than eight parameters:

@
encodeParams $
 col (.fieldA) (E.nonNullable E.text) :|
 [ col (.fieldB) (E.nonNullable E.int4)
 , col (.fieldC) (E.nullable E.timestamptz)
 ]
@

The 'NonEmpty' argument prevents a silent empty-list mistake that
would produce a zero-parameter encoder and fail at statement execution
time.
-}
encodeParams :: NonEmpty (E.Params t) -> E.Params t
encodeParams (p :| ps) = mconcat (p : ps)
