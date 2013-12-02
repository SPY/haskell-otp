module Concurrency.OTP.Process (
  Pid,
  spawn,
  send,
  receive,
  self,
  exit,
  terminate,
  liftIO
) where

import Data.Maybe (isJust, fromJust)
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
    pQueue :: Queue a,
    pTID :: ThreadId
  }

type Process a = ReaderT (Pid a) IO

spawn :: Process a () -> IO (Pid a)
spawn body = do
  queue <- newChan >>= newMVar . Just
  tid <- flip forkFinally (processFinalizer queue) $ do
    tid <- myThreadId
    runReaderT body (Pid queue tid)
  return $ Pid queue tid

processFinalizer :: Queue a -> Either SomeException () -> IO ()
processFinalizer queue = const $ putMVar queue Nothing

send :: Pid a -> a -> Process a ()
send (Pid { pQueue = cell }) msg = liftIO $ do
  queue <- readMVar cell
  when (isJust queue) $ do
    writeChan (fromJust queue) msg

receive :: Pid a -> Process a a
receive (Pid { pQueue = cell }) = liftIO $ do
  Just queue <- readMVar cell -- always just if we here
  readChan queue

self :: Process a (Pid a)
self = ask

exit :: Process a ()
exit = liftIO $ do
  tId <- myThreadId
  killThread tId

terminate :: Pid a -> IO ()
terminate (Pid { pTID = tid }) = killThread tid
