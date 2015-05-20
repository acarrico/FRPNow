{-# LANGUAGE  RecursiveDo, Rank2Types,OverlappingInstances, DeriveFunctor,TupleSections,TypeOperators,MultiParamTypeClasses, FlexibleInstances,TypeSynonymInstances, LambdaCase, ExistentialQuantification, GeneralizedNewtypeDeriving, BangPatterns #-}
module Impl.WXFRPNow(Behavior, Event, Now, never, whenJust, switch, sample, unsafeLazy, callbackE , whenJustSample ,syncIO, runWx,frpFrame) where



import Control.Monad.Writer hiding (mapM_,liftIO)
import Control.Monad.Writer.Class
import Control.Monad.Reader.Class
import Control.Monad.Reader hiding (mapM_,liftIO)
import Control.Monad hiding (mapM_)
import Control.Monad.IO.Class
import Control.Applicative hiding (Const,empty)
import Data.IORef
import Data.Maybe
import Graphics.UI.WX hiding (Event,empty)
import System.IO.Unsafe -- only for unsafeMemoAgain at the bottom
import Debug.Trace
import Prelude
import Data.Either

import Swap
import Impl.Ref
import Impl.WxPrimEv


-- comment/uncomment here to disable optimization
again :: (x -> M  x) -> M x -> M x
again = unsafeMemoAgain
--again f m = m

 
type N x = M x


-- Start events, a bit more optimized than in paper


data Event a = E (M (Event a))
             | Occ a
             | Never

runE :: Event a -> M (Event a)
runE (Occ a) = return (Occ a)
runE Never   = return Never
runE (E m)   = m
{-# INLINE runE #-}

curE ::  Event a -> M (Maybe a)
curE e = runE e >>= return . \case
  Occ x -> Just x
  _     -> Nothing


fromMaybeM :: M (Maybe a) -> Event a
fromMaybeM m =
  let x = E $ m >>= return . \case
           Just x -> Occ x
           _      -> x
  in x

never :: Event a
never = Never

instance Monad Event where
  return = Occ
  Never    >>= f = Never
  (Occ x)  >>= f = f x
  (E em)   >>= f = memoE $
    em >>= \case
      Never ->  return Never
      Occ x ->  runE (f x)
      E em'  ->  return (E $ bindE em' f)

bindE :: M (Event a) -> (a -> Event b) -> M (Event b)
bindE em f = em >>= \case
    Never -> return Never
    Occ x -> runE (f x)
    E em' -> return $ E $ bindE em' f

rerunE = runE

memoE :: M (Event a) -> Event a
memoE m = E (again rerunE m)

instance Functor Event where
  fmap = liftM

instance Applicative Event where
  pure = return
  (<*>) = ap

-- Start behaviors, also a bit more optimized than in paper

data Behavior a = B (M  (a, Event (Behavior a)))
                | Const a

runB :: Behavior a -> M  (a, Event (Behavior a))
runB (Const x) = return (x, never)
runB (B m)     = m

curB :: Behavior a -> M a
curB b = fst <$> runB b

instance Monad Behavior where
  return = Const
  (Const x) >>= f = f x
  (B bm)    >>= f = memoB $
    do (h,t) <- bm
       case f h of
         Const fv -> return (fv, (`bindB` f) <$> t)
         B fm     -> 
              do (fh,th) <- fm
                 return (fh, switchEv th ( (`bindB` f) <$> t) )

bindB (Const x) (!f) = f x
bindB (B bm)   (!f) = B $ 
    do (h,t) <- bm
       case f h of
         Const fv -> return (fv, (`bindB` f) <$> t)
         B fm     -> 
              do (fh,th) <- fm
                 return (fh, switchEv th ((`bindB` f) <$> t))

switch :: Behavior a -> Event (Behavior a) -> Behavior a
switch b Never   = b
switch _ (Occ b) = b
switch b e@(E em)   = memoB $ em >>= \case
   Occ   x -> runB x
   Never   -> runB b
   _       -> do (h,t) <- runB b
                 return (h, switchEv t e)

switch' :: Behavior a -> Event (Behavior a) -> Behavior a
switch' b Never   = b
switch' _ (Occ b) = b
switch' b e@(E em)   = B $ em >>= \case
   Occ   x -> runB x
   Never   -> runB b
   E em'   -> do (h,t) <- runB b
                 return (h, switchEv t e)

switchEv :: Event (Behavior a) -> Event (Behavior a) -> Event (Behavior a)
switchEv l Never     = l
switchEv l (Occ r)   = Occ r
switchEv Never r     = r
switchEv (Occ x) r   = Occ (x `switch'` r)
switchEv (E l) (E r) = E $
  r >>= \case
    Occ y -> return $ Occ y
    r' -> l >>= return . \case
           Occ x -> Occ (x `switch'` r')
           l'    -> switchEv l' r'



whenJust :: Behavior (Maybe a) -> Behavior (Event a)
whenJust (Const Nothing)  = pure never
whenJust (Const (Just x)) = pure (pure x)
whenJust (B bm) = memoB $
  do (h, t) <- bm
     case h of
      Just x -> return (return x, whenJust' <$> t)
      Nothing -> do en <- planM (runB . whenJust' <$> t)
                    return (en >>= fst, en >>= snd)

whenJust' :: Behavior (Maybe a) -> Behavior (Event a)
whenJust' (Const Nothing)  = pure never
whenJust' (Const (Just x)) = pure (pure x)
whenJust' (B bm) = B $
  do (h, t) <- bm
     case h of
      Just x -> return (return x, whenJust' <$> t)
      Nothing -> do en <- planM (runB . whenJust' <$> t)
                    return (en >>= fst, en >>= snd)


rerunB :: (a, Event (Behavior a)) -> M (a, Event (Behavior a))
rerunB (h,t) = runE t >>= \case
      Occ x -> runB x
      Never     -> return (h,Never)
      t'        -> return (h,t')

memoB :: M (a, Event (Behavior a)) -> Behavior a
memoB m = B (again rerunB m)


-- specialize this..
whenJustSample :: Behavior (Maybe (Behavior a)) -> Behavior (Event a)
{-
whenJustSample b = do x <- whenJust b 
                      plan x
-}
whenJustSample (Const Nothing)  = pure never
whenJustSample (Const (Just x)) = B $ do v <- curB x; return (pure v, never)
whenJustSample (B bm) = memoB $
  do (h, t) <- bm
     case h of
      Just x -> do v <- curB x; return (pure v, whenJustSample' <$> t)
      Nothing -> do en <- planM (runB . whenJustSample' <$> t)
                    return (en >>= fst, en >>= snd)

whenJustSample' (Const Nothing)  = pure never
whenJustSample' (Const (Just x)) = B $ do v <- curB x; return (pure v, never)
whenJustSample' (B bm) = B $
  do (h, t) <- bm
     case h of
      Just x -> do v <- curB x; return (pure v, whenJustSample' <$> t)
      Nothing -> do en <- planM (runB . whenJustSample' <$> t)
                    return (en >>= fst, en >>= snd)

instance Swap Behavior Event  where
   swap Never = pure Never
   swap (Occ x) = Occ <$> x
   swap e       = B $
       runE e >>= \case
         Never -> return (Never, Never)
         Occ x -> runB (Occ <$> x)
         _    -> do ev <- planM (runB <$> e)
                    return (fst <$> ev, (Occ <$>) <$> (ev >>= snd))

instance Functor Behavior where
  fmap = liftM

instance Applicative Behavior where
  pure = return
  (<*>) = ap


-- Memo stuff:
{-
again :: (x -> M x) -> M x -> M x
again f m = unsafePerformIO $
             runMemo f <$> newIORef m

runMemo ::  (x -> M x) -> IORef (M x) -> M x
runMemo f mem = 
   do m <- liftIO $ readIORef mem
      v <- m
      liftIO $ putIORef (f v)
      return v
-}

unsafeMemoAgain :: (x -> M  x) -> M x -> M x
unsafeMemoAgain again m = unsafePerformIO $ runMemo <$> newIORef (Nothing, m) where
   runMemo mem =
    -- use mdo notation such that we can obtain the result of this computation in the
    -- computation m...
    mdo r <- getRound
        (v,m) <- liftIO $ readIORef mem
        liftIO $ writeIORef mem (Just (r,res), again res)
        res <- case v of
         Just (p,val) ->
           case compare p r of
            LT -> m
            EQ -> return val
            GT -> error "non monotonic sampling!!"
         Nothing -> m
        return res


-- unexported helper functions

getRound :: N Round
getRound = ReaderT $ \c -> curRound (mclock c)
{-# INLINE getRound #-}
getClock :: N Clock
getClock = ReaderT  $ \c -> return (mclock c)
{-# INLINE getClock #-}
getIdleCallback = ReaderT $ \c -> return (mcallback c)
{-# INLINE getIdleCallback #-}
addPlan :: Plan -> N ()
addPlan p = ReaderT  $ \s  -> modifyIORef (mplans s) (p :)
{-# INLINE addPlan #-}

addLazy :: Lazy -> N ()
addLazy p = ReaderT $ \s  -> modifyIORef (mlazies s) (p :)
{-# INLINE addLazy #-}

takePlans :: N Plans
takePlans = ReaderT $ \s  -> do x <- readIORef (mplans s) ; writeIORef (mplans s) []; return (reverse x)
{-# INLINE takePlans #-}

takeLazies :: N Lazies
takeLazies = ReaderT $ \s  -> do x <- readIORef (mlazies s) ; writeIORef (mlazies s) []; return (reverse x)

-- Start main loop

type Plans = [Plan]
type PlanState a = IORef (Either (N (Event (N a))) a)
data Plan = forall a. Plan !(Ref (PlanState a))

type Lazies = [Lazy]
data Lazy = forall a. Lazy!(N a) {-# UNPACK #-} !(IORef a)

data MInfo = MInfo { mclock :: {-# UNPACK #-}  !Clock, mcallback :: IO Bool, mlazies ::  {-# UNPACK #-}  !(IORef Lazies), mplans :: {-# UNPACK #-}  !(IORef Plans) }

type M a = ReaderT MInfo IO a  

runM x = runReaderT x

makeLazy :: N a -> N (Event a)
makeLazy m = ReaderT $ \c -> 
       do n <- curRound (mclock c)
          r <- newIORef undefined
          modifyIORef (mlazies c) (Lazy m r :)
          return (readLazyState n r)

readLazyState :: Round -> IORef a -> Event a
readLazyState n r =
  let x = E $ ReaderT $ \c -> 
       do m <- curRound (mclock c)
          if n == m
          then return x
          else Occ <$> readIORef r
  in x


elimLazies :: MInfo -> IO ()
elimLazies c = loop
  where 
   loop = 
     do  lz <- reverse <$> readIORef (mlazies c) 
         writeIORef (mlazies c) []
         case lz of
          [] -> return ()
          l  -> mapM_ (\(Lazy m r) -> runM m c >>= writeIORef r) l >> loop


tryPlans :: MInfo -> IO ()
tryPlans c =  
  do --pl' <- makeStrongRefs pl
     pl <- reverse <$> readIORef (mplans c) 
     writeIORef (mplans c) []
     -- liftIO $ putStrLn ("nrplans " ++ show (length pl))
     mapM_ tryPlan pl where
   tryPlan :: Plan -> IO  ()
   tryPlan p@(Plan r) = 
     deRef r >>= \x -> case x of
        Just x -> runM (tryAgain x) c >>= \case
             E _     -> modifyIORef (mplans c) (p :)
             _       -> return ()

        Nothing ->  return ()



runLazies ::  N a -> MInfo -> IO a
runLazies m c = 
             do  v <- runM m c
                 elimLazies c
                 return v



frpFrame :: [Prop (Frame ())] -> Now (Frame ())
frpFrame p = Now $ do cb <- getIdleCallback
                      liftIO $ frame ((on idle := cb): p)

runWx :: Now () -> IO ()
runWx  m =  start $ 
                do p <- newIORef []
                   l <- newIORef []
                   c <- newClock
                   let mi = (let x = MInfo c (idleCallback x) l p in x)
                   runLazies (toN m) mi

idleCallback :: MInfo -> IO Bool
idleCallback c = 
  roundEnd (mclock c) >>= \x -> 
     if x 
     then do elimLazies c
             tryPlans c
             return False
     else return False


-- Plan stuff


{-
makePlanRef :: (forall a. IORef a -> IO (Ref (IORef a))) -> Event (N a) -> N (Event a)
makePlanRef makeRef (E em)   = em >>= \case
  Never -> return Never
  Occ m -> return <$> m
  E em'    -> do r <- liftIO $ newIORef (Left em')
		 let res = E $ tryAgain r
		 ref <- liftIO $ makeRef r
		 addPlan (Plan ref)
		 return res
-}

planM ::  Event (N a) -> N (Event a)
planM (E em)   = em >>= \case
  Never -> return Never
  Occ m -> return <$> m
  E em'    -> do r <- liftIO $ newIORef (Left em')
		 let res = E $ tryAgain r
		 ref <- liftIO $ makeWeakIORef r
		 addPlan (Plan ref)
		 return res

planN ::  Event (N a) -> N (Event a)
planN (E em)   = em >>= \case
  Never -> return Never
  Occ m -> return <$> m
  E em'    -> do r <- liftIO $ newIORef (Left em')
		 let res = E $ tryAgain r
		 ref <- liftIO $ makeStrongRef r
		 addPlan (Plan ref)
		 return res

tryAgain :: PlanState a -> N (Event a)
tryAgain r =
   let x = ReaderT $ \c -> 
           do readIORef r >>= \case
               Right x -> return (Occ x)
               Left em -> runM em c >>= \case
                 Never -> return Never
                 Occ m -> do res <- runM m c
                             writeIORef r (Right res)
                             return (Occ res)
                 E em'    -> do writeIORef r (Left em')
                                return (E x)
  in x



-- Start IO Stuff

newtype Now a = Now {toN :: N a} deriving (Functor,Applicative,Monad, MonadFix)

sample :: Behavior a -> Now a
sample b = Now $ curB b
{-
async :: IO a -> Now (Event a)
async m = Now $
  do c <- ask
     pe <- liftIO $ spawn c m
     return (fromPrimEv pe)
-}
callbackE :: Now (Event a, a -> IO ())
callbackE = Now $
  do c <- getClock
     (pe,cb) <- liftIO $ getCallback c
     return (fromPrimEv pe, cb)

fromPrimEv :: PrimEv a -> Event a
fromPrimEv pe = fromMaybeM $ (pe `observeAt`) <$> getRound

instance Swap Now Event where
 swap e = Now $ planN (toN <$> e)


unsafeLazy :: Behavior (Event a) -> Behavior (Event a)
unsafeLazy m = B $
   do e <- makeLazy (runB m)
      return (e >>= fst, e >>= snd)

-- occasionally handy for debugging

syncIO :: IO a -> Now a
syncIO m = Now $ liftIO m
