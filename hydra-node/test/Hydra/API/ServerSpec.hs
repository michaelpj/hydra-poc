module Hydra.API.ServerSpec where

import Hydra.Prelude
import Control.Monad.Class.MonadSTM (
  modifyTVar',
  check,
  newTQueue,
  newTVarIO,
  readTQueue,
  readTVar,
  tryReadTQueue,
  writeTQueue,
 )
import qualified Data.Text as Text
import Hydra.API.Server (withAPIServer)
import Hydra.HeadLogic (ClientResponse (..))
import Hydra.Ledger.Simple (SimpleTx)
import Hydra.Logging (nullTracer)
import Hydra.Network (close)
import Network.Wai.Handler.Warp (openFreePort)
import Network.WebSockets (runClient)
import Network.WebSockets.Connection (receiveData)
import Test.Hspec
import Test.Util (failAfter)
import Control.Exception (IOException)

spec :: Spec
spec = describe "API Server" $ do
  it "sends response to all connected clients" $ do
    queue <- atomically newTQueue
    failAfter 5 $
      withFreePort $ \port ->
        withAPIServer @SimpleTx "127.0.0.1" (fromIntegral port) nullTracer noop $ \response -> do
          semaphore <- newTVarIO 0
          withAsync (concurrently_ (testClient port queue semaphore) (testClient port queue semaphore)) $ \_ -> do
            atomically $ readTVar semaphore >>= \n -> check (n == 2)
            response ReadyToCommit

            atomically (replicateM 2 (readTQueue queue)) `shouldReturn` [ReadyToCommit, ReadyToCommit]
            atomically (tryReadTQueue queue) `shouldReturn` Nothing

withFreePort :: (Int -> IO ()) -> IO ()
withFreePort action = do
  (port, sock) <- openFreePort
  close sock
  action port

noop :: Applicative m => a -> m ()
noop = const $ pure ()

testClient :: HasCallStack => Int -> TQueue IO (ClientResponse SimpleTx) -> TVar IO Int -> IO ()
testClient port queue semaphore =
  failAfter 5 $ tryClient
 where
  tryClient =
    runClient
      "127.0.0.1"
      port
      "/"
      ( \cnx -> do
          atomically $ modifyTVar' semaphore (+ 1)
          msg <- receiveData cnx
          case readMaybe (Text.unpack msg) of
            Just resp -> atomically (writeTQueue queue resp)
            Nothing -> expectationFailure (show $ "Failed to decode message " <> msg)
      )
      `catch` \(_ :: IOException) -> tryClient
