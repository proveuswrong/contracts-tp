const { BN, Address, toChecksumAddress } = require("ethereumjs-util");
const fetch = require("node-fetch");

module.exports = async ({ getNamedAccounts, deployments, getChainId, getUnnamedAccounts, ethers, config, args }) => {
  // INFURA_PROJECT_ID, PRIVATE_KEY and ETHERSCAN environment variables are required for this task. See Hardhat configuation for more information.
  const sleepDuration = 10000;

  const SUBCOURT = 0;
  const NUMBER_OF_VOTES = 1;

  const chainId = await getChainId();

  const KLEROS = {
    1: "0x988b3A538b618C7A603e1c11Ab82Cd16dbE28069",
    4: "0x6e376E049BD375b53d31AFDc21415AeD360C1E70",
    42: "0x60B2AbfDfaD9c0873242f59f2A8c32A3Cc682f80",
  };

  const REALITIOv30 = {
    1: "0x5b7dD1E86623548AF054A4985F7fc8Ccbb554E2c",
    4: "0xDf33060F476F8cff7511F806C72719394da1Ad64",
    42: "0xcB71745d032E16ec838430731282ff6c10D29Dea",
  };

  const primaryDocumentIPFSPath = "QmaUr6hnSVxYD899xdcn2GUVtXVjXoSXKZbce3zFtGWw4H/Question_Resolution_Policy.pdf";

  const metaevidence = {
    category: "Curation",
    title: "A Claim Was Challenged",
    description: "A claim was challenged and a dispute between claimant and challenger has been raised.",
    question: "Is the claim correct?",
    rulingOptions: {
      type: "single-select",
      titles: ["Yes", "No"],
    },
    evidenceDisplayInterfaceURI: "/ipfs/QmWCmzMB4zbzii8HV9HFGa8Evgt5i63GyveJtw2umxRrcX/reality-evidence-display-4/index.html",
    dynamicScriptURI: "/ipfs/QmWWsDmvjhR9UVRgkcG75vAKzfK3vB85EkZzudnaxwfAWr/bundle.js",
    fileURI: `/ipfs/${primaryDocumentIPFSPath}`,
    arbitrableChainID: chainId,
    arbitratorChainID: chainId,
    dynamicScriptRequiredParams: ["arbitrableChainID", "arbitrableJsonRpcUrl", "arbitrableContractAddress"],
    evidenceDisplayInterfaceRequiredParams: ["arbitrableChainID", "arbitrableJsonRpcUrl", "arbitrableContractAddress"],
  };
  const ipfsHashMetaEvidenceObj = await ipfsPublish("metaEvidence.json", new TextEncoder().encode(JSON.stringify(metaevidence)));
  const metaevidenceURI = `/ipfs/${ipfsHashMetaEvidenceObj[1].hash}${ipfsHashMetaEvidenceObj[0].path}`;
  console.log(`Metaevidence deployed at: https://ipfs.kleros.io${metaevidenceURI}`);
  console.log(`Subcourt: ${SUBCOURT} and number of votes: ${NUMBER_OF_VOTES}`);

  if (chainId == 1) {
    console.log(`Going to try proceed with deployment in ${(3 * sleepDuration) / 1000} seconds. Please verify arguments.`);
    await new Promise((resolve) => setTimeout(resolve, 3 * sleepDuration));
  }

  const { deploy } = deployments;
  const { providers } = ethers;
  const networks = {
    42: config.networks.kovan,
    1: config.networks.main,
  };
  const web3provider = new providers.JsonRpcProvider(networks[chainId]);
  const accounts = await getUnnamedAccounts();
  const deployer = accounts[0];
  const contractName = "ProveMeWrong";

  const ra21 = deploy(contractName, {
    from: deployer,
    gasLimit: 4000000,
    args: [KLEROS[chainId], generateArbitratorExtraData(SUBCOURT, NUMBER_OF_VOTES), metaevidenceURI, 1, 1, 1],
  });
  console.log("Tx sent. Waiting for confirmation.");

  const deployment = await ra21;

  console.log(`Going to try verifying the source code on Etherscan in ${sleepDuration / 1000} seconds.`);

  await new Promise((resolve) => setTimeout(resolve, sleepDuration));
  console.log("Trying to verify now.");
  await hre.run("verify:verify", {
    address: deployment.address,
    constructorArguments: deployment.args,
  });
};

function generateArbitratorExtraData(subcourtID, noOfVotes) {
  return `0x${parseInt(subcourtID, 10).toString(16).padStart(64, "0") + parseInt(noOfVotes, 10).toString(16).padStart(64, "0")}`;
}

async function ipfsPublish(fileName, data) {
  const buffer = await Buffer.from(data);

  return new Promise((resolve, reject) => {
    fetch("https://ipfs.kleros.io/add", {
      method: "POST",
      body: JSON.stringify({
        fileName,
        buffer,
      }),
      headers: {
        "content-type": "application/json",
      },
    })
      .then((response) => response.json())
      .then((success) => resolve(success.data))
      .catch((err) => reject(err));
  });
}
