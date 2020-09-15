const connectionConfig = require('frg-ethereum-runners/config/network_config.json');
const { projectId, mnemonic } = require('./secrets.json');
const HDWalletProvider = require('@truffle/hdwallet-provider');

const mainnetUrl = 'https://mainnet.infura.io/v3/2521699167dc43c8b4c15f07860c208a';

function keystoreProvider (providerURL) {
  const fs = require('fs');
  const EthereumjsWallet = require('ethereumjs-wallet');
  const HDWalletProvider = require('truffle-hdwallet-provider');

  const KEYFILE = process.env.KEYFILE;
  const PASSPHRASE = (process.env.PASSPHRASE || '');
  if (!KEYFILE) {
    throw new Error('Expected environment variable KEYFILE with path to ethereum wallet keyfile');
  }

  const KEYSTORE = JSON.parse(fs.readFileSync(KEYFILE));
  const wallet = EthereumjsWallet.fromV3(KEYSTORE, PASSPHRASE);
  return new HDWalletProvider(wallet._privKey.toString('hex'), providerURL);
}

module.exports = {
  networks: {
    ganacheUnitTest: connectionConfig.ganacheUnitTest,
    gethUnitTest: connectionConfig.gethUnitTest,
    testrpcCoverage: connectionConfig.testrpcCoverage,
    rink_e_by: {
      provider: () => new HDWalletProvider(
        mnemonic, `https://rinkeby.infura.io/v3/${projectId}`
      ),
      networkId: 4,
      gasPrice: 10e9
    },
    mainnet: {
      provider: () => new HDWalletProvider(
        mnemonic, `https://mainnet.infura.io/v3/${projectId}`
      ),
      networkId: 1,
      gasPrice: 140e9 // check https://www.ethgasstation.info/
    }
  },
  mocha: {
    enableTimeouts: false,
    reporter: 'eth-gas-reporter',
    reporterOptions: {
      currency: 'USD'
    }
  },
  compilers: {
    solc: {
      version: '0.5.0'
    }
  }
};
