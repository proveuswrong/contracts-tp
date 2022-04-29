# Smart Contracts of Prove Me Wrong

Decentralized curation of truth, utilizing Kleros for decentralized fact-checking.

Or in other words: Create a claim, put a bounty, invite others to prove you wrong. 

Potential usecases: 
- Curated news: you can write news article that are provably not fake
- Bug bounties: you can claim your product is bug-free.
- Advertisement: you can advertise your product with near zero cost (you only pay if you are proven wrong). 


## Deployment

`ETHERSCAN=<etherscan_api_key> INFURA_PROJECT_ID=<infura_project_id> PRIVATE_KEY=<private_key> yarn hardhat deploy --network <network>`

Also see the [Hardhat Config](https://github.com/proveuswrong/contracts-pmw/blob/master/hardhat.config.js) and the [deployment script](https://github.com/proveuswrong/contracts-pmw/blob/master/deploy/1_deploy_pmw.js).
