{-# LANGUAGE DeriveDataTypeable #-}
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
    def,

    -- * Exceptions
    ConnException(..),
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
    { connOpen      :: !(TVar Bool)
    , connRecvQueue :: !ByteQueue
    , connRecvState :: !(TVar RecvState)
    , connSendState :: !(TVar SendState)
    , connClose     :: !(IO ())
    }

data RecvState
  = RecvOpen
    -- ^ More bytes may appear in 'connRecvQueue'.
  | RecvClosed
    -- ^ Received EOF.  After 'connRecvQueue' is exhausted, no more bytes left.
  | RecvError !SomeException
    -- ^ 'backendRecv' failed.  After 'connRecvQueue' is exhausted,
    --   throw this exception.

data SendState
  = SendOpen !ByteQueue
    -- ^ Send thread alive and processing this queue.
  | SendError !SomeException
    -- ^ 'backendSend' failed.

instance Eq Connection

-- | Wrap a connection handle so sending and receiving can be done with
-- STM transactions.
new :: HasBackend h
    => Config -- ^ Limits and timeouts.  Use 'def' for defaults.
    -> h      -- ^ Connection handle, such as returned by @connectTo@ or
              --   @accept@ from the network package.
    -> IO Connection
new = undefined

-- | Close the connection.  After this, 'recv', 'unRecv', and 'send' will fail.
close :: Connection -> IO ()
close = connClose

checkOpen :: Connection -> STM ()
checkOpen Connection{..} = do
    b <- readTVar connOpen
    if b then return () else throwSTM ConnClosed

-- | Receive the next chunk of bytes from the connection.
-- Return 'Nothing' on EOF, a non-empty string otherwise.  Throw an exception
-- if the 'Connection' is closed, or if the underlying 'backendRecv' failed.
--
-- This will block if no bytes are available right now.
recv :: Connection -> STM (Maybe ByteString)
recv conn@Connection{..} = do
    checkOpen conn
    (Just <$> BQ.read connRecvQueue) `orElse` do
        s <- readTVar connRecvState
        case s of
            RecvOpen     -> retry
            RecvClosed   -> return Nothing
            RecvError ex -> throwSTM ex

-- | Put some bytes back.  They will be the next bytes returned by 'recv'.
--
-- This will never block, but it will throw 'ConnClosed' if the connection
-- is closed.
unRecv :: Connection -> ByteString -> STM ()
unRecv conn@Connection{..} bs = do
    checkOpen conn
    BQ.unRead connRecvQueue bs

-- | Send a chunk of bytes on the connection.  Throw an exception if the
-- 'Connection' is closed, or if a /previous/ 'backendSend' failed.
--
-- This will block if the send queue is full.
send :: Connection -> ByteString -> STM ()
send conn@Connection{..} bs = do
    checkOpen conn
    s <- readTVar connSendState
    case s of
        SendOpen queue -> BQ.write queue bs
        SendError ex   -> throwSTM ex

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
    , configRecvTimeout :: !(Maybe Int)
      -- ^ Default: 'Nothing'
      --
      --   Number of microseconds a 'backendRecv' may take before timing out.
      --   If 'backendRecv' times out, 'recv' will throw 'ConnRecvTimeout'.
    , configSendTimeout :: !(Maybe Int)
      -- ^ Default: 'Nothing'
      --
      --   Number of microseconds a 'backendSend' may take before timing out.
      --   If 'backendSend' times out, subsequent 'send' calls will throw
      --   'ConnSendTimeout'.
    , configCloseTimeout :: !(Maybe Int)
      -- ^ Default: 'Nothing'
      --
      --   Number of microseconds 'close' will wait before giving up and
      --   throwing 'ConnCloseTimeout'.  The closing process will continue in
      --   the background, however.
      --
      --   This is useful when 'backendRecv' and 'backendSend' can't be
      --   interrupted with asynchronous exceptions.  This is currently the case
      --   for network I\/O on Windows; on other systems, this option is
      --   usually not necessary.
    }

instance Default Config where
    def = Config
          { configRecvMaxBytes = 16384
          , configSendMaxBytes = 16384
          , configRecvTimeout = Nothing
          , configSendTimeout = Nothing
          , configCloseTimeout = Nothing
          }

------------------------------------------------------------------------
-- Exceptions

data ConnException
  = ConnClosed        -- ^ connection 'close'd
  | ConnRecvTimeout   -- ^ 'recv' timed out
  | ConnSendTimeout   -- ^ 'send' timed out
  | ConnCloseTimeout  -- ^ 'close' timed out
  deriving Typeable

instance Show ConnException where
    show err = case err of
        ConnClosed       -> "connection closed"
        ConnRecvTimeout  -> "recv timed out"
        ConnSendTimeout  -> "send timed out"
        ConnCloseTimeout -> "close timed out"

instance Exception ConnException

------------------------------------------------------------------------
-- Utilities

-- | Like 'System.Timeout.timeout', but:
--
--  * Throw the given exception if the action takes too long,
--    instead of returning 'Nothing'.
--
--  * Don't treat negative interval as \"wait indefinitely\".
--
-- The usual caveats of "System.Timeout" apply.  In particular, timing out
-- network I/O will not work on Windows unless you set a socket timeout first.
timeoutThrow :: Exception e => e -> Int -> IO a -> IO a
timeoutThrow ex usec io = do
    tid <- myThreadId
    bracket (forkIOWithUnmask $ \unmask ->
                 unmask $ threadDelay usec >> throwTo tid ex)
            killThread
            (\_ -> io)
