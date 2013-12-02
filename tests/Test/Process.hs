{-# OPTIONS_GHC -F -pgmF htfpp #-}
module Test.Process (htf_thisModulesTests) where

import Test.Framework

import Data.Unique
import Control.Applicative ((<$>))
import Control.Concurrent (threadDelay)

import Concurrency.OTP.Process

ms = threadDelay . (1000*)

test_spawnNewProcess = do
  spawn $ liftIO $ assertBool True
  ms 200

data Message = Message Unique 
  deriving (Eq)

instance Show Message where
  show (Message u) = "Message#" ++ show (hashUnique u)

test_sendMessage = do
  msg <- Message <$> newUnique
  putStrLn $ "Send: " ++ show msg
  pid <- spawn $ do
    msg' <- receive
    liftIO $ putStrLn $ "Received: " ++ show msg'
  sendIO pid msg
  ms 200
