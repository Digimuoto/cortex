{- |
Module      : Cortex.Pulse.Rewrite.Contract
Description : Decidable admission check for an external-call frontier contraction.
Copyright   : (c) 2026 Digimuoto Oy
License     : Apache-2.0
Maintainer  : julius.koskela@digimuoto.com
Stability   : experimental

Sinking the set of upstream backend nodes feeding a collect node into one durable
stage is a contraction. ADR 0059 §2 requires a /decidable/ admission check that
runs in the @validatorReady@ lineage rather than host-side guesswork: every node in
the collected set must share one external-call authority and one await strategy, and
no non-backend node may sit inside the set. A set that violates this is __rejected__
(the author/materializer must place separate realize nodes); the validator never
silently splits it.

The check is on the /collected set/ only. Frozen boundary inputs to the collect
node (request parameters, runtime config, domain values) are legitimate inbound
edges, not members of the collected set, so they are not authority violations — they
are excluded by the lowering's collection traversal, not by this check.

This module is pure and polymorphic over the node, authority, and strategy types so
it carries no runtime dependency; call sites instantiate it with the concrete
'Cortex.Wire.Executor.WireExecutorId' and
'Cortex.Capability.Catalog.AwaitStrategy.AwaitStrategy'.
-}
module Cortex.Pulse.Rewrite.Contract
  ( FrontierAdmissionError (..)
  , CollectedNode (..)
  , admitFrontierContraction
  )
where

import Data.List (nub)
import Data.Maybe (isNothing)

{- | A node collected into an external-call frontier, paired with its backend classification:
@Just (authority, strategy)@ for a backend node, @Nothing@ for a non-backend node
that must not appear inside the collected set.
-}
data CollectedNode node authority strategy = CollectedNode
  { cnNode :: !node
  , cnClassification :: !(Maybe (authority, strategy))
  }
  deriving stock (Eq, Show)

{- | Why a collected frontier is inadmissible. Carries the offending nodes so the
caller can report a precise rejection rather than silently splitting.
-}
data FrontierAdmissionError node
  = -- | The collected set spans more than one external-call authority.
    FrontierMixedAuthority ![node]
  | -- | The collected set spans more than one await strategy.
    FrontierMixedAwaitStrategy ![node]
  | -- | A non-backend node sits inside the collected set.
    FrontierNonBackendIntervening !node
  | -- | The collected set is empty; there is no frontier to realize.
    FrontierEmpty
  deriving stock (Eq, Show)

{- | Decide whether a collected frontier may contract into one realize stage. Rejects
(never splits) on a mixed authority, a mixed await strategy, an intervening
non-backend node, or an empty set.
-}
admitFrontierContraction
  :: (Eq authority, Eq strategy)
  => [CollectedNode node authority strategy]
  -> Either (FrontierAdmissionError node) ()
admitFrontierContraction [] = Left FrontierEmpty
admitFrontierContraction collected =
  case [cnNode n | n <- collected, isNothing (cnClassification n)] of
    (nonBackend : _) -> Left (FrontierNonBackendIntervening nonBackend)
    [] ->
      let classified = [(a, s) | CollectedNode _ (Just (a, s)) <- collected]
          authorities = nub (fmap fst classified)
          strategies = nub (fmap snd classified)
       in if length authorities > 1
            then Left (FrontierMixedAuthority (fmap cnNode collected))
            else
              if length strategies > 1
                then Left (FrontierMixedAwaitStrategy (fmap cnNode collected))
                else Right ()
