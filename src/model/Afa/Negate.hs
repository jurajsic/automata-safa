{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE LambdaCase #-}

module Afa.Negate where

import Shaper.Helpers (BuildD, BuildInheritShareD, buildInheritShare)

import Afa.Finalful.STerm (Term (..), QVR(Q), create, Create, Creation)
import qualified DepDict as D
import TypeDict
    ( d, g, d', g', Named(Name), TypeDict((:+:)), TypeDict(End, LiftTags) )
import Shaper (MonadFn(monadfn), ask, Mk, IsTree, MfnK, FRecK, FunRecur, funRecur, Recur, MkN, RecK, Recur0(recur))
import DepDict (DepDict((:|:)))
import Data.Traversable (for)
import Data.Function.Apply ((-$))
import Control.Monad (foldM)
import Data.Foldable (toList, for_)
import Data.Array.MArray
import Data.Array.IO (IOArray)
import Data.Array (listArray, (!), Array)
import Data.Array.Unsafe (unsafeFreeze)
import Lift (K(K))

type DeMorganAlgD d m = DeMorganAlgD_ d m (DeMorganAlgA d [g|q|] [g|v|] [g|r|]) [g|q|] [g|v|] [g|r|]
type DeMorganAlgA d q v r =  -- keyword aliases
  Name "rec" (Mk (MfnK r r) [d|rec|])
    :+: Name "self" (Mk (MfnK () r) [d|rec|])
    :+: Name "buildD"
          ( Name "shareTree" (Mk (MfnK r r) [d|shareTree|])
              :+: Name "buildTree" (Mk (MfnK (Term q v r) r) [d|buildTree|])
              :+: d
          )
    :+: End
type DeMorganAlgD_ :: TypeDict -> (* -> *) -> TypeDict -> * -> * -> * -> DepDict
type DeMorganAlgD_ d m d' q v r =
  D.Name "aliases" (q ~ [g|q|], v ~ [g|v|], r ~ [g|r|], d' ~ DeMorganAlgA d q v r)
  :|: D.Name "rec"
        ( D.Name "self" (MonadFn [d'|self|] m)
            :|: D.Name "rec" (MonadFn [d'|rec|] m)
            :|: D.Name "isTree" (MonadFn (Mk IsTree [d|rec|]) m)
            :|: D.End
        )
  :|: D.Name "build" (D.Remove "isTree" (BuildInheritShareD [g'|buildD|] (Term q v r) r m))
  :|: D.End
deMorganAlg ::
  forall d m d' q v r.
  D.ToConstraint (DeMorganAlgD_ d m d' q v r) => 
  Term q v r -> m r
deMorganAlg LTrue = buildInheritShare @[g'|buildD|] LFalse
deMorganAlg LFalse = buildInheritShare @[g'|buildD|] LTrue
deMorganAlg (State q) = [d'|ask|self|]
deMorganAlg (Var v) = [d'|ask|self|] >>= buildInheritShare @[g'|buildD|] . Not
deMorganAlg (Not r) = return r
deMorganAlg (And a b) =
  Or <$> [d'|monadfn|rec|] a <*> [d'|monadfn|rec|] b >>= buildInheritShare @[g'|buildD|]
deMorganAlg (Or a b) =
  And <$> [d'|monadfn|rec|] a <*> [d'|monadfn|rec|] b >>= buildInheritShare @[g'|buildD|]


data Qombo q = Qombo Int q

type QomboD d m = QomboD_ d (QomboA d [g|q|] [g|v|] [g|r|] [g|r'|]) [g|q|] [g|v|] [g|r|] [g|r'|]
type QomboA d q v r r' =  -- keyword aliases
  QomboA1 d
    ( Name "buildTree" (Mk (MfnK (Term q v r) r) [d|buildTree|])
        :+: Name "qomboF" ([g|fun|] '[Q] :: *)
        :+: Name "qomboFn" (q -> Qombo q)
        :+: End
    )
    r r'
type QomboA1 d d' r r' =
  Name "qombo" (Mk (FRecK r r' (Creation [g'|qomboF|] [g'|qomboFn|])) [d|funr|])
    :+: d'
type QomboD_ d d' q v r r' =
  D.Name "aliases" (q ~ [g|q|], v ~ [g|v|], r ~ [g|r|], r' ~ [g|r'|], d' ~ QomboA d q v r r')
  :|: D.Name "build" (MonadFn [d'|buildTree|] IO)
  :|: D.Name "enumStates"
        ( Create [g'|qomboF|] (q -> Qombo q)
        , FunRecur [d'|qombo|] IO
        )
  :|: D.End
qombo ::
  forall d d' q v r r' f fq.
  (D.ToConstraint (QomboD_ d d' q v r r'), Foldable f) =>
  [(r, f q, (Int, Int -> q, Int -> r, q -> Int))]
  -> IO ([r'], [Qombo q], (Int, Int -> Qombo q, Int -> r', Qombo q -> Int))
qombo afas = do
  let qcounts = map (\(_, _, (c, _, _, _)) -> c) afas
  let totalQCount = sum qcounts
  let afaCount = length afas
  let offsets = listArray (0, afaCount - 1) $ scanl (+) 0 qcounts
  let q2iArr = listArray (0, afaCount - 1) $ map (\(_, _, (_, _, _, fn)) -> fn) afas 
  let finals = (`concatMap` zip [0..] afas) \(afai, (_, fs, _)) -> Qombo afai <$> toList fs
  let q2i (Qombo i q) = (offsets ! i) + (q2iArr ! i) q

  qtsArr :: IOArray Int r' <- newArray_ (0, totalQCount - 1)
  i2qArr :: IOArray Int (Qombo q) <- newArray_ (0, totalQCount - 1)
  inits <- for (zip [0 ..] afas) $
    \(afai, (init, finals, (qCount, i2q, i2r, q2i)))
     -> do
      let mfun = create @[g'|qomboF|] (Qombo afai :: q -> Qombo q)
      mapQombo <- [d'|funRecur|qombo|] mfun
      let finals' = Qombo afai <$> toList finals
      let offset = offsets ! afai
      for_ [0 .. qCount - 1] \qi -> do
        let qi' = offset + qi
        writeArray i2qArr qi' (Qombo afai (i2q qi))
        qts <- mapQombo $ i2r qi
        writeArray qtsArr qi' qts
      mapQombo init
  qtsArr' :: Array Int r' <- unsafeFreeze qtsArr
  i2qArr' :: Array Int (Qombo q) <- unsafeFreeze i2qArr

  return (inits, finals, (totalQCount, (i2qArr' !), (qtsArr' !), q2i))


type UnshareAlgD d f r m = UnshareAlgD_ d m (UnshareAlgA d f r) f r
type UnshareAlgA d f r =  -- keyword aliases
  Name "rec" (Mk (MfnK r r) [d|rec|])
    :+: Name "buildTree" (Mk (MfnK (f r) r) [d|buildTree|])
    :+: End
type UnshareAlgD_ d m d' f r =
  D.Name "aliases" (d' ~ UnshareAlgA d f r)
  :|: D.Name "rec" (D.Name "rec" (MonadFn [d'|rec|] m) :|: D.End)
  :|: D.Name "build" (MonadFn [d'|buildTree|] m)
  :|: D.End
unshareAlg ::
  forall d m d' f r.
  (D.ToConstraint (UnshareAlgD_ d m d' f r), Traversable f) =>
  f r -> m r
unshareAlg fr = mapM [d'|monadfn|rec|] fr >>= [d'|monadfn|buildTree|]

type UnshareA d q v r = Name "recK" (MkN (RecK r (Term q v r) r) [d|any|]) :+: End
type UnshareD_ d m d' q v r =
  D.Name "aliases" (d' ~ UnshareA d q v r, q ~ [g|q|], v ~ [g|v|], r ~ [g|r|])
    :|: D.Name "rec"
          ( D.Name "" (Recur [d'|recK|] m)
              :|: D.Remove "rec" (UnshareAlgD d (Term q v) r m)
          )
    :|: D.End
unshare ::
  forall d m d' q v r n x.
  (D.ToConstraint (UnshareD_ d m d' q v r), [d|buildTree|] ~ 'K n x) =>  -- TODO explicit Inc invariant
  (r, r, (Int, Int -> q, Int -> r, q -> Int)) ->
  m (r, r, (Int, Int -> q, Int -> r, q -> Int))
unshare (init, final, (qCount, i2q, i2r, q2i)) = do
  convert <- [d'|recur|recK|] (unshareAlg @(Name "rec" [d'|recK|] :+: LiftTags d))
  init' <- convert init
  final' <- convert final
  i2r' <- listArray (0, qCount - 1) <$> for [0 .. qCount - 1] (convert . i2r)
  return (init', final', (qCount, i2q, (i2r' !), q2i))

type UnInitStateA d q v r = Name "deref" (Mk (MfnK r (Term q v r)) [d|deref|]) :+: End
type UnInitStateD_ d m d' q v r =
  D.Name "aliases" (d' ~ UnInitStateA d q v r, q ~ [g|q|], v ~ [g|v|], r ~ [g|r|])
    :|: D.Name "deref" (MonadFn [d'|deref|] m)
    :|: D.End
unInitState ::
  forall d m d' q v r n x.
  D.ToConstraint (UnInitStateD_ d m d' q v r) =>
  (r, r, (Int, Int -> q, Int -> r, q -> Int)) ->
  m (r, r, (Int, Int -> q, Int -> r, q -> Int))
unInitState afa@(init, final, states@(_, _, i2r, q2i)) = do
  [d'|monadfn|deref|] init >>= \case
    State q -> return (i2r $ q2i q, final, states)
    _ -> return afa
