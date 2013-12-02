module Concurrency.OTP.Process (
  Pid,
  spawn,
  send,
  receive,
  self
) where

import Data.Maybe (isJust, fromJust)
import Control.Concurrent (forkFinally)
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
import Control.Applicative ((<$>))
import Control.Monad (when)
import Control.Monad.Reader (ReaderT(..), ask, liftIO)

data Pid a = Pid (MVar (Maybe (Chan a)))

type Process a = ReaderT (Pid a) IO

spawn :: Process a () -> IO (Pid a)
spawn body = do
  queue <- newChan
  cell <- newMVar $ Just queue
  let pid = Pid cell
  forkFinally (runReaderT body pid) $ const $ putMVar cell Nothing
  return pid

send :: Pid a -> a -> Process a ()
send (Pid cell) msg = do
  queue <- liftIO $ readMVar cell
  when (isJust queue) $ do
    liftIO $ writeChan (fromJust queue) msg

receive :: Pid a -> Process a a
receive (Pid cell) = do
  Just queue <- liftIO $ readMVar cell -- always just if we here
  liftIO $ readChan queue

self :: Process a (Pid a)
self = ask
