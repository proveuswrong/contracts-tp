module.exports = async ({getNamedAccounts, deployments, getChainId, getUnnamedAccounts, ethers, config, args}) => {

  // INFURA_PROJECT_ID and PRIVATE_KEY environment variables are required for this task. See Hardhat configuation for more information.
  const chainId = await getChainId();
  console.log("here");
  if (chainId == 1) {
    return;
  }

  const {providers} = ethers;
  const networks = {
    42: config.networks.kovan,
    1: config.networks.main,
    5: config.networks.goerli
  };
  const contractName = "TruthPost";
  const lastDeployedInstanceAddress = (await deployments.get(contractName)).address;
  const lastDeployedInstance = (await ethers.getContractAt(contractName, lastDeployedInstanceAddress));

  const items = [
    {
      claimID: "/ipfs/QmPEA42GgauQS4RS5HXPWHBQvd9ohB2FiFgiyfR6wkPivu",
      categoryID: 0,
    },
    {
      claimID: "/ipfs/QmNoFXoNGM2eGGanNr76PkYTaSeAqLZJGmGrYshUC8iUeM",
      categoryID: 0,
    },
    {
      claimID: "/ipfs/QmQh7dghb9QExNvhLbrvDDh3NwA6Ux43nQwvasUCFawcxp",
      categoryID: 0,
    },
    {
      claimID: "/ipfs/QmcUZJMFGBDEFUJcNhMWXKVsgL4nAamvkx5AFepKjpQ3vw",
      categoryID: 0,
    },
    {
      claimID: "/ipfs/QmaRM968N6QiHxrXoLS5ZqTTv78pmceEsKyZahdDX6SRYe",
      categoryID: 0
    },
    { claimID: "/ipfs/QmUP6812UxCKR9hbBe78fJziGaHizarcVtFvTHhonXQNfn", categoryID: 0 },
    { claimID: "/ipfs/QmcYcYuUsuRPiMZSRpbTLtSkqLAwSz9wWk8t271RD3r5jg", categoryID: 0 },
  ];

  for (const item of items) {
    await lastDeployedInstance.initializeArticle(item.claimID, item.categoryID, 0, {
      value: ethers.BigNumber.from("2").pow(ethers.BigNumber.from("50")),
      gasLimit: 100000
    })
  }

};
module.exports.tags = ["populate"];
