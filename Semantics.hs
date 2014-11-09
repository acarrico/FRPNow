{-# LANGUAGE  TypeSynonymInstances, TypeOperators #-}

module Semantics where

import Control.Applicative
import Control.Monad.Fix
import Data.Maybe

type Time = Double
inf = 1/0

type Behaviour a = Time -> a
data Event a = a :@ Time


instance Monad Event where -- writer monad
  return a = a :@ (-inf)
  (a :@ t) >>= f = b :@ max t t' where (b :@ t') = f a

switch :: Behaviour a -> Event (Behaviour a) -> Behaviour a
switch b (s :@ ts) t = if t < ts then b t else s t


whenJust :: Behaviour (Maybe a) -> Behaviour (Event a)
whenJust f t = let t' = undefined -- min { t' >= t | isJust (f t') }
               in fromJust (f t') :@ t'

seqB :: Behaviour x -> Behaviour a -> Behaviour a
seqB s b t = s t `seq` b t

{- reader monad
   this monad & monadfix is listed in the
   standard libraries as Monad ((->) r) 
   the only difference is that r = time

instance Monad Behaviour where
    return = const
    f >>= k = \ r -> k (f r) r

instance MonadFix Behaviour where
   mfix f = \t -> let a = f a t in a
-}

data SpaceTimeM a -- SpaceTime -> (SpaceTime,a)

instance Monad SpaceTimeM where

type Now a = Behaviour (SpaceTimeM a)

doAt :: IO a -> Now (Event a)
--      IO a -> Behaviour (SpaceTimeM (Event a))
doAt = undefined


continue :: Now (Event (Now a)) -> Now a
--   Behaviour (SpaceTimeM (Event (Behaviour (SpaceTimeM a))) --> Behaviour (SpaceTimeM a)
continue n t = do n' :@ t' <- n t
                  n' (max t' t)

runFRP :: Now (Event a) -> IO a
--        Behaviour (SpaceTimeM (Event a)) -> IO a
runFRP = undefined


--- Derived combinators

step :: a -> Event (Behaviour a) -> Behaviour a
step a s = pure a `switch` s

toBehaviour :: Event (Behaviour a) -> Behaviour (Maybe a)
toBehaviour e = Nothing `step` fmap (fmap Just) e

plan :: Event (Behaviour a) -> Behaviour (Event a)
plan = whenJust . toBehaviour


---- Monad - applicative - functor  stuff

instance Functor Event where
  fmap f (a :@ t) = f a :@ t

instance Applicative Event where
  pure = return
  f <*> g = do x <- f ; y <- g ; return (x y)
