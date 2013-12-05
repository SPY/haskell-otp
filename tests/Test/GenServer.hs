{-# OPTIONS_GHC -F -pgmF htfpp #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Test.GenServer (htf_thisModulesTests) where

import Test.Framework

import Control.Monad.State
import Control.Concurrent.MVar (
    MVar,
    newEmptyMVar,
    putMVar,
    takeMVar,
    isEmptyMVar
  )

import Concurrency.OTP.GenServer

data CounterState = Counter { counter :: Int }

data Command = Get | Inc

instance GenServerState Command Int CounterState where
  handle_call Get = gets counter
  
  handle_cast Inc =
    modify $ \st -> st { counter = counter st + 1 }

data TerminatedState = TS { termCell :: MVar () }

instance GenServerState Int () TerminatedState where
  handle_call 1 = return () -- for fail
  handle_cast 1 = return ()

  onTerminate (TS cell) = putMVar cell ()

test_successStart = do
  cell <- newEmptyMVar
  Ok serv <- start $ do
    liftIO $ putMVar cell ()
    return $ Counter 0
  isEmptyMVar cell >>= assertBool . not

test_failureStart = do
  Fail <- start $ do
    error "Bad params"
    return $ Counter 0
  assertBool True

test_call = do
  Ok serv <- start $ return $ Counter 0
  call serv Get >>= assertEqual 0
  
test_cast = do
  Ok serv <- start $ return $ Counter 1
  call serv Get >>= assertEqual 1
  cast serv Inc
  call serv Get >>= assertEqual 2

test_terminate = do
  cell <- newEmptyMVar
  Ok serv <- start $ return $ TS cell
  call serv 1 -- ok
  isEmptyMVar cell >>= assertBool
  cast serv 2 -- fail
  takeMVar cell >>= assertEqual ()
