const { BN, Address, toChecksumAddress } = require("ethereumjs-util")
const fetch = require("node-fetch")

module.exports = async ({ getNamedAccounts, deployments, getChainId, getUnnamedAccounts, ethers, config, args }) => {
    // INFURA_PROJECT_ID, PRIVATE_KEY and ETHERSCAN environment variables are required for this task. See Hardhat configuation for more information.
    const sleepDuration = 30000

    const SUBCOURT = 0
    const NUMBER_OF_VOTES = 1

    const chainId = await getChainId()

    const KLEROS = {
        1: "0x988b3A538b618C7A603e1c11Ab82Cd16dbE28069",
        4: "0x6e376E049BD375b53d31AFDc21415AeD360C1E70",
        42: "0x60B2AbfDfaD9c0873242f59f2A8c32A3Cc682f80",
        5: "0x1128eD55ab2d796fa92D2F8E1f336d745354a77A",
    }
    const TREASURY = "0x387e8B40e332831b7a8ad629966df3E9f969C6ad"

    const primaryDocumentIPFSPath = "/ipfs/QmZQevKY9w7GYzyoHhmHYsEcF9N9jkU52gefqdLShiEaSh/NewsCurationPolicy.html"

    const metaevidence = {
        category: "News",
        title: "An Article of Truth Post Was Challenged",
        description:
            "A news article of The Truth Post was challenged and a dispute between reporter and challenger has been raised.",
        question: "Is this article accurate according to the policy of this curation pool?",
        rulingOptions: {
            type: "single-select",
            titles: ["Yes", "No"],
        },
        // evidenceDisplayInterfaceURI: "/ipfs/QmSaac2Xh2LCxKWoekmbWG2z2vM4DGjZmbcRhXqUkQpd3h/index.html",
        dynamicScriptURI: "/ipfs/QmaMdkAG4CL6ZWWAbJGeHdMGBbHQJM1hmA7gthq9aqYSRC/index.js\n",
        fileURI: `${primaryDocumentIPFSPath}`,
        arbitrableChainID: chainId,
        arbitratorChainID: chainId,
        evidenceDisplayInterfaceRequiredParams: ["disputeID", "arbitrableChainID"],
        dynamicScriptRequiredParams: ["disputeID", "arbitrableChainID", "arbitrableContractAddress"],

        _v: "1.0.0",
    }
    const ipfsHashMetaEvidenceObj = await ipfsPublish(
        "metaEvidence.json",
        new TextEncoder().encode(JSON.stringify(metaevidence))
    )
    const metaevidenceURI = `/ipfs/${ipfsHashMetaEvidenceObj[1].hash}${ipfsHashMetaEvidenceObj[0].path}`
    console.log(`Metaevidence deployed at: https://ipfs.kleros.io${metaevidenceURI}`)
    console.log(`Subcourt: ${SUBCOURT} and number of votes: ${NUMBER_OF_VOTES}`)

    if (chainId == 1) {
        console.log(
            `Going to try proceed with deployment in ${(3 * sleepDuration) / 1000} seconds. Please verify arguments.`
        )
        await new Promise((resolve) => setTimeout(resolve, 3 * sleepDuration))
    }

    const { deploy } = deployments
    const { providers } = ethers
    const networks = {
        42: config.networks.kovan,
        1: config.networks.main,
        5: config.networks.goerli,
    }
    const web3provider = new providers.JsonRpcProvider(networks[chainId])
    const accounts = await getUnnamedAccounts()
    const deployer = accounts[0]
    const contractName = "TruthPost"

    const contractInstance = deploy(contractName, {
        from: deployer,
        gasLimit: 4000000,
        args: [
            KLEROS[chainId],
            generateArbitratorExtraData(SUBCOURT, NUMBER_OF_VOTES),
            metaevidenceURI,
            60 * 60 * 24 * 7,
            256,
            384,
            TREASURY,
        ],
    })
    console.log("Tx sent. Waiting for confirmation.")

    const deployment = await contractInstance

    console.log(`Going to try verifying the source code on Etherscan in ${sleepDuration / 1000} seconds.`)

    await new Promise((resolve) => setTimeout(resolve, sleepDuration))
    console.log("Trying to verify now.")
    await hre.run("verify:verify", {
        address: deployment.address,
        constructorArguments: deployment.args,
    })
}

function generateArbitratorExtraData(subcourtID, noOfVotes) {
    return `0x${
        parseInt(subcourtID, 10).toString(16).padStart(64, "0") + parseInt(noOfVotes, 10).toString(16).padStart(64, "0")
    }`
}

async function ipfsPublish(fileName, data) {
    const buffer = await Buffer.from(data)

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
            .catch((err) => reject(err))
    })
}
