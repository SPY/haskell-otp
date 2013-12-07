{-# LANGUAGE FunctionalDependencies, FlexibleInstances #-}
module Concurrency.OTP.Process (
  Pid,
  Process,
  Reason(..),
  IsProcess(..),
  LinkId,
  spawn,
  linkIO,
  unlinkIO,
  link,
  send,
  sendIO,
  receive,
  self,
  exit,
  terminate,
  isAlive,
  wait,
  liftIO
) where

import Data.Maybe (isJust, fromJust)
import Data.Unique (Unique, newUnique, hashUnique)
import Data.Map (
    Map,
    empty,
    insert,
    delete,
    elems
  )
import Control.Applicative (
    (<$>),
    (<*>),
    pure
  )
import Control.Concurrent (
    ThreadId,
    forkFinally,
    myThreadId,
    killThread
  )
import Control.Concurrent.MVar (
    newEmptyMVar,
    takeMVar,
    putMVar
  )
import Control.Monad.STM (atomically)
import Control.Concurrent.STM.TMChan (
    TMChan,
    newBroadcastTMChan,
    readTMChan,
    writeTMChan,
    closeTMChan,
    dupTMChan,
    isClosedTMChan
    )
import Control.Concurrent.STM.TVar (
    TVar,
    newTVar,
    readTVar,
    writeTVar,
    modifyTVar'
  )
import Control.Monad (when)
import Control.Monad.Reader (ReaderT(..), ask, liftIO)
import Control.Exception.Base (
    Exception(..),
    SomeException,
    AsyncException(ThreadKilled)
  )

class IsProcess a p | p -> a where
  getPid :: p -> Pid a

type Queue a = TMChan a

newtype LinkId = LinkId Unique deriving (Eq, Ord)

data Pid a = Pid {
    pUniq :: Unique,
    pQueue :: Queue a,
    pTID :: ThreadId,
    pLinked :: TVar (Maybe (Map LinkId (Reason -> IO ()))),
    pReason :: TVar (Maybe Reason)
  }

instance IsProcess a (Pid a) where
  getPid = id

data Reason = Normal
            | Aborted
            | Error String
  deriving (Show, Eq)

instance Eq (Pid a) where
  Pid { pUniq = u1 } == Pid { pUniq = u2 } = u1 == u2

instance Show (Pid a) where
  show Pid { pUniq = u } = "Pid<" ++ show (hashUnique u) ++ ">"

type Process msg = ReaderT (Pid msg) IO

spawn :: Process msg () -> IO (Pid msg)
spawn body = do
  u <- newUnique
  pid <- atomically $
    Pid <$> pure u
        <*> newBroadcastTMChan
        <*> pure undefined
        <*> newTVar (Just empty)
        <*> newTVar Nothing
  -- We need this to workaround a bug in stm-chans where
  -- closing of broadcast channel doesn't lead to closing
  -- of the duplicated channel
  rQueue <- atomically $ dupTMChan (pQueue pid)
  tid <- flip forkFinally (processFinalizer rQueue pid) $ do
    tid <- myThreadId
    runReaderT body $ pid{pTID=tid,pQueue=rQueue}
  return $ pid{pTID=tid}

resultToReason :: Either SomeException () -> Reason
resultToReason (Left e)
  | fromException e == Just ThreadKilled = Aborted
  | otherwise = Error $ show e
resultToReason (Right ()) = Normal

processFinalizer :: TMChan a
                 -> Pid a
                 -> Either SomeException () -> IO ()
processFinalizer queue Pid{pLinked=linked,pReason=reason} result = do
  (handlers, r) <- atomically $ do
    closeTMChan queue
    Just hs <- readTVar linked
    writeTVar linked Nothing
    modifyTVar' reason $ \r ->
      case r of
        Nothing -> Just $ resultToReason result
        Just _ -> r
    Just r <- readTVar reason
    return (elems hs, r)
  mapM_ ($ r) handlers
    
sendIO :: Pid msg -> msg -> IO ()
sendIO Pid { pQueue = cell } msg = atomically $ writeTMChan cell msg

send :: Pid msg -> msg -> Process a ()
send pid msg = liftIO $ sendIO pid msg

receive :: Process msg msg
receive = do
  Pid { pQueue = cell } <- ask
  liftIO $ atomically $ fmap fromJust (readTMChan cell)

self :: Process msg (Pid msg)
self = ask

exit :: Process msg ()
exit = do
  Pid { pReason = reason } <- ask
  liftIO $ do
    tId <- myThreadId
    atomically $ writeTVar reason $ Just Normal
    killThread tId

terminate :: (IsProcess msg p) => p -> IO ()
terminate p =
  let Pid { pTID = tid } = getPid p
  in killThread tid

isAlive :: (IsProcess msg p ) => p -> IO Bool
isAlive p =
  let Pid { pQueue = q } = getPid p
  in atomically $ fmap not (isClosedTMChan q)

linkIO :: (IsProcess msg p) => p -> (Reason -> IO ()) -> IO LinkId
linkIO p handler = do
  let Pid { pLinked = cell, pReason = r } = getPid p
  linkId <- LinkId <$> newUnique
  reason <- atomically $ do
    content <- readTVar cell
    case content of
      Just linked -> do
        writeTVar cell $ Just $ insert linkId handler linked
        return Nothing
      Nothing ->
        readTVar r
  when (isJust reason) $ handler $ fromJust reason
  return linkId

link :: (IsProcess msg p) => p -> Process msg LinkId
link p = do
  self' <- self
  liftIO $ linkIO p $ const $ terminate self'

unlinkIO :: (IsProcess msg p) => p -> LinkId -> IO ()
unlinkIO p linkId = do
  let Pid { pLinked = cell } = getPid p
  atomically $ do
    handlers <- readTVar cell
    when (isJust handlers) $ do
      writeTVar cell $ Just $ delete linkId $ fromJust handlers

wait :: (IsProcess msg p) => p -> IO ()
wait p = do
 done <- newEmptyMVar
 linkIO (getPid p) $ const $ putMVar done ()
 takeMVar done
