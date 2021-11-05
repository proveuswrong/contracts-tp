//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";
import "@kleros/erc-792/contracts/IArbitrable.sol";
import "@kleros/erc-792/contracts/IArbitrator.sol";
import "@kleros/erc-792/contracts/erc-1497/IEvidence.sol";

contract ProveMeWrong is IArbitrable, IEvidence {
  uint8 constant NUMBER_OF_RULING_OPTIONS = 2;
  uint24 public immutable CLAIM_WITHDRAWAL_TIMELOCK; // To prevent claimants to act fast and escape punishment.

  event BalanceUpdate(string indexed claimID, address indexed actor, BalanceUpdateType indexed bat, uint256 balanceDelta);
  event NewSetting(uint24 index, IArbitrator indexed arbitrator, bytes arbitratorExtraData);
  event NewClaim(string indexed claimID, uint32 settingPointer);
  event Challange(string indexed claimID, address challanger);
  event TimelockStarted(string indexed claimID, address indexed funder, uint256 funds);

  enum RulingOutcomes {
    ChallengeFailed,
    ProvedWrong
  }

  enum BalanceUpdateType {
    Fund,
    Unfund,
    Sweep
  }

  struct ArbitratorSetting {
    IArbitrator arbitrator;
    bytes arbitratorExtraData;
  }

  struct DisputeData {
    uint256 id;
    address payable challanger;
    uint16 metaevidenceID;
  }

  struct Contribution {
    uint256 amount;
    uint256 withdrawalPermittedAt;
  }

  struct Claim {
    uint256 bountyAmount;
    uint8 settingPointer;
    DisputeData lastDispute;
    mapping(address => Contribution) contributions;
  }

  uint16 metaevidenceCounter = 0;
  mapping(string => Claim) claims;
  ArbitratorSetting[] settings;
  mapping(uint256 => string) externalIDtoLocalID;

  constructor(ArbitratorSetting memory setting) {
    CLAIM_WITHDRAWAL_TIMELOCK = 2 weeks;

    settings.push(setting);

    emit NewSetting(uint24(settings.length - 1), setting.arbitrator, setting.arbitratorExtraData);
    emit MetaEvidence(metaevidenceCounter++, "0x00");
  }

  function fund(string calldata claimID) public payable {
    Claim storage claim = claims[claimID];

    claim.contributions[msg.sender].amount += msg.value;
    claim.bountyAmount += msg.value;

    // console.log("%s contributed %s weis", msg.sender, msg.value);

    emit BalanceUpdate(claimID, msg.sender, BalanceUpdateType.Fund, msg.value);
  }

  function unfund(string calldata claimID) public {
    Claim storage claim = claims[claimID];
    if (claim.contributions[msg.sender].withdrawalPermittedAt == 0) {
      claim.contributions[msg.sender].withdrawalPermittedAt = block.timestamp + CLAIM_WITHDRAWAL_TIMELOCK;
      emit TimelockStarted(claimID, msg.sender, claim.contributions[msg.sender].amount);
    } else {
      require(claim.bountyAmount > 0, "Can't withdraw funds from a claim that has no funds.");
      require(
        claim.contributions[msg.sender].withdrawalPermittedAt != 0 && claim.contributions[msg.sender].withdrawalPermittedAt <= block.timestamp,
        "You need to wait for timelock."
      );
      require(claim.bountyAmount > 0, "Claim is not live.");

      uint256 withdrawal = uint256(claim.contributions[msg.sender].amount);
      payable(msg.sender).transfer(withdrawal);

      // console.log("Trying to send %s weis to %s", withdrawal, msg.sender);
      emit BalanceUpdate(claimID, msg.sender, BalanceUpdateType.Unfund, withdrawal);
    }
  }

  function challenge(string calldata claimID) public payable {
    Claim storage claim = claims[claimID];
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    uint256 disputeID = setting.arbitrator.createDispute{value: msg.value}(NUMBER_OF_RULING_OPTIONS, setting.arbitratorExtraData);
    externalIDtoLocalID[disputeID] = claimID;

    claim.lastDispute = DisputeData({id: disputeID, challanger: payable(msg.sender), metaevidenceID: metaevidenceCounter - 1});

    emit Dispute(IArbitrator(setting.arbitrator), disputeID, metaevidenceCounter - 1, disputeID);

    emit Challange(claimID, msg.sender);
  }

  function submitEvidence(string calldata _claimID, string calldata _evidenceURI) public {
    Claim storage claim = claims[_claimID];
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    emit Evidence(setting.arbitrator, claim.lastDispute.id, msg.sender, _evidenceURI);
  }

  function createNewArbitratorSettings(IArbitrator _arbitrator, bytes calldata _arbitratorExtraData) public payable {
    settings.push(ArbitratorSetting({arbitrator: _arbitrator, arbitratorExtraData: _arbitratorExtraData}));

    emit NewSetting(uint24(settings.length - 1), _arbitrator, _arbitratorExtraData);
  }

  function initialize(string calldata _claimID, uint8 _settingPointer) public payable {
    Claim storage claim = claims[_claimID];

    require(claim.bountyAmount < 1000, "You can't change arbitrator settings of a live claim.");
    claims[_claimID].settingPointer = _settingPointer;

    if (msg.value > 0) fund(_claimID);

    emit NewClaim(_claimID, _settingPointer);
  }

  function rule(uint256 _disputeID, uint256 _ruling) external override {
    string memory claimID = externalIDtoLocalID[_disputeID];
    Claim storage claim = claims[claimID];
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    require(IArbitrator(msg.sender) == setting.arbitrator);
    emit Ruling(IArbitrator(msg.sender), _disputeID, _ruling);

    if (RulingOutcomes(_ruling) == RulingOutcomes.ProvedWrong) {
      uint256 bounty = claim.bountyAmount;
      claim.bountyAmount = 0;
      emit BalanceUpdate(claimID, claim.lastDispute.challanger, BalanceUpdateType.Sweep, claim.bountyAmount);
      claim.lastDispute.challanger.send(bounty);
    }
  }

  function challengeFee(string calldata _claimID) public view returns (uint256 arbitrationFee) {
    Claim storage claim = claims[_claimID];
    ArbitratorSetting storage setting = settings[claim.settingPointer];

    arbitrationFee = setting.arbitrator.arbitrationCost(setting.arbitratorExtraData);
  }
}
