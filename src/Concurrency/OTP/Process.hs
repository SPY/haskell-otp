module Concurrency.OTP.Process (
  Pid,
  spawn,
  send,
  sendIO,
  receive,
  self,
  exit,
  terminate,
  isAlive,
  liftIO
) where

import Data.Maybe (isJust, fromJust)
import Data.Unique (Unique, newUnique)
import Control.Concurrent (
    ThreadId,
    forkFinally,
    myThreadId,
    killThread
  )
import Control.Concurrent.Chan (
    Chan,
    newChan,
    readChan,
    writeChan
  )
import Control.Concurrent.MVar (
    MVar,
    newMVar,
    readMVar,
    putMVar
  )
import Control.Monad (when)
import Control.Monad.Reader (ReaderT(..), ask, liftIO)
import Control.Exception.Base (SomeException(..))

type Queue a = MVar (Maybe (Chan a))
data Pid a = Pid {
    pUniq :: Unique,
    pQueue :: Queue a,
    pTID :: ThreadId
  }

instance Eq (Pid a) where
  Pid { pUniq = u1 } == Pid { pUniq = u2 } = u1 == u2

type Process a = ReaderT (Pid a) IO

spawn :: Process a () -> IO (Pid a)
spawn body = do
  queue <- newChan >>= newMVar . Just
  u <- newUnique
  tid <- flip forkFinally (processFinalizer queue) $ do
    tid <- myThreadId
    runReaderT body (Pid u queue tid)
  return $ Pid u queue tid

processFinalizer :: Queue a -> Either SomeException () -> IO ()
processFinalizer queue = const $ putMVar queue Nothing

sendIO :: Pid a -> a -> IO ()
sendIO (Pid { pQueue = cell }) msg = do
  queue <- readMVar cell
  when (isJust queue) $
    writeChan (fromJust queue) msg

send :: Pid a -> a -> Process a ()
send pid msg = liftIO $ sendIO pid msg

receive :: Process a a
receive = do
  Pid { pQueue = cell } <- ask
  liftIO $ do
    Just queue <- readMVar cell -- always Just here
    readChan queue

self :: Process a (Pid a)
self = ask

exit :: Process a ()
exit = liftIO $ do
  tId <- myThreadId
  killThread tId

terminate :: Pid a -> IO ()
terminate (Pid { pTID = tid }) = killThread tid

isAlive :: Pid a -> IO Bool
isAlive Pid { pQueue = q } =
  readMVar q >>= return . isJust
