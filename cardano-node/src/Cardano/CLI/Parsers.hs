module Cardano.CLI.Parsers
  ( ClientCommand(..)
  , command'
  , parseDelegationRelatedValues
  , parseGenesisParameters
  , parseGenesisRelatedValues
  , parseKeyRelatedValues
  , parseLocalNodeQueryValues
  , parseMiscellaneous
  , parseRequiresNetworkMagic
  , parseTxRelatedValues
  ) where

import           Cardano.Prelude hiding (option)
import           Prelude (String)

import qualified Control.Arrow
import qualified Data.List.NonEmpty as NE
import           Data.Text (pack)
import           Data.Time (UTCTime)
import           Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import           Options.Applicative as OA

import           Cardano.CLI.Byron.Parsers (ByronCommand(..))
import           Cardano.CLI.Delegation
import           Cardano.CLI.Genesis
import           Cardano.CLI.Key
import           Cardano.CLI.Tx

import           Cardano.Common.Parsers

import           Cardano.Binary (Annotated(..))
import           Cardano.Chain.Common
                   (Address(..), BlockCount(..), Lovelace,
                    NetworkMagic(..), decodeAddressBase58,
                    mkLovelace, rationalToLovelacePortion)
import           Cardano.Chain.Genesis (FakeAvvmOptions(..), TestnetBalanceOptions(..))
import           Cardano.Chain.Slotting (EpochNumber(..))
import           Cardano.Chain.UTxO (TxId, TxIn(..), TxOut(..))
import           Cardano.Config.Types
import           Cardano.Crypto (RequiresNetworkMagic(..), decodeHash)
import           Cardano.Crypto.ProtocolMagic
                   (AProtocolMagic(..), ProtocolMagic
                   , ProtocolMagicId(..))

-- | Sub-commands of 'cardano-cli'.
data ClientCommand
  =
  --- Byron Related Commands ---
    ByronClientCommand ByronCommand

  --- Genesis Related Commands ---
  | Genesis
    NewDirectory
    GenesisParameters
    Protocol
  | PrintGenesisHash
    GenesisFile

  --- Key Related Commands ---
  | Keygen
    Protocol
    NewSigningKeyFile
    PasswordRequirement
  | ToVerification
    Protocol
    SigningKeyFile
    NewVerificationKeyFile

  | PrettySigningKeyPublic
    Protocol
    SigningKeyFile

  | MigrateDelegateKeyFrom
    Protocol
    -- ^ Old protocol
    SigningKeyFile
    -- ^ Old key
    Protocol
    -- ^ New protocol
    NewSigningKeyFile
    -- ^ New Key

  | PrintSigningKeyAddress
    Protocol
    NetworkMagic  -- TODO:  consider deprecation in favor of ProtocolMagicId,
                  --        once Byron is out of the picture.
    SigningKeyFile

    --- Delegation Related Commands ---

  | IssueDelegationCertificate
    ConfigYamlFilePath
    EpochNumber
    -- ^ The epoch from which the delegation is valid.
    SigningKeyFile
    -- ^ The issuer of the certificate, who delegates their right to sign blocks.
    VerificationKeyFile
    -- ^ The delegate, who gains the right to sign blocks on behalf of the issuer.
    NewCertificateFile
    -- ^ Filepath of the newly created delegation certificate.
  | CheckDelegation
    ConfigYamlFilePath
    CertificateFile
    VerificationKeyFile
    VerificationKeyFile

  | GetLocalNodeTip
    ConfigYamlFilePath
    (Maybe CLISocketPath)

    -----------------------------------

  | SubmitTx
    TxFile
    -- ^ Filepath of transaction to submit.
    ConfigYamlFilePath
    (Maybe CLISocketPath)

  | SpendGenesisUTxO
    ConfigYamlFilePath
    NewTxFile
    -- ^ Filepath of the newly created transaction.
    SigningKeyFile
    -- ^ Signing key of genesis UTxO owner.
    Address
    -- ^ Genesis UTxO address.
    (NonEmpty TxOut)
    -- ^ Tx output.
  | SpendUTxO
    ConfigYamlFilePath
    NewTxFile
    -- ^ Filepath of the newly created transaction.
    SigningKeyFile
    -- ^ Signing key of Tx underwriter.
    (NonEmpty TxIn)
    -- ^ Inputs available for spending to the Tx underwriter's key.
    (NonEmpty TxOut)
    -- ^ Genesis UTxO output Address.

    --- Misc Commands ---

  | DisplayVersion

  | ValidateCBOR
    CBORObject
    -- ^ Type of the CBOR object
    FilePath

  | PrettyPrintCBOR
    FilePath
   deriving Show

-- | See the rationale for cliParseBase58Address.
cliParseLovelace :: Word64 -> Lovelace
cliParseLovelace =
  either (panic . ("Bad Lovelace value: " <>) . show) identity
  . mkLovelace

-- | Here, we hope to get away with the usage of 'error' in a pure expression,
--   because the CLI-originated values are either used, in which case the error is
--   unavoidable rather early in the CLI tooling scenario (and especially so, if
--   the relevant command ADT constructor is strict, like with ClientCommand), or
--   they are ignored, in which case they are arguably irrelevant.
--   And we're getting a correct-by-construction value that doesn't need to be
--   scrutinised later, so that's an abstraction benefit as well.
cliParseBase58Address :: Text -> Address
cliParseBase58Address =
  either (panic . ("Bad Base58 address: " <>) . show) identity
  . decodeAddressBase58


-- | See the rationale for cliParseBase58Address.
cliParseTxId :: String -> TxId
cliParseTxId =
  either (panic . ("Bad Lovelace value: " <>) . show) identity
  . decodeHash . pack

parseAddress :: String -> String -> Parser Address
parseAddress opt desc =
  option (cliParseBase58Address <$> auto)
    $ long opt <> metavar "ADDR" <> help desc

parseCBORObject :: Parser CBORObject
parseCBORObject = asum
  [ flagParser CBORBlockByron "byron-block"
    "The CBOR file is a byron era block"
  , flagParser CBORDelegationCertificateByron "byron-delegation-certificate"
    "The CBOR file is a byron era delegation certificate"
  , flagParser CBORTxByron "byron-tx"
    "The CBOR file is a byron era tx"
  , flagParser CBORUpdateProposalByron "byron-update-proposal"
    "The CBOR file is a byron era update proposal"
  ]

parseCertificateFile :: String -> String -> Parser CertificateFile
parseCertificateFile opt desc = CertificateFile <$> parseFilePath opt desc

parseDelegationRelatedValues :: Parser ClientCommand
parseDelegationRelatedValues =
  subparser $ mconcat
    [ commandGroup "Delegation related commands"
    , metavar "Delegation related commands"
    , command'
        "issue-delegation-certificate"
        "Create a delegation certificate allowing the\
        \ delegator to sign blocks on behalf of the issuer"
        $ IssueDelegationCertificate
        <$> (ConfigYamlFilePath <$> parseConfigFile)
        <*> ( EpochNumber
                <$> parseIntegral
                      "since-epoch"
                      "The epoch from which the delegation is valid."
              )
        <*> parseSigningKeyFile
              "secret"
              "The issuer of the certificate, who delegates\
              \ their right to sign blocks."
        <*> parseVerificationKeyFile
              "delegate-key"
              "The delegate, who gains the right to sign block."
        <*> parseNewCertificateFile "certificate"
    , command'
        "check-delegation"
        "Verify that a given certificate constitutes a valid\
        \ delegation relationship between keys."
        $ CheckDelegation
            <$> (ConfigYamlFilePath <$> parseConfigFile)
            <*> parseCertificateFile
                  "certificate"
                  "The certificate embodying delegation to verify."
            <*> parseVerificationKeyFile
                  "issuer-key"
                  "The genesis key that supposedly delegates."
            <*> parseVerificationKeyFile
                  "delegate-key"
                  "The operation verification key supposedly delegated to."
      ]


parseFakeAvvmOptions :: Parser FakeAvvmOptions
parseFakeAvvmOptions =
  FakeAvvmOptions
    <$> parseIntegral "avvm-entry-count" "Number of AVVM addresses."
    <*> parseLovelace "avvm-entry-balance" "AVVM address."

-- | Values required to create genesis.
parseGenesisParameters :: Parser GenesisParameters
parseGenesisParameters =
  GenesisParameters
    <$> parseUTCTime
          "start-time"
          "Start time of the new cluster to be enshrined in the new genesis."
    <*> parseFilePath
          "protocol-parameters-file"
          "JSON file with protocol parameters."
    <*> parseK
    <*> parseProtocolMagic
    <*> parseTestnetBalanceOptions
    <*> parseFakeAvvmOptions
    <*> (rationalToLovelacePortion <$>
         parseFractionWithDefault
          "avvm-balance-factor"
          "AVVM balances will be multiplied by this factor (defaults to 1)."
          1)
    <*> optional
        ( parseIntegral
            "secret-seed"
            "Optionally specify the seed of generation."
        )

parseGenesisRelatedValues :: Parser ClientCommand
parseGenesisRelatedValues =
  subparser $ mconcat
    [ commandGroup "Genesis related commands"
    , metavar "Genesis related commands"
    , command' "genesis" "Create genesis."
      $ Genesis
          <$> parseNewDirectory
              "genesis-output-dir"
              "Non-existent directory where genesis JSON file and secrets shall be placed."
          <*> parseGenesisParameters
          <*> parseProtocol
    , command' "print-genesis-hash" "Compute hash of a genesis file."
        $ PrintGenesisHash
            <$> parseGenesisFile "genesis-json"
    ]

parseK :: Parser BlockCount
parseK =
  BlockCount
    <$> parseIntegral "k" "The security parameter of the Ouroboros protocol."

parseNewDirectory :: String -> String -> Parser NewDirectory
parseNewDirectory opt desc = NewDirectory <$> parseFilePath opt desc

-- | Values required to create keys and perform
-- transformation on keys.
parseKeyRelatedValues :: Parser ClientCommand
parseKeyRelatedValues =
  subparser $ mconcat
        [ commandGroup "Key related commands"
        , metavar "Key related commands"
        , command' "keygen" "Generate a signing key."
            $ Keygen
                <$> parseProtocol
                <*> parseNewSigningKeyFile "secret"
                <*> parseFlag' GetPassword EmptyPassword
                      "no-password"
                      "Disable password protection."
        , command'
            "to-verification"
            "Extract a verification key in its base64 form."
            $ ToVerification
                <$> parseProtocol
                <*> parseSigningKeyFile
                      "secret"
                      "Signing key file to extract the verification part from."
                <*> parseNewVerificationKeyFile "to"
        , command'
            "signing-key-public"
            "Pretty-print a signing key's verification key (not a secret)."
            $ PrettySigningKeyPublic
                <$> parseProtocol
                <*> parseSigningKeyFile
                      "secret"
                      "Signing key to pretty-print."
        , command'
            "signing-key-address"
            "Print address of a signing key."
            $ PrintSigningKeyAddress
                <$> parseProtocol
                <*> parseNetworkMagic
                <*> parseSigningKeyFile
                      "secret"
                      "Signing key, whose address is to be printed."
        , command'
            "migrate-delegate-key-from"
            "Migrate a delegate key from an older version."
            $ MigrateDelegateKeyFrom
                <$> parseProtocol -- Old protocol
                <*> parseSigningKeyFile "from" "Signing key file to migrate."
                <*> parseProtocol -- New protocol
                <*> parseNewSigningKeyFile "to"
        ]
parseLocalNodeQueryValues :: Parser ClientCommand
parseLocalNodeQueryValues =
  subparser $ mconcat
        [ commandGroup "Local node related commands"
        , metavar "Local node related commands"
        , command' "get-tip" "Get the tip of your local node's blockchain"
            $ GetLocalNodeTip
                <$> (ConfigYamlFilePath <$> parseConfigFile)
                <*> parseCLISocketPath "Socket of target node"
        ]



parseFractionWithDefault
  :: String
  -> String
  -> Double
  -> Parser Rational
parseFractionWithDefault optname desc w =
  toRational <$> ( option readDouble
                 $ long optname
                <> metavar "DOUBLE"
                <> help desc
                <> value w
                )

parseNetworkMagic :: Parser NetworkMagic
parseNetworkMagic =
  asum [ flag' NetworkMainOrStage $ mconcat
           [ long "main-or-staging"
           , help ""
           ]
       , option (fmap NetworkTestnet auto)
           $ long "testnet-magic"
             <> metavar "MAGIC"
             <> help "The testnet network magic, decibal"
       ]

parseNewCertificateFile :: String -> Parser NewCertificateFile
parseNewCertificateFile opt =
  NewCertificateFile
    <$> parseFilePath opt "Non-existent file to write the certificate to."

parseNewSigningKeyFile :: String -> Parser NewSigningKeyFile
parseNewSigningKeyFile opt =
  NewSigningKeyFile
    <$> parseFilePath opt "Non-existent file to write the signing key to."

parseNewTxFile :: String -> Parser NewTxFile
parseNewTxFile opt =
  NewTxFile
    <$> parseFilePath opt "Non-existent file to write the signed transaction to."

parseNewVerificationKeyFile :: String -> Parser NewVerificationKeyFile
parseNewVerificationKeyFile opt =
  NewVerificationKeyFile
    <$> parseFilePath opt "Non-existent file to write the verification key to."

parseMiscellaneous :: Parser ClientCommand
parseMiscellaneous = subparser $ mconcat
  [ commandGroup "Miscellaneous commands"
  , metavar "Miscellaneous commands"
  , command'
      "validate-cbor"
      "Validate a CBOR blockchain object."
      $ ValidateCBOR
          <$> parseCBORObject
          <*> parseFilePath "filepath" "Filepath of CBOR file."
  , command'
      "version"
      "Show cardano-cli version"
      $ pure DisplayVersion
  , command'
      "pretty-print-cbor"
      "Pretty print a CBOR file."
      $ PrettyPrintCBOR
          <$> parseFilePath "filepath" "Filepath of CBOR file."
  ]

parseProtocolMagicId :: String -> Parser ProtocolMagicId
parseProtocolMagicId arg =
  ProtocolMagicId
    <$> parseIntegral arg "The magic number unique to any instance of Cardano."

parseProtocolMagic :: Parser ProtocolMagic
parseProtocolMagic =
  flip AProtocolMagic RequiresMagic . flip Annotated ()
    <$> parseProtocolMagicId "protocol-magic"

parseRequiresNetworkMagic :: Parser RequiresNetworkMagic
parseRequiresNetworkMagic =
  flag RequiresNoMagic RequiresMagic
    ( long "require-network-magic"
        <> help "Require network magic in transactions."
        <> hidden
    )

parseTestnetBalanceOptions :: Parser TestnetBalanceOptions
parseTestnetBalanceOptions =
  TestnetBalanceOptions
    <$> parseIntegral
          "n-poor-addresses"
          "Number of poor nodes (with small balance)."
    <*> parseIntegral
          "n-delegate-addresses"
          "Number of delegate nodes (with huge balance)."
    <*> parseLovelace
          "total-balance"
          "Total balance owned by these nodes."
    <*> parseFraction
          "delegate-share"
          "Portion of stake owned by all delegates together."

parseTxFile :: String -> Parser TxFile
parseTxFile opt =
  TxFile
    <$> parseFilePath opt "File containing the signed transaction."

parseTxIn :: Parser TxIn
parseTxIn =
  option
  ( uncurry TxInUtxo
    . Control.Arrow.first cliParseTxId
    <$> auto
  )
  $ long "txin"
    <> metavar "(TXID,INDEX)"
    <> help "Transaction input is a pair of an UTxO TxId and a zero-based output index."

parseTxOut :: Parser TxOut
parseTxOut =
  option
    ( uncurry TxOut
      . Control.Arrow.first cliParseBase58Address
      . Control.Arrow.second cliParseLovelace
      <$> auto
    )
    $ long "txout"
      <> metavar "ADDR:LOVELACE"
      <> help "Specify a transaction output, as a pair of an address and lovelace."

parseTxRelatedValues :: Parser ClientCommand
parseTxRelatedValues =
  subparser $ mconcat
    [ commandGroup "Transaction related commands"
    , metavar "Transaction related commands"
    , command'
        "submit-tx"
        "Submit a raw, signed transaction, in its on-wire representation."
        $ SubmitTx
            <$> parseTxFile "tx"
            <*> (ConfigYamlFilePath <$> parseConfigFile)
            <*> parseCLISocketPath "Socket of target node"
    , command'
        "issue-genesis-utxo-expenditure"
        "Write a file with a signed transaction, spending genesis UTxO."
        $ SpendGenesisUTxO
            <$> (ConfigYamlFilePath <$> parseConfigFile)
            <*> parseNewTxFile "tx"
            <*> parseSigningKeyFile
                  "wallet-key"
                  "Key that has access to all mentioned genesis UTxO inputs."
            <*> parseAddress
                  "rich-addr-from"
                  "Tx source: genesis UTxO richman address (non-HD)."
            <*> (NE.fromList <$> some parseTxOut)

    , command'
        "issue-utxo-expenditure"
        "Write a file with a signed transaction, spending normal UTxO."
        $ SpendUTxO
            <$> (ConfigYamlFilePath <$> parseConfigFile)
            <*> parseNewTxFile "tx"
            <*> parseSigningKeyFile
                  "wallet-key"
                  "Key that has access to all mentioned genesis UTxO inputs."
            <*> (NE.fromList <$> some parseTxIn)
            <*> (NE.fromList <$> some parseTxOut)
      ]


parseUTCTime :: String -> String -> Parser UTCTime
parseUTCTime optname desc =
  option (posixSecondsToUTCTime . fromInteger <$> auto)
    $ long optname <> metavar "POSIXSECONDS" <> help desc

parseVerificationKeyFile :: String -> String -> Parser VerificationKeyFile
parseVerificationKeyFile opt desc = VerificationKeyFile <$> parseFilePath opt desc
