{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}

module Afa.Convert.Separated where

import Afa
import Afa.Bool
import Afa.Lib (listArray')
import Afa.Lib.LiftArray
import qualified Afa.Term.Bool as BTerm
import Afa.Term.Mix
import Control.Category ((>>>))
import Control.Lens
import Control.Monad
import Control.Monad.Free
import Control.Monad.ST
import Control.Monad.Trans
import Control.Monad.Trans.Maybe
import Control.RecursionSchemes.Lens
import Control.RecursionSchemes.Utils.HashCons
import Control.RecursionSchemes.Utils.NoCons
import Data.Array
import Data.Array.ST
import Data.Bifunctor
import Data.Bitraversable
import Data.Hashable
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Maybe
import Data.Traversable
import Data.Void

import qualified Afa.Convert.Separated.Model as SepAfa

separabilizeAfa :: AfaUnswallowed p -> AfaUnswallowed p
separabilizeAfa afa@Afa{terms, states} =
  afa{terms = terms', states = (ixMap !) <$> states}
  where
    (ixMap, terms') = separabilizeTerms terms

separabilizeTerms ::
  forall p q.
  Array Int (Term p q Int) ->
  (Array Int Int, Array Int (Term p q Int))
separabilizeTerms arr = second listArray' $ runST action
  where
    action :: forall s. ST s (Array Int Int, [Term p q Int])
    action =
      runNoConsT $
        fmap fst
          <$> cataScanT' @(LiftArray (STArray s)) traversed separabilize arr

-- Note: The function looks recursive but it recurs only one level down.
separabilize ::
  Monad m =>
  Term p q (Int, SepData Int) ->
  NoConsT (Term p q Int) m (Int, SepData Int)
separabilize (Predicate p) = (,PureP) <$> nocons (Predicate p)
separabilize (State q) = (,PureQ) <$> nocons (State q)
separabilize (Or tseps) = do
  result <- nocons $ Or $ NE.map fst tseps
  case partitionBySepData $ NE.toList tseps of
    (_, [], [], []) -> return (result, PureP)
    ([], _, [], []) -> return (result, PureQ)
    (purePs, pureQs, mAnds, mOrs) -> do
      pureP <- nothingSingleMulti Or $ purePs ++ mapMaybe (^. _2) mOrs
      pureQ <- nothingSingleMulti Or $ pureQs ++ mapMaybe (^. _3) mOrs
      return (result, MixedOr pureP pureQ (mAnds ++ concatMap (^. _4) mOrs))
separabilize (And tseps) = case partitionBySepData $ NE.toList tseps of
  (purePs, [], [], []) -> (,PureP) <$> nocons (And $ NE.fromList purePs)
  ([], pureQs, [], []) -> (,PureQ) <$> nocons (And $ NE.fromList pureQs)
  (purePs, pureQs, mAnds, []) -> do
    pureP <- nothingSingleMulti And $ purePs ++ map (^. _2) mAnds
    pureQ <- nothingSingleMulti And $ pureQs ++ map (^. _3) mAnds
    (,MixedAnd (fromJust pureP) (fromJust pureQ)) <$> nocons (And $ NE.map fst tseps)
  (purePs, pureQs, mAnds, mOrs) -> do
    let mAnds' = mAnds <&> \(t, tP, tQ) -> (t, MixedAnd tP tQ)
        purePs' = purePs <&> (,PureP)
        pureQs' = pureQs <&> (,PureQ)

        mOrs' = flip map mOrs $ \(_, tP, tQ, mts) ->
          catMaybes $
            (tP <&> (,PureP)) :
            (tQ <&> (,PureQ)) :
            map (\(t, tP, tQ) -> Just (t, MixedAnd tP tQ)) mts

        step xs1 xs2 = sequence $ do
          x1 <- xs1
          x2 <- xs2
          return $ separabilize $ And (x1 :| [x2])

    starter <- case purePs' ++ pureQs' ++ mAnds' of
      [] -> return []
      [x] -> return [[x]]
      x : xs -> separabilize (And $ x :| xs) <&> \x -> [[x]]

    let action0 : actions = starter ++ mOrs'
    explosion <- foldM step action0 actions
    separabilize $ Or $ NE.fromList explosion
separabilize LTrue = (,PureQ) <$> nocons LTrue

data SepData t
  = PureP
  | PureQ
  | MixedAnd t t
  | MixedOr (Maybe t) (Maybe t) [(t, t, t)]
  deriving (Functor)

partitionBySepData ::
  [(a, SepData t)] ->
  ([a], [a], [(a, t, t)], [(a, Maybe t, Maybe t, [(t, t, t)])])
partitionBySepData = foldr step ([], [], [], [])
  where
    step (a, PureP) = _1 %~ (a :)
    step (a, PureQ) = _2 %~ (a :)
    step (a, MixedAnd tP tQ) = _3 %~ ((a, tP, tQ) :)
    step (a, MixedOr tP tQ mts) = _4 %~ ((a, tP, tQ, mts) :)

nothingSingleMulti ::
  Monad m => (NonEmpty Int -> f Int) -> [Int] -> NoConsT (f Int) m (Maybe Int)
nothingSingleMulti f = \case
  [x] -> return $ Just x
  xs -> traverse (nocons . f) $ NE.nonEmpty xs

-- States in ATerms are used for bypassing
-- Predicates in QTerms are used for bypassing
separate :: Term p q [(Maybe p, Maybe t)] -> Maybe [(Term p p p, Term t q t)]
separate LTrue = Just [(LTrue, LTrue)]
separate (State q) = Just [(LTrue, State q)]
separate (Predicate p) = Just [(Predicate p, LTrue)]
separate (And cs)
  | any (\case _ : _ : _ -> True; _ -> False) cs = Nothing
  | otherwise = Just [(conj ps, conj ts)]
  where
    (ps, ts) = unzip $ map head $ NE.toList cs
    conj = maybe LTrue And . NE.nonEmpty . catMaybes
separate (Or cs)
  | all isNothing ps = Just [(LTrue, disj ts)]
  | all isNothing ts = Just [(disj ps, LTrue)]
  | any (\(x, y) -> isNothing x && isNothing y) cs' = Just [(LTrue, LTrue)]
  | otherwise = Just $ map (maybe LTrue State `bimap` maybe LTrue Predicate) cs'
  where
    cs' = concat $ NE.toList cs
    (ps, ts) = unzip cs'
    disj = maybe LTrue (Or . NE.fromList) . sequence

mixedToSeparated ::
  forall p.
  (Eq p, Hashable p) =>
  BoolAfaUnswallowed p ->
  Maybe (SepAfa.Afa p)
mixedToSeparated
  BoolAfa{boolTerms = bterms, afa = Afa{terms = mterms, states, initState}} =
    runST action
    where
      action :: forall s. ST s (Maybe (SepAfa.Afa p))
      action = do
        result <- runHashConsT $
          runHashConsT $
            runMaybeT $ do
              bixMap <-
                cataScanT' @(LiftArray (LiftArray (LiftArray (STArray s))))
                  traversed
                  (lift . lift . hashCons')
                  bterms
              cataScanT' @(LiftArray (LiftArray (LiftArray (STArray s))))
                traversed
                (alg bixMap)
                mterms

        case result of
          ((Just ixMap, mterms), bterms) ->
            return $
              Just
                SepAfa.Afa
                  { SepAfa.aterms = listArray' bterms
                  , SepAfa.qterms = listArray' mterms
                  , SepAfa.states = fmap (ixMap !) states
                  , SepAfa.initState = initState
                  }
          _ -> return Nothing

      alg bixMap =
        separate >>> \case
          Nothing -> MaybeT $ return Nothing
          Just conjs -> for conjs $ bitraverse addP addQ
        where
          addP LTrue = return Nothing
          addP (State p) = return $ Just p
          addP (Predicate p) = return $ Just $ bixMap ! p
          addP (And ps) = fmap Just $ lift $ lift $ hashCons' $ BTerm.And ps
          addP (Or ps) = fmap Just $ lift $ lift $ hashCons' $ BTerm.Or ps

      addQ LTrue = return Nothing
      addQ (Predicate t) = return $ Just t
      addQ (State q) = fmap Just $ lift $ hashCons' $ State q
      addQ (And ts) = fmap Just $ lift $ hashCons' $ And ts
      addQ (Or ts) = fmap Just $ lift $ hashCons' $ Or ts

absurdPredicates :: Term Void q t -> Term p q t
absurdPredicates = appMTFun mtfun0{mtfunP = absurd}

-- Much more cleanly implemented via swallowed afa, see below
separatedToMixed :: forall p. SepAfa.Afa p -> BoolAfaUnswallowed p
separatedToMixed (SepAfa.Afa aterms qterms states initState) =
  BoolAfa
    { boolTerms = aterms
    , afa =
        Afa
          { terms = listArray' $ map absurdPredicates (elems qterms) ++ mtermsFromStates
          , states = states'
          , initState = initState
          }
    }
  where
    qtermSize = rangeSize $ bounds qterms
    Identity (states', mtermsFromStates) = runNoConsTFrom qtermSize $ do
      for states $ \qs -> do
        ands <- for qs $ \(p, t) -> do
          p' <- nocons $ maybe LTrue Predicate p
          t' <- maybe (nocons LTrue) return t
          nocons $ And $ p' :| [t']
        nocons $ Or $ NE.fromList ands

separatedToMixedSwallowed :: forall p. SepAfa.Afa p -> BoolAfaSwallowed p
separatedToMixedSwallowed (SepAfa.Afa aterms qterms states initState) =
  BoolAfa
    { boolTerms = fmap (Free . fmap Pure) aterms
    , afa =
        Afa
          { terms = fmap (Free . fmap Pure . absurdPredicates) qterms
          , states = fmap toFormula states
          , initState = initState
          }
    }
  where
    toFormula = ((Free . Or . NE.fromList) .) $
      map $ \(a, b) ->
        Free $
          And $
            maybe (Free LTrue) (Free . Predicate . Pure) a :| [maybe (Free LTrue) Pure b]
