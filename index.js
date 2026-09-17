export const protocol = {
  name: "quevra",
  version: "0.0.0",
};

export const contracts = {
  ValidatorRegistry: {
    name: "ValidatorRegistry",
    solPath: "src/ValidatorRegistry.sol",
  },
  VeMON: {
    name: "VeMON",
    solPath: "src/ve/VeMON.sol",
  },
  MonVault: {
    name: "MonVault",
    solPath: "src/vault/MonVault.sol",
  },
  ValidatorsVoter: {
    name: "ValidatorsVoter",
    solPath: "src/voter/ValidatorsVoter.sol",
  },
  ProposalGauge: {
    name: "ProposalGauge",
    solPath: "src/voter/ProposalGauge.sol",
  },
};
