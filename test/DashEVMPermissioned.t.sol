pragma solidity ^0.8.10;

import "forge-std/Test.sol";

import "../contracts/StakeHub.sol";
import "./FinalLayerFeeGovernance.t.sol";

// DashEVM launch permissioning (design decision 2026-11-19): minimum self-stake
// 0.027 DASH, safe only because StakeHub registration and every path that adds
// stake (delegate, redelegate) is limited to a governance allowlist while
// `permissioned` is on. Undelegate and claim stay open to everyone.
//
// The source tree keeps BSC's large minimums and permissioned = false (the ada
// chain); make_genesis.py patches the dash values in. These tests write the
// dash minimums with stdstore and switch permissioning on through the real
// governance route (Timelock -> GovHub.updateParam -> StakeHub.updateParam), so
// they pass on both the source tree and a patched dash build. With
// DASH_GENESIS_PARAMS=1 (run inside a make_genesis.py dash build) the patched
// genesis values are checked as well.
interface IGovHub {
    function updateParam(string calldata key, bytes calldata value, address target) external;
}

interface IGovTokenView {
    function balanceOf(address) external view returns (uint256);
    function getVotes(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function delegate(address) external;
}

interface IStakeCreditView {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function delegate(address) external payable returns (uint256);
    function getPooledBNB(address) external view returns (uint256);
}

contract DashEVMPermissionedTest is Test {
    using stdStorage for StdStorage;

    address payable constant VALIDATOR_CONTRACT_ADDR = payable(0x0000000000000000000000000000000000001000);
    address payable constant STAKE_HUB_ADDR = payable(0x0000000000000000000000000000000000002002);
    address payable constant STAKE_CREDIT_ADDR = payable(0x0000000000000000000000000000000000002003);
    address constant GOV_TOKEN_ADDR = 0x0000000000000000000000000000000000002005;
    address constant GOV_HUB_ADDR = 0x0000000000000000000000000000000000001007;
    address constant TIMELOCK_ADDR = 0x0000000000000000000000000000000000002006;
    address constant PQ_VERIFY = address(0x0f01);
    uint256 constant PQ_PK_LEN = 2592;
    uint256 constant PQ_SIG_LEN = 4627;

    uint256 constant DASH_MIN_SELF = 0.027 ether;
    uint256 constant DASH_MIN_CHANGE = 0.001 ether;

    StakeHub stakeHub = StakeHub(STAKE_HUB_ADDR);
    IGovTokenView govToken = IGovTokenView(GOV_TOKEN_ADDR);
    address coinbase = address(0xC0FFEE);
    uint256 nextId = 1;

    address launchOp; // allowlisted at "genesis" (setUp)
    address stranger = address(0xBAD);

    function setUp() public {
        vm.etch(VALIDATOR_CONTRACT_ADDR, vm.getDeployedCode("BSCValidatorSet.sol:BSCValidatorSet"));
        vm.etch(STAKE_HUB_ADDR, vm.getDeployedCode("StakeHub.sol:StakeHub"));
        vm.etch(STAKE_CREDIT_ADDR, vm.getDeployedCode("StakeCredit.sol:StakeCredit"));
        vm.etch(GOV_TOKEN_ADDR, vm.getDeployedCode("GovToken.sol:GovToken"));
        vm.etch(GOV_HUB_ADDR, vm.getDeployedCode("GovHub.sol:GovHub"));
        vm.coinbase(coinbase);
        vm.txGasPrice(0);
        vm.prank(coinbase);
        stakeHub.initialize();
        vm.prank(coinbase);
        (bool ok,) = GOV_TOKEN_ADDR.call(abi.encodeWithSignature("initialize()"));
        require(ok, "govtoken init");
        vm.mockCall(
            0x0000000000000000000000000000000000001001,
            abi.encodeWithSignature("getSlashIndicator(address)"),
            abi.encode(uint256(0), uint256(0))
        );
        // dash launch minimums (make_genesis.py DASH_PARAMS) on an unpatched build
        if (stakeHub.minSelfDelegationBNB() != DASH_MIN_SELF) {
            stdstore.target(STAKE_HUB_ADDR).sig("minSelfDelegationBNB()").checked_write(DASH_MIN_SELF);
            stdstore.target(STAKE_HUB_ADDR).sig("minDelegationBNBChange()").checked_write(DASH_MIN_CHANGE);
        }
        launchOp = _operator(1000);
        _gov("allowlistAdd", abi.encodePacked(launchOp));
        _gov("permissioned", abi.encode(uint256(1)));
        // launch pool cap (dash genesis: 0.05 = lock 0.001 + 0.049)
        if (stakeHub.launchStakeCap() == 0) _gov("launchStakeCap", abi.encode(stakeHub.LOCK_AMOUNT() + 0.049 ether));
    }

    /*----------------- helpers -----------------*/
    // The governance route: a passed proposal makes the timelock call GovHub.
    function _gov(string memory key, bytes memory value) internal {
        vm.prank(TIMELOCK_ADDR);
        IGovHub(GOV_HUB_ADDR).updateParam(key, value, STAKE_HUB_ADDR);
    }

    function govExternal(string memory key, bytes memory value) external {
        _gov(key, value);
    }

    function _operator(uint256 i) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("dash-op", i)))));
    }

    function _moniker(uint256 i) internal pure returns (string memory) {
        bytes memory b = new bytes(6);
        b[0] = "D";
        for (uint256 j = 5; j >= 1; --j) {
            b[j] = bytes1(uint8(65 + (i % 26)));
            i /= 26;
        }
        return string(b);
    }

    function _fakePubKey(uint256 i) internal pure returns (bytes memory pk) {
        pk = new bytes(PQ_PK_LEN);
        bytes32 seed = keccak256(abi.encode("dash-pk", i));
        for (uint256 j = 0; j < 32; j++) {
            pk[j] = seed[j];
        }
    }

    function _consensusOf(bytes memory pk) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes.concat(bytes1(0x01), pk)))));
    }

    // forge has no ML-DSA precompile: accept exactly this proof of possession
    function _acceptPop(bytes memory pk, address consensus, address operator) internal {
        bytes32 message =
            keccak256(abi.encodePacked("FinalLayer/validator-pop/v1", block.chainid, consensus, operator));
        vm.mockCall(PQ_VERIFY, bytes.concat(bytes1(0x01), message, pk, new bytes(PQ_SIG_LEN)), abi.encode(uint256(1)));
    }

    function _selfStakeValue() internal view returns (uint256) {
        return stakeHub.LOCK_AMOUNT() + stakeHub.minSelfDelegationBNB();
    }

    function _create(address operator) internal {
        uint256 id = nextId++;
        bytes memory pk = _fakePubKey(id);
        address consensus = _consensusOf(pk);
        _acceptPop(pk, consensus, operator);
        uint256 value = _selfStakeValue();
        vm.deal(operator, operator.balance + value);
        vm.prank(operator);
        stakeHub.createValidator{ value: value }(
            consensus,
            bytes.concat(bytes4("FLPQ"), bytes24(0), bytes20(consensus)),
            bytes.concat(bytes1(0x01), pk, new bytes(PQ_SIG_LEN)),
            StakeHub.Commission({ rate: 1000, maxRate: 5000, maxChangeRate: 500 }),
            StakeHub.Description({ moniker: _moniker(id), identity: "", website: "", details: "" })
        );
    }

    function createExternal(address operator) external {
        _create(operator);
    }

    function _credit(address operator) internal view returns (IStakeCreditView) {
        return IStakeCreditView(stakeHub.getValidatorCreditContract(operator));
    }

    /*----------------- tests -----------------*/
    function testPermissionedOnAndOnlyGovernanceChangesIt() public {
        assertTrue(stakeHub.permissioned());
        assertTrue(stakeHub.allowlisted(launchOp));
        // not the governance route: direct callers, the timelock itself, the coinbase
        address[3] memory callers = [stranger, TIMELOCK_ADDR, coinbase];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert();
            stakeHub.updateParam("permissioned", abi.encode(uint256(0)));
            vm.prank(callers[i]);
            vm.expectRevert();
            stakeHub.updateParam("allowlistAdd", abi.encodePacked(stranger));
        }
        // GovHub.updateParam only from the timelock
        vm.prank(stranger);
        vm.expectRevert();
        IGovHub(GOV_HUB_ADDR).updateParam("allowlistAdd", abi.encodePacked(stranger), STAKE_HUB_ADDR);
        assertTrue(stakeHub.permissioned());
        assertFalse(stakeHub.allowlisted(stranger));
        // bad values
        vm.expectRevert();
        this.govExternal("permissioned", abi.encode(uint256(2)));
        vm.expectRevert();
        this.govExternal("allowlistAdd", abi.encodePacked(address(0)));
        vm.expectRevert();
        this.govExternal("allowlistAdd", abi.encode(stranger)); // 32 bytes, not 20
    }

    function testNonAllowlistedCreateValidatorReverts() public {
        vm.expectRevert(StakeHub.NotAllowlisted.selector);
        this.createExternal(stranger);
        (,, uint256 total) = stakeHub.getValidators(0, 0);
        assertEq(total, 0);
    }

    function testAllowlistedCreateValidatorWithLaunchMinimum() public {
        assertEq(stakeHub.minSelfDelegationBNB(), DASH_MIN_SELF);
        _create(launchOp);
        IStakeCreditView credit = _credit(launchOp);
        assertEq(credit.getPooledBNB(launchOp), DASH_MIN_SELF);
        // self-stake below the minimum still fails for an allowlisted operator
        address op2 = _operator(1001);
        _gov("allowlistAdd", abi.encodePacked(op2));
        bytes memory pk = _fakePubKey(99);
        address consensus = _consensusOf(pk);
        _acceptPop(pk, consensus, op2);
        uint256 value = _selfStakeValue() - 1;
        vm.deal(op2, value);
        vm.prank(op2);
        vm.expectRevert(StakeHub.SelfDelegationNotEnough.selector);
        stakeHub.createValidator{ value: value }(
            consensus,
            bytes.concat(bytes4("FLPQ"), bytes24(0), bytes20(consensus)),
            bytes.concat(bytes1(0x01), pk, new bytes(PQ_SIG_LEN)),
            StakeHub.Commission({ rate: 1000, maxRate: 5000, maxChangeRate: 500 }),
            StakeHub.Description({ moniker: "Dshort", identity: "", website: "", details: "" })
        );
    }

    function testNonAllowlistedDelegateAndRedelegateRevert() public {
        _create(launchOp);
        address op2 = _operator(1001);
        _gov("allowlistAdd", abi.encodePacked(op2));
        _create(op2);
        vm.deal(stranger, 10 ether);
        vm.prank(stranger);
        vm.expectRevert(StakeHub.NotAllowlisted.selector);
        stakeHub.delegate{ value: 1 ether }(launchOp, true);
        vm.prank(stranger);
        vm.expectRevert(StakeHub.NotAllowlisted.selector);
        stakeHub.delegate{ value: 1 ether }(launchOp, false);
        vm.prank(stranger);
        vm.expectRevert(StakeHub.NotAllowlisted.selector);
        stakeHub.redelegate(launchOp, op2, 1, true);
        assertEq(govToken.balanceOf(stranger), 0);
        assertEq(govToken.getVotes(stranger), 0);
        // an allowlisted operator may top up its own pool
        vm.deal(launchOp, 1 ether);
        vm.prank(launchOp);
        stakeHub.delegate{ value: DASH_MIN_CHANGE }(launchOp, true);
    }

    // review H-1: while permissioned an allowlisted key cannot stack stake
    // (and govBNB) on another validator's pool, directly or by redelegating.
    function testDelegateToAnotherValidatorRevertsWhilePermissioned() public {
        _create(launchOp);
        address op2 = _operator(1001);
        _gov("allowlistAdd", abi.encodePacked(op2));
        _create(op2);
        vm.deal(launchOp, 1 ether);
        vm.prank(launchOp);
        vm.expectRevert(StakeHub.OnlySelfDelegation.selector);
        stakeHub.delegate{ value: DASH_MIN_CHANGE }(op2, true);
        // an allowlisted address that is not a validator cannot delegate at all
        address holder = address(0xD3);
        _gov("allowlistAdd", abi.encodePacked(holder));
        vm.deal(holder, 1 ether);
        vm.prank(holder);
        vm.expectRevert(StakeHub.OnlySelfDelegation.selector);
        stakeHub.delegate{ value: DASH_MIN_CHANGE }(launchOp, true);
        // redelegating own stake into another pool is refused too
        uint256 shares = _credit(launchOp).balanceOf(launchOp);
        vm.prank(launchOp);
        vm.expectRevert(StakeHub.OnlySelfDelegation.selector);
        stakeHub.redelegate(launchOp, op2, shares / 10, true);
    }

    // review H-1: no launch pool grows past launchStakeCap while permissioned.
    function testLaunchStakeCapEnforced() public {
        uint256 cap = stakeHub.launchStakeCap();
        assertGt(cap, 0);
        _create(launchOp);
        uint256 room = cap - _credit(launchOp).getPooledBNB(launchOp) - stakeHub.LOCK_AMOUNT();
        vm.deal(launchOp, 1 ether);
        vm.prank(launchOp);
        vm.expectRevert(StakeHub.LaunchStakeCapExceeded.selector);
        stakeHub.delegate{ value: room + 1 }(launchOp, false);
        vm.prank(launchOp);
        stakeHub.delegate{ value: room }(launchOp, false); // exactly at the cap
        // a validator cannot start above the cap either
        address op2 = _operator(1001);
        _gov("allowlistAdd", abi.encodePacked(op2));
        bytes memory pk = _fakePubKey(77);
        address consensus = _consensusOf(pk);
        _acceptPop(pk, consensus, op2);
        vm.deal(op2, cap + 1);
        vm.prank(op2);
        vm.expectRevert(StakeHub.LaunchStakeCapExceeded.selector);
        stakeHub.createValidator{ value: cap + 1 }(
            consensus,
            bytes.concat(bytes4("FLPQ"), bytes24(0), bytes20(consensus)),
            bytes.concat(bytes1(0x01), pk, new bytes(PQ_SIG_LEN)),
            StakeHub.Commission({ rate: 1000, maxRate: 5000, maxChangeRate: 500 }),
            StakeHub.Description({ moniker: "Dbig", identity: "", website: "", details: "" })
        );
        // bounds: no cap below minimum + lock; the minimum cannot pass the cap while permissioned
        uint256 tooLow = stakeHub.minSelfDelegationBNB() + stakeHub.LOCK_AMOUNT() - 1;
        vm.expectRevert();
        this.govExternal("launchStakeCap", abi.encode(tooLow));
        vm.expectRevert();
        this.govExternal("minSelfDelegationBNB", abi.encode(cap));
        // governance lifts the cap (0) and top-ups work again
        _gov("launchStakeCap", abi.encode(uint256(0)));
        vm.prank(launchOp);
        stakeHub.delegate{ value: 0.1 ether }(launchOp, false);
    }

    // review R2-H1: block-fee rewards grow a pool past launchStakeCap
    // without a deposit; the govBNB they would add stays clamped at the cap
    // until governance lifts it, then any sync restores the full votes.
    function testRewardsCannotBuyVotesPastTheCap() public {
        uint256 cap = stakeHub.launchStakeCap();
        _create(launchOp);
        address consensus = stakeHub.getValidatorConsensusAddress(launchOp);
        uint256 reward = 40 * cap; // the dead-address lock shares take part of it
        vm.deal(VALIDATOR_CONTRACT_ADDR, reward);
        vm.prank(VALIDATOR_CONTRACT_ADDR);
        stakeHub.distributeReward{ value: reward }(consensus);
        IStakeCreditView credit = _credit(launchOp);
        uint256 pooled = credit.getPooledBNB(launchOp);
        assertGt(pooled, cap, "rewards pushed the pool over the cap");
        assertEq(govToken.balanceOf(launchOp), cap, "votes clamped at the cap");
        // a public re-sync cannot lift it either
        address[] memory ops = new address[](1);
        ops[0] = launchOp;
        stakeHub.syncGovToken(ops, launchOp);
        assertEq(govToken.balanceOf(launchOp), cap);
        // governance lifts the cap: the next sync mints the rest
        _gov("launchStakeCap", abi.encode(uint256(0)));
        stakeHub.syncGovToken(ops, launchOp);
        assertEq(govToken.balanceOf(launchOp), credit.getPooledBNB(launchOp));
        // back under a cap (raised again) the excess is burned on sync
        _gov("launchStakeCap", abi.encode(cap));
        stakeHub.syncGovToken(ops, launchOp);
        assertEq(govToken.balanceOf(launchOp), cap);
        // opening registration also lifts the vote clamp
        _gov("permissioned", abi.encode(uint256(0)));
        stakeHub.syncGovToken(ops, launchOp);
        assertEq(govToken.balanceOf(launchOp), credit.getPooledBNB(launchOp));
    }

    // review: block-fee rewards must not lift a pool's ELECTED power past
    // the cap either (FeeCurrencyDirectory's 2/3 validator actions weigh it).
    function testElectionPowerAndDirectoryWeightCapped() public {
        uint256 cap = stakeHub.launchStakeCap();
        address op2 = _operator(1001);
        address op3 = _operator(1002);
        _gov("allowlistAdd", abi.encodePacked(op2));
        _gov("allowlistAdd", abi.encodePacked(op3));
        _create(launchOp);
        _create(op2);
        _create(op3);
        // launchOp: rewards push it far past the cap; op2: topped up to the cap
        uint256 reward = 40 * cap;
        address consensusA = stakeHub.getValidatorConsensusAddress(launchOp);
        vm.deal(VALIDATOR_CONTRACT_ADDR, reward);
        vm.prank(VALIDATOR_CONTRACT_ADDR);
        stakeHub.distributeReward{ value: reward }(consensusA);
        assertGt(IStakeCreditView(stakeHub.getValidatorCreditContract(launchOp)).getPooledBNB(launchOp), cap);
        uint256 room = cap - _selfStakeValue();
        vm.deal(op2, room);
        vm.prank(op2);
        stakeHub.delegate{ value: room }(op2, false);
        assertEq(_power(launchOp), cap, "rewards do not lift elected power past the cap");
        assertEq(_power(op2), cap);
        assertEq(_power(op3), _selfStakeValue());
        _electAll();
        _checkDirectoryWeights(cap, op2);
        // lifting the cap restores the full power at the next election
        _gov("launchStakeCap", abi.encode(uint256(0)));
        assertGt(_power(launchOp), cap);
    }

    // the engine's election: powers / 1e10 into BSCValidatorSet
    function _electAll() internal {
        (address[] memory cons, uint256[] memory powers, bytes[] memory votesAddr,) =
            stakeHub.getValidatorElectionInfo(0, 0);
        uint64[] memory p64 = new uint64[](cons.length);
        for (uint256 i; i < cons.length; ++i) {
            p64[i] = uint64(powers[i] / 1e10);
        }
        (bool ok,) = VALIDATOR_CONTRACT_ADDR.call(abi.encodeWithSignature("init()"));
        require(ok, "valset init");
        vm.prank(coinbase);
        (ok,) = VALIDATOR_CONTRACT_ADDR.call(
            abi.encodeWithSignature("updateValidatorSetV2(address[],uint64[],bytes[])", cons, p64, votesAddr)
        );
        require(ok, "valset update");
    }

    // FeeCurrencyDirectory weighs launchOp (rewards past the cap) and op2 (at the cap) equally
    function _checkDirectoryWeights(uint256 cap, address op2) internal {
        address dirAddr = 0x0000000000000000000000000000000000005052;
        vm.etch(dirAddr, address(new FeeCurrencyDirectory()).code);
        FeeCurrencyDirectory dir = FeeCurrencyDirectory(dirAddr);
        vm.prank(launchOp);
        bytes32 id = dir.validatorSetConfig(address(0x70CE), address(0x5053), 50_000, 0, 0, 0);
        (,,,, uint256 approvedA, uint256 total) = dir.getAction(id);
        assertEq(approvedA, cap / 1e10);
        assertEq(total, (2 * cap + _selfStakeValue()) / 1e10);
        vm.prank(op2);
        dir.validatorSetConfig(address(0x70CE), address(0x5053), 50_000, 0, 0, 0);
        (,,,, uint256 approvedAB,) = dir.getAction(id);
        assertEq(approvedAB, 2 * approvedA, "capped pools weigh the same");
    }

    function _power(address operator) internal view returns (uint256) {
        (address[] memory cons, uint256[] memory powers,,) = stakeHub.getValidatorElectionInfo(0, 0);
        address c = stakeHub.getValidatorConsensusAddress(operator);
        for (uint256 i; i < cons.length; ++i) {
            if (cons[i] == c) return powers[i];
        }
        revert("not registered");
    }

    // review M-1 / L-1: removal from the allowlist and a raised minimum
    // both take a validator out of the next election (power 0).
    function testElectionPowerZeroForRemovedOrUnderMinimum() public {
        _create(launchOp);
        address op2 = _operator(1001);
        _gov("allowlistAdd", abi.encodePacked(op2));
        _create(op2);
        assertEq(_power(launchOp), _selfStakeValue());
        assertEq(_power(op2), _selfStakeValue());
        _gov("allowlistRemove", abi.encodePacked(op2));
        assertEq(_power(op2), 0, "removed operator is not elected");
        _gov("allowlistAdd", abi.encodePacked(op2));
        assertEq(_power(op2), _selfStakeValue());
        // raise the minimum by one wei: both fall under it
        uint256 base = _selfStakeValue();
        uint256 newMin = stakeHub.minSelfDelegationBNB() + 1;
        if (newMin >= stakeHub.MIN_SELF_DELEGATION_FLOOR()) {
            _gov("minSelfDelegationBNB", abi.encode(newMin));
        } else {
            // source tree: BSC's 100,000 floor, so write the dash-sized raise directly
            stdstore.target(STAKE_HUB_ADDR).sig("minSelfDelegationBNB()").checked_write(newMin);
        }
        assertEq(_power(launchOp), 0, "under the new minimum");
        assertEq(_power(op2), 0);
        // a top-up restores it
        vm.deal(launchOp, 1 ether);
        vm.prank(launchOp);
        stakeHub.delegate{ value: DASH_MIN_CHANGE }(launchOp, false);
        assertEq(_power(launchOp), base + DASH_MIN_CHANGE);
        // once open, the allowlist no longer matters, the minimum still does
        _gov("permissioned", abi.encode(uint256(0)));
        _gov("allowlistRemove", abi.encodePacked(launchOp));
        assertGt(_power(launchOp), 0);
        assertEq(_power(op2), 0);
    }

    // StakeCredit shares and govBNB are not transferable and are minted only by
    // StakeHub, so the allowlist cannot be bypassed by a direct call or a transfer.
    function testNoBypassThroughStakeCreditOrGovToken() public {
        _create(launchOp);
        IStakeCreditView credit = _credit(launchOp);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert();
        credit.delegate{ value: 1 ether }(stranger);
        uint256 shares = credit.balanceOf(launchOp);
        assertGt(shares, 0);
        vm.prank(launchOp);
        vm.expectRevert();
        credit.transfer(stranger, 1);
        uint256 gov = govToken.balanceOf(launchOp);
        assertEq(gov, DASH_MIN_SELF);
        vm.prank(launchOp);
        vm.expectRevert();
        govToken.transfer(stranger, 1);
        vm.prank(launchOp);
        vm.expectRevert();
        govToken.approve(stranger, 1);
        // the lock shares at 0xdEaD never get govBNB (they would inflate the quorum base)
        address[] memory ops = new address[](1);
        ops[0] = launchOp;
        uint256 supply = govToken.totalSupply();
        vm.expectRevert(StakeHub.InvalidRequest.selector);
        stakeHub.syncGovToken(ops, address(0xdEaD));
        // syncing a stranger mints nothing (it has no shares)
        stakeHub.syncGovToken(ops, stranger);
        assertEq(govToken.totalSupply(), supply);
    }

    // A delegator removed from the allowlist (or one who staked before the flag
    // was turned back on) is never stuck: undelegate and claim stay open.
    function testUndelegateAndClaimOpenToEveryone() public {
        address delegator = address(0xD1);
        _create(launchOp);
        // a delegation made while registration was open
        _gov("permissioned", abi.encode(uint256(0)));
        vm.deal(delegator, 1 ether);
        vm.prank(delegator);
        stakeHub.delegate{ value: 0.5 ether }(launchOp, true);
        assertEq(govToken.getVotes(launchOp), 0.5 ether);
        _gov("permissioned", abi.encode(uint256(1)));
        assertFalse(stakeHub.allowlisted(delegator));
        // no more stake from it
        vm.prank(delegator);
        vm.expectRevert(StakeHub.NotAllowlisted.selector);
        stakeHub.delegate{ value: 0.1 ether }(launchOp, false);
        // but it can leave
        IStakeCreditView credit = _credit(launchOp);
        uint256 shares = credit.balanceOf(delegator);
        vm.prank(delegator);
        stakeHub.undelegate(launchOp, shares);
        assertEq(govToken.balanceOf(delegator), 0);
        vm.warp(block.timestamp + stakeHub.unbondPeriod() + 1);
        uint256 before = delegator.balance;
        vm.prank(delegator);
        stakeHub.claim(launchOp, 0);
        assertEq(delegator.balance - before, 0.5 ether);
    }

    function testGovernanceOpensRegistration() public {
        _create(launchOp);
        // governance adds one more operator while permissioned
        address op2 = _operator(1001);
        _gov("allowlistAdd", abi.encodePacked(op2));
        _create(op2);
        // exit: governance lifts the launch cap, the launch validators top up
        // FIRST, then governance raises the minimum, then opens registration
        uint256 newMin = stakeHub.MIN_SELF_DELEGATION_FLOOR();
        if (newMin < 10 ether) newMin = 10 ether;
        _gov("launchStakeCap", abi.encode(uint256(0)));
        vm.deal(launchOp, newMin);
        vm.prank(launchOp);
        stakeHub.delegate{ value: newMin }(launchOp, false);
        _gov("minSelfDelegationBNB", abi.encode(newMin));
        assertGt(_power(launchOp), 0, "topped up: still elected");
        assertEq(_power(op2), 0, "not topped up: out of the election");
        _gov("permissioned", abi.encode(uint256(0)));
        assertFalse(stakeHub.permissioned());
        // public registration and delegation now work for anyone
        _create(stranger);
        assertGe(_credit(stranger).getPooledBNB(stranger), 10 ether);
        address publicDelegator = address(0xD2);
        vm.deal(publicDelegator, 1 ether);
        vm.prank(publicDelegator);
        stakeHub.delegate{ value: 0.5 ether }(launchOp, true);
        // and governance can close it again
        _gov("permissioned", abi.encode(uint256(1)));
        vm.prank(publicDelegator);
        vm.expectRevert(StakeHub.NotAllowlisted.selector);
        stakeHub.delegate{ value: 0.1 ether }(launchOp, true);
    }

    // The dash slash and delegation params can still be moved by governance
    // within the per-chain floors (BSC's 0.1 / 1 / 10 floors would freeze them).
    function testDashParamsStayGovernable() public {
        if (!vm.envOr("DASH_GENESIS_PARAMS", false)) return;
        _gov("minDelegationBNBChange", abi.encode(uint256(0.0005 ether)));
        assertEq(stakeHub.minDelegationBNBChange(), 0.0005 ether);
        _gov("downtimeSlashAmount", abi.encode(uint256(0.0002 ether)));
        _gov("felonySlashAmount", abi.encode(uint256(0.004 ether)));
        _gov("minSelfDelegationBNB", abi.encode(uint256(0.01 ether)));
        vm.expectRevert();
        this.govExternal("minSelfDelegationBNB", abi.encode(uint256(0.009 ether)));
    }
}

// Runs only inside a make_genesis.py dash build (DASH_GENESIS_PARAMS=1): the
// values initialize() writes at genesis, on fresh StakeHub storage.
contract DashEVMGenesisParamsTest is Test {
    address payable constant STAKE_HUB_ADDR = payable(0x0000000000000000000000000000000000002002);

    function testDashGenesisParams() public {
        if (!vm.envOr("DASH_GENESIS_PARAMS", false)) return;
        StakeHub stakeHub = StakeHub(STAKE_HUB_ADDR);
        vm.etch(STAKE_HUB_ADDR, vm.getDeployedCode("StakeHub.sol:StakeHub"));
        vm.coinbase(address(0xC0FFEE));
        vm.txGasPrice(0);
        vm.prank(address(0xC0FFEE));
        stakeHub.initialize();
        assertEq(stakeHub.minSelfDelegationBNB(), 0.027 ether);
        assertEq(stakeHub.MIN_SELF_DELEGATION_FLOOR(), 0.01 ether);
        assertEq(stakeHub.minDelegationBNBChange(), 0.001 ether);
        assertEq(stakeHub.MIN_DELEGATION_CHANGE_FLOOR(), 0.0001 ether);
        assertEq(stakeHub.downtimeSlashAmount(), 0.00027 ether);
        assertEq(stakeHub.felonySlashAmount(), 0.0054 ether);
        assertEq(stakeHub.DOWNTIME_SLASH_FLOOR(), 0.0001 ether);
        assertEq(stakeHub.FELONY_SLASH_FLOOR(), 0.001 ether);
        assertEq(stakeHub.LOCK_AMOUNT(), 0.001 ether);
        assertEq(stakeHub.maxElectedValidators(), vm.envOr("EXPECT_MAX_ELECTED", uint256(7)));
        assertTrue(stakeHub.permissioned());
        assertEq(stakeHub.launchStakeCap(), 0.05 ether);
        address first = vm.envOr("EXPECT_ALLOWLISTED", address(0));
        assertTrue(first != address(0));
        assertTrue(stakeHub.allowlisted(first));
        assertFalse(stakeHub.allowlisted(address(0xBAD)));
    }
}

// review H-2 / mitigation 3: the StakeHub keys that decide who validates
// are strict proposals (STRICT_QUORUM_PERCENT of all govBNB must vote for, and
// 2/3 of for+against), and on a dash build the strict quorum is 67% and the
// voting delay 1 day.
contract DashEVMStrictGovernanceTest is Test {
    address constant GOVERNOR = 0x0000000000000000000000000000000000002004;
    address constant GOV_TOKEN = 0x0000000000000000000000000000000000002005;
    address constant TIMELOCK = 0x0000000000000000000000000000000000002006;
    address constant GOV_HUB = 0x0000000000000000000000000000000000001007;
    address constant STAKE_HUB = 0x0000000000000000000000000000000000002002;
    bytes4 constant UP = bytes4(keccak256("updateParam(string,bytes,address)"));

    BSCGovernor gov = BSCGovernor(payable(GOVERNOR));
    MockVotes votes;
    address alice = address(0xA11CE); // 40%
    address bob = address(0xB0B); // 25%
    address carol = address(0xCA201); // 35%

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(100);
        vm.etch(GOVERNOR, vm.getDeployedCode("BSCGovernor.sol:BSCGovernor"));
        vm.etch(TIMELOCK, vm.getDeployedCode("BSCTimelock.sol:BSCTimelock"));
        vm.etch(GOV_HUB, vm.getDeployedCode("GovHub.sol:GovHub"));
        vm.etch(GOV_TOKEN, address(new MockVotes()).code);
        votes = MockVotes(GOV_TOKEN);
        vm.coinbase(address(0xC0FFEE));
        vm.txGasPrice(0);
        vm.startPrank(address(0xC0FFEE));
        gov.initialize();
        BSCTimelock(payable(TIMELOCK)).initialize();
        vm.stopPrank();
        votes.mint(alice, 8_000_000 ether);
        votes.mint(bob, 5_000_000 ether);
        votes.mint(carol, 7_000_000 ether);
        vm.prank(alice);
        votes.delegate(alice);
        vm.prank(bob);
        votes.delegate(bob);
        vm.prank(carol);
        votes.delegate(carol);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 3);
    }

    function _one(bytes memory data) internal pure returns (address[] memory t, uint256[] memory v, bytes[] memory c) {
        t = new address[](1);
        v = new uint256[](1);
        c = new bytes[](1);
        t[0] = GOV_HUB;
        c[0] = data;
    }

    function testLaunchKeysAreStrict() public {
        string[6] memory keys = [
            "permissioned",
            "allowlistAdd",
            "allowlistRemove",
            "minSelfDelegationBNB",
            "maxRegisteredValidators",
            "launchStakeCap"
        ];
        for (uint256 i; i < keys.length; ++i) {
            (address[] memory t,, bytes[] memory c) =
                _one(abi.encodeWithSelector(UP, keys[i], abi.encode(uint256(1)), STAKE_HUB));
            assertTrue(gov.isStrictProposal(t, c), keys[i]);
        }
        (address[] memory t2,, bytes[] memory c2) =
            _one(abi.encodeWithSelector(UP, "maxElectedValidators", abi.encode(uint256(7)), STAKE_HUB));
        assertTrue(gov.isStrictProposal(t2, c2));
        (address[] memory t3,, bytes[] memory c3) =
            _one(abi.encodeWithSelector(UP, "unbondPeriod", abi.encode(uint256(7 days)), STAKE_HUB));
        assertFalse(gov.isStrictProposal(t3, c3), "other StakeHub params stay normal");
    }

    // 65% voting for (alice + bob, carol absent): passes a 30% strict quorum,
    // fails the dash 67% one. A normal proposal passes with that vote either way.
    function testStrictQuorumAppliesToAllowlist() public {
        bytes memory data = abi.encodeWithSelector(UP, "allowlistAdd", abi.encodePacked(address(0xE71)), STAKE_HUB);
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(data);
        vm.prank(alice);
        uint256 id = gov.propose(t, v, c, "allowlist 0xE71");
        assertTrue(gov.strictProposals(id));
        vm.roll(block.number + gov.votingDelay() + 1);
        vm.prank(alice);
        gov.castVote(id, 1);
        vm.prank(bob);
        gov.castVote(id, 1);
        vm.roll(gov.proposalDeadline(id) + 1);
        IGovernorUpgradeable.ProposalState want = gov.STRICT_QUORUM_PERCENT() > 65
            ? IGovernorUpgradeable.ProposalState.Defeated
            : IGovernorUpgradeable.ProposalState.Succeeded;
        assertEq(uint256(gov.state(id)), uint256(want));
        if (vm.envOr("DASH_GENESIS_PARAMS", false)) {
            assertEq(gov.STRICT_QUORUM_PERCENT(), 67);
            assertEq(gov.votingDelay(), 28_800); // 1 day of 3 s blocks
            assertEq(uint256(gov.state(id)), uint256(IGovernorUpgradeable.ProposalState.Defeated));
        }
    }

    // A proposal cannot be voted in its own block (votes are snapshotted
    // votingDelay blocks later; dash: 1 day, so stake bought after a proposal
    // appears is visible to everyone for a day before it counts).
    function testVotingDelay() public {
        if (!vm.envOr("DASH_GENESIS_PARAMS", false)) return;
        (address[] memory t, uint256[] memory v, bytes[] memory c) =
            _one(abi.encodeWithSelector(UP, "permissioned", abi.encode(uint256(0)), STAKE_HUB));
        vm.prank(alice);
        uint256 id = gov.propose(t, v, c, "open");
        vm.roll(block.number + 1);
        vm.prank(alice);
        vm.expectRevert();
        gov.castVote(id, 1);
        assertEq(gov.proposalSnapshot(id), block.number - 1 + 1 days / 3);
    }
}

// review L-3 / mitigation 7: make_genesis.py refuses a dash genesis with
// fewer than 7 elected validators or fewer allowlisted operators than elected.
// Runs the script through ffi (skipped where the script is not next to the
// contracts, e.g. inside a make_genesis build copy). The guards run before the
// build dir is touched; BUILD_DIR points at out/ anyway.
contract DashEVMGenesisGuardTest is Test {
    function _run(string memory env1, string memory env2, string memory chain) internal returns (Vm.FfiResult memory) {
        string memory script = string.concat(vm.projectRoot(), "/../scripts/make_genesis.py");
        string[] memory cmd = new string[](13);
        cmd[0] = "env";
        cmd[1] = env1;
        cmd[2] = env2;
        cmd[3] = string.concat("BUILD_DIR=", vm.projectRoot(), "/out/guard-test-never-built");
        cmd[4] = "python3";
        cmd[5] = script;
        cmd[6] = chain;
        cmd[7] = "/nonexistent";
        cmd[8] = "/nonexistent";
        cmd[9] = "/nonexistent";
        cmd[10] = "0x00000000000000000000000000000000000dEa11";
        cmd[11] = "1";
        cmd[12] = "/nonexistent/genesis.json";
        return vm.tryFfi(cmd);
    }

    function _ops(uint256 n) internal pure returns (string memory list) {
        list = "VALIDATOR_ALLOWLIST=";
        for (uint256 i = 1; i <= n; ++i) {
            list = string.concat(list, i == 1 ? "" : ",", vm.toString(address(uint160(0x1000 + i))));
        }
    }

    function _contains(bytes memory h, bytes memory n) internal pure returns (bool) {
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool hit = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }

    function testMakeGenesisGuards() public {
        Vm.FfiResult memory r = _run(_ops(6), "MAX_ELECTED=7", "dash");
        // not next to the contracts (a make_genesis build copy): nothing to test
        if (_contains(r.stderr, "can't open file")) return;
        assertTrue(r.exitCode != 0);
        assertTrue(_contains(r.stderr, "fewer than MAX_ELECTED"), string(r.stderr));
        r = _run(_ops(9), "MAX_ELECTED=6", "dash-testnet");
        assertTrue(r.exitCode != 0);
        assertTrue(_contains(r.stderr, "at least 7"), string(r.stderr));
        r = _run(_ops(9), "MAX_ELECTED=21", "ada");
        assertTrue(r.exitCode != 0);
        assertTrue(_contains(r.stderr, "must be empty"), string(r.stderr));
        r = _run("VALIDATOR_ALLOWLIST=", "MAX_ELECTED=7", "dash");
        assertTrue(r.exitCode != 0);
        assertTrue(_contains(r.stderr, "set VALIDATOR_ALLOWLIST"), string(r.stderr));
    }
}

// Fee currencies (gas paid in a governance-listed ERC-20): every change of the
// FeeCurrencyDirectory (0x...5052) or FixedRateOracle (0x...5053) through
// governance is a strict proposal on DashEVM, removals included
// (FEE_REMOVAL_IS_STRICT). A normal-quorum vote cannot list a currency; a
// strict vote can, and executes through the timelock.
contract DashEVMFeeCurrencyGovernanceTest is Test {
    address constant GOVERNOR = 0x0000000000000000000000000000000000002004;
    address constant GOV_TOKEN = 0x0000000000000000000000000000000000002005;
    address constant TIMELOCK = 0x0000000000000000000000000000000000002006;
    address constant GOV_HUB = 0x0000000000000000000000000000000000001007;
    address constant DIRECTORY = 0x0000000000000000000000000000000000005052;
    address constant ORACLE = 0x0000000000000000000000000000000000005053;

    BSCGovernor gov = BSCGovernor(payable(GOVERNOR));
    FeeCurrencyDirectory dir = FeeCurrencyDirectory(DIRECTORY);
    FixedRateOracle oracle = FixedRateOracle(ORACLE);
    MockVotes votes;
    address token;
    address alice = address(0xA11CE); // 40%
    address bob = address(0xB0B); // 25%
    address carol = address(0xCA201); // 35%

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(100);
        vm.etch(GOVERNOR, vm.getDeployedCode("BSCGovernor.sol:BSCGovernor"));
        vm.etch(TIMELOCK, vm.getDeployedCode("BSCTimelock.sol:BSCTimelock"));
        vm.etch(GOV_HUB, vm.getDeployedCode("GovHub.sol:GovHub"));
        vm.etch(GOV_TOKEN, address(new MockVotes()).code);
        vm.etch(DIRECTORY, address(new FeeCurrencyDirectory()).code);
        vm.etch(ORACLE, address(new FixedRateOracle()).code);
        votes = MockVotes(GOV_TOKEN);
        vm.coinbase(address(0xC0FFEE));
        vm.txGasPrice(0);
        vm.startPrank(address(0xC0FFEE));
        gov.initialize();
        BSCTimelock(payable(TIMELOCK)).initialize();
        vm.stopPrank();
        votes.mint(alice, 8_000_000 ether);
        votes.mint(bob, 5_000_000 ether);
        votes.mint(carol, 7_000_000 ether);
        vm.prank(alice);
        votes.delegate(alice);
        vm.prank(bob);
        votes.delegate(bob);
        vm.prank(carol);
        votes.delegate(carol);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 3);
        token = address(new FLTestDollar());
    }

    function _one(address target, bytes memory data)
        internal
        pure
        returns (address[] memory t, uint256[] memory v, bytes[] memory c)
    {
        t = new address[](1);
        v = new uint256[](1);
        c = new bytes[](1);
        t[0] = target;
        c[0] = data;
    }

    function _vote(address target, bytes memory data, string memory desc, address[] memory yes)
        internal
        returns (uint256 id)
    {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(target, data);
        vm.prank(alice);
        id = gov.propose(t, v, c, desc);
        vm.roll(block.number + gov.votingDelay() + 1);
        for (uint256 i; i < yes.length; ++i) {
            vm.prank(yes[i]);
            gov.castVote(id, 1);
        }
        vm.roll(gov.proposalDeadline(id) + 1);
    }

    function _execute(address target, bytes memory data, string memory desc) internal {
        (address[] memory t, uint256[] memory v, bytes[] memory c) = _one(target, data);
        bytes32 dh = keccak256(bytes(desc));
        gov.queue(t, v, c, dh);
        vm.warp(block.timestamp + 1 days + 1);
        gov.execute(t, v, c, dh);
    }

    function _listCall() internal view returns (bytes memory) {
        return abi.encodeWithSelector(FeeCurrencyDirectory.setCurrencyConfig.selector, token, ORACLE, 50_000);
    }

    function testEveryFeeChangeIsStrict() public {
        bytes[6] memory calls = [
            _listCall(),
            abi.encodeWithSelector(FeeCurrencyDirectory.unsuspend.selector, token),
            abi.encodeWithSelector(FeeCurrencyDirectory.removeCurrency.selector, token),
            abi.encodeWithSelector(FixedRateOracle.setRate.selector, token, 1, 1, 0),
            abi.encodeWithSelector(FixedRateOracle.removeRate.selector, token),
            abi.encodeWithSignature("anythingElse()")
        ];
        address[6] memory targets = [DIRECTORY, DIRECTORY, DIRECTORY, ORACLE, ORACLE, DIRECTORY];
        for (uint256 i; i < calls.length; ++i) {
            (address[] memory t,, bytes[] memory c) = _one(targets[i], calls[i]);
            bool isRemoval = i == 2 || i == 4;
            if (isRemoval && !gov.FEE_REMOVAL_IS_STRICT()) {
                assertFalse(gov.isStrictProposal(t, c), "removal is normal off DashEVM");
            } else {
                assertTrue(gov.isStrictProposal(t, c));
            }
        }
        if (vm.envOr("DASH_GENESIS_PARAMS", false)) assertTrue(gov.FEE_REMOVAL_IS_STRICT());
    }

    // bob alone (25% for, nobody against) meets the normal 10% quorum and a
    // simple majority, which would pass a normal proposal, but not a listing.
    function testNormalQuorumCannotListAStrictOneCan() public {
        vm.prank(TIMELOCK);
        oracle.setRate(token, 1, 1, 0);
        address[] memory yes = new address[](1);
        yes[0] = bob;
        uint256 id = _vote(DIRECTORY, _listCall(), "list, bob only", yes);
        assertTrue(gov.strictProposals(id));
        assertEq(uint256(gov.state(id)), uint256(IGovernorUpgradeable.ProposalState.Defeated));
        // everyone for: past the strict quorum (30% or the strict 67%) and 2/3
        address[] memory all = new address[](3);
        all[0] = alice;
        all[1] = bob;
        all[2] = carol;
        id = _vote(DIRECTORY, _listCall(), "list, all", all);
        assertEq(uint256(gov.state(id)), uint256(IGovernorUpgradeable.ProposalState.Succeeded));
        _execute(DIRECTORY, _listCall(), "list, all");
        (uint256 n,,) = dir.getCurrencyConfigAndRate(token);
        assertEq(n, 1, "listed through the timelock");
        // removal by bob alone: normal off DashEVM, strict (defeated) on it
        bytes memory rm = abi.encodeWithSelector(FeeCurrencyDirectory.removeCurrency.selector, token);
        id = _vote(DIRECTORY, rm, "remove, bob only", yes);
        IGovernorUpgradeable.ProposalState want = gov.FEE_REMOVAL_IS_STRICT()
            ? IGovernorUpgradeable.ProposalState.Defeated
            : IGovernorUpgradeable.ProposalState.Succeeded;
        assertEq(uint256(gov.state(id)), uint256(want));
    }
}
