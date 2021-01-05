const HDWalletProvider = require('truffle-hdwallet-provider');
require('dotenv').config();

const config = {
  'ganacheUnitTest': {
    'ref': 'ganache-unit-test',
    'host': '127.0.0.1',
    'port': 7545,
    'network_id': '*',
    'gas': 4989556,
    'gasPrice': 9000000000
  },
  'ganacheIntegration': {
    'ref': 'ganache-integration',
    'host': '127.0.0.1',
    'port': 7545,
    'network_id': '*',
    'gas': 7989556,
    'gasPrice': 100000000000
  },
  'gethUnitTest': {
    'ref': 'geth-unit-test',
    'host': '127.0.0.1',
    'port': 8550,
    'wsPort': 8551,
    'networkId': 85500,
    'gas': 7989556,
    'gasPrice': 100000000000,
    'testOnlyHDWPasscode': 'dollars',
    'chainId': 5,
    'network_id': 5
  },
  'gethIntegration': {
    'ref': 'geth-integration',
    'host': '127.0.0.1',
    'port': 7560,
    'wsPort': 7561,
    'networkId': 75600,
    'gas': 7989556,
    'gasPrice': 100000000000,
    'testOnlyHDWPasscode': 'dollars',
    'chainId': 5,
    'network_id': 5
  },
  'testrpcCoverage': {
    'ref': 'testrpc-coverage',
    'host': '127.0.0.1',
    'port': 6545,
    'wsPort': 6546,
    'networkId': '*',
    'gas': '0xfffffffffff',
    'gasPrice': '0x01',
    'chainId': 5,
    'network_id': 5
  }
};

module.exports = {
  networks: {
    ganacheUnitTest: config.ganacheUnitTest,
    gethUnitTest: config.gethUnitTest,
    testrpcCoverage: config.testrpcCoverage,
    ropsten: {
      provider: () => new HDWalletProvider(process.env.MNEMONIC, `https://ropsten.infura.io/v3/${process.env.INFURA}`),
      network_id: 3,
      gas: 4323783,
      gasPrice: 40000000000
    },
    live: {
      provider: () => new HDWalletProvider(process.env.MNEMONIC, `https://mainnet.infura.io/v3/${process.env.INFURA}`),
      network_id: 1,
      gas: 1000000,
      gasPrice: 150000000000
    }
  },
  compilers: {
    solc: {
      version: '0.4.24',
      settings: {
        optimizer: {
          enabled: true,
          runs: 1337
        }
      }
    }
  },
  mocha: {
    enableTimeouts: false
  }
}; 
