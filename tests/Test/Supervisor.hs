{-# OPTIONS_GHC -F -pgmF htfpp #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances #-}
module Test.Supervisor (htf_thisModulesTests) where

import Test.Framework

import Control.Monad ( forever )
import Control.Monad.State
import Control.Concurrent ( yield )
import Control.Concurrent.MVar
import Data.Unique (Unique)
import Control.Concurrent (threadDelay, forkIO)

import Concurrency.OTP.Supervisor
import Concurrency.OTP.Process

ms n = threadDelay $ n * 1000

test_init_empty = do
  Ok s <- supervisor_init OneForOne (MRF 1 5) []
  count_children s >>= assertEqual 0

test_init_one = do
  started <- newEmptyMVar
  Ok s <- supervisor_init OneForOne (MRF 1 5)
            [defChild (liftIO $ putMVar started ())]
  takeMVar started
  count_children s >>= assertEqual 1

test_init_two = do
  s1 <- newEmptyMVar
  s2 <- newEmptyMVar
  Ok s <- supervisor_init OneForOne (MRF 1 5)
            [ defChild (liftIO $ putMVar s1 ())
            , defChild (liftIO $ putMVar s2 ())]
  takeMVar s1
  takeMVar s2
  count_children s >>= assertEqual 2

test_restart_simple = do
  s1 <- newMVar False
  s2 <- newEmptyMVar 
  Ok s <- supervisor_init OneForOne (MRF 1 5)
            [ defChild $ liftIO $ do
                b <- takeMVar s1
                if b  
                then putMVar s2 () >> forever yield
                else putMVar s1 True
            ]
  takeMVar s2
  count_children s >>= assertEqual 1

test_restart_simple_transient = do
  restarts <- newMVar 0
  s1 <- newMVar True
  s2 <- newEmptyMVar
  Ok s <- supervisor_init OneForOne (MRF 1 5)
            [ (defChild $ liftIO $ do
                modifyMVar_ restarts (return . (+1))  -- increase restart on each start
                b <- takeMVar s1
                if b 
                then putMVar s1 False >> error "abnormal exit"
                else return () -- normal exit
              ){csRestart=Transient}
            ]
  threadDelay 500         
  readMVar restarts >>= assertEqual 2
  count_children s  >>= assertEqual 0

test_restart_simple_temporary = do
  restarts <- newMVar 0
  Ok s <- supervisor_init OneForOne (MRF 1 5)
            [(defChild $ liftIO $ modifyMVar_ restarts (return . (+1))){csRestart=Temporary}]
  threadDelay 500
  readMVar restarts >>= assertEqual 1
  count_children s  >>= assertEqual 0
