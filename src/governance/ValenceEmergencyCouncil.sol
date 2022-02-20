// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/// @title ValenceEmergencyCouncil
/// @notice Multisig emergency council for rapid protocol response, pausing, and crisis mitigation.
contract ValenceEmergencyCouncil {
    uint256 public immutable threshold;
    address[] public councilMembers;
    mapping(address => bool) public isCouncilMember;

    struct ActionProposal {
        bytes32 actionId;
        address target;
        bytes callData;
        uint32 approvalsCount;
        bool isExecuted;
    }

    mapping(bytes32 => ActionProposal) public proposals;
    mapping(bytes32 => mapping(address => bool)) public hasApproved;

    event ActionProposed(bytes32 indexed actionId, address indexed target, bytes callData);
    event ActionApproved(bytes32 indexed actionId, address indexed approver);
    event ActionExecuted(bytes32 indexed actionId);

    error ValenceEmergencyCouncil__Unauthorized();
    error ValenceEmergencyCouncil__AlreadyApproved();
    error ValenceEmergencyCouncil__ThresholdNotMet();
    error ValenceEmergencyCouncil__AlreadyExecuted();
    error ValenceEmergencyCouncil__ExecutionFailed();

    modifier onlyCouncil() {
        if (!isCouncilMember[msg.sender]) revert ValenceEmergencyCouncil__Unauthorized();
        _;
    }

    constructor(address[] memory _members, uint256 _threshold) {
        require(_members.length >= _threshold && _threshold > 0, "Invalid threshold");
        threshold = _threshold;

        for (uint256 i = 0; i < _members.length;) {
            address member = _members[i];
            require(member != address(0), "Zero address");
            require(!isCouncilMember[member], "Duplicate member");

            isCouncilMember[member] = true;
            councilMembers.push(member);
            unchecked {
                i++;
            }
        }
    }

    function proposeAction(address target, bytes calldata data) external onlyCouncil returns (bytes32 actionId) {
        actionId = keccak256(abi.encodePacked(target, data, block.timestamp));
        require(proposals[actionId].target == address(0), "Already proposed");

        proposals[actionId] = ActionProposal({
            actionId: actionId,
            target: target,
            callData: data,
            approvalsCount: 1,
            isExecuted: false
        });

        hasApproved[actionId][msg.sender] = true;

        emit ActionProposed(actionId, target, data);
        emit ActionApproved(actionId, msg.sender);
    }

    function approveAction(bytes32 actionId) external onlyCouncil {
        ActionProposal storage prop = proposals[actionId];
        require(prop.target != address(0), "Proposal not found");
        if (prop.isExecuted) revert ValenceEmergencyCouncil__AlreadyExecuted();
        if (hasApproved[actionId][msg.sender]) revert ValenceEmergencyCouncil__AlreadyApproved();

        hasApproved[actionId][msg.sender] = true;
        prop.approvalsCount++;

        emit ActionApproved(actionId, msg.sender);
    }

    function executeAction(bytes32 actionId) external onlyCouncil returns (bytes memory) {
        ActionProposal storage prop = proposals[actionId];
        require(prop.target != address(0), "Proposal not found");
        if (prop.isExecuted) revert ValenceEmergencyCouncil__AlreadyExecuted();
        if (prop.approvalsCount < threshold) revert ValenceEmergencyCouncil__ThresholdNotMet();

        prop.isExecuted = true;
        (bool success, bytes memory returnData) = prop.target.call(prop.callData);
        if (!success) revert ValenceEmergencyCouncil__ExecutionFailed();

        emit ActionExecuted(actionId);
        return returnData;
    }
}
