{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

module Afa.Convert.Smv where

import Data.Array
import qualified Data.Text as T
import Data.String.Interpolate.IsString
import qualified Data.List.NonEmpty as NE

import Afa
import Afa.Bool
import qualified Afa.Term.Bool as BTerm
import qualified Afa.Term.Mix as MTerm
import qualified Afa.Convert.Capnp.Afa as CapAfa (varCount)

toSmv :: BoolAfaUnswallowed Int -> T.Text
toSmv (BoolAfa bterms (Afa mterms states init)) = T.unlines$
     [ "MODULE main"
     , "VAR"
     ]
  ++ map (\j -> [i|  q#{j}: boolean;|]) [0..qcount - 1]
  ++ map (\j -> [i|  v#{j}: boolean;|]) [0..varCnt - 1]
  ++ "DEFINE"
   : map (\(j, t) -> [i|  b#{j} := #{fromBTerm t};|]) (assocs bterms)
  ++ map (\(j, t) -> [i|  m#{j} := #{fromMTerm t};|]) (assocs mterms)
  ++ [ [i|INIT q#{init}|]
     , T.append "TRANS "$ T.intercalate " & "$
         map (\(q, t) -> [i|(q#{q} -> m#{t})|]) (assocs states)
     , [i|SPEC AG(#{qDisj})|]
     ]
  where
  qcount = rangeSize$ bounds states
  (varCnt, bterms') = CapAfa.varCount bterms
  qDisj = T.intercalate " | "$ map (\q -> [i|q#{q}|]) [0..qcount-1]

fromBTerm :: BTerm.Term Int Int -> T.Text
fromBTerm BTerm.LTrue = "TRUE"
fromBTerm BTerm.LFalse = "FALSE"
fromBTerm (BTerm.Predicate p) = [i|v#{p}|]
fromBTerm (BTerm.Not x) = [i|!b#{x}|]
fromBTerm (BTerm.And xs) = T.intercalate " & "$ map (\x -> [i|b#{x}|])$ NE.toList xs
fromBTerm (BTerm.Or xs) = T.intercalate " | "$ map (\x -> [i|b#{x}|])$ NE.toList xs

fromMTerm :: MTerm.Term Int Int Int -> T.Text
fromMTerm MTerm.LTrue = "TRUE"
fromMTerm (MTerm.Predicate p) = [i|b#{p}|]
fromMTerm (MTerm.State q) = [i|next(q#{q})|]
fromMTerm (MTerm.And xs) = T.intercalate " & "$ map (\x -> [i|m#{x}|])$ NE.toList xs
fromMTerm (MTerm.Or xs) = T.intercalate " | "$ map (\x -> [i|m#{x}|])$ NE.toList xs
