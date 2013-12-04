{-# LANGUAGE FunctionalDependencies #-}
module Concurrency.OTP.GenServer (
  GenServerState(..),
  start,
  call,
  cast
) where

import Control.Applicative ((<$>))
import Control.Monad.State
import Control.Concurrent.MVar (
    MVar,
    newEmptyMVar,
    putMVar,
    takeMVar
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

start :: (GenServerState req res s) => s -> IO (GenServer req res)
start initState = GenServer <$> (spawn $ evalStateT handler initState)

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
