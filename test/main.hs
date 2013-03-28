{-# LANGUAGE OverloadedStrings #-}
import qualified Control.Concurrent.STM.Connection as C

import Control.Concurrent
import Control.Concurrent.STM
import Data.Default
import Network

main = do
    sock <- listenOn $ PortNumber 1234
    serverOk <- newEmptyMVar
    _ <- forkIO $ do
        (h, _, _) <- accept sock
        conn <- C.new def h
        atomically $ C.send conn "Hello"
        Just "ahoy" <- atomically $ C.recv conn
        Nothing <- atomically $ C.recv conn
        putMVar serverOk ()
        C.close conn

    h <- connectTo "localhost" $ PortNumber 1234
    conn <- C.new def h
    Just "Hello" <- atomically $ C.recv conn
    atomically $ C.send conn "ahoy"
    C.close conn

    takeMVar serverOk
