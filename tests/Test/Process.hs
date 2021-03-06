{-# OPTIONS_GHC -F -pgmF htfpp #-}
module Test.Process (htf_thisModulesTests) where

import Test.Framework

import Data.Unique
import Data.Maybe (isNothing, isJust)
import Control.Applicative ((<$>))
import Control.Concurrent (threadDelay, yield)
import Control.Concurrent.MVar (
    newEmptyMVar,
    takeMVar,
    putMVar,
    isEmptyMVar
  )

import Concurrency.OTP.Process

ms = threadDelay . (1000*)

test_spawnNewProcessAndWait = do
  resp <- newEmptyMVar
  pid <- spawn $ liftIO $ do
    ms 5
    putMVar resp ()
  isEmptyMVar resp >>= assertBool
  wait pid
  isEmptyMVar resp >>= assertBool . not

test_normalTerminate = do
  resp <- newEmptyMVar
  pid <- spawn $ return ()
  linkIO pid $ putMVar resp
  takeMVar resp >>= assertEqual Normal

test_isAlive = do
  pid <- spawn $ liftIO $ ms 10
  isAlive pid >>= assertBool
  wait pid
  isAlive pid >>= assertBool . not

test_unlink = do
  lock     <- newEmptyMVar
  handler1 <- newEmptyMVar
  handler2 <- newEmptyMVar
  pid <- spawn $ liftIO $ takeMVar lock
  linkId <- linkIO pid $ putMVar handler1
  linkIO pid $ putMVar handler2
  unlinkIO pid linkId
  putMVar lock ()
  takeMVar handler2
  yield
  isEmptyMVar handler1 >>= assertBool

test_failInLinkedAction = do
  handler1 <- newEmptyMVar
  handler2 <- newEmptyMVar
  pid <- spawn $ liftIO $ ms 5
  linkIO pid $ const $ putMVar handler1 () >> error "oops"
  linkIO pid $ const $ putMVar handler2 ()
  takeMVar handler1
  ms 3
  isEmptyMVar handler2 >>= assertBool . not

test_processLinkNormal = do
  pid <- spawn $ liftIO $ ms 10
  pid2 <- spawn $ link pid >> (liftIO $ ms 50)
  wait pid
  ms 1
  isAlive pid2 >>= assertBool

test_processLinkAbnormal = do
  waitCell <- newEmptyMVar
  pid <- spawn $ (liftIO $ ms 10) >> error "something wrong"
  pid2 <- spawn $ link pid >> (liftIO $ ms 50)
  wait pid
  ms 1
  isAlive pid2 >>= assertBool . not


data Message = Message Unique 
  deriving (Eq)

instance Show Message where
  show (Message u) = "Message#" ++ show (hashUnique u)

newMessage = Message <$> newUnique

test_sendMessage = do
  msg <- newMessage
  resp <- newEmptyMVar
  pid <- spawn $
    receive >>= liftIO . putMVar resp
  sendIO pid msg
  takeMVar resp >>= assertEqual msg

test_send2Messages = do
  msg <- newMessage
  resp <- newEmptyMVar
  pid <- spawn $ do
    receive >>= liftIO . putMVar resp
    receive >>= liftIO . putMVar resp
  sendIO pid msg
  takeMVar resp >>= assertEqual msg
  sendIO pid msg
  takeMVar resp >>= assertEqual msg

test_notReceiveMessageWithTimeout = do
  lock <- newEmptyMVar
  spawn $ do
    msg <- receiveWithTimeout $ Just 10
    liftIO $ putMVar lock msg
  takeMVar lock >>= assertBool . isNothing

test_receiveMessageWithTimeout = do
  lock <- newEmptyMVar
  pid <- spawn $ do
    msg <- receiveWithTimeout $ Just 20
    liftIO $ putMVar lock msg
  ms 10
  sendIO pid ()
  takeMVar lock >>= assertBool . isJust

test_2processInteraction = do
  msg <- newMessage
  resp <- newEmptyMVar
  pid <- spawn $ do
    from <- receive
    send from msg
  spawn $ do
    self >>= send pid
    receive >>= liftIO . putMVar resp
  takeMVar resp >>= assertEqual msg

test_processExit = do
  reason <- newEmptyMVar
  pid <- spawn $ exit
  linkIO pid $ putMVar reason
  takeMVar reason >>= assertEqual Normal
  isAlive pid >>= assertBool . not

test_processException = do
  reason <- newEmptyMVar
  pid <- spawn $ error "test"
  linkIO pid $ putMVar reason
  takeMVar reason >>= assertEqual (Error "test")

test_terminate = do
  msg <- newMessage
  resp <- newEmptyMVar
  reason <- newEmptyMVar
  pid <- spawn $ do
    receive >>= liftIO . putMVar resp
    receive >>= liftIO . putMVar resp
  sendIO pid msg
  takeMVar resp >>= assertEqual msg
  linkIO pid $ putMVar reason
  terminate pid
  sendIO pid msg
  takeMVar reason >>= assertEqual Aborted
