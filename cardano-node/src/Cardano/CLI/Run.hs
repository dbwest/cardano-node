{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

{-# OPTIONS_GHC -Wno-all-missed-specialisations #-}

module Cardano.CLI.Run (
    CliError (..)
  , ClientCommand(..)
  , runCommand
  --
  , NewDirectory(..)
  , SigningKeyFile(..)
  , VerificationKeyFile(..)
  , NewVerificationKeyFile(..)
  , CertificateFile(..)
  , NewCertificateFile(..)
  , TxFile(..)
  , NewTxFile(..)

  -- * re-exports from Ouroboros-Network
  , IOManager
  , withIOManager
  ) where

import           Cardano.Prelude hiding (option, trace)
import           Control.Monad.Trans.Except (ExceptT)
import           Control.Monad.Trans.Except.Extra (hoistEither, firstExceptT, left)
import qualified Data.ByteString.Lazy as LB
import           Data.Semigroup ((<>))
import qualified Data.Text.Lazy.IO as TL
import qualified Data.Text.Lazy.Builder as Builder
import           Data.Version (showVersion)
import qualified Formatting as F
import           Paths_cardano_node (version)
import           System.Directory (doesPathExist)
import           System.Info (arch, compilerName, compilerVersion, os)

import qualified Cardano.Chain.Common as Common
import qualified Cardano.Chain.Delegation as Delegation
import qualified Cardano.Chain.Genesis as Genesis
import           Cardano.Chain.Update (ApplicationName(..))

import           Cardano.Crypto (RequiresNetworkMagic(..))
import qualified Cardano.Crypto.Hashing as Crypto
import qualified Cardano.Crypto.Signing as Crypto

import           Ouroboros.Network.NodeToClient ( IOManager
                                                , withIOManager
                                                )

import           Cardano.CLI.Byron.Parsers (ByronCommand(..))
import           Cardano.CLI.Byron.UpdateProposal
                   (createUpdateProposal, serialiseByronUpdateProposal, submitByronUpdateProposal)
import           Cardano.CLI.Delegation
import           Cardano.CLI.Genesis
import           Cardano.CLI.Key
import           Cardano.CLI.Ops
import           Cardano.CLI.Parsers
import           Cardano.CLI.Tx
import           Cardano.Common.LocalSocket
import           Cardano.Config.Types


runCommand :: ClientCommand -> ExceptT CliError IO ()
runCommand (ByronClientCommand
             (UpdateProposal configFp sKey pVer sVer sysTag
                             insHash outputFp paramsToUpdate)) = do

  sK <- readSigningKey RealPBFT sKey
  proposal <- createUpdateProposal  configFp sK pVer sVer sysTag insHash paramsToUpdate
  ensureNewFileLBS outputFp (serialiseByronUpdateProposal proposal)

runCommand (ByronClientCommand (SubmitUpdateProposal configFp proposalFp mSocket)) =
  withIOManagerE $ \iocp -> submitByronUpdateProposal iocp configFp proposalFp mSocket


runCommand DisplayVersion = do
  liftIO . putTextLn
         . toS
         $ concat [ "cardano-cli " <> showVersion version
                  , " - " <> os <> "-" <> arch
                  , " - " <> compilerName <> "-" <> showVersion compilerVersion
                  ]

runCommand (Genesis outDir params ptcl) = do
  (genData, genSecrets) <- mkGenesis params
  dumpGenesis ptcl outDir genData genSecrets

runCommand (GetLocalNodeTip configFp mSockPath) =
  withIOManagerE $ \iocp -> liftIO $ getLocalTip configFp mSockPath iocp

runCommand (ValidateCBOR cborObject fp) = do
  bs <- readCBOR fp
  res <- hoistEither $ validateCBOR cborObject bs
  liftIO $ putTextLn res

runCommand (PrettyPrintCBOR fp) = do
  bs <- readCBOR fp
  pPrintCBOR bs

runCommand (PrettySigningKeyPublic ptcl skF) = do
  sK <- readSigningKey ptcl skF
  liftIO . putTextLn . prettyPublicKey $ Crypto.toVerification sK
runCommand (MigrateDelegateKeyFrom oldPtcl oldKey newPtcl (NewSigningKeyFile newKey)) = do
  sk <- readSigningKey oldPtcl oldKey
  sDk <- hoistEither $ serialiseDelegateKey newPtcl sk
  ensureNewFileLBS newKey sDk

runCommand (PrintGenesisHash genFp) = do
  eGen <- readGenesis genFp

  let formatter :: (a, Genesis.GenesisHash)-> Text
      formatter = F.sformat Crypto.hashHexF . Genesis.unGenesisHash . snd

  liftIO . putTextLn $ formatter eGen

runCommand (PrintSigningKeyAddress ptcl netMagic skF) = do
  sK <- readSigningKey ptcl skF
  let sKeyAddress = prettyAddress . Common.makeVerKeyAddress netMagic $ Crypto.toVerification sK
  liftIO $ putTextLn sKeyAddress

runCommand (Keygen ptcl (NewSigningKeyFile skF) passReq) = do
  pPhrase <- liftIO $ getPassphrase ("Enter password to encrypt '" <> skF <> "': ") passReq
  sK <- liftIO $ keygen pPhrase
  serDk <- hoistEither $ serialiseDelegateKey ptcl sK
  ensureNewFileLBS skF serDk

runCommand (ToVerification ptcl skFp (NewVerificationKeyFile vkFp)) = do
  sk <- readSigningKey ptcl skFp
  let vKey = Builder.toLazyText . Crypto.formatFullVerificationKey $ Crypto.toVerification sk
  ensureNewFile TL.writeFile vkFp vKey

runCommand (IssueDelegationCertificate configFp epoch issuerSK delegateVK cert) = do
  nc <- liftIO $ parseNodeConfigurationFP configFp
  vk <- readVerificationKey delegateVK
  sk <- readSigningKey (ncProtocol nc) issuerSK
  pmId <- readProtocolMagicId $ ncGenesisFile nc
  let byGenDelCert :: Delegation.Certificate
      byGenDelCert = issueByronGenesisDelegation pmId epoch sk vk
  sCert <- hoistEither $ serialiseDelegationCert (ncProtocol nc) byGenDelCert
  ensureNewFileLBS (nFp cert) sCert

runCommand (CheckDelegation configFp cert issuerVF delegateVF) = do
  nc <- liftIO $ parseNodeConfigurationFP configFp
  issuerVK <- readVerificationKey issuerVF
  delegateVK <- readVerificationKey delegateVF
  pmId <- readProtocolMagicId $ ncGenesisFile nc
  checkByronGenesisDelegation cert pmId issuerVK delegateVK

runCommand (SubmitTx fp configFp mCliSockPath) = withIOManagerE $ \iocp -> do
    nc <- liftIO $ parseNodeConfigurationFP configFp
    -- Default update value
    let update = Update (ApplicationName "cardano-sl") 1 $ LastKnownBlockVersion 0 2 0
    tx <- readByronTx fp

    firstExceptT
      NodeSubmitTxError
      $ nodeSubmitTx
          iocp
          Nothing
          (ncGenesisFile nc)
          RequiresNoMagic
          Nothing
          Nothing
          Nothing
          (chooseSocketPath (ncSocketPath nc) mCliSockPath)
          update
          (ncProtocol nc)
          tx
runCommand (SpendGenesisUTxO configFp (NewTxFile ctTx) ctKey genRichAddr outs) = do
    nc <- liftIO $ parseNodeConfigurationFP configFp
    sk <- readSigningKey (ncProtocol nc) ctKey
    -- Default update value
    let update = Update (ApplicationName "cardano-sl") 1 $ LastKnownBlockVersion 0 2 0

    tx <- firstExceptT SpendGenesisUTxOError
            $ issueGenesisUTxOExpenditure
                genRichAddr
                outs
                (ncGenesisFile nc)
                RequiresNoMagic
                Nothing
                Nothing
                Nothing
                update
                (ncProtocol nc)
                sk
    ensureNewFileLBS ctTx $ toCborTxAux tx

runCommand (SpendUTxO configFp (NewTxFile ctTx) ctKey ins outs) = do
    nc <- liftIO $ parseNodeConfigurationFP configFp
    sk <- readSigningKey (ncProtocol nc) ctKey
    -- Default update value
    let update = Update (ApplicationName "cardano-sl") 1 $ LastKnownBlockVersion 0 2 0

    gTx <- firstExceptT
             IssueUtxoError
             $ issueUTxOExpenditure
                 ins
                 outs
                 (ncGenesisFile nc)
                 RequiresNoMagic
                 Nothing
                 Nothing
                 Nothing
                 update
                 (ncProtocol nc)
                 sk
    ensureNewFileLBS ctTx $ toCborTxAux gTx

{-------------------------------------------------------------------------------
  Supporting functions
-------------------------------------------------------------------------------}

-- TODO:  we'd be better served by a combination of a temporary file
--        with an atomic rename.
-- | Checks if a path exists and throws and error if it does.
ensureNewFile :: (FilePath -> a -> IO ()) -> FilePath -> a -> ExceptT CliError IO ()
ensureNewFile writer outFile blob = do
  exists <- liftIO $ doesPathExist outFile
  when exists $
    left $ OutputMustNotAlreadyExist outFile
  liftIO $ writer outFile blob

ensureNewFileLBS :: FilePath -> LB.ByteString -> ExceptT CliError IO ()
ensureNewFileLBS = ensureNewFile LB.writeFile

withIOManagerE :: (IOManager -> ExceptT e IO a) -> ExceptT e IO a
withIOManagerE k = ExceptT $ withIOManager (runExceptT . k)
