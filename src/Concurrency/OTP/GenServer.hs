{-# LANGUAGE FunctionalDependencies, DeriveDataTypeable #-}
module Concurrency.OTP.GenServer (
  GenServerState(..),
  StartStatus(..),
  ServerIsDead(..),
  start,
  call,
  cast
) where

import Control.Monad.State
import Control.Concurrent.MVar (
    MVar,
    newEmptyMVar,
    putMVar,
    takeMVar,
    isEmptyMVar
  )
import Data.IORef (
    IORef,
    newIORef,
    readIORef,
    writeIORef
  )
import Control.Exception (
    Exception,
    throw
  )
import Data.Typeable (Typeable)

import Concurrency.OTP.Process

type GenServerM s req res = StateT s (Process (Request req res))

class GenServerState req res s | s -> req, s -> res where
  handle_call :: req -> GenServerM s req res res
  handle_cast :: req -> GenServerM s req res ()
  onTerminate :: s -> IO ()
  
  onTerminate = const $ return ()

data GenServer req res = GenServer {
    gsPid :: Pid (Request req res)
  }

instance IsProcess (Request req res) (GenServer req res) where
  getPid (GenServer pid) = pid

data Request req res = Call req (MVar (Maybe res))
                     | Cast req

data StartStatus req res = Ok (GenServer req res) | Fail

start :: (GenServerState req res s) => Process (Request req res) s -> IO (StartStatus req res)
start initFn = do
  after <- newEmptyMVar
  pid <- spawn $ do
    initState <- initFn
    stateRef <- liftIO $ newIORef initState
    liftIO $ putMVar after $ Just stateRef
    handler stateRef
  failLink <- linkIO pid $ const $ do
    isEmpty <- isEmptyMVar after
    when isEmpty $ putMVar after Nothing
  result <- takeMVar after
  unlinkIO pid failLink
  case result of
    Just stateRef -> do
      linkIO pid $ const $ do
        st <- readIORef stateRef
        onTerminate st
      return $ Ok $ GenServer pid
    Nothing -> return Fail

handler :: (GenServerState req res s) => IORef s -> Process (Request req res) ()
handler stateRef = forever $ do
  req <- receive
  serverState <- liftIO $ readIORef stateRef
  case req of
    Call r res -> do
      (result, newState) <- runStateT (handle_call r) serverState
      liftIO $ writeIORef stateRef newState
      liftIO $ putMVar res $ Just result
    Cast r -> do
      newState <- execStateT (handle_cast r) serverState
      liftIO $ writeIORef stateRef newState

data ServerIsDead = ServerIsDead deriving (Show, Typeable)

instance Exception ServerIsDead

call :: GenServer req res -> req -> IO res
call GenServer { gsPid = pid } msg = do
  response <- newEmptyMVar
  linkId <- linkIO pid $ const $ putMVar response Nothing
  sendIO pid $ Call msg response
  result <- takeMVar response
  unlinkIO pid linkId
  case result of
    Just r -> return r
    Nothing -> throw ServerIsDead

cast :: GenServer req res -> req -> IO ()
cast GenServer { gsPid = pid } msg =
  sendIO pid $ Cast msg
