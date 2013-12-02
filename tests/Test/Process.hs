{-# OPTIONS_GHC -F -pgmF htfpp #-}
module Test.Process (htf_thisModulesTests) where

import Test.Framework

import Data.Unique
import Control.Applicative ((<$>))
import Control.Concurrent (threadDelay)

import Concurrency.OTP.Process

ms = threadDelay . (1000*)

test_spawnNewProcessAndWait = do
  pid <- spawn $ liftIO $ do
    putStrLn "I'm alive"
    assertBool True
  wait pid

data Message = Message Unique 
  deriving (Eq)

instance Show Message where
  show (Message u) = "Message#" ++ show (hashUnique u)

newMessage = Message <$> newUnique

test_sendMessage = do
  msg <- newMessage
  putStrLn $ "Send: " ++ show msg
  pid <- spawn $ do
    msg' <- receive
    liftIO $ putStrLn $ "Received: " ++ show msg'
  sendIO pid msg
  wait pid

test_send2Messages = do
  msg <- newMessage
  putStrLn $ "Send: " ++ show msg
  pid <- spawn $ do
    msg' <- receive
    liftIO $ putStrLn $ "First received: " ++ show msg'
    msg'' <- receive
    liftIO $ putStrLn $ "Second received: " ++ show msg''
  sendIO pid msg
  sendIO pid msg
  wait pid

test_terminate = do
  msg <- newMessage
  putStrLn $ "Send: " ++ show msg
  pid <- spawn $ do
    msg' <- receive
    liftIO $ putStrLn $ "First received: " ++ show msg'
    msg'' <- receive
    liftIO $ putStrLn $ "Second received: " ++ show msg'
  sendIO pid msg
  ms 100
  putStrLn $ "Terminate " ++ show pid
  terminate pid
  sendIO pid msg
  wait pid