{-# LANGUAGE FunctionalDependencies, DeriveDataTypeable, LambdaCase, GeneralizedNewtypeDeriving, FlexibleInstances #-}
-- | Attempt to reproduce Erlang pattern of resource owner process gen_server.
--
--   Original documentation: http://www.erlang.org/doc/man/gen_server.html
module Concurrency.OTP.GenServer (
  GenServerState(..),
  GenServer,
  GenServerM,
  RequestId,
  StartStatus(..),
  ServerIsDead(..),
  CallResult,
  CastResult,
  start,
  call,
  cast,
  replyWith,
  reply,
  noreply,
  stop,
  replyAndStop,
  callWithTimeout
) where

import Control.Applicative
import Control.Monad.Catch (try, SomeException)
import Control.Monad.State
import Control.Monad.Reader
import Control.Concurrent.MVar (
    newEmptyMVar,
    putMVar,
    takeMVar
  )
import Control.Concurrent.STM
import Data.IORef (
    IORef,
    newIORef,
    readIORef,
    writeIORef,
    atomicModifyIORef'
  )
import Control.Exception (Exception, throw)
import Data.Typeable (Typeable)
import qualified Data.Map as Map
import Data.Unique (Unique, newUnique)
import Data.Maybe (fromJust, isJust)

import Concurrency.OTP.Process

type RequestStore res = IORef (Map.Map RequestId (res -> IO ()))
type RequestId = Unique

-- | Monad for execution GenServer implementation callbacks.
newtype GenServerM s req res a = GenServerM {
    unGenServer :: ReaderT (RequestStore res) (StateT s (Process (Request req res))) a
  } deriving (Applicative, Functor, Monad, MonadIO)

instance MonadState s (GenServerM s req res) where
  get = GenServerM $ lift get
  put = GenServerM . lift . put

-- | Describe GenServer callbacks.
class GenServerState req res s | s -> req, s -> res where
  -- | Triggered when somebody send request to GenServer by `call` function.
  --   Executed in State monad, and state of GenServer can be changed by implementation.
  --   Callback accept request and `Unique` id of request.
  --   Return `CallResult` (one of: `reply`, `noreply`, `stop`, `replyAndStop`).
  --
  --   If callback retrun `noreply` caller process will be blocked until GenServer will explicity call `replyWith`.
  --
  --   If callback return `reply` or `replyAndStop` caller will receive response and continue execution.
  --   
  --   If callback retrun 'stop' server will be terminated, `onTerminate` callback called.
  --   Exception `ProcessIsDead` will be raised in caller process.
  handle_call :: req -> Unique -> GenServerM s req res (CallResult res)
  -- | Triggered when somebody send asyncronous command to GenServer by `cast` function.
  --   Executed in State monad, and state of GenServer can be changed by implementation.
  --   Callback accept request and return `CallResult` (one of: `noreply`, `stop`).
  --   Used for change server state without any response.
  handle_cast :: req -> GenServerM s req res CastResult
  -- | Termination callback executed on GenServer termination.
  --   This callback usefull for release resources allocated on server start.
  onTerminate :: s -> IO ()
  
  onTerminate = const $ return ()

-- | GenServer handle
data GenServer req res = GenServer {
    gsPid :: Pid (Request req res)
  }

instance IsProcess (Request req res) (GenServer req res) where
  getPid (GenServer pid) = pid

data Request req res = Call req (res -> IO ())
                     | Cast req

class HandlerResult a where
  noreply :: a
  stop    :: String -> a

-- | Returned by `handle_call` callback.
data CallResult res = Reply res
                    | NoReply
                    | ReplyAndStop res String
                    | Stop String

instance HandlerResult (CallResult res) where
  noreply = NoReply
  stop    = Stop

reply :: res -> CallResult res
reply = Reply

replyAndStop :: res -> String -> CallResult res
replyAndStop = ReplyAndStop

-- | Returned by `handle_cast` callback.
data CastResult = CastNoReply
                | CastStop String

instance HandlerResult CastResult where
  noreply = CastNoReply
  stop    = CastStop

-- | Returned by `start`.
--   If start is success - (`Ok` serverHandle) will be returned, else - `Fail`.
data StartStatus req res = Ok (GenServer req res) | Fail

-- | Start instance of GenServer.
--   Take action for initialization of state. And return `StartStatus`.
--   If `start` returns Fail, initialization was failed. In that case onTerminate callback will not be called.
start :: (GenServerState req res s) => Process (Request req res) s -> IO (StartStatus req res)
start initFn = do
   result <- newEmptyMVar
   pid <- spawn $
     try (initFn >>= liftIO . newIORef) >>= \case
       Right stateRef -> do
         liftIO (putMVar result (Right stateRef))
         handler stateRef
       Left e -> liftIO $ putMVar result (Left e)
   takeMVar result >>= \case
     Right stateRef -> do
       linkIO pid $ const $ do
         st <- readIORef stateRef
         onTerminate st
       return $ Ok $ GenServer pid
     Left e -> fail1 e
  where
    -- XXX: we are hidding exception here, we shouldn't do it
    fail1 :: SomeException -> IO (StartStatus req res)
    fail1 _ = return Fail

handler :: (GenServerState req res s) => IORef s -> Process (Request req res) ()
handler stateRef = do
  requests <- liftIO $ newIORef Map.empty
  forever $ do
    req <- receive
    serverState <- liftIO $ readIORef stateRef
    case req of
      Call r res -> do
        requestId <- liftIO newUnique
        let callHandler = unGenServer $ handle_call r requestId
        let stateTAction = flip runReaderT requests callHandler
        (result, newState) <- runStateT stateTAction serverState
        liftIO $ writeIORef stateRef newState
        case result of
          Reply response ->
            liftIO $ res response
          NoReply ->
            liftIO $ atomicModifyIORef' requests $ \rs ->
              (Map.insert requestId res rs, ())
          ReplyAndStop response _reason ->
            liftIO (res response) >> exit
          Stop _reason ->
            exit
      Cast r -> do
        let castHandler = flip runReaderT requests $ unGenServer $ handle_cast r
        (result, newState) <- runStateT castHandler serverState
        liftIO $ writeIORef stateRef newState
        case result of
          CastNoReply ->
            return ()
          CastStop _reason ->
            exit

data ServerIsDead = ServerIsDead deriving (Show, Typeable)

instance Exception ServerIsDead

-- | Send synchronous request to GenServer.
--   `call` block caller process until GenServer will reply.
--   If GenServer instance is not alive or will be terminated during `call`
--   `ServerIsDead` exception will be raised.
call :: GenServer req res -> req -> IO res
call srv msg =
  fromJust <$> callWithTimeout srv Nothing msg

-- | Send synchronous request to GenServer with timeout.
--   `call` block caller process until GenServer will reply or timeout will be expired.
--   If GenServer instance is not alive or will be terminated during `call`
--   `ServerIsDead` exception will be raised.
--   If Timeout will be expired, `Nothing` will be returned.
callWithTimeout :: GenServer req res -> Maybe Int -> req -> IO (Maybe res)
callWithTimeout GenServer { gsPid = pid } tm msg = do
  response <- newEmptyTMVarIO
  isTimeOut <- maybe (newTVarIO False) (registerDelay.(*1000)) tm
  result <- withLinkIO_ pid
    (const $ void $ atomically $ tryPutTMVar response (Left (Left ())))
    (do
    sendIO pid $ Call msg (atomically . void . (tryPutTMVar response) . Right)
    atomically $ (readTVar isTimeOut >>= flip unless retry >> return (Left (Right ())))
                 `orElse` (takeTMVar response)
    )
  case result of
    Right x -> return (Just x)
    Left (Left _)  -> throw ServerIsDead
    Left (Right _) -> return Nothing -- put delayed in mbox

-- | Send asynchronous request to GenServer.
--   `cast` doesn't block caller thread.
cast :: GenServer req res -> req -> IO ()
cast GenServer { gsPid = pid } msg =
  sendIO pid $ Cast msg

-- | Reply to process, which waits response from server.
replyWith :: RequestId -> res -> GenServerM s req res ()
replyWith reqId response = do
  requestsRef <- GenServerM ask
  res <- liftIO $ atomicModifyIORef' requestsRef $ \rs ->
    (Map.delete reqId rs, Map.lookup reqId rs)
  when (isJust res) $ liftIO $ fromJust res response
