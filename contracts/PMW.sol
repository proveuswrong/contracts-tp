//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";

contract ProveMeWrong is IArbitrable, IEvidence {
  uint8 constant NUMBER_OF_RULING_OPTIONS = 2;
  uint24 constant NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE = 32; // To compress bounty amount to uint48, saving 32 bits. Right shift to compress and left shift to decompress. This compression will make beneficiary to lose some amount between 0 to 4 gwei.
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

  struct ArbitratorSetting {
    IArbitrator arbitrator;
    bytes arbitratorExtraData;
  }

  struct DisputeData {
    uint256 id;
    address payable challenger;
  }

  // 256 bits
  struct Claim {
    address payable owner; // 160 bit
    uint16 settingPointer;
    uint32 withdrawalPermittedAt;
    uint48 bountyAmount;
  }

  mapping(string => Claim) claims;
  mapping(uint256 => DisputeData) disputes;
  ArbitratorSetting[] settings;
  mapping(uint256 => string) externalIDtoLocalID; // Maps arbitrator dispute ID to claim ID.

  function initialize(string calldata _claimID, uint8 _settingPointer) public payable {
    Claim storage claim = claims[_claimID];
    require(claim.bountyAmount == 0, "You can't change arbitrator settings of a live claim.");

    claim.settingPointer = _settingPointer;
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

  function withdraw(string calldata _claimID) public {
    Claim storage claim = claims[_claimID];
    require(msg.sender == claim.owner, "Only claimant can withdraw a claim.");

    if (claim.withdrawalPermittedAt == 0) {
      // Start withdrawal process.
      claim.withdrawalPermittedAt = uint32(block.timestamp + CLAIM_WITHDRAWAL_TIMELOCK);
      emit TimelockStarted(_claimID);
    } else {
      // Withdraw.
      require(claim.withdrawalPermittedAt <= block.timestamp, "You need to wait for timelock.");

      uint256 withdrawal = uint80(claim.bountyAmount) << NUMBER_OF_LEAST_SIGNIFICANT_BITS_TO_IGNORE;
      claim.bountyAmount = 0;
      claim.withdrawalPermittedAt = 0;
      payable(msg.sender).transfer(withdrawal);

      emit Withdrew(_claimID);
    }
  }

  function challenge(string calldata _claimID) public payable {
    Claim storage claim = claims[_claimID];
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    uint256 disputeID = setting.arbitrator.createDispute{value: msg.value}(NUMBER_OF_RULING_OPTIONS, setting.arbitratorExtraData);
    externalIDtoLocalID[disputeID] = _claimID;

    disputes[disputeID] = DisputeData({id: disputeID, challenger: payable(msg.sender)});

    emit Dispute(IArbitrator(setting.arbitrator), disputeID, claim.settingPointer, uint256(keccak256(bytes(_claimID))));
    emit Challenge(_claimID, msg.sender);
  }

  function appeal(string calldata _claimID, uint256 _disputeID) public payable {
    Claim storage claim = claims[_claimID];
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    setting.arbitrator.appeal{value: msg.value}(_disputeID, setting.arbitratorExtraData);
  }

  function submitEvidence(string calldata _claimID, string calldata _evidenceURI) public {
    Claim storage claim = claims[_claimID];
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    emit Evidence(setting.arbitrator, uint256(keccak256(bytes(_claimID))), msg.sender, _evidenceURI);
  }

  function createNewArbitratorSettings(
    IArbitrator _arbitrator,
    bytes calldata _arbitratorExtraData,
    string memory _metaevidenceURI
  ) public payable {
    settings.push(ArbitratorSetting({arbitrator: _arbitrator, arbitratorExtraData: _arbitratorExtraData}));

    emit NewSetting(settings.length - 1, _arbitrator, _arbitratorExtraData);
    emit MetaEvidence(settings.length - 1, _metaevidenceURI);
  }

  function rule(uint256 _disputeID, uint256 _ruling) external override {
    string memory claimID = externalIDtoLocalID[_disputeID];
    Claim storage claim = claims[claimID];
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    require(IArbitrator(msg.sender) == setting.arbitrator);
    emit Ruling(IArbitrator(msg.sender), _disputeID, _ruling);

    if (RulingOutcomes(_ruling) == RulingOutcomes.Debunked) {
      uint256 bounty = claim.bountyAmount;
      claim.bountyAmount = 0;
      emit Debunked(claimID);
      disputes[_disputeID].challenger.send(bounty);
    }
  }

  function challengeFee(string calldata _claimID) public view returns (uint256 arbitrationFee) {
    Claim storage claim = claims[_claimID];
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    arbitrationFee = setting.arbitrator.arbitrationCost(setting.arbitratorExtraData);
  }

  function appealFee(string calldata _claimID, uint256 _disputeID) public view returns (uint256 arbitrationFee) {
    Claim storage claim = claims[_claimID];
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    arbitrationFee = setting.arbitrator.appealCost(_disputeID, setting.arbitratorExtraData);
  }
}
