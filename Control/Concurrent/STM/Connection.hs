{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE EmptyDataDecls #-}
module Control.Concurrent.STM.Connection (
    Connection,
    new,
    close,
    recv,
    send,

    -- * Connection backends
    HasBackend(..),
    Backend(..),
    Config(..),

    -- * Exceptions
    ConnException(..),
) where

import Control.Concurrent.STM
import Control.Exception
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Default
import Data.Typeable (Typeable)
import System.IO

data Connection

instance Eq Connection

-- | Wrap a connection handle, such as returned by 'Network.connectTo' or
-- 'Network.accept'.  Perform sending and receiving in the background, writing
-- to and reading from channels.  'recv' and 'send' are STM transactions for
-- accessing these channels.
new :: HasBackend h => h -> IO Connection
new = undefined

-- | Close the connection.  After this, 'recv' and 'send' will fail.
close :: Connection -> IO ()
close = undefined

-- | Receive the next chunk of bytes from the connection.
-- Return 'B.empty' on EOF.  Throw an exception if the 'Connection' is closed,
-- or if the underlying 'backendRecv' fails.
recv :: Connection -> STM ByteString
recv = undefined

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
        { backendRecv   = B.hGetSome h 16384
        , backendSend   = B.hPut h
        , backendClose  = hClose h
        , backendConfig = def
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
    , backendConfig :: !Config
      -- ^ Configuration parameters (buffer sizes and timeouts).
      --   'HasBackend' instances will typically use 'def'.
    }

data Config = Config
    { configRecvBufSize :: !Int
      -- ^ Default: 16384
      --
      --   Number of bytes that may sit in the receive queue before the
      --   receiving thread blocks.
    , configSendBufSize :: !Int
      -- ^ Default: 16384
      --
      --   Number of bytes that may sit in the send queue
      --   before 'send' blocks.  This limit will be exceeded if 'send' is called
      --   with a chunk larger than this, to avoid blocking indefinitely.

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
      --   interrupted with asynchronous exceptions, as is currently the case
      --   for network I\/O on Windows.  On other systems, this is usually not
      --   necessary.
    }

instance Default Config where
    def = Config
          { configRecvBufSize = 16384
          , configSendBufSize = 16384
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
