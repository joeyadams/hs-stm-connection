{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}
module Data.STM.Queue (
    Queue,
    newIO,
    close,
    read,
    isEmpty,
    write,
    cram,
) where

import Control.Applicative
import Control.Concurrent.STM
import Prelude hiding (read)

data Queue t a = Queue
    { chan  :: !(TChan a)
    , count :: !(TVar Int)
      -- ^ Number of items currently in the queue.
    , limit :: !Int
      -- ^ Loosely-enforced limit on number of items in the queue.
      --   Use 'maxBound' for \"no limit\".
    , closed :: !(TVar (Maybe t))
    }
    -- ^ Invariants:
    --
    --  * count == length chan
    --
    --  * limit >= 0

instance Eq (Queue t a) where
    a == b = chan a == chan b

newIO :: Maybe Int
         -- ^ Limit on number of items in queue.  'Nothing' means no limit.
      -> IO (Queue t a)
newIO mlimit = do
    chan  <- newTChanIO
    count <- newTVarIO 0
    let !limit = maybe maxBound (max 0) mlimit
    closed <- newTVarIO Nothing
    return $! Queue{..}

whenOpen :: Queue t a -> STM b -> STM (Either t b)
whenOpen Queue{..} onOpen = do
    m <- readTVar closed
    case m of
        Nothing -> Right <$> onOpen
        Just t  -> return $ Left t

-- | Close the 'Queue' with the given terminator value.  No more items may be
-- queued after this, but items still in the queue may be read.
--
-- If 'close' has already been called, return 'Left' with the old terminator
-- value.  All of the 'Queue' accessors signal failure this way.
close :: Queue t a -> t -> STM (Either t ())
close q@Queue{..} t =
    whenOpen q $ writeTVar closed $ Just t

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

-- | Read an item from the queue.  Return 'Left' if the queue is 'close'd and
-- all items have been read out of it.
read :: Queue t a -> STM (Either t a)
read q@Queue{..} = do
    m <- tryReadTChan chan
    case m of
        Nothing -> whenOpen q retry
        Just a -> do
            dec count
            return $ Right a

-- | Return 'True' if the queue is empty, meaning 'read' would block.
-- This ignores whether the queue is 'close'd.
isEmpty :: Queue t a -> STM Bool
isEmpty = isEmptyTChan . chan

-- | Write an item to the queue.  Block if the queue is full.
-- Return 'Left' if the queue is 'close'd.
write :: Queue t a -> a -> STM (Either t ())
write q@Queue{..} a =
    whenOpen q $ do
        incLimit count limit
        writeTChan chan a

-- | Like 'write', but proceed even if the queue limit is exceeded.
cram :: Queue t a -> a -> STM (Either t ())
cram q@Queue{..} a =
    whenOpen q $ do
        inc count
        writeTChan chan a
