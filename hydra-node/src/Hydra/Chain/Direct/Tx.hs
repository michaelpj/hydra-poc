{-# LANGUAGE TypeApplications #-}

-- | Smart constructors for creating Hydra protocol transactions to be used in
-- the 'Hydra.Chain.Direct' way of talking to the main-chain.
--
-- This module also encapsulates the transaction format used when talking to the
-- cardano-node, which is currently different from the 'Hydra.Ledger.Cardano',
-- thus we have not yet "reached" 'isomorphism'.
module Hydra.Chain.Direct.Tx where

import Hydra.Prelude

import Cardano.Ledger.Address (Addr (Addr))
import Cardano.Ledger.Alonzo (AlonzoEra)
import Cardano.Ledger.Alonzo.Data (Data (Data), hashData)
import Cardano.Ledger.Alonzo.Scripts (Script (PlutusScript))
import Cardano.Ledger.Alonzo.Tx (IsValid (IsValid), ValidatedTx (..))
import Cardano.Ledger.Alonzo.TxBody (TxBody (..), TxOut (TxOut))
import Cardano.Ledger.Alonzo.TxWitness (Redeemers (..), TxDats (..), TxWitness (..), unTxDats)
import Cardano.Ledger.Crypto (StandardCrypto)
import Cardano.Ledger.ShelleyMA.Timelocks (ValidityInterval (..))
import Cardano.Ledger.Val (inject)
import qualified Data.Map as Map
import qualified Data.Sequence.Strict as StrictSeq
import qualified Data.Set as Set
import Hydra.Chain (HeadParameters (..), OnChainTx (OnInitTx), PostChainTx (InitTx))
import Hydra.Contract.Head (State (Initial))
import Hydra.Data.ContestationPeriod (contestationPeriodFromDiffTime, contestationPeriodToDiffTime)
import Hydra.Data.Party (partyFromVerKey, partyToVerKey)
import Hydra.Party (anonymousParty, vkey)
import Plutus.V1.Ledger.Api (fromData, toBuiltinData, toData)
import Shelley.Spec.Ledger.API (
  Coin (..),
  Credential (ScriptHashObj),
  Network (Testnet),
  StakeReference (StakeRefNull),
  StrictMaybe (..),
  TxIn,
  Wdrl (Wdrl),
 )
import Shelley.Spec.Ledger.Tx (hashScript)

-- TODO(SN): parameterize
network :: Network
network = Testnet

-- * Post Hydra Head transactions

-- | Construct the Head protocol transactions as Alonzo 'Tx'. Note that
-- 'ValidatedTx' this produces an unbalanced, unsigned transaction and this type
-- was used (in contrast to 'TxBody') to be able to express included datums,
-- onto which at least the 'initTx' relies on.
constructTx :: TxIn StandardCrypto -> PostChainTx tx -> ValidatedTx (AlonzoEra StandardCrypto)
constructTx txIn = \case
  InitTx p -> initTx p txIn
  _ -> error "not implemented"

-- | Create the init transaction from some 'HeadParameters' and a single TxIn
-- which will be used as unique parameter for minting NFTs.
initTx :: HeadParameters -> TxIn StandardCrypto -> ValidatedTx (AlonzoEra StandardCrypto)
initTx HeadParameters{contestationPeriod, parties} txIn =
  mkUnsignedTx body dats
 where
  body =
    TxBody
      { inputs = Set.singleton txIn
      , collateral = mempty
      , outputs = StrictSeq.singleton headOut
      , txcerts = mempty
      , txwdrls = Wdrl mempty
      , txfee = Coin 0
      , txvldt = ValidityInterval SNothing SNothing
      , txUpdates = SNothing
      , reqSignerHashes = mempty
      , mint = mempty
      , scriptIntegrityHash = SNothing
      , adHash = SNothing
      , txnetworkid = SNothing
      }

  dats = TxDats $ Map.singleton headDatumHash headDatum

  headOut = TxOut headAddress headValue (SJust headDatumHash)

  -- TODO(SN): The main Hydra Head script address. Will be parameterized by the
  -- thread token eventually. For now, this is just some arbitrary address, as
  -- it is also later quite arbitrary/different per Head.
  headAddress :: Addr StandardCrypto
  headAddress =
    Addr
      network
      (ScriptHashObj $ hashScript @(AlonzoEra StandardCrypto) headScript)
      -- REVIEW(SN): stake head funds?
      StakeRefNull

  -- REVIEW(SN): how much to store here / minUtxoValue / depending on assets?
  headValue = inject (Coin 0)

  headDatumHash = hashData @(AlonzoEra StandardCrypto) headDatum

  headDatum =
    Data . toData . toBuiltinData $
      Initial
        (contestationPeriodFromDiffTime contestationPeriod)
        (map (partyFromVerKey . vkey) parties)

  headScript = PlutusScript "some invalid plutus script"

-- * Observe Hydra Head transactions

observeTx :: ValidatedTx (AlonzoEra StandardCrypto) -> Maybe (OnChainTx tx)
observeTx tx =
  observeInitTx tx
    <|> observeCommitTx tx

observeInitTx :: ValidatedTx (AlonzoEra StandardCrypto) -> Maybe (OnChainTx tx)
observeInitTx ValidatedTx{wits} = do
  (Data d) <- firstDatum
  fromData d >>= \case
    Initial cp ps ->
      pure $ OnInitTx (contestationPeriodToDiffTime cp) (map convertParty ps)
    _ -> Nothing
 where
  firstDatum = snd . head <$> nonEmpty datums

  datums = Map.toList . unTxDats $ txdats wits

  convertParty = anonymousParty . partyToVerKey

observeCommitTx :: ValidatedTx (AlonzoEra StandardCrypto) -> Maybe (OnChainTx tx)
observeCommitTx _ = Nothing
--

-- * Helpers

mkUnsignedTx ::
  TxBody (AlonzoEra StandardCrypto) ->
  TxDats (AlonzoEra StandardCrypto) ->
  ValidatedTx (AlonzoEra StandardCrypto)
mkUnsignedTx body datums =
  ValidatedTx
    { body
    , wits =
        TxWitness
          mempty -- txwitsVKey
          mempty -- txwitsBoot
          mempty --txscripts
          datums -- txdats
          (Redeemers mempty) -- txrdmrs
    , isValid = IsValid True -- REVIEW(SN): no idea of the semantics of this
    , auxiliaryData = SNothing
    }
