//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";

contract ProveMeWrong is IArbitrable, IEvidence {
  uint24 constant SHARE_DENOMINATOR = 1_000_000;
  uint8 constant MIN_FUND_INCREASE_PERCENT = 15; // To prevent too many event emission. Ideally, we want less than 100 contributions per claim.
  uint64 constant MIN_BOUNTY = 10_000_000 gwei; // 10M gwei == 0.01 ether
  uint8 constant NUMBER_OF_RULING_OPTIONS = 2;

  event BalanceUpdate(string indexed claimID, address indexed actor, BalanceUpdateType indexed bat, uint80 balanceDelta);
  event NewSetting(IArbitrator indexed arbitrator, bytes arbitratorExtraData);
  event NewClaim(string indexed claimID, uint32 settingPointer);

  enum RulingOutcomes {
    ChallengeFailed,
    ProvedWrong
  }

  enum BalanceUpdateType {
    Fund,
    Unfund,
    Sweep
  }

  enum Status {
    Absent,
    Live,
    Challenged
    // Also Debunked and Withdrawn, but these statuses can be deduced via events and not required on chain.
    // Debunked: Absent but once was Live. Taken down with a challenge.
    // Withdrawn: Absent but once was Live. No fund left.
  }

  struct ArbitratorSetting {
    IArbitrator arbitrator;
    bytes arbitratorExtraData;
  }

  // TODO: Tightly pack
  struct Claim {
    uint256[] arbitratorDisputeIDs;
    address payable lastChallanger;
    uint120 bountyAmount;
    uint8 settingPointer;
    Status status;
    uint80 initialContribution; // This is used for logic on share calculation. Max: 1.20892582×10²⁴
    mapping(address => uint40) individualSharesOnABounty; // Instead of storing actual contributions, store shares. This uses less space. Max: 1.099511628×10¹²
  }

  mapping(string => Claim) claims; // To maintain uniqueness addressed by IPFS hash, not CID v0, or CID v1.
  ArbitratorSetting[] settings;
  mapping(uint256 => string) externalIDtoLocalID;

  constructor(ArbitratorSetting memory setting) {
    settings.push(setting);
    emit NewSetting(setting.arbitrator, setting.arbitratorExtraData);
  }

  function setArbitratorSettings(string calldata _claimID, uint8 _settingPointer) public payable {
    Claim storage claim = claims[_claimID];

    require(claim.bountyAmount < SHARE_DENOMINATOR, "You can't change arbitrator settings of a live claim.");
    claims[_claimID].settingPointer = _settingPointer;

    if (msg.value > 0) fundClaim(_claimID);

    emit NewClaim(_claimID, _settingPointer);
  }

  function fundClaim(string calldata claimID) public payable {
    require(msg.value >= MIN_BOUNTY, "Minimum funding amount is not covered.");

    Claim storage claim = claims[claimID];
    if (claim.bountyAmount == 0) {
      claim.individualSharesOnABounty[msg.sender] = SHARE_DENOMINATOR;
      claim.initialContribution = uint80(msg.value);
      claim.status = Status.Live;
    } else {
      require(msg.value >= (claim.bountyAmount * MIN_FUND_INCREASE_PERCENT) / 100, "Minimum funding amount is not covered.");
      claim.individualSharesOnABounty[msg.sender] = uint40((msg.value * SHARE_DENOMINATOR) / claim.initialContribution);
    }

    emit BalanceUpdate(claimID, msg.sender, BalanceUpdateType.Fund, uint80(msg.value));
  }

  function unfundClaim(string calldata claimID) public {
    require(claims[claimID].bountyAmount > 0, "Can't withdraw funds from a claim that has no funds.");
    Claim storage claim = claims[claimID];

    payable(msg.sender).transfer((claim.individualSharesOnABounty[msg.sender] * claim.initialContribution) / SHARE_DENOMINATOR);

    if (claim.bountyAmount < SHARE_DENOMINATOR) claim.status = Status.Absent; // Nothing left or maybe some dust.

    emit BalanceUpdate(claimID, msg.sender, BalanceUpdateType.Unfund, uint80((claim.individualSharesOnABounty[msg.sender] * claim.initialContribution) / SHARE_DENOMINATOR));
  }

  function challengeClaim(string calldata claimID) public payable {
    Claim storage claim = claims[claimID];
    require(claim.status == Status.Live, "Claim is not live.");
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    uint256 arbitrationCost = setting.arbitrator.arbitrationCost(setting.arbitratorExtraData);
    require(msg.value >= arbitrationCost, "Not enough funds for this challenge.");

    uint256 disputeID = setting.arbitrator.createDispute{value: msg.value}(NUMBER_OF_RULING_OPTIONS, setting.arbitratorExtraData);
    externalIDtoLocalID[disputeID] = claimID;

    claim.arbitratorDisputeIDs.push(disputeID);

    uint256 evidenceGroupID = uint256(keccak256(abi.encodePacked(arbitrationCost, arbitrationCost))); // TODO: Decide on evidenceGroupID. We should group evidence by per item and per request.
    uint256 metaEvidenceID = 0; // TODO
    emit Dispute(IArbitrator(setting.arbitrator), disputeID, metaEvidenceID, evidenceGroupID);

    claim.status = Status.Challenged;
  }

  function submitEvidence(string calldata _claimID, string calldata _evidenceURI) public {
    Claim storage claim = claims[_claimID];
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    emit Evidence(setting.arbitrator, uint256(keccak256(abi.encodePacked(_claimID))), msg.sender, _evidenceURI);
  }

  function rule(uint256 _disputeID, uint256 _ruling) external override {
    string memory claimID = externalIDtoLocalID[_disputeID];
    Claim storage claim = claims[claimID];
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    require(IArbitrator(msg.sender) == setting.arbitrator);
    emit Ruling(IArbitrator(msg.sender), _disputeID, _ruling);

    if (RulingOutcomes(_ruling) == RulingOutcomes.ProvedWrong) {
      claim.lastChallanger.send(claim.bountyAmount);
      claim.status = Status.Absent;
      emit BalanceUpdate(claimID, claim.lastChallanger, BalanceUpdateType.Sweep, uint80(claim.bountyAmount));
    }
  }
}
