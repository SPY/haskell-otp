{-# LANGUAGE FunctionalDependencies, FlexibleInstances, GeneralizedNewtypeDeriving, StandaloneDeriving #-}
module Concurrency.OTP.Process (
  Pid,
  Process,
  Reason(..),
  IsProcess(..),
  LinkId,
  spawn,
  linkIO,
  unlinkIO,
  withLinkIO,
  withLinkIO_,
  link,
  send,
  sendIO,
  receive,
  receiveWithTimeout,
  self,
  exit,
  terminate,
  isAlive,
  wait,
  liftIO
) where

import Data.Maybe (isJust, fromJust)
import Data.Unique (Unique, newUnique, hashUnique)
import Data.Map (
    Map,
    empty,
    insert,
    delete,
    elems
  )
import Control.Applicative (
    Applicative,
    (<$>),
    (<*>),
    pure
  )
import Control.Concurrent (
    ThreadId,
    forkFinally,
    myThreadId,
    killThread
  )
import Control.Concurrent.MVar (
    newMVar,
    newEmptyMVar,
    tryTakeMVar,
    takeMVar,
    putMVar,
    withMVar
  )
import Control.Monad.Catch (bracket)
import Control.Monad.STM (STM, atomically, retry, orElse)
import Control.Concurrent.STM.TMChan (
    TMChan,
    newBroadcastTMChan,
    readTMChan,
    writeTMChan,
    closeTMChan,
    dupTMChan,
    isClosedTMChan
    )
import Control.Concurrent.STM.TVar (
    TVar,
    newTVar,
    readTVar,
    writeTVar,
    modifyTVar',
    newTVarIO,
    registerDelay
  )
import Control.Monad (when, unless)
import Control.Monad.Reader (ReaderT(..), ask)
import Control.Monad.Trans (MonadIO, liftIO)
import Control.Exception (catch)
import Control.Exception.Base (
    Exception(..),
    SomeException,
    AsyncException(ThreadKilled)
  )
import Control.Monad.Catch (MonadCatch, MonadThrow)

class IsProcess a p | p -> a where
  getPid :: p -> Pid a

type Queue msg = TMChan msg

-- | Id of subscription on process termination.
newtype LinkId = LinkId Unique deriving (Eq, Ord)

-- | Identificator of process accepted messages of type 'msg'
data Pid msg = Pid {
    pUniq :: Unique,
    pQueue :: Queue msg,
    pTID :: ThreadId,
    pLinked :: TVar (Maybe (Map LinkId (Reason -> IO ()))),
    pReason :: TVar (Maybe Reason)
  }

instance IsProcess a (Pid a) where
  getPid = id

-- | Process termination reason
data Reason = Normal       -- ^ Caused when process terminate on end of computation or call `exit` function
            | Aborted      -- ^ Caused when process terminate from another process by 'terminate' function
            | Error String -- ^ Caused when process terminate abnormal way and store exception description
  deriving (Show, Eq)

instance Eq (Pid a) where
  Pid { pUniq = u1 } == Pid { pUniq = u2 } = u1 == u2

instance Show (Pid a) where
  show Pid { pUniq = u } = "Pid<" ++ show (hashUnique u) ++ ">"

-- | Process computation monad
newtype Process msg a = Process { unProcess :: ReaderT (Pid msg) IO a } 
  deriving (Monad, Applicative, MonadIO, Functor, MonadThrow, MonadCatch)

class (Monad m) => MonadProcess msg m | m -> msg where
  -- | Get message from process mailbox with timeout in milliseconds.
  --   Blocked, if mailbox is empty, until message will be received or timeout will be expired.
  receiveWithTimeout :: Maybe Int -> m (Maybe msg)
  -- | Return pid of current process
  self :: m (Pid msg)
  -- | Terminate current process with Normal reason.
  exit :: m ()

instance MonadProcess msg (Process msg) where
  receiveWithTimeout = receiveWithTimeoutProcess
  self = selfProcess
  exit = exitProcess

-- | Get message from process mailbox.
--   Blocked, if mailbox is empty, until message will be received.
receive :: (MonadProcess msg m) => m msg
receive = do
  Just msg <- receiveWithTimeout Nothing
  return msg

-- | Spawn new process in own thread
spawn :: Process msg () -> IO (Pid msg)
spawn body = do
  u <- newUnique
  pid <- atomically $
    Pid <$> pure u
        <*> newBroadcastTMChan
        <*> pure undefined
        <*> newTVar (Just empty)
        <*> newTVar Nothing
  -- We need this to workaround a bug in stm-chans where
  -- closing of broadcast channel doesn't lead to closing
  -- of the duplicated channel
  rQueue <- atomically $ dupTMChan (pQueue pid)
  tid <- flip forkFinally (processFinalizer rQueue pid) $ do
    tid <- myThreadId
    runReaderT (unProcess body) $ pid{pTID=tid,pQueue=rQueue}
  return $ pid{pTID=tid}

resultToReason :: Either SomeException () -> Reason
resultToReason (Left e)
  | fromException e == Just ThreadKilled = Aborted
  | otherwise = Error $ show e
resultToReason (Right ()) = Normal

processFinalizer :: TMChan a
                 -> Pid a
                 -> Either SomeException () -> IO ()
processFinalizer queue Pid{pLinked=linked,pReason=reason} result = do
  (handlers, r) <- atomically $ do
    closeTMChan queue
    Just hs <- readTVar linked
    writeTVar linked Nothing
    modifyTVar' reason $ \r ->
      case r of
        Nothing -> Just $ resultToReason result
        Just _ -> r
    Just r <- readTVar reason
    return (elems hs, r)
  let skipAll :: SomeException -> IO ()
      skipAll _ = return ()
      eval handler = catch (handler r) skipAll
  mapM_ eval handlers

-- | Asynchronious send messages of type `msg` to process
sendIO :: Pid msg -> msg -> IO ()
sendIO Pid { pQueue = cell } msg = atomically $ writeTMChan cell msg

-- | Send messages from one process to another
send :: Pid msg -> msg -> Process a ()
send pid msg = liftIO $ sendIO pid msg

receiveWithTimeoutProcess :: Maybe Int -> Process msg (Maybe msg)
receiveWithTimeoutProcess timeout = do
  Pid { pQueue = cell } <- Process ask
  isTimeOut <- liftIO $ maybe (newTVarIO False) (registerDelay.(*1000)) timeout
  liftIO $ atomically
    $ waitTimeout isTimeOut `orElse` readTMChan cell
  where
    waitTimeout :: TVar Bool -> STM (Maybe msg)
    waitTimeout isTimeOut = do
      res <- readTVar isTimeOut
      unless res retry
      return Nothing

selfProcess :: Process msg (Pid msg)
selfProcess = Process ask

exitProcess :: Process msg ()
exitProcess = do
  Pid { pReason = reason } <- Process ask
  liftIO $ do
    tId <- myThreadId
    atomically $ writeTVar reason $ Just Normal
    killThread tId

-- | Terminate process p
terminate :: (IsProcess msg p) => p -> IO ()
terminate p =
  let Pid { pTID = tid } = getPid p
  in killThread tid

-- | Check what process p is alive
isAlive :: (IsProcess msg p ) => p -> IO Bool
isAlive p =
  let Pid { pQueue = q } = getPid p
  in atomically $ fmap not (isClosedTMChan q)

-- | Register callback, which will be called on process termination and return subscription id.
--   If process has died already, callback will be called immediatly.
linkIO :: (IsProcess msg p) => p -> (Reason -> IO ()) -> IO LinkId
linkIO p handler = do
  let Pid { pLinked = cell, pReason = r } = getPid p
  linkId <- LinkId <$> newUnique
  reason <- atomically $ do
    content <- readTVar cell
    case content of
      Just linked -> do
        writeTVar cell $ Just $ insert linkId handler linked
        return Nothing
      Nothing ->
        readTVar r
  when (isJust reason) $ handler $ fromJust reason
  return linkId

-- | Link current process with another process p.
--   Current process will be terminated, if process p will be terminated abnormal.
link :: (IsProcess msg p) => p -> Process msg LinkId
link p = do
  self' <- self
  liftIO $ linkIO p $ \reason -> when (reason /= Normal) (terminate self')

-- | Remove termination callback by LinkId
unlinkIO :: (IsProcess msg p) => p -> LinkId -> IO ()
unlinkIO p linkId = do
  let Pid { pLinked = cell } = getPid p
  atomically $ do
    handlers <- readTVar cell
    when (isJust handlers) $ do
      writeTVar cell $ Just $ delete linkId $ fromJust handlers

-- | Run action in under link bracket.
withLinkIO :: (IsProcess msg p) => p -> (Reason -> IO ()) -> (LinkId -> IO a) -> IO a
withLinkIO p clb act = do
  lock <- newMVar ()  
  let cleaner r = tryTakeMVar lock >>= maybe (clb r) return
  bracket (linkIO p cleaner)
          (unlinkIO p)
          (withMVar lock . const . act)

withLinkIO_ :: (IsProcess msg p) => p -> (Reason -> IO ()) -> (IO a) -> IO a
withLinkIO_ p clb =
  withLinkIO p clb . const

-- | Block current execution thread until process is alive.
wait :: (IsProcess msg p) => p -> IO ()
wait p = do
 done <- newEmptyMVar
 linkIO (getPid p) $ const $ putMVar done ()
 takeMVar done
