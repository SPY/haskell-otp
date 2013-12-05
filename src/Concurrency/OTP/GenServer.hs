{-# LANGUAGE FunctionalDependencies #-}
module Concurrency.OTP.GenServer (
  GenServerState(..),
  StartStatus(..),
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

import Concurrency.OTP.Process

type GenServerM s req res = StateT s (Process (Request req res))

class GenServerState req res s | s -> req, s -> res where
  handle_call :: req -> GenServerM s req res res
  handle_cast :: req -> GenServerM s req res ()

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
    self' <- self
    liftIO $ putMVar after $ Ok $ GenServer self'
    evalStateT handler initState
  linkIO pid $ const $ do -- TODO: add unlink on success
    isEmpty <- isEmptyMVar after
    when isEmpty $ putMVar after Fail
  takeMVar after

handler :: (GenServerState req res s) => GenServerM s req res ()
handler = forever $ do
  req <- lift receive
  case req of
    Call r res -> do
      result <- handle_call r
      liftIO $ putMVar res $ Just result
    Cast r -> do
      handle_cast r
      return ()

call :: GenServer req res -> req -> IO res
call GenServer { gsPid = pid } msg = do
  response <- newEmptyMVar
  sendIO pid $ Call msg response
  result <- takeMVar response
  case result of
    Just r -> return r
    Nothing -> error "GenServer is dead"

cast :: GenServer req res -> req -> IO ()
cast GenServer { gsPid = pid } msg =
  sendIO pid $ Cast msg
