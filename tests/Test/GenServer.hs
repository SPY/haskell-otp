{-# OPTIONS_GHC -F -pgmF htfpp #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Test.GenServer (htf_thisModulesTests) where

import Test.Framework

import Control.Monad.State

import Concurrency.OTP.GenServer

data CounterState = Counter { counter :: Int }

data Command = Get | Inc

instance GenServerState Command Int CounterState where
  handle_call Get = gets counter
  
  handle_cast Inc =
    modify $ \st -> st { counter = counter st + 1 }

test_call = do
  serv <- start $ Counter 0
  call serv Get >>= assertEqual 0
  
test_cast = do
  serv <- start $ Counter 1
  call serv Get >>= assertEqual 1
  cast serv Inc
  call serv Get >>= assertEqual 2
