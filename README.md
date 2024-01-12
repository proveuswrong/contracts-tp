# Smart Contracts of Truth Post

Decentralized curation of truth, utilizing Kleros for decentralized fact-checking.

Or in other words: Create a news post, put a bounty, invite others to prove you wrong. 

Potential usecases: 
- Curated news: you can write news article that are provably not fake
- Bug bounties: you can claim your product is bug-free.
- Advertisement: you can advertise your product with near zero cost (you only pay if you are proven wrong). 


## Deployment

`ETHERSCAN=<etherscan_api_key> INFURA_PROJECT_ID=<infura_project_id> PRIVATE_KEY=<private_key> yarn hardhat deploy --network <network>`

Also see the [Hardhat Config](https://github.com/proveuswrong/contracts-pmw/blob/master/hardhat.config.js) and the [deployment script](https://github.com/proveuswrong/contracts-pmw/blob/master/deploy/1_deploy_pmw.js).

Note: [PMW project was abandoned](https://proveuswrong.io/faq/#prove-us-wrong-prove-me-wrong-im-confused) and actually this contract is used by the Truth Post.
