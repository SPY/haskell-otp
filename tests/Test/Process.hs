{-# OPTIONS_GHC -F -pgmF htfpp #-}
module Test.Process (htf_thisModulesTests) where

import Test.Framework

import Data.Unique
import Control.Applicative ((<$>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (
    newEmptyMVar,
    takeMVar,
    putMVar,
    isEmptyMVar
  )

import Concurrency.OTP.Process

ms = threadDelay . (1000*)

test_spawnNewProcessAndWait = do
  pid <- spawn $ liftIO $ ms 100
  isAlive pid >>= assertBool
  wait pid

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

test_terminate = do
  msg <- newMessage
  resp <- newEmptyMVar
  pid <- spawn $ do
    receive >>= liftIO . putMVar resp
    receive >>= liftIO . putMVar resp
  sendIO pid msg
  takeMVar resp >>= assertEqual msg
  terminate pid
  wait pid
  sendIO pid msg
  isEmptyMVar resp >>= assertBool
