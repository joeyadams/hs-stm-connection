{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}
module Data.STM.Queue (
    Queue,
    newIO,
    read,
    write,
    cram,
    isEmpty,
) where

import Control.Concurrent.STM
import Prelude hiding (read)

data Queue a = Queue
    { chan  :: !(TChan a)
    , count :: !(TVar Int)
      -- ^ Number of items currently in the queue.
    , limit :: !Int
      -- ^ Loosely-enforced limit on number of items in the queue.
      --   Use 'maxBound' for \"no limit\".
    }
    -- ^ Invariants:
    --
    --  * count == length chan
    --
    --  * limit >= 0

instance Eq (Queue a) where
    a == b = chan a == chan b

newIO :: Maybe Int
         -- ^ Limit on number of items in queue.  'Nothing' means no limit.
      -> IO (Queue a)
newIO mlimit = do
    chan  <- newTChanIO
    count <- newTVarIO 0
    let !limit = maybe maxBound (max 0) mlimit
    return $! Queue{..}

dec :: TVar Int -> STM ()
dec var = do
    n <- readTVar var
    writeTVar var $! n-1

inc :: TVar Int -> STM ()
inc var = do
    n <- readTVar var
    writeTVar var $! n+1

incLimit :: TVar Int -> Int -> STM ()
incLimit var limit = do
    n <- readTVar var
    if n < limit
        then writeTVar var $! n+1
        else retry

-- | Read an item from the queue.
read :: Queue a -> STM a
read Queue{..} = do
    a <- readTChan chan
    dec count
    return a

-- | Write an item to the queue.  Block if the queue is full.
write :: Queue a -> a -> STM ()
write Queue{..} a = do
    incLimit count limit
    writeTChan chan a

-- | Like 'write', but proceed even if the queue limit is exceeded.
cram :: Queue a -> a -> STM ()
cram Queue{..} a = do
    inc count
    writeTChan chan a

-- | Return 'True' if the queue is empty, meaning 'read' would block.
isEmpty :: Queue a -> STM Bool
isEmpty = isEmptyTChan . chan
