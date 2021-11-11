//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";

contract ProveMeWrong is IArbitrable, IEvidence {
  uint8 constant NUMBER_OF_RULING_OPTIONS = 2;
  uint24 constant NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE = 40; // To compress bounty amount to uint48, saving 32 bits. Right shift to compress and left shift to decompress. This compression will make beneficiary to lose some amount between 0 to 4 gwei.
  uint24 public constant CLAIM_WITHDRAWAL_TIMELOCK = 2 weeks; // To prevent claimants to act fast and escape punishment.

  event BalanceUpdate(string indexed claimID, uint256 newTotal);
  event Debunked(string indexed claimID);
  event Withdrew(string indexed claimID);
  event NewSetting(uint256 index, IArbitrator indexed arbitrator, bytes arbitratorExtraData);
  event NewClaim(string indexed claimID);
  event Challenge(string indexed claimID, address challanger);
  event TimelockStarted(string indexed claimID);

  enum RulingOutcomes {
    ChallengeFailed,
    Debunked
  }

  // TODO: Implement  crowdfunded appeals
  struct DisputeData {
    uint256 id;
    address payable challenger;
  }

  // 256 bits - TODO: Try to reuse same storage slot for another claim, after the original claim frees the space.
  struct Claim {
    address payable owner; // 160 bit
    uint16 freeSpace;
    uint32 withdrawalPermittedAt;
    uint48 bountyAmount;
  }

  IArbitrator public immutable arbitrator;
  bytes public arbitratorExtraData;

  mapping(string => Claim) claims;
  mapping(uint256 => DisputeData) disputes;
  mapping(uint256 => string) externalIDtoLocalID; // Maps arbitrator dispute ID to claim ID.

  constructor(IArbitrator _arbitrator, bytes memory _arbitratorExtraData) {
    arbitrator = _arbitrator;
    arbitratorExtraData = _arbitratorExtraData;
  }

  function initialize(string calldata _claimID) public payable {
    Claim storage claim = claims[_claimID];
    require(claim.bountyAmount == 0, "You can't initialize a live claim.");
    require(msg.value > 0, "You can't initialize a claim without putting a bounty.");

    claim.owner = payable(msg.sender);
    claim.bountyAmount += uint48(msg.value >> NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);

    emit BalanceUpdate(_claimID, uint256(claim.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);
    emit NewClaim(_claimID);
  }

  function increaseBounty(string calldata _claimID) public payable {
    Claim storage claim = claims[_claimID];
    require(msg.sender == claim.owner, "Only claimant can increase bounty of a claim.");

    claim.bountyAmount += uint48(msg.value >> NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);

    emit BalanceUpdate(_claimID, uint256(claim.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE);
  }

  function initiateWithdrawal(string calldata _claimID) public {
    Claim storage claim = claims[_claimID];
    require(msg.sender == claim.owner, "Only claimant can withdraw a claim.");
    require(claim.withdrawalPermittedAt == 0, "Withdrawal already initiated.");

    claim.withdrawalPermittedAt = uint32(block.timestamp + CLAIM_WITHDRAWAL_TIMELOCK);
    emit TimelockStarted(_claimID);
  }

  function withdraw(string calldata _claimID) public {
    Claim storage claim = claims[_claimID];
    require(msg.sender == claim.owner, "Only claimant can withdraw a claim.");
    require(claim.withdrawalPermittedAt != 0, "You need to initiate withdrawal first.");
    require(claim.withdrawalPermittedAt <= block.timestamp, "You need to wait for timelock.");

    uint256 withdrawal = uint88(claim.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE;
    claim.bountyAmount = 0;
    claim.withdrawalPermittedAt = 0;
    payable(msg.sender).transfer(withdrawal);
    emit Withdrew(_claimID);
  }

  function challenge(string calldata _claimID) public payable {
    uint256 disputeID = arbitrator.createDispute{value: msg.value}(NUMBER_OF_RULING_OPTIONS, arbitratorExtraData);
    externalIDtoLocalID[disputeID] = _claimID;

    disputes[disputeID] = DisputeData({id: disputeID, challenger: payable(msg.sender)});

    uint256 metaevidenceID = 0;
    emit Dispute(arbitrator, disputeID, metaevidenceID, uint256(keccak256(bytes(_claimID))));
    emit Challenge(_claimID, msg.sender);
  }

  function appeal(string calldata _claimID, uint256 _disputeID) public payable {
    arbitrator.appeal{value: msg.value}(_disputeID, arbitratorExtraData);
  }

  function submitEvidence(string calldata _claimID, string calldata _evidenceURI) public {
    emit Evidence(arbitrator, uint256(keccak256(bytes(_claimID))), msg.sender, _evidenceURI);
  }

  function rule(uint256 _disputeID, uint256 _ruling) external override {
    string memory claimID = externalIDtoLocalID[_disputeID];
    Claim storage claim = claims[claimID];

    require(IArbitrator(msg.sender) == arbitrator);
    emit Ruling(IArbitrator(msg.sender), _disputeID, _ruling);

    if (RulingOutcomes(_ruling) == RulingOutcomes.Debunked) {
      uint256 bounty = uint88(claim.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE;
      claim.bountyAmount = 0;
      emit Debunked(claimID);
      disputes[_disputeID].challenger.send(bounty);
    }
  }

  function challengeFee(string calldata _claimID) public view returns (uint256 arbitrationFee) {
    arbitrationFee = arbitrator.arbitrationCost(arbitratorExtraData);
  }

  function appealFee(string calldata _claimID, uint256 _disputeID) public view returns (uint256 arbitrationFee) {
    arbitrationFee = arbitrator.appealCost(_disputeID, arbitratorExtraData);
  }
}
