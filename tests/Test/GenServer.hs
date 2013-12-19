{-# OPTIONS_GHC -F -pgmF htfpp #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances #-}
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
import Data.Unique (Unique)
import Control.Concurrent (threadDelay, forkIO)

import Concurrency.OTP.GenServer
import Concurrency.OTP.Process

ms n = threadDelay $ n * 1000

data CounterState = Counter { counter :: Int }

data Command = Get | Inc

instance GenServerState Command Int CounterState where
  handle_call Get _ = gets $ reply . counter
  
  handle_cast Inc = do
    modify $ \st -> st { counter = counter st + 1 }
    return noreply

test_successStart = do
  cell <- newEmptyMVar
  Ok serv <- start $ do
    liftIO $ putMVar cell ()
    return $ Counter 0
  isEmptyMVar cell >>= assertBool . not

test_failureStart = do
  result <- start $ do
    error "Bad params"
    return $ Counter 0
  assertBool $ isFail result
  where isFail Fail = True
        isFail _    = False

test_call = do
  Ok serv <- start $ return $ Counter 0
  call serv Get >>= assertEqual 0 

test_callWithTimeout = do
  Ok serv <- start $ return $ Counter 0
  callWithTimeout serv (Just 10) Get >>= assertEqual (Just 0)

data SlowCallState = SlowCallState

instance GenServerState () () SlowCallState where
  handle_call _ _ = liftIO (ms 10) >> return (reply ())
  handle_cast _ = return noreply

test_callWithFailByTimeout = do
  Ok serv <- start $ return SlowCallState
  callWithTimeout serv (Just 5) () >>= assertEqual Nothing
  callWithTimeout serv (Just 20) () >>= assertEqual (Just ())

data StopOnCallState = StopOnCallState

instance GenServerState (MVar ()) () StopOnCallState where
  handle_call _ _ = return $ stop "stop"
  handle_cast r = do
    liftIO $ putMVar r ()
    return $ stop "stop"

test_stopOnCall = do
  req <- newEmptyMVar
  Ok serv <- start $ return StopOnCallState
  assertThrowsIO (call serv req) isServerDead

test_stopOnCast = do
  req <- newEmptyMVar
  Ok serv <- start $ return StopOnCallState
  cast serv req
  takeMVar req
  isAlive serv >>= assertBool . not

data ReplyAndStopState = ReplyAndStopState

instance GenServerState () () ReplyAndStopState where
  handle_call () _ = return $ replyAndStop () "stop"
  handle_cast () = return noreply

test_replyAndStop = do
  Ok serv <- start $ return ReplyAndStopState
  call serv ()
  isAlive serv >>= assertBool . not

data DelayedReplyState = DelayedReplyState (Maybe Unique)

instance GenServerState () () DelayedReplyState where
  handle_call () reqId = do
    put $ DelayedReplyState $ Just reqId
    return noreply
  handle_cast () = do
    DelayedReplyState (Just reqId) <- get
    replyWith reqId ()
    return noreply

test_delayedReply = do
  Ok server <- start $ return $ DelayedReplyState Nothing
  forkIO $ do
    threadDelay $ 10*1000
    cast server ()
  call server ()
  assertBool True

test_cast = do
  Ok serv <- start $ return $ Counter 1
  call serv Get >>= assertEqual 1
  cast serv Inc
  call serv Get >>= assertEqual 2

data TerminatedState = TS { termCell :: MVar () }

instance GenServerState Int () TerminatedState where
  handle_call 1 _ = return $ reply () -- for fail
  handle_cast 1 = return noreply

  onTerminate (TS cell) = putMVar cell ()

test_terminate = do
  cell <- newEmptyMVar
  Ok serv <- start $ return $ TS cell
  call serv 1 -- ok
  isEmptyMVar cell >>= assertBool
  cast serv 2 -- fail
  takeMVar cell >>= assertEqual ()

isServerDead ServerIsDead = True

test_failOnCall = do
  cell <- newEmptyMVar
  Ok serv <- start $ return $ TS cell
  call serv 1 -- ok
  isEmptyMVar cell >>= assertBool
  assertThrowsIO (call serv 2) isServerDead
  takeMVar cell >>= assertEqual ()
