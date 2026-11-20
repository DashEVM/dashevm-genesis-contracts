pragma solidity ^0.8.10;

import "./BridgeChainStakeHub.t.sol";
import "../contracts/bridgechain/ValidatorRewards.sol";
import "../contracts/StakeCredit.sol";

contract TestDEIT {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "balance");
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// DashEVM / CardanoEVM: validators' native fee share (live from genesis) and DEIT share
/// (deferred), paid through ValidatorRewards (0x...5061) into each validator's StakeCredit
/// pool (commission to the operator, the rest per share).
contract BridgeChainValidatorRewardsTest is BridgeChainStakeHubTest {
    address payable constant VR_ADDR = payable(0x0000000000000000000000000000000000005061);
    address constant TIMELOCK_ADDR = 0x0000000000000000000000000000000000002006;
    ValidatorRewards vr = ValidatorRewards(VR_ADDR);
    TestDEIT token;
    uint256 constant TOL = 1e6;
    address d1 = address(0xD1);
    address d2 = address(0xD2);

    function _setupRewards() internal {
        _setupNativeOnly();
        token = new TestDEIT();
        vm.prank(TIMELOCK_ADDR);
        vr.setDeit(address(token));
    }

    /// Launch state: DEIT deferred, ValidatorRewards.deit unset.
    function _setupNativeOnly() internal {
        vm.etch(VR_ADDR, vm.getDeployedCode("ValidatorRewards.sol:ValidatorRewards"));
        vm.mockCall(SLASH_ADDR, abi.encodeWithSignature("felonyThreshold()"), abi.encode(uint256(150)));
        _three();
        vm.warp(block.timestamp + 1 days);
        _electToday(consensusAddrs);
    }

    /// Today's breathe block elected `set` (BSCValidatorSet.getElectedSet), all working.
    function _electToday(address[] memory set) internal {
        vm.mockCall(VALIDATOR_CONTRACT_ADDR, abi.encodeWithSignature("getElectedSet()"), abi.encode(set, block.timestamp / 1 days));
        vm.mockCall(VALIDATOR_CONTRACT_ADDR, abi.encodeWithSignature("isCurrentValidator(address)"), abi.encode(true));
    }

    function _notWorking(address consensus) internal {
        vm.mockCall(VALIDATOR_CONTRACT_ADDR, abi.encodeWithSignature("isCurrentValidator(address)", consensus), abi.encode(false));
    }

    function _nextDay() internal {
        vm.warp(block.timestamp + 1 days);
        _electToday(consensusAddrs);
    }

    function _credit(uint256 i) internal view returns (StakeCredit) {
        return StakeCredit(payable(stakeHub.getValidatorCreditContract(operators[i])));
    }

    function _delegate(address who, uint256 i, uint256 amount) internal {
        vm.deal(who, amount);
        vm.prank(who);
        stakeHub.delegate{ value: amount }(operators[i], false);
    }

    function testSplitByStakeCommissionAndShares() public {
        _setupRewards();
        _delegate(d1, 0, 100_001 ether); // pool 0 has twice the stake of pools 1 and 2
        token.mint(VR_ADDR, 1000 ether);
        vr.distribute();
        assertEq(token.balanceOf(address(_credit(0))), 500 ether);
        assertEq(token.balanceOf(address(_credit(1))), 250 ether);
        assertEq(token.balanceOf(address(_credit(2))), 250 ether);
        StakeCredit c0 = _credit(0);
        uint256 op = c0.pendingDeit(operators[0]);
        uint256 del = c0.pendingDeit(d1);
        // 10% commission to the operator, 450 shared by shares: operator 100,000 (1 locked
        // at the dead address does not earn), d1 100,001.
        assertApproxEqAbs(op, 50 ether + (uint256(450 ether) * 100_000) / 200_001, TOL);
        assertApproxEqAbs(del, (uint256(450 ether) * 100_001) / 200_001, TOL);
        assertLe(op + del, 500 ether);
        assertApproxEqAbs(op + del, uint256(500 ether), TOL);
        assertEq(c0.pendingDeit(address(0xdEaD)), 0);
    }

    function testLateDelegatorEarnsNothingRetroactively() public {
        _setupRewards();
        _delegate(d1, 0, 100_001 ether);
        token.mint(VR_ADDR, 1000 ether);
        vr.distribute();
        _delegate(d2, 0, 100_001 ether);
        assertEq(_credit(0).pendingDeit(d2), 0);
        uint256 before = _credit(0).pendingDeit(d1);
        StakeCredit c0 = _credit(0);
        vm.prank(d1);
        c0.claimDeit(d1);
        assertEq(token.balanceOf(d1), before);
        assertEq(_credit(0).pendingDeit(d1), 0);
        // next day: d2 earns from now on
        _nextDay();
        token.mint(VR_ADDR, 1000 ether);
        vr.distribute();
        assertGt(_credit(0).pendingDeit(d2), 0);
    }

    function testUndelegateKeepsEarnedDeit() public {
        _setupRewards();
        _delegate(d1, 0, 100_001 ether);
        token.mint(VR_ADDR, 1000 ether);
        vr.distribute();
        uint256 earned = _credit(0).pendingDeit(d1);
        uint256 shares = _credit(0).balanceOf(d1);
        vm.prank(d1);
        stakeHub.undelegate(operators[0], shares);
        assertEq(_credit(0).balanceOf(d1), 0);
        assertEq(_credit(0).pendingDeit(d1), earned);
        StakeCredit c0 = _credit(0);
        vm.prank(d1);
        c0.claimDeit(d1);
        assertEq(token.balanceOf(d1), earned);
    }

    function testJailedValidatorEarnsNothing() public {
        _setupRewards();
        vm.prank(SLASH_ADDR);
        stakeHub.downtimeSlash(consensusAddrs[2]);
        token.mint(VR_ADDR, 900 ether);
        vr.distribute();
        assertEq(token.balanceOf(address(_credit(2))), 0);
        // M-2: the jailed member's third stays here; it is not handed to the others.
        assertApproxEqRel(token.balanceOf(address(_credit(0))), uint256(300 ether), 1e14); // the downtime slash shrank pool 2 slightly
        assertApproxEqRel(token.balanceOf(VR_ADDR), uint256(300 ether), 1e14); // the downtime slash shrank pool 2 slightly
    }

    function testMissedBlocksReduceWeight() public {
        _setupRewards();
        vm.mockCall(
            SLASH_ADDR, abi.encodeWithSignature("getSlashIndicator(address)", consensusAddrs[1]), abi.encode(uint256(0), uint256(75))
        );
        token.mint(VR_ADDR, 1000 ether);
        vr.distribute();
        // earned 1 : 0.5 : 1 of a full-set weight of 3; the missed half stays here
        assertApproxEqAbs(token.balanceOf(address(_credit(1))), uint256(1000 ether) / 6, TOL);
        assertApproxEqAbs(token.balanceOf(address(_credit(0))), uint256(1000 ether) / 3, TOL);
        assertApproxEqAbs(token.balanceOf(VR_ADDR), uint256(1000 ether) / 6, TOL);
    }

    function testOncePerDayAndGovernanceOnly() public {
        _setupRewards();
        token.mint(VR_ADDR, 10 ether);
        vr.distribute();
        token.mint(VR_ADDR, 10 ether);
        vm.expectRevert(ValidatorRewards.NotReady.selector);
        vr.distribute();
        vm.expectRevert(ValidatorRewards.AlreadySet.selector);
        vm.prank(TIMELOCK_ADDR);
        vr.setDeit(address(token));
        vm.expectRevert(ValidatorRewards.OnlyTimelock.selector);
        vr.setDeit(address(0xB));
        StakeCredit c0 = _credit(0);
        vm.expectRevert(StakeCredit.OnlyValidatorRewards.selector);
        c0.notifyDeitReward(1 ether, 0);
    }

    function testNothingToPayDoesNotUseUpTheDay() public {
        _setupRewards();
        vr.distribute(); // balance 0
        assertEq(vr.lastDay(), 0);
        token.mint(VR_ADDR, 10 ether);
        vr.distribute();
        assertEq(vr.lastDay(), block.timestamp / 1 days);
    }

    function _pay(uint256 amount) internal {
        address rd = address(0xFEE5);
        vm.deal(rd, amount);
        vm.prank(rd);
        // The RewardDistributors push with a 100k gas limit; receive must accept it.
        (bool ok,) = VR_ADDR.call{ value: amount, gas: 100_000 }("");
        assertTrue(ok, "receive");
    }

    function testNativeFeesPaidWhileDeitIsDeferred() public {
        _setupNativeOnly();
        assertEq(vr.deit(), address(0));
        _delegate(d1, 0, 100_001 ether); // pool 0 has twice the stake of pools 1 and 2
        uint256[3] memory pooled;
        uint256[3] memory held;
        for (uint256 i = 0; i < 3; i++) {
            pooled[i] = _credit(i).totalPooledBNB();
            held[i] = address(_credit(i)).balance;
        }
        uint256 opShares = _credit(0).balanceOf(operators[0]);
        _pay(4 ether);
        vr.distribute();
        assertEq(VR_ADDR.balance, 0);
        uint256[3] memory want = [uint256(2 ether), 1 ether, 1 ether];
        for (uint256 i = 0; i < 3; i++) {
            assertApproxEqAbs(_credit(i).totalPooledBNB() - pooled[i], want[i], TOL);
            assertEq(address(_credit(i)).balance - held[i], _credit(i).totalPooledBNB() - pooled[i]);
        }
        // The operator's commission is minted to it as new shares (same as block fees).
        assertGt(_credit(0).balanceOf(operators[0]), opShares);
        // A delegator's stake is worth more: the rest raised every share's value.
        assertGt(_credit(0).getPooledBNB(d1), 100_001 ether);
        // Once per day, also for native.
        _pay(1 ether);
        vm.expectRevert(ValidatorRewards.NotReady.selector);
        vr.distribute();
    }

    function testNativeAndDeitTogether() public {
        _setupRewards();
        _pay(3 ether);
        token.mint(VR_ADDR, 300 ether);
        uint256 pooled0 = _credit(0).totalPooledBNB();
        vr.distribute();
        assertApproxEqAbs(_credit(0).totalPooledBNB() - pooled0, uint256(1 ether), TOL);
        assertEq(token.balanceOf(address(_credit(0))), 100 ether);
        assertEq(VR_ADDR.balance, 0);
        assertEq(token.balanceOf(VR_ADDR), 0);
    }

    function testJailedValidatorGetsNoNativeShare() public {
        _setupNativeOnly();
        vm.prank(SLASH_ADDR);
        stakeHub.downtimeSlash(consensusAddrs[2]);
        uint256 pooled2 = _credit(2).totalPooledBNB();
        _pay(2 ether);
        vr.distribute();
        assertEq(_credit(2).totalPooledBNB(), pooled2);
        assertApproxEqRel(VR_ADDR.balance, uint256(2 ether) / 3, 1e14); // its share stays (pool 2 was slashed slightly)
    }

    function testNoValidatorsEarningKeepsNative() public {
        _setupNativeOnly();
        vm.mockCall(SLASH_ADDR, abi.encodeWithSignature("felonyThreshold()"), abi.encode(uint256(0)));
        _pay(1 ether);
        vr.distribute();
        assertEq(VR_ADDR.balance, 1 ether);
    }

    function testOnlyStakeHubOrValidatorRewardsPayNativeIntoAPool() public {
        _setupNativeOnly();
        StakeCredit c0 = _credit(0);
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        c0.distributeReward{ value: 1 ether }(0);
    }

    // ---------------------------------------------------------------- review M-1, M-2, L-1

    /// M-1: while permissioned with a launch cap, weight = min(pooled stake, cap).
    function testWeightCappedWhilePermissioned() public {
        _setupNativeOnly();
        _delegate(d1, 0, 100_001 ether); // pool 0 = 200,002, pools 1 and 2 = 100,001
        vm.mockCall(STAKE_HUB_ADDR, abi.encodeWithSignature("permissioned()"), abi.encode(true));
        vm.mockCall(STAKE_HUB_ADDR, abi.encodeWithSignature("launchStakeCap()"), abi.encode(uint256(100_001 ether)));
        uint256 p0 = _credit(0).totalPooledBNB();
        uint256 p1 = _credit(1).totalPooledBNB();
        _pay(3 ether);
        vr.distribute();
        assertApproxEqAbs(_credit(0).totalPooledBNB() - p0, uint256(1 ether), TOL);
        assertApproxEqAbs(_credit(1).totalPooledBNB() - p1, uint256(1 ether), TOL);
    }

    /// M-1 control: without permissioning the uncapped stake counts (2 : 1 : 1).
    function testWeightUncappedWhenOpen() public {
        _setupNativeOnly();
        _delegate(d1, 0, 100_001 ether);
        vm.mockCall(STAKE_HUB_ADDR, abi.encodeWithSignature("permissioned()"), abi.encode(false));
        vm.mockCall(STAKE_HUB_ADDR, abi.encodeWithSignature("launchStakeCap()"), abi.encode(uint256(100_001 ether)));
        uint256 p0 = _credit(0).totalPooledBNB();
        _pay(4 ether);
        vr.distribute();
        assertApproxEqAbs(_credit(0).totalPooledBNB() - p0, uint256(2 ether), TOL);
    }

    /// M-2: a jailed member's share stays here and is paid the next day, to that day's set.
    function testJailedShareStaysForTheNextDistribution() public {
        _setupNativeOnly();
        vm.prank(SLASH_ADDR);
        stakeHub.downtimeSlash(consensusAddrs[2]);
        uint256 p0 = _credit(0).totalPooledBNB();
        _pay(3 ether);
        vr.distribute();
        assertApproxEqRel(_credit(0).totalPooledBNB() - p0, uint256(1 ether), 1e14); // the downtime slash shrank pool 2 slightly
        assertApproxEqRel(VR_ADDR.balance, uint256(1 ether), 1e14); // the downtime slash shrank pool 2 slightly
        // Next day the election drops the jailed member; the kept third goes to the new set.
        vm.warp(block.timestamp + 1 days);
        address[] memory two = new address[](2);
        two[0] = consensusAddrs[0];
        two[1] = consensusAddrs[1];
        _electToday(two);
        vr.distribute();
        assertApproxEqRel(_credit(0).totalPooledBNB() - p0, uint256(1.5 ether), 1e14); // the downtime slash shrank pool 2 slightly
        assertApproxEqAbs(VR_ADDR.balance, 0, TOL);
    }

    /// M-2: the timing of the call cannot move value between members or shift the day.
    function testTimingCannotBeFrontRun() public {
        _setupNativeOnly();
        // (a) before today's breathe block (election recorded for yesterday): refused.
        vm.mockCall(
            VALIDATOR_CONTRACT_ADDR,
            abi.encodeWithSignature("getElectedSet()"),
            abi.encode(consensusAddrs, block.timestamp / 1 days - 1)
        );
        _pay(3 ether);
        vm.expectRevert(ValidatorRewards.NotReady.selector);
        vr.distribute();
        _electToday(consensusAddrs);
        // (b) calling while member 1 is in maintenance does not raise member 0's payout:
        // member 1's third stays here instead of being shared out.
        _notWorking(consensusAddrs[1]);
        uint256 p0 = _credit(0).totalPooledBNB();
        vr.distribute();
        assertApproxEqAbs(_credit(0).totalPooledBNB() - p0, uint256(1 ether), TOL);
        assertApproxEqAbs(VR_ADDR.balance, uint256(1 ether), TOL);
        // (c) a 1 wei top-up cannot buy a second round today; the day index is fixed.
        _pay(1);
        vm.expectRevert(ValidatorRewards.NotReady.selector);
        vr.distribute();
        // At the next UTC day (not 24h after the last call) the next round opens.
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        _electToday(consensusAddrs);
        vr.distribute();
        assertEq(vr.lastDay(), block.timestamp / 1 days);
    }

    /// The breathe block (updateValidatorSetV2) records the full elected set and its day.
    function testBreatheRecordsElectedSet() public {
        _three();
        _breathe();
        (bool ok, bytes memory ret) = VALIDATOR_CONTRACT_ADDR.staticcall(abi.encodeWithSignature("getElectedSet()"));
        assertTrue(ok);
        (address[] memory set, uint256 day) = abi.decode(ret, (address[], uint256));
        assertEq(set.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(set[i], consensusAddrs[i]);
        }
        assertEq(day, block.timestamp / 1 days);
    }

    /// L-1: setDeit needs a contract, and a broken DEIT token never blocks the native payout.
    function testBrokenDeitNeverBlocksNative() public {
        _setupNativeOnly();
        vm.prank(TIMELOCK_ADDR);
        vm.expectRevert(ValidatorRewards.AlreadySet.selector);
        vr.setDeit(address(0xB0B)); // no code
        RevertingToken bad = new RevertingToken();
        vm.prank(TIMELOCK_ADDR);
        vr.setDeit(address(bad));
        uint256 p0 = _credit(0).totalPooledBNB();
        _pay(3 ether);
        vr.distribute(); // balanceOf reverts: native still paid
        assertApproxEqAbs(_credit(0).totalPooledBNB() - p0, uint256(1 ether), TOL);
        bad.setMode(1); // balanceOf works, transfer reverts
        _nextDay();
        _pay(3 ether);
        vr.distribute();
        assertApproxEqAbs(_credit(0).totalPooledBNB() - p0, uint256(2 ether), TOL);
        bad.setMode(2); // transfer returns false
        _nextDay();
        _pay(3 ether);
        vr.distribute();
        assertApproxEqAbs(_credit(0).totalPooledBNB() - p0, uint256(3 ether), TOL);
    }
}

/// mode 0: balanceOf reverts; 1: transfer reverts; 2: transfer returns false.
contract RevertingToken {
    uint256 public mode;

    function setMode(uint256 m) external {
        mode = m;
    }

    function balanceOf(address) external view returns (uint256) {
        require(mode != 0, "bad");
        return 1000 ether;
    }

    function transfer(address, uint256) external view returns (bool) {
        require(mode != 1, "bad");
        return false;
    }
}
