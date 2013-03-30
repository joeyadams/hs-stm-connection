{-# LANGUAGE RecordWildCards #-}
import Control.Concurrent.STM.Connection (Connection, Backend(..))
import qualified Control.Concurrent.STM.Connection as C

import Control.Applicative
import Control.Concurrent
import Control.Concurrent.STM
import Control.Exception
import Control.Monad
import Data.Default
import Network
import System.IO
import System.IO.Error (isEOFError)

connectHandle :: Handle -> IO (Connection String String)
connectHandle h = do
    hSetBuffering h LineBuffering
    let backendRecv          = (Just <$> hGetLine h) `catchEOF` return Nothing
        backendSend Nothing  = return ()
        backendSend (Just s) = hPutStrLn h s
        backendClose         = hClose h
    C.new def Backend{..}
  where
    catchEOF io handler = catchJust (guard . isEOFError) io (\_ -> handler)

main = do
    sock <- listenOn $ PortNumber 1234
    serverOk <- newEmptyMVar
    _ <- forkIO $ do
        (h, _, _) <- accept sock
        conn <- connectHandle h
        atomically $ C.send conn "Hello"
        Just "ahoy" <- atomically $ C.recv conn
        Nothing <- atomically $ C.recv conn
        putMVar serverOk ()
        C.close conn

    h <- connectTo "localhost" $ PortNumber 1234
    conn <- connectHandle h
    Just "Hello" <- atomically $ C.recv conn
    atomically $ C.send conn "ahoy"
    C.close conn

    takeMVar serverOk
