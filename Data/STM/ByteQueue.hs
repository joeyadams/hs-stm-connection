{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE RecordWildCards #-}
module Data.STM.ByteQueue (
    ByteQueue,
    newIO,
    read,
    unRead,
    write,
) where

import Control.Concurrent.STM
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Prelude hiding (read)

data ByteQueue = ByteQueue
    { chan  :: !(TChan ByteString)
    , bytes :: !(TVar Int)
      -- ^ Number of bytes currently in the queue.
    , limit :: !Int
      -- ^ Loosely-enforced limit on number of bytes in the queue.
    }
    -- ^ Invariants:
    --
    --  * bytes == sum (map B.length chan)
    --
    --  * No chunks in 'chan' are empty.
    --
    --  * limit >= 0

instance Eq ByteQueue where
    (==) a b = chan a == chan b

newIO :: Int  -- ^ Limit on number of bytes in queue
      -> IO ByteQueue
newIO n = do
    chan  <- newTChanIO
    bytes <- newTVarIO 0
    return $! ByteQueue{limit = max 0 n, ..}

-- | Read a chunk of bytes from the queue.
read :: ByteQueue -> STM ByteString
read ByteQueue{..} = do
    s <- readTChan chan
    modifyTVar' bytes (\n -> n - B.length s)
    return s

-- | Put some bytes back.  They will be the next bytes read.
-- This will never block.
unRead :: ByteQueue -> ByteString -> STM ()
unRead ByteQueue{..} s
  | B.null s = return ()
  | otherwise = do
      unGetTChan chan s
      modifyTVar' bytes (\n -> n + B.length s)

-- | Write some bytes to the queue.  Block if the queue is full.
write :: ByteQueue -> ByteString -> STM ()
write ByteQueue{..} s
  | B.null s = return ()
  | otherwise = do
      n <- readTVar bytes
      let !n' = n + B.length s
      -- Write item if channel is empty or if item does not exceed the limit.
      -- Otherwise, wait.
      if n <= 0 || n' <= limit then do
          writeTChan chan s
          writeTVar bytes n'
      else
          retry
