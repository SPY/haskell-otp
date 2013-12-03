{-# LANGUAGE FlexibleContexts #-}
module Concurrency.OTP.Process (
  Pid,
  Reason(..),
  spawn,
  linkIO,
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
import Control.Concurrent.STM.TQueue (
    TQueue,
    newTQueue,
    readTQueue,
    writeTQueue
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

type Queue a = TVar (Maybe (TQueue a))

data Pid a = Pid {
    pUniq :: Unique,
    pQueue :: Queue a,
    pTID :: ThreadId,
    pLinked :: TVar (Maybe [Reason -> IO ()]),
    pReason :: TVar (Maybe Reason)
  }

data Reason = Normal
            | Aborted
            | Error String
  deriving (Show, Eq)

instance Eq (Pid a) where
  Pid { pUniq = u1 } == Pid { pUniq = u2 } = u1 == u2

instance Show (Pid a) where
  show Pid { pUniq = u } = "Pid<" ++ show (hashUnique u) ++ ">"

type Process a = ReaderT (Pid a) IO

spawn :: Process a () -> IO (Pid a)
spawn body = do
  queue <- atomically $ newTQueue >>= newTVar . Just
  u <- newUnique
  linked <- atomically $ newTVar $ Just []
  reason <- atomically $ newTVar Nothing
  tid <- flip forkFinally (processFinalizer queue linked reason) $ do
    tid <- myThreadId
    runReaderT body $ Pid u queue tid linked reason
  return $ Pid u queue tid linked reason

resultToReason :: Either SomeException () -> Reason
resultToReason (Left e)
  | fromException e == Just ThreadKilled = Aborted
  | otherwise = Error $ show e
resultToReason (Right ()) = Normal

processFinalizer :: Queue a
                 -> TVar (Maybe [Reason -> IO ()])
                 -> TVar (Maybe Reason)
                 -> Either SomeException () -> IO ()
processFinalizer queue linked reason result = do
  (handlers, r) <- atomically $ do
    writeTVar queue Nothing
    Just hs <- readTVar linked
    writeTVar linked Nothing
    modifyTVar' reason $ \r ->
      case r of
        Nothing -> Just $ resultToReason result
        Just _ -> r
    Just r <- readTVar reason
    return (hs, r)
  mapM_ ($ r) handlers
    
sendIO :: Pid a -> a -> IO ()
sendIO Pid { pQueue = cell } msg = atomically $ do
  queue <- readTVar cell
  when (isJust queue) $
    writeTQueue (fromJust queue) msg

send :: Pid a -> a -> Process b ()
send pid msg = liftIO $ sendIO pid msg

receive :: Process a a
receive = do
  Pid { pQueue = cell } <- ask
  liftIO $ atomically $ do
    Just queue <- readTVar cell -- always Just here
    readTQueue queue

self :: Process a (Pid a)
self = ask

exit :: Process a ()
exit = do
  Pid { pReason = reason } <- ask
  liftIO $ do
    tId <- myThreadId
    atomically $ writeTVar reason $ Just Normal
    killThread tId

terminate :: Pid a -> IO ()
terminate Pid { pTID = tid } = killThread tid

isAlive :: Pid a -> IO Bool
isAlive Pid { pQueue = q } =
  atomically $ readTVar q >>= return . isJust

linkIO :: Pid a -> (Reason -> IO ()) -> IO ()
linkIO Pid { pLinked = cell, pReason = r } handler = do
  reason <- atomically $ do
    content <- readTVar cell
    case content of
      Just linked -> do
        writeTVar cell $ Just $ handler : linked
        return Nothing
      Nothing ->
        readTVar r
  when (isJust reason) $ handler $ fromJust reason

wait :: Pid a -> IO ()
wait pid = do
 done <- newEmptyMVar
 linkIO pid $ const $ putMVar done ()
 takeMVar done
