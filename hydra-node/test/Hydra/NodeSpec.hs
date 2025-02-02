{-# LANGUAGE DuplicateRecordFields #-}

module Hydra.NodeSpec where

import Hydra.Prelude
import Test.Hydra.Prelude

import Cardano.Crypto.DSIGN (DSIGNAlgorithm (deriveVerKeyDSIGN, rawSerialiseVerKeyDSIGN), rawSerialiseSignKeyDSIGN)
import Hydra.API.Server (Server (..))
import Hydra.Chain (Chain (..), OnChainTx (..))
import Hydra.ClientInput (ClientInput (..))
import Hydra.HeadLogic (
  Environment (..),
  Event (..),
  HeadState (..),
 )
import Hydra.Ledger (Tx)
import Hydra.Ledger.Simple (SimpleTx (..), simpleLedger, utxoRef, utxoRefs)
import Hydra.Logging (Tracer, showLogsOnFailure)
import Hydra.Network (Host (..), Network (..))
import Hydra.Network.Message (Message (..))
import Hydra.Node (EventQueue (..), HydraNode (..), HydraNodeLog, createEventQueue, createHydraHead, initEnvironment, isEmpty, stepHydraNode)
import Hydra.Options (Options (..), defaultOptions)
import Hydra.Party (Party, SigningKey, alias, deriveParty, generateKey, sign)
import Hydra.Snapshot (Snapshot (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

spec :: Spec
spec = parallel $ do
  describe "initEnvironment" $ do
    -- TODO(SN): maybe we should rather create some 'loadParty' from file
    -- functions and unit test them instead?
    it "only aliases parties which start with a letter" $ do
      withSystemTempDirectory "hydra-node-init-environment" $ \tmp -> do
        -- Store some SigningKey and VerificationKeys (the same)
        let sk = generateKey 4711
        writeFileBS (tmp </> "_me.sk") $ rawSerialiseSignKeyDSIGN sk
        let vkBytes = rawSerialiseVerKeyDSIGN $ deriveVerKeyDSIGN sk
        writeFileBS (tmp </> "alice.vk") vkBytes
        writeFileBS (tmp </> "2.vk") vkBytes
        writeFileBS (tmp </> "~charlie.vk") vkBytes

        Environment{party, otherParties} <-
          initEnvironment $
            defaultOptions
              { me = tmp </> "_me.sk"
              , parties = [tmp </> "alice.vk", tmp </> "2.vk", tmp </> "~charlie.vk"]
              }

        alias party `shouldBe` Nothing
        map alias otherParties `shouldBe` [Just "alice", Nothing, Nothing]

  it "emits a single ReqSn and AckSn as leader, even after multiple ReqTxs" $
    showLogsOnFailure $ \tracer -> do
      -- NOTE(SN): Sequence of parties in OnInitTx of
      -- 'prefix' is relevant, so 10 is the (initial) snapshot leader
      let tx1 = SimpleTx{txSimpleId = 1, txInputs = utxoRefs [2], txOutputs = utxoRefs [4]}
          tx2 = SimpleTx{txSimpleId = 2, txInputs = utxoRefs [4], txOutputs = utxoRefs [5]}
          tx3 = SimpleTx{txSimpleId = 3, txInputs = utxoRefs [5], txOutputs = utxoRefs [6]}
          events =
            prefix
              <> [ NetworkEvent{message = ReqTx{party = 10, transaction = tx1}}
                 , NetworkEvent{message = ReqTx{party = 10, transaction = tx2}}
                 , NetworkEvent{message = ReqTx{party = 10, transaction = tx3}}
                 ]
          signedSnapshot = sign 10 $ Snapshot 1 (utxoRefs [1, 3, 4]) [tx1]
      node <- createHydraNode 10 [20, 30] events
      (node', getNetworkMessages) <- recordNetwork node
      runToCompletion tracer node'
      getNetworkMessages `shouldReturn` [ReqSn 10 1 [tx1], AckSn 10 signedSnapshot 1]

  it "rotates snapshot leaders" $
    showLogsOnFailure $ \tracer -> do
      let tx1 = SimpleTx{txSimpleId = 1, txInputs = utxoRefs [2], txOutputs = utxoRefs [4]}
          sn1 = Snapshot 1 (utxoRefs [1, 2, 3]) mempty
          sn2 = Snapshot 2 (utxoRefs [1, 3, 4]) [tx1]
          events =
            prefix
              <> [ NetworkEvent{message = ReqSn{party = 10, snapshotNumber = 1, transactions = mempty}}
                 , NetworkEvent{message = AckSn 10 (sign 10 sn1) 1}
                 , NetworkEvent{message = AckSn 30 (sign 30 sn1) 1}
                 , NetworkEvent{message = ReqTx{party = 10, transaction = tx1}}
                 ]

      node <- createHydraNode 20 [10, 30] events
      (node', getNetworkMessages) <- recordNetwork node
      runToCompletion tracer node'

      getNetworkMessages `shouldReturn` [AckSn 20 (sign 20 sn1) 1, ReqSn 20 2 [tx1], AckSn 20 (sign 20 sn2) 2]

  it "processes out-of-order AckSn" $
    showLogsOnFailure $ \tracer -> do
      let snapshot = Snapshot 1 (utxoRefs [1, 2, 3]) []
          sig20 = sign 20 snapshot
          sig10 = sign 10 snapshot
          events =
            prefix
              <> [ NetworkEvent{message = AckSn{party = 20, signed = sig20, snapshotNumber = 1}}
                 , NetworkEvent{message = ReqSn{party = 10, snapshotNumber = 1, transactions = []}}
                 ]
      node <- createHydraNode 10 [20, 30] events
      (node', getNetworkMessages) <- recordNetwork node
      runToCompletion tracer node'
      getNetworkMessages `shouldReturn` [AckSn{party = 10, signed = sig10, snapshotNumber = 1}]

oneReqSn :: [Message tx] -> Bool
oneReqSn = (== 1) . length . filter isReqSn

isReqSn :: Message tx -> Bool
isReqSn = \case
  ReqSn{} -> True
  _ -> False

prefix :: [Event SimpleTx]
prefix =
  [ NetworkEvent{message = Connected{peer = Host{hostname = "10.0.0.30", port = 5000}}}
  , NetworkEvent{message = Connected{peer = Host{hostname = "10.0.0.10", port = 5000}}}
  , OnChainEvent
      { onChainTx = OnInitTx 10 [10, 20, 30]
      }
  , ClientEvent{clientInput = Commit (utxoRef 2)}
  , OnChainEvent{onChainTx = OnCommitTx 30 (utxoRef 3)}
  , OnChainEvent{onChainTx = OnCommitTx 20 (utxoRef 2)}
  , OnChainEvent{onChainTx = OnCommitTx 10 (utxoRef 1)}
  , OnChainEvent{onChainTx = OnCollectComTx}
  ]

runToCompletion :: Tx tx => Tracer IO (HydraNodeLog tx) -> HydraNode tx IO -> IO ()
runToCompletion tracer node@HydraNode{eq = EventQueue{isEmpty}} = go
 where
  go =
    unlessM isEmpty $
      stepHydraNode tracer node >> go

createHydraNode ::
  (MonadSTM m, MonadDelay m, MonadAsync m) =>
  SigningKey ->
  [Party] ->
  [Event SimpleTx] ->
  m (HydraNode SimpleTx m)
createHydraNode signingKey otherParties events = do
  eq@EventQueue{putEvent} <- createEventQueue
  forM_ events putEvent
  hh <- createHydraHead ReadyState simpleLedger
  pure $
    HydraNode
      { eq
      , hn = Network{broadcast = const $ pure ()}
      , hh
      , oc = Chain{postTx = const $ pure ()}
      , server = Server{sendOutput = const $ pure ()}
      , env =
          Environment
            { party
            , signingKey
            , otherParties
            }
      }
 where
  party = deriveParty signingKey

recordNetwork :: HydraNode tx IO -> IO (HydraNode tx IO, IO [Message tx])
recordNetwork node = do
  ref <- newIORef []
  pure (patchedNode ref, queryMsgs ref)
 where
  recordMsg ref x = atomicModifyIORef' ref $ \old -> (old <> [x], ())

  patchedNode ref = node{hn = Network{broadcast = recordMsg ref}}

  queryMsgs = readIORef
