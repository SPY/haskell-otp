{-# OPTIONS_GHC -F -pgmF htfpp #-}
module Test.Process (htf_thisModulesTests) where

import Test.Framework

import Data.Unique
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
  pid <- spawn $ liftIO $ putMVar resp ()
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
  handler1 <- newEmptyMVar
  handler2 <- newEmptyMVar
  pid <- spawn $ return ()
  linkId <- linkIO pid $ putMVar handler1
  linkIO pid $ putMVar handler2
  unlinkIO pid linkId
  takeMVar handler2
  isEmptyMVar handler1 >>= assertBool

test_processLink = do
  waitCell <- newEmptyMVar
  pid <- spawn $ liftIO $ ms 10
  pid2 <- spawn $ link pid >> liftIO (takeMVar waitCell)
  wait pid2
  assertBool True

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
