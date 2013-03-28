{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE EmptyDataDecls #-}
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

import Control.Concurrent.STM
import Control.Exception
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Default
import Data.STM.ByteQueue (ByteQueue)
import qualified Data.STM.ByteQueue as ByteQueue
import Data.Typeable (Typeable)
import System.IO

data Connection

instance Eq Connection

-- | Wrap a connection handle so sending and receiving can be done with
-- STM transactions.
new :: HasBackend h
    => Config -- ^ Limits and timeouts.  Use 'def' for defaults.
    -> h      -- ^ Connection handle, such as returned by @connectTo@ or
              --   @accept@ from the network package.
    -> IO Connection
new = undefined

-- | Close the connection.  After this, 'recv' and 'send' will fail.
close :: Connection -> IO ()
close = undefined

-- | Receive the next chunk of bytes from the connection.
-- Return 'Nothing' on EOF, a non-empty string otherwise.  Throw an exception
-- if the 'Connection' is closed, or if the underlying 'backendRecv' failed.
recv :: Connection -> STM (Maybe ByteString)
recv = undefined

-- | Put some bytes back.  They will be the next bytes returned by 'recv'.
unRecv :: Connection -> ByteString -> STM ()
unRecv = undefined

-- | Send a chunk of bytes on the connection.  Throw an exception if the
-- 'Connection' is closed, or if a /previous/ 'backendSend' failed.
send :: Connection -> ByteString -> STM ()
send = undefined

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
