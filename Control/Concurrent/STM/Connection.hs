{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE RecordWildCards #-}
module Control.Concurrent.STM.Connection (
    Connection,
    new,
    close,
    recv,
    send,
    cram,
    isSendQueueEmpty,
    bye,

    -- * Connection backend
    Backend(..),

    -- * Configuration
    Config(..),
    defaultConfig,

    -- * Exceptions
    Error(..),
) where

import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.Default
import Data.STM.Queue (Queue)
import qualified Data.STM.Queue as Q
import Data.Typeable (Typeable)

data Connection r s = Connection
    { connOpen    :: !(TVar Bool)
      -- ^ If 'True', the connection has not been 'close'd yet.
      --   If 'False', accessing the connection will throw
      --   'ErrorConnectionClosed'.
    , connBackend :: !(Backend r s)
    , connRecv    :: !(Half r)
    , connSend    :: !(Half s)
    , connDone    :: !(TVar Bool)
      -- ^ If 'True', the connection is done being used and the backend is done
      --   being closed.
      --
      --   This does not imply that 'connOpen' is 'False'.  Both 'connOpen' and
      --   'connDone' will be 'True' if the connection is closed automatically.
    }

instance Eq (Connection r s) where
    a == b = connOpen a == connOpen b

data Half a = Half
    { queue  :: !(Queue HalfTerminator a)
    , done   :: !(TVar Bool)
    , thread :: !ThreadId
    }

data HalfTerminator
  = HTEOF
  | HTError !SomeException

-- | Wrap a connection handle so sending and receiving can be done with
-- STM transactions.
new :: Config       -- ^ Queue size limits.  Use 'defaultConfig' for defaults.
    -> Backend r s  -- ^ Callbacks for accessing the underlying device.
    -> IO (Connection r s)
new Config{..} connBackend =
  mask_ $ do
    conn_mv <- newEmptyTMVarIO
    let getConn = atomically $ readTMVar conn_mv

    connOpen <- newTVarIO True
    connRecv <- newHalf configRecvLimit $ getConn >>= recvLoop
    connSend <- newHalf configSendLimit $ getConn >>= sendLoop
    connDone <- newTVarIO False

    -- Automatically close the backend when we are done using it.
    _ <- forkIOWithUnmask $ \unmask ->
         (`finally` atomically (writeTVar connDone True)) $
         unmask $ do
             waitHalf connRecv
             waitHalf connSend
             backendClose connBackend

    let !conn = Connection{..}
    atomically $ putTMVar conn_mv conn
    return conn

newHalf :: Maybe Int -> IO HalfTerminator -> IO (Half a)
newHalf limit work = do
    queue  <- Q.newIO limit
    done   <- newTVarIO False
    thread <- forkIOWithUnmask $ \unmask -> do
        t <- unmask work `catch` (return . HTError)
        atomically $ do
            _ <- Q.close queue t
            writeTVar done True
    return Half{..}

waitHalf :: Half a -> IO ()
waitHalf Half{..} =
  atomically $ do
    d <- readTVar done
    if d then return () else retry

killHalf :: Half a -> IO ()
killHalf = void . forkIO . killThread . thread

recvLoop :: Connection r s -> IO HalfTerminator
recvLoop Connection{connRecv = Half{..}, connBackend = Backend{..}} =
    loop
  where
    loop = do
        m <- backendRecv
        case m of
            Nothing -> return HTEOF
            Just r -> do
                res <- atomically $ Q.write queue r
                case res of
                    Left t   -> return t
                    Right () -> loop

sendLoop :: Connection r s -> IO HalfTerminator
sendLoop Connection{connSend = Half{..}, connBackend = Backend{..}} =
    loop
  where
    loop = do
        res <- atomically $ Q.read queue
        case res of
            Left t -> do
                backendSend Nothing
                return t
            Right s -> do
                backendSend $ Just s
                loop

-- | Close the connection.  After this, 'recv' and 'send' will fail.
--
-- 'close' will block until all queued data has been sent and the connection
-- has been closed.  If 'close' is interrupted, it will abandon any data still
-- sitting in the send queue, and finish closing the connection in the
-- background.
close :: Connection r s -> IO ()
close Connection{..} =
  mask_ $
  join $ atomically $ do
    b <- readTVar connOpen
    if b then do
        -- Mark the connection as closed so subsequent accesses to the
        -- 'Connection' object will fail.
        writeTVar connOpen False

        -- Close the recv and send queues.
        --
        --  * The recv thread will terminate when it tries to queue a message.
        --
        --  * The send thread will terminate *after* consuming remaining data
        --    in the send queue.
        _ <- Q.close (queue connRecv) $ HTError $ toException ThreadKilled
        _ <- Q.close (queue connSend) $ HTError $ toException ThreadKilled

        return $ do
            -- Kill the receive thread now, but let any pending sends
            -- flush out.  Wait for closing to complete, but if interrupted,
            -- terminate the send thread early.
            killHalf connRecv
            waitDone `onException` killHalf connSend
    else
        -- Connection already being closed.  Wait for it to finish closing.
        return waitDone
  where
    waitDone = atomically $ do
        d <- readTVar connDone
        if d then return () else retry

checkOpen :: Connection r s -> String -> STM ()
checkOpen Connection{..} loc = do
    b <- readTVar connOpen
    when (not b) $ throwSTM $ ErrorConnectionClosed loc

-- | Receive the next message from the connection.  Return 'Nothing' on EOF.
-- Throw an exception if the 'Connection' is closed, or if the underlying
-- 'backendRecv' failed.
--
-- This will block if no messages are available right now.
recv :: Connection r s -> STM (Maybe r)
recv conn@Connection{connRecv = Half{..}} = do
    checkOpen conn loc
    res <- Q.read queue
    case res of
        Right r           -> return $ Just r
        Left HTEOF        -> return Nothing
        Left (HTError ex) -> throwSTM ex
  where
    loc = "recv"

-- | Send a message on the connection.  Throw an exception if the
-- 'Connection' is closed, or if a /previous/ 'backendSend' failed.
--
-- This will block if the send queue is full.
send :: Connection r s -> s -> STM ()
send conn@Connection{connSend = Half{..}} s = do
    checkOpen conn loc
    res <- Q.write queue s
    case res of
        Right ()          -> return ()
        Left HTEOF        -> throwSTM $ ErrorSentClose loc
        Left (HTError ex) -> throwSTM ex
  where
    loc = "send"

-- | Like 'send', but never block, even if this causes the send queue to exceed
-- 'configSendLimit'.
cram :: Connection r s -> s -> STM ()
cram conn@Connection{connSend = Half{..}} s = do
    checkOpen conn loc
    res <- Q.cram queue s
    case res of
        Right ()          -> return ()
        Left HTEOF        -> throwSTM $ ErrorSentClose loc
        Left (HTError ex) -> throwSTM ex
  where
    loc = "cram"

-- | Test if the send queue is empty.  This is useful when sending dummy
-- messages to keep the connection alive, to avoid queuing such messages when
-- the connection is already congested with messages to send.
isSendQueueEmpty :: Connection r s -> STM Bool
isSendQueueEmpty conn@Connection{connSend = Half{..}} = do
    checkOpen conn loc
    Q.isEmpty queue
  where
    loc = "isSendQueueEmpty"

-- | Shut down the connection for sending, but keep the connection open so
-- more data can be received.  Subsequent calls to 'send' and 'cram'
-- will fail.
bye :: Connection r s -> STM ()
bye conn@Connection{connSend = Half{..}} = do
    checkOpen conn loc
    res <- Q.close queue HTEOF
    case res of
        Right ()          -> return ()
        Left HTEOF        -> return ()
        Left (HTError ex) -> throwSTM ex
  where
    loc = "bye"

------------------------------------------------------------------------
-- Connection backends

-- |
-- Connection I\/O driver.
--
-- 'backendSend' and 'backendRecv' will often be called at the same time, so
-- they must not block each other.  However, 'backendRecv' and 'backendSend'
-- are each called in their own thread, so it is safe to use
-- 'Data.IORef.IORef's to marshal state from call to call.
data Backend r s = Backend
    { backendRecv :: !(IO (Maybe r))
      -- ^ Receive the next message.  Return 'Nothing' on EOF.
    , backendSend :: !(Maybe s -> IO ())
      -- ^ Send (and flush) the given message.
      --
      --   If 'Nothing' is given, shut down the underlying connection for
      --   sending, as 'backendSend' will not be called again.  If your device
      --   does not support this, do nothing.
    , backendClose :: !(IO ())
      -- ^ Close the device.  'backendSend' and 'backendRecv' are never
      --   called during or after this.
      --
      --   'backendClose' is called when the 'Connection' is done using the
      --   device, even if you don't use 'close'.
    }

------------------------------------------------------------------------
-- Configuration

data Config = Config
    { configRecvLimit :: !(Maybe Int)
      -- ^ Default: @'Just' 10@
      --
      --   Number of messages that may sit in the receive queue before the
      --   'Connection''s receiving thread blocks.  Having a limit is
      --   recommended in case the client produces messages faster than your
      --   program consumes them.
    , configSendLimit :: !(Maybe Int)
      -- ^ Default: @'Just' 10@
      --
      --   Number of messages that may sit in the send queue before 'send'
      --   blocks.  Having a limit is recommended if your program produces
      --   messages faster than they can be sent.
    }

instance Default Config where
    def = defaultConfig

defaultConfig :: Config
defaultConfig = Config
    { configRecvLimit = Just 10
    , configSendLimit = Just 10
    }

------------------------------------------------------------------------
-- Exceptions

data Error
  = ErrorConnectionClosed String
    -- ^ connection 'close'd
  | ErrorSentClose String
    -- ^ connection shut down for sending
  deriving Typeable

instance Show Error where
    show err = case err of
        ErrorConnectionClosed loc -> loc ++ ": connection closed"
        ErrorSentClose        loc -> loc ++ ": connection shut down for sending"

instance Exception Error
