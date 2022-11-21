{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DerivingStrategies  #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE NumericUnderscores  #-}

{-# OPTIONS_GHC -fno-warn-unused-imports   #-}
{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}


module Vesting.OffChain where


import qualified Control.Monad             as Monad (void, unless, when)
import qualified GHC.Generics              as GHCGenerics (Generic)
import qualified Data.Aeson                as DataAeson (ToJSON, FromJSON)
import qualified Data.OpenApi.Schema       as DataOpenApiSchema (ToSchema)
import qualified Prelude                   as P
import qualified Data.Void                 as Void (Void)
import qualified Data.Map                  as Map
import Data.Text                           (Text, replicate)
import qualified Data.Text                 as T
import Text.Printf                         (printf)
                                           
import qualified PlutusTx                  
import PlutusTx.Prelude                    
import qualified Plutus.Contract           as PlutusContract
import qualified Ledger.Ada                as Ada
import qualified Ledger.Tx                 as LedgerTx
import qualified Plutus.V2.Ledger.Api      as LedgerApiV2
import qualified Ledger                    (PaymentPubKeyHash, getCardanoTxId, unitRedeemer)
import qualified Ledger.Constraints        as Constraints
import qualified Plutus.V1.Ledger.Scripts  as ScriptsLedger
import qualified Plutus.V1.Ledger.Interval as LedgerIntervalV1

import qualified Vesting.OnChain           as OnChain


-- ----------------------------------------------------------------------
-- Data types 

data GiveParams = GiveParams
  { gpBeneficiary :: !Ledger.PaymentPubKeyHash
  , gpDeadline    :: !LedgerApiV2.POSIXTime
  , gpAmount      :: !Integer
  } deriving (GHCGenerics.Generic,
              DataAeson.ToJSON,
              DataAeson.FromJSON,
              DataOpenApiSchema.ToSchema)


-- ----------------------------------------------------------------------
-- Give endpoint (producer)

give :: forall w s e. PlutusContract.AsContractError e
     => GiveParams
     -> PlutusContract.Contract w s e ()
give GiveParams{..} = do
  let dat = OnChain.Dat {
              OnChain.beneficiary = gpBeneficiary,
              OnChain.deadline    = gpDeadline
            }
      lookups = Constraints.plutusV2OtherScript OnChain.validator
      tx = Constraints.mustPayToOtherScript OnChain.validatorHash
             (LedgerApiV2.Datum $ PlutusTx.toBuiltinData dat)
             (Ada.lovelaceValueOf gpAmount)

  submittedTx <- PlutusContract.submitTxConstraintsWith @OnChain.VTypes
                   lookups tx
  Monad.void $ PlutusContract.awaitTxConfirmed (Ledger.getCardanoTxId submittedTx)


-- ----------------------------------------------------------------------
-- Grab endpoint (consumer)

grab :: forall w s e. PlutusContract.AsContractError e
     => PlutusContract.Contract w s e ()
grab = do
  pkh   <- PlutusContract.ownFirstPaymentPubKeyHash
  now   <- PlutusContract.currentTime
  utxos <- PlutusContract.utxosAt OnChain.address

  let validUtxos = Map.filter (isSuitable $ utxoPred pkh now) utxos
      utxosNotFound = Map.null validUtxos

  Monad.when utxosNotFound $ do
    PlutusContract.logInfo @P.String $ printf "No valid UTXOs found"

  Monad.unless utxosNotFound $ do
    PlutusContract.logInfo @P.String $ printf "Found %d UTXOs" (P.length validUtxos)
    let interval' = LedgerIntervalV1.from now
        lookups = Constraints.unspentOutputs validUtxos P.<>
                  Constraints.plutusV2OtherScript OnChain.validator
        tx = mconcat [Constraints.mustSpendScriptOutput oref Ledger.unitRedeemer
                     | oref <- fst <$> Map.toList validUtxos ] P.<>
             Constraints.mustValidateIn interval'
    Monad.void $ PlutusContract.submitTxConstraintsWith @OnChain.VTypes lookups tx


-- ----------------------------------------------------------------------
-- Utility functions

isSuitable :: (OnChain.Dat -> Bool)         -- filter predicate 
           -> LedgerTx.ChainIndexTxOut      -- utxo
           -> Bool                          -- valid or invalid
isSuitable p o =
  case LedgerTx._ciTxOutScriptDatum o of
    (_, Nothing)  -> False
    (_, Just dat) ->
      let mDat = PlutusTx.fromBuiltinData (LedgerApiV2.getDatum dat)
      in maybe False p mDat


utxoPred :: Ledger.PaymentPubKeyHash   -- spending pkh
              -> LedgerApiV2.POSIXTime      -- now 
              -> OnChain.Dat                -- datum of found utxo
              -> Bool
utxoPred pkh now dat = OnChain.deadline dat <= now
                    && OnChain.beneficiary dat == pkh
        
  
