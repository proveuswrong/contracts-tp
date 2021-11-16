//SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "hardhat/console.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";

/* Draft - Do not review.
  TODOs
  - Implement crowdfunded appeals
  - Evidence group id needs to be designed. Currently, information seems inadequate to propoperly categorize evidence.
  ·---------------------------------------|---------------------------|--------------|-----------------------------·
  |          Solc version: 0.8.4          ·  Optimizer enabled: true  ·  Runs: 1000  ·  Block limit: 30000000 gas  │
  ········································|···························|··············|······························
  |  Methods                                                                                                       │
  ·················|······················|·············|·············|··············|···············|··············
  |  Contract      ·  Method              ·  Min        ·  Max        ·  Avg         ·  # calls      ·  usd (avg)  │
  ·················|······················|·············|·············|··············|···············|··············
  |  Arbitrator    ·  createDispute       ·      82573  ·      99673  ·       84283  ·           10  ·          -  │
  ·················|······················|·············|·············|··············|···············|··············
  |  Arbitrator    ·  giveRuling          ·          -  ·          -  ·       78616  ·            2  ·          -  │
  ·················|······················|·············|·············|··············|···············|··············
  |  ProveMeWrong  ·  appeal              ·          -  ·          -  ·       42138  ·            2  ·          -  │
  ·················|······················|·············|·············|··············|···············|··············
  |  ProveMeWrong  ·  challenge           ·          -  ·          -  ·      127908  ·            1  ·          -  │
  ·················|······················|·············|·············|··············|···············|··············
  |  ProveMeWrong  ·  increaseBounty      ·          -  ·          -  ·       28534  ·            2  ·          -  │
  ·················|······················|·············|·············|··············|···············|··············
  |  ProveMeWrong  ·  initialize          ·      32210  ·      53936  ·       46023  ·           10  ·          -  │
  ·················|······················|·············|·············|··············|···············|··············
  |  ProveMeWrong  ·  initiateWithdrawal  ·          -  ·          -  ·       28001  ·            2  ·          -  │
  ·················|······················|·············|·············|··············|···············|··············
  |  ProveMeWrong  ·  submitEvidence      ·          -  ·          -  ·       27563  ·            2  ·          -  │
  ·················|······················|·············|·············|··············|···············|··············
  |  ProveMeWrong  ·  withdraw            ·          -  ·          -  ·       34963  ·            1  ·          -  │
  ·················|······················|·············|·············|··············|···············|··············
  |  Deployments                          ·                                          ·  % of limit   ·             │
  ········································|·············|·············|··············|···············|··············
  |  Arbitrator                           ·          -  ·          -  ·      907963  ·          3 %  ·          -  │
  ········································|·············|·············|··············|···············|··············
  |  ProveMeWrong                         ·          -  ·          -  ·     1361724  ·        4.5 %  ·          -  │
  ·---------------------------------------|-------------|-------------|--------------|---------------|-------------·

*/
contract ProveMeWrong is IArbitrable, IEvidence {
  IArbitrator public immutable ARBITRATOR;
  uint256 public immutable CLAIM_WITHDRAWAL_TIMELOCK; // To prevent claimants to act fast and escape punishment.
  uint256 public constant NUMBER_OF_RULING_OPTIONS = 2;
  uint256 public constant NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE = 40; // To compress bounty amount to gain space in struct. Lossy compression.
  uint256 public immutable WINNER_STAKE_MULTIPLIER; // Multiplier of the arbitration cost that the winner has to pay as fee stake for a round in basis points.
  uint256 public immutable LOSER_STAKE_MULTIPLIER; // Multiplier of the arbitration cost that the loser has to pay as fee stake for a round in basis points.
  uint256 public constant LOSER_APPEAL_PERIOD_MULTIPLIER = 5000; // Multiplier of the appeal period for losers (any other ruling options) in basis points. The loser is given less time to fund its appeal to defend against last minute appeal funding attacks.
  uint256 public constant MULTIPLIER_DENOMINATOR = 10000; // Denominator for multipliers.

  event NewClaim(string indexed claimID, uint256 claimAddress);
  event Debunked(uint256 claimAddress);
  event Withdrew(uint256 claimAddress);
  event BalanceUpdate(uint256 claimAddress, uint256 newTotal);
  event TimelockStarted(uint256 claimAddress);
  event Challenge(uint256 indexed claimID, address challanger);

  event Contribution(uint256 indexed claimAddress, uint256 indexed roundPointer, RulingOutcomes indexed ruling, address funder, uint256 amount);
  event RulingFunded(uint256 indexed claimAddress, uint256 indexed roundPointer, RulingOutcomes indexed ruling);

  enum RulingOutcomes {
    ChallengeFailed,
    Debunked
  }

  // TODO: Implement  crowdfunded appeals
  struct DisputeData {
    uint256 id;
    address payable challenger;
    Round[] rounds; // Tracks each appeal round of a dispute.
  }

  struct Round {
    mapping(address => mapping(RulingOutcomes => uint256)) contributions;
    mapping(RulingOutcomes => bool) hasPaid; // True if the fees for this particular answer has been fully paid in the form hasPaid[rulingOutcome].
    mapping(RulingOutcomes => uint256) totalPerRuling;
    uint256 totalClaimableAfterExpenses;
  }

  // Claims are not addressed with their identifiers, to enable reusing a storage slot.
  struct Claim {
    address payable owner; // 160 bit
    uint16 freeSpace;
    uint32 withdrawalPermittedAt; // Overflows on in year 2106
    uint48 bountyAmount;
  }

  bytes public arbitratorExtraData;

  mapping(uint256 => Claim) public claimStorage; // Key: Address of claim.
  mapping(uint256 => DisputeData) disputes; // Key: Address of claim.

  mapping(uint256 => uint256) externalIDtoLocalID; // Maps ARBITRATOR dispute ID to claim ID.

  constructor(
    IArbitrator _arbitrator,
    bytes memory _arbitratorExtraData,
    string memory _metaevidenceIpfsUri,
    uint256 _claimWithdrawalTimelock,
    uint256 _winnerStakeMultiplier,
    uint256 _loserStakeMultiplier
  ) {
    ARBITRATOR = _arbitrator;
    arbitratorExtraData = _arbitratorExtraData;
    CLAIM_WITHDRAWAL_TIMELOCK = _claimWithdrawalTimelock;
    WINNER_STAKE_MULTIPLIER = _winnerStakeMultiplier;
    LOSER_STAKE_MULTIPLIER = _loserStakeMultiplier;

    emit MetaEvidence(0, _metaevidenceIpfsUri);
  }

  function initialize(string calldata _claimID, uint256 _searchPointer) external payable {
    Claim storage claim;
    do {
      claim = claimStorage[_searchPointer++];
    } while (claim.bountyAmount != 0);

    require(claim.bountyAmount == 0, "You can't initialize a live claim.");

    claim.owner = payable(msg.sender);
    claim.bountyAmount += uint48(msg.value >> NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);

    require(claim.bountyAmount > 0, "You can't initialize a claim without putting a bounty.");

    uint256 claimAddress = _searchPointer - 1;
    emit NewClaim(_claimID, claimAddress);
    emit BalanceUpdate(claimAddress, uint256(claim.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);
  }

  function increaseBounty(uint256 _claimAddress) public payable {
    Claim storage claim = claimStorage[_claimAddress];
    require(msg.sender == claim.owner, "Only claimant can increase bounty of a claim.");

    claim.bountyAmount += uint48(msg.value >> NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);

    emit BalanceUpdate(_claimAddress, uint256(claim.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);
  }

  function initiateWithdrawal(uint256 _claimAddress) public {
    Claim storage claim = claimStorage[_claimAddress];
    require(msg.sender == claim.owner, "Only claimant can withdraw a claim.");
    require(claim.withdrawalPermittedAt == 0, "Withdrawal already initiated or there is a challenge.");

    claim.withdrawalPermittedAt = uint32(block.timestamp + CLAIM_WITHDRAWAL_TIMELOCK);
    emit TimelockStarted(_claimAddress);
  }

  function withdraw(uint256 _claimAddress) external {
    Claim storage claim = claimStorage[_claimAddress];

    require(msg.sender == claim.owner, "Only claimant can withdraw a claim.");
    require(claim.withdrawalPermittedAt != 0, "You need to initiate withdrawal first.");
    require(claim.withdrawalPermittedAt <= block.timestamp, "You need to wait for timelock.");

    uint256 withdrawal = uint88(claim.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE;
    claim.bountyAmount = 0; // This is critical to reset.
    claim.withdrawalPermittedAt = 0; // This too, otherwise new claim inside the same slot can withdraw instantly.
    // We could reset claim.owner as well, this refunds 4K gas. But not resetting it here and let it to be reset
    // during initialization of a claim using a previously used storage slot provides 17K gas refund. So net gain 13K.
    payable(msg.sender).transfer(withdrawal);
    emit Withdrew(_claimAddress);
  }

  function challenge(uint256 _claimAddress) public payable {
    Claim storage claim = claimStorage[_claimAddress];
    claim.withdrawalPermittedAt = type(uint32).max;

    require(claim.bountyAmount > 0, "Nothing to challenge.");

    uint256 disputeID = ARBITRATOR.createDispute{value: msg.value}(NUMBER_OF_RULING_OPTIONS, arbitratorExtraData);
    externalIDtoLocalID[disputeID] = _claimAddress;

    disputes[_claimAddress].id = disputeID;
    disputes[_claimAddress].challenger = payable(msg.sender);
    disputes[_claimAddress].rounds.push();

    emit Dispute(ARBITRATOR, disputeID, 0, uint256(keccak256(abi.encode(_claimAddress, claim.owner)))); // TODO Evidence Group ID
    emit Challenge(_claimAddress, msg.sender);
  }

  function fundAppeal(uint256 _claimAddress, RulingOutcomes _supportedRuling) external payable returns (bool fullyFunded) {
    DisputeData storage dispute = disputes[_claimAddress];
    uint256 disputeID = dispute.id;
    uint256 currentRuling = ARBITRATOR.currentRuling(disputeID);
    uint256 originalCost;
    uint256 totalCost;
    {
      (uint256 originalStart, uint256 originalEnd) = ARBITRATOR.appealPeriod(disputeID);

      uint256 multiplier;

      if (uint256(_supportedRuling) == currentRuling) {
        require(block.timestamp < originalEnd, "Funding must be made within the appeal period.");

        multiplier = WINNER_STAKE_MULTIPLIER;
      } else {
        require(block.timestamp < (originalStart + ((originalEnd - originalStart) / 2)), "Funding must be made within the first half appeal period.");

        multiplier = LOSER_STAKE_MULTIPLIER;
      }

      originalCost = ARBITRATOR.appealCost(disputeID, arbitratorExtraData);
      totalCost = originalCost + ((originalCost * (multiplier)) / MULTIPLIER_DENOMINATOR);
    }

    uint256 lastRoundIndex = dispute.rounds.length - 1;
    Round storage lastRound = dispute.rounds[lastRoundIndex];
    require(!lastRound.hasPaid[_supportedRuling], "Appeal fee has already been paid.");

    uint256 contribution = totalCost - (lastRound.totalPerRuling[_supportedRuling]) > msg.value ? msg.value : totalCost - (lastRound.totalPerRuling[_supportedRuling]);
    emit Contribution(_claimAddress, lastRoundIndex, _supportedRuling, msg.sender, contribution);

    lastRound.contributions[msg.sender][_supportedRuling] += contribution;
    lastRound.totalPerRuling[_supportedRuling] += contribution;

    if (lastRound.totalPerRuling[_supportedRuling] >= totalCost) {
      lastRound.totalClaimableAfterExpenses += lastRound.totalPerRuling[_supportedRuling];
      lastRound.hasPaid[_supportedRuling] = true;
      emit RulingFunded(_claimAddress, lastRoundIndex, _supportedRuling);
    }

    if (lastRound.hasPaid[RulingOutcomes.ChallengeFailed] && lastRound.hasPaid[RulingOutcomes.Debunked]) {
      dispute.rounds.push();

      lastRound.totalClaimableAfterExpenses -= originalCost;
      ARBITRATOR.appeal{value: originalCost}(disputeID, arbitratorExtraData);
    }

    if (msg.value - (contribution) > 0) payable(msg.sender).send(msg.value - (contribution)); // Sending extra value back to contributor.

    return lastRound.hasPaid[_supportedRuling];
  }

  //TODO Evidence group ID
  function submitEvidence(string calldata _claimID, string calldata _evidenceURI) public {
    emit Evidence(ARBITRATOR, uint256(keccak256(bytes(_claimID))), msg.sender, _evidenceURI);
  }

  function rule(uint256 _disputeID, uint256 _ruling) external override {
    uint256 claimAddress = externalIDtoLocalID[_disputeID];
    Claim storage claim = claimStorage[claimAddress];

    require(IArbitrator(msg.sender) == ARBITRATOR);
    emit Ruling(IArbitrator(msg.sender), _disputeID, _ruling);

    if (RulingOutcomes(_ruling) == RulingOutcomes.Debunked) {
      uint256 bounty = uint88(claim.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE;
      claim.bountyAmount = 0;

      emit Debunked(claimAddress);
      disputes[_disputeID].challenger.send(bounty);
    } // In case of tie, claim stands.
    claim.withdrawalPermittedAt = 0;
  }

  function transferOwnership(uint256 _claimAddress, address payable _newOwner) external {
    Claim storage claim = claimStorage[_claimAddress];
    require(msg.sender == claim.owner, "Only claimant can transfer ownership.");
    claim.owner = _newOwner;
  }

  function challengeFee(string calldata _claimID) external view returns (uint256 arbitrationFee) {
    arbitrationFee = ARBITRATOR.arbitrationCost(arbitratorExtraData);
  }

  function appealFee(string calldata _claimID, uint256 _disputeID) external view returns (uint256 arbitrationFee) {
    arbitrationFee = ARBITRATOR.appealCost(_disputeID, arbitratorExtraData);
  }

  function findVacantStorageSlot(uint256 _searchPointer) external view returns (uint256 vacantSlotIndex) {
    Claim storage claim;
    do {
      claim = claimStorage[_searchPointer++];
    } while (claim.bountyAmount != 0);

    return _searchPointer - 1;
  }
}
