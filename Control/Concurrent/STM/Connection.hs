{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE RecordWildCards #-}
module Control.Concurrent.STM.Connection (
    Connection,
    new,
    close,
    recv,
    unRecv,
    send,

    -- * Connection backends
    HasBackend(..),
    Backend(..),

    -- * Configuration
    Config(..),
    defaultConfig,

    -- * Exceptions
    ConnectionError(..),
) where

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Default
import Data.STM.ByteQueue (ByteQueue)
import qualified Data.STM.ByteQueue as BQ
import Data.Typeable (Typeable)
import System.IO

data Connection = Connection
    { connState   :: !(TVar ConnState)
    , connBackend :: !Backend
    , connRecv    :: !(Half RecvState)
    , connSend    :: !(Half SendState)
    }

instance Eq Connection where
    a == b = connState a == connState b

data Half s = Half
    { queue  :: !ByteQueue
    , state  :: !(TVar s)
    , thread :: !ThreadId
    , done   :: !(TVar Bool)
    }

data ConnState
  = ConnOpen
  | ConnClosing
  | ConnClosed
  deriving Eq

data RecvState
  = RecvOpen
    -- ^ More bytes may appear in 'connRecvQueue'.
  | RecvClosed
    -- ^ Received EOF.  After 'connRecvQueue' is exhausted, no more bytes left.
  | RecvError !SomeException
    -- ^ 'backendRecv' failed.  After 'connRecvQueue' is exhausted,
    --   throw this exception.

data SendState
  = SendOpen
    -- ^ Send thread alive and processing 'connSendQueue'.
  | SendError !SomeException
    -- ^ 'backendSend' failed.

-- | Wrap a connection handle so sending and receiving can be done with
-- STM transactions.
new :: HasBackend h
    => Config -- ^ Queue size limits.  Use 'def' for defaults.
    -> h      -- ^ Connection handle, such as returned by @connectTo@ or
              --   @accept@ from the network package.
    -> IO Connection
new Config{..} h = do
    conn_mv <- newEmptyTMVarIO
    let getConn = atomically $ readTMVar conn_mv

    connState     <- newTVarIO ConnOpen
    connBackend   <- getBackend h
    connRecv      <- newHalf RecvOpen configRecvMaxBytes $ getConn >>= recvLoop
    connSend      <- newHalf SendOpen configSendMaxBytes $ getConn >>= sendLoop

    let !conn = Connection{..}
    atomically $ putTMVar conn_mv conn
    return conn

newHalf :: s -> Int -> IO () -> IO (Half s)
newHalf s limit work = do
    queue  <- BQ.newIO limit
    state  <- newTVarIO s
    done   <- newTVarIO False
    thread <- forkIOWithUnmask $ \unmask ->
        unmask work `finally` atomically (writeTVar done True)
    return Half{..}

recvLoop :: Connection -> IO ()
recvLoop Connection{connRecv = Half{..}, ..} =
    loop
  where
    loop = do
        -- Test if connection is closed, in case 'close' fails to kill us.
        -- Shouldn't be necessary, but a silly 'backendClose' might swallow
        -- 'ThreadKilled' and return successfully.
        --
        -- It's okay if we queue bytes after the connection is no longer in the
        -- 'ConnOpen' state, as 'recv' and 'unRecv' call 'checkOpen'.
        s <- readTVarIO connState
        when (s /= ConnOpen) $ throwIO ThreadKilled

        res <- try $ backendRecv connBackend
        case res of
            Left ex ->
                  atomically $ writeTVar state $! RecvError ex
            Right bs
              | B.null bs ->
                  atomically $ writeTVar state RecvClosed
              | otherwise -> do
                  atomically $ BQ.write queue bs
                  loop

sendLoop :: Connection -> IO ()
sendLoop Connection{connSend = Half{..}, ..} =
    loop
  where
    loop = do
        bs <- atomically $ BQ.read queue `orElse` do
                  -- Terminate if the queue is exhausted *and* the connection
                  -- is being closed.
                  s <- readTVar connState
                  if s == ConnOpen then retry else throwSTM ThreadKilled

        res <- try $ backendSend connBackend bs
        case res of
            Left ex -> atomically $ writeTVar state $! SendError ex
            Right _ -> loop

-- | Close the connection.  After this, 'recv', 'unRecv', and 'send' will fail.
--
-- 'close' will block until all queued data has been sent and the connection
-- has been closed.  If 'close' is interrupted, it will abandon any data still
-- sitting in the send queue, and finish closing the connection in the
-- background.
close :: Connection -> IO ()
close Connection{..} =
  mask_ $
  join $ atomically $ do
    s <- readTVar connState
    case s of
        ConnOpen -> do
            writeTVar connState ConnClosing
            return $ do
                killHalf connRecv
                _ <- forkIOWithUnmask $ \unmask ->
                     (`finally` setClosed) $ unmask $ do
                         waitHalf connRecv
                         waitHalf connSend
                         backendClose connBackend
                -- Wait for closing to complete, but if interrupted,
                -- terminate the send thread early.
                waitClosed `onException` killHalf connSend
        ConnClosing ->
            retry
        ConnClosed ->
            return $ return ()
  where
    waitClosed = atomically $ do
        s <- readTVar connState
        if s == ConnClosed then return () else retry
    setClosed = atomically $ writeTVar connState ConnClosed

waitHalf :: Half s -> IO ()
waitHalf Half{..} =
  atomically $ do
    d <- readTVar done
    if d then return () else retry

killHalf :: Half s -> IO ()
killHalf = void . forkIO . killThread . thread

checkOpen :: Connection -> STM ()
checkOpen Connection{..} = do
    s <- readTVar connState
    when (s /= ConnOpen) $ throwSTM ErrorConnectionClosed

-- | Receive the next chunk of bytes from the connection.
-- Return 'Nothing' on EOF, a non-empty string otherwise.  Throw an exception
-- if the 'Connection' is closed, or if the underlying 'backendRecv' failed.
--
-- This will block if no bytes are available right now.
recv :: Connection -> STM (Maybe ByteString)
recv conn@Connection{connRecv = Half{..}, ..} = do
    checkOpen conn
    (Just <$> BQ.read queue) `orElse` do
        s <- readTVar state
        case s of
            RecvOpen     -> retry
            RecvClosed   -> return Nothing
            RecvError ex -> throwSTM ex

-- | Put some bytes back.  They will be the next bytes returned by 'recv'.
--
-- This will never block, but it will throw 'ErrorConnectionClosed' if the
-- connection is closed.
unRecv :: Connection -> ByteString -> STM ()
unRecv conn@Connection{..} bs = do
    checkOpen conn
    BQ.unRead (queue connRecv) bs

-- | Send a chunk of bytes on the connection.  Throw an exception if the
-- 'Connection' is closed, or if a /previous/ 'backendSend' failed.
--
-- This will block if the send queue is full.
send :: Connection -> ByteString -> STM ()
send conn@Connection{connSend = Half{..}, ..} bs = do
    checkOpen conn
    s <- readTVar state
    case s of
        SendOpen     -> BQ.write queue bs
        SendError ex -> throwSTM ex

------------------------------------------------------------------------
-- Connection backends

class HasBackend h where
    -- | Create a 'Backend' for accessing this handle.
    getBackend :: h -> IO Backend

instance HasBackend Backend where
    getBackend = return

instance HasBackend Handle where
    getBackend h = return $! Backend
        { backendRecv  = B.hGetSome h 16384
        , backendSend  = B.hPut h
        , backendClose = hClose h
        }

-- |
-- Connection I\/O driver.
--
-- 'backendSend' and 'backendRecv' will often be called at the same time,
-- so they must not block each other.
data Backend = Backend
    { backendRecv :: !(IO ByteString)
      -- ^ Receive the next chunk of bytes.  Return 'B.empty' on EOF.
    , backendSend :: !(ByteString -> IO ())
      -- ^ Send (and flush) the given bytes.  'backendSend' is never called
      --   with an empty string.
    , backendClose :: !(IO ())
      -- ^ Close the connection.  'backendSend' and 'backendRecv' are never
      --   called during or after this.
    }

------------------------------------------------------------------------
-- Configuration

data Config = Config
    { configRecvMaxBytes :: !Int
      -- ^ Default: 16384
      --
      --   Number of bytes that may sit in the receive queue before the
      --   receiving thread blocks.
    , configSendMaxBytes :: !Int
      -- ^ Default: 16384
      --
      --   Number of bytes that may sit in the send queue before 'send' blocks.
    }

instance Default Config where
    def = defaultConfig

defaultConfig :: Config
defaultConfig = Config
    { configRecvMaxBytes = 16384
    , configSendMaxBytes = 16384
    }

------------------------------------------------------------------------
-- Exceptions

data ConnectionError
  = ErrorConnectionClosed -- ^ connection 'close'd
  deriving Typeable

instance Show ConnectionError where
    show err = case err of
        ErrorConnectionClosed -> "connection closed"

instance Exception ConnectionError
