{-# LANGUAGE FunctionalDependencies, DeriveDataTypeable, LambdaCase, ExistentialQuantification #-}
-- | Attempt to reproduce Erlang pattern of supervisor module.
--
--   Original documentation: http://www.erlang.org/doc/man/supervisor.html
module Concurrency.OTP.Supervisor 
  ( -- * Datatypes
    RestartStrategy(..)
  , ProcessType(..)
  , MRF(..)
  , Restart(..)
  , Shutdown(..)
    -- ** Children description
  , ChildSpec(..)
  , defChild
    -- * Supervisor
    -- $loop-preventing
  , Supervisor
  , Status(..)
--  , IsSupervisor(..)
  , supervisor_init
  , count_children
--  , start_child
  ) where 

import Control.Applicative
import Control.Concurrent.MVar
import Control.Concurrent.Chan
import Control.Monad
import Data.Void

import Concurrency.OTP.Process
import Concurrency.OTP.Internal.Types

data RestartStrategy 
        = OneForOne 
        -- ^ If one child process terminates and should be restarted, only that
        -- child process is affected.
        | OneForAll
        -- ^ If one child process terminates and should be restarted, all
        -- other child processes are terminated and then all child
        -- processes are restarted.
        | RestForOne
        -- ^ If one child process terminates and should be restarted, the
        -- 'rest' of the child processes -- i.e. the child processes after
        -- the terminated child process in the start order -- are terminated. 
        -- Then the terminated child process and all child processes after
        -- it are restarted.
        --
        -- | SimpleOneForOne

data ProcessType
        = WorkerType  -- ^ gen_event, gen_fsm, gen_server
        | SupervisorType -- ^ supervisor

-- $loop-preventing
-- To prevent supervisor from infinite loop of child process termination
-- and restart, a maximum restart frequency is defined using "MRF" type


-- | Maximum Restart frequency, i.e. more then maxR restarts in maxT
-- seconds.
data MRF = MRF { maxR :: Int, maxT :: Int }

-- | Restart type
data Restart
        = Permanent -- ^ Service should always be restarted
        | Temporary -- ^ Child process should never be restarted
        | Transient -- ^ Child process should be restarted if it dies abnormally

-- | Description how process will be terminated
data Shutdown
       = BrutalKill -- ^ kill with "exit" ChildPid kill
       | Timeout (Maybe Int) -- ^ call "exit" ChildPid shutdown, wait for timeout and kill.

data ChildSpec = ChildSpec
       { csStartFunc :: SomeProcess ()
       , csRestart   :: Restart
       , csShutdown  :: Shutdown
--       , csType  --XXX I don't understand why it's needed
       }    
      
-- | Helper for creating of the default child.
defChild :: Process msg () -> ChildSpec -- XXX: we need to relax Process a to IsProcess a msg
defChild p = ChildSpec ((SomeProcess p)) Permanent BrutalKill

-- | Default supervisor pattern that is suitable for most of the cases.
--
-- Default supervisor as typed as a void type, this means that we can't
-- send any message to this process. 
data Supervisor = Supervisor (Pid Void) RestartStrategy MRF (MVar SupervisorState)

type SupervisorState = [(SomePid, (ChildSpec, LinkId))]

instance IsProcess Void Supervisor where
  getPid (Supervisor p _ _ _) = p

class IsSupervisor a where
  getChildren :: a -> IO [ChildSpec]

instance IsSupervisor Supervisor where
  getChildren (Supervisor _ _ _ s) = map (fst . snd) <$> readMVar s

-- | Initialize supervisor.
supervisor_init :: RestartStrategy
                -> MRF
                -> [ChildSpec]
                -> IO (Status Supervisor)
supervisor_init strategy mfr children = do
    state <- newEmptyMVar
    pid   <- spawn $ do
       events <- liftIO $ do
           ch <- newChan
           pids  <- mapM (startChild ch) children
           putMVar state pids
           return ch
       liftIO $ forever $ do
           ev <- readChan events
           runStrategy strategy ev state events
    return $ Ok (Supervisor pid strategy mfr state)
  where
    runStrategy OneForOne = strategyOneForOne
    runStrategy OneForAll = strategyOneForAll
    runStrategy _ = error "not yet implemented"

startChild :: Chan (SomePid, Reason) -> ChildSpec -> IO (SomePid, (ChildSpec,LinkId))
startChild ch s@(ChildSpec (SomeProcess p) _ _) = do
  pid <- spawn p
  lid <- linkIO pid (\r -> writeChan ch (SomePid pid, r))
  return (SomePid pid, (s, lid))

strategyOneForOne :: (SomePid, Reason) -> MVar SupervisorState -> Chan (SomePid, Reason) -> IO ()
strategyOneForOne (pid,reason) state ch = void $ withMVar state $ \st -> do
    let (hd,p@(_,(spec,_)):tl) = break ((== pid) . fst) st
    case csRestart spec of
        Permanent -> do
            p' <- startChild ch spec
            return $ hd ++ p':tl
        Temporary -> return $ hd++tl
          -- XXX: do we need to forget specification of the temporary service?
        Transient -> 
          case reason of
            Normal -> return $ hd++tl
            _      -> do
              p' <- startChild ch spec
              return $ hd ++ p':tl

strategyOneForAll :: (SomePid, Reason) -> MVar SupervisorState -> Chan (SomePid, Reason) -> IO ()
strategyOneForAll (pid,reason) state ch = void $ withMVar state $ \st -> do
    mapM_ (unlinkIO . snd . snd) st
    mapM_ (terminate . fst) st
    catMaybes <$> mapM (restartChild . ) 



{-
start_child :: (IsProcess p, IsSupervisor s) => s -> Restart -> Shutdown -> p -> IO Status
start_child sv r s = undefined
-}

{-
terminate_child :: IO ()
terminate_child = undefined

delete_child :: IO ()
delete_child = undefined
-}

{-
restart_child :: IsSupervisor p => p -> SomePid -> IO ()
restart_child p s = do
  strategy <- getStrategy p
  mchild   <- findChild s <$> getChildren p
  case mchild of
      Just x  -> strategy p x
      Nothing -> return ()
-}

{-
which_children :: IO ()
which_children = undefined
-}

count_children :: IsSupervisor p => p -> IO Int
count_children p = fmap length (getChildren p)
