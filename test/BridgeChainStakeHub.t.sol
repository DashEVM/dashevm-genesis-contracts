pragma solidity ^0.8.10;

import "forge-std/Test.sol";

import "../contracts/StakeHub.sol";

// DashEVM / CardanoEVM system contracts: no native staking inflation, the
// validator set update feeds StakeHub's rotation guard (chain review H-2),
// and the fee share BSC burns goes to the FeeVault. Helpers are copied from
// the earlier inflation test suite.
interface VmCool {
    function cool(address target) external;
}

interface IFLValidatorSet {
    function init() external;
    function updateValidatorSetV2(address[] memory, uint64[] memory, bytes[] memory) external;
    function getValidators() external view returns (address[] memory);
    function lastEvictionBlock() external view returns (uint256);
    function updateParam(string calldata key, bytes calldata value) external;
    function getTurnLength() external view returns (uint256);
    function MAX_CONSENSUS_VALIDATORS() external view returns (uint256);
    function RECOVERY_OFFSET_BLOCKS() external view returns (uint256);
    function deposit(address valAddr) external payable;
    function enterMaintenance() external;
    function isSystemRewardIncluded() external view returns (bool);
    function systemRewardBaseRatio() external view returns (uint256);
    function burnRatio() external view returns (uint256);
    function systemRewardAntiMEVRatio() external view returns (uint256);
}

interface IFLSystemReward {
    function claimRewards(address payable to, uint256 amount) external returns (uint256);
    function isOperator(address addr) external view returns (bool);
    function alreadyInit() external view returns (bool);
    function updateParam(string calldata key, bytes calldata value) external;
}

contract BridgeChainStakeHubTest is Test {
    address payable constant VALIDATOR_CONTRACT_ADDR = payable(0x0000000000000000000000000000000000001000);
    address payable constant STAKE_HUB_ADDR = payable(0x0000000000000000000000000000000000002002);
    address payable constant STAKE_CREDIT_ADDR = payable(0x0000000000000000000000000000000000002003);
    address constant GOV_TOKEN_ADDR = 0x0000000000000000000000000000000000002005;
    address constant GOV_HUB_ADDR = 0x0000000000000000000000000000000000001007;

    // Gas the miner reserves for ALL system transactions of a breathe block
    // (params.SystemTxsGasHardLimit). updateValidatorSetV2 needs most of it.
    uint256 constant SYSTEM_TXS_GAS_HARD_LIMIT = 20_000_000;

    StakeHub stakeHub = StakeHub(STAKE_HUB_ADDR);
    address coinbase = address(0xC0FFEE);
    uint256 nextUser = 1;
    address[] operators;
    address[] consensusAddrs;

    function setUp() public {
        vm.etch(VALIDATOR_CONTRACT_ADDR, vm.getDeployedCode("BSCValidatorSet.sol:BSCValidatorSet"));
        vm.etch(STAKE_HUB_ADDR, vm.getDeployedCode("StakeHub.sol:StakeHub"));
        vm.etch(STAKE_CREDIT_ADDR, vm.getDeployedCode("StakeCredit.sol:StakeCredit"));
        vm.etch(GOV_TOKEN_ADDR, vm.getDeployedCode("GovToken.sol:GovToken"));
        vm.coinbase(coinbase);
        vm.txGasPrice(0);
        vm.prank(coinbase);
        stakeHub.initialize();
        // no missed turns recorded unless a test says otherwise
        vm.mockCall(
            0x0000000000000000000000000000000000001001,
            abi.encodeWithSignature("getSlashIndicator(address)"),
            abi.encode(uint256(0), uint256(0))
        );
    }

    function _moniker(uint256 i) internal pure returns (string memory) {
        bytes memory b = new bytes(6);
        b[0] = "V";
        for (uint256 j = 5; j >= 1; --j) {
            b[j] = bytes1(uint8(65 + (i % 26)));
            i /= 26;
        }
        return string(b);
    }

    address constant PQ_VERIFY = address(0x0f01);
    uint256 constant PQ_PK_LEN = 2592;
    uint256 constant PQ_SIG_LEN = 4627;

    // A stand-in ML-DSA-87 public key: forge has no ML-DSA precompile, so the
    // signature check at 0x0f01 is mocked and these tests cover the binding
    // logic around it (derived address, message, vote identifier).
    function _fakePubKey(uint256 i) internal pure returns (bytes memory pk) {
        pk = new bytes(PQ_PK_LEN);
        bytes32 seed = keccak256(abi.encode("pk", i));
        for (uint256 j = 0; j < 32; j++) {
            pk[j] = seed[j];
        }
    }

    function _consensusOf(bytes memory pk) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes.concat(bytes1(0x01), pk)))));
    }

    function _proof(bytes memory pk) internal pure returns (bytes memory) {
        return bytes.concat(bytes1(0x01), pk, new bytes(PQ_SIG_LEN));
    }

    function _voteId(address consensus) internal pure returns (bytes memory) {
        return bytes.concat(bytes4("FLPQ"), bytes24(0), bytes20(consensus));
    }

    function _popMessage(address consensus, address operator) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("FinalLayer/validator-pop/v1", block.chainid, consensus, operator));
    }

    // Mocks the precompile to accept exactly this (pk, message) pair.
    function _acceptPop(bytes memory pk, address consensus, address operator) internal {
        bytes memory input = bytes.concat(bytes1(0x01), _popMessage(consensus, operator), pk, new bytes(PQ_SIG_LEN));
        vm.mockCall(PQ_VERIFY, input, abi.encode(uint256(1)));
    }

    function _commission() internal pure returns (StakeHub.Commission memory) {
        return StakeHub.Commission({ rate: 1000, maxRate: 5000, maxChangeRate: 500 });
    }

    function _description(uint256 i) internal pure returns (StakeHub.Description memory) {
        return StakeHub.Description({ moniker: _moniker(i), identity: "", website: "", details: "" });
    }

    function _createValidator() internal {
        address operator = address(uint160(uint256(keccak256(abi.encode("op", nextUser)))));
        bytes memory pk = _fakePubKey(nextUser);
        address consensus = _consensusOf(pk);
        _acceptPop(pk, consensus, operator);
        uint256 value = 100_001 ether;
        vm.deal(operator, value);
        vm.prank(operator);
        stakeHub.createValidator{ value: value }(
            consensus, _voteId(consensus), _proof(pk), _commission(), _description(nextUser)
        );
        nextUser++;
        operators.push(operator);
        consensusAddrs.push(consensus);
    }

    address constant SLASH_ADDR = 0x0000000000000000000000000000000000001001;
    address payable constant FEE_VAULT = payable(0x0000000000000000000000000000000000005060);
    bool vsInit;

    function _setElected(address[] memory elected) internal {
        vm.mockCall(VALIDATOR_CONTRACT_ADDR, abi.encodeWithSignature("getValidators()"), abi.encode(elected));
    }

    function _rotate(uint256 i, uint256 seed) internal returns (address newConsensus) {
        bytes memory pk = _fakePubKey(seed);
        newConsensus = _consensusOf(pk);
        _acceptPop(pk, newConsensus, operators[i]);
        vm.prank(operators[i]);
        stakeHub.editConsensusAddress(newConsensus, _proof(pk));
    }

    function rotateExternal(uint256 i, uint256 seed) external {
        _rotate(i, seed);
    }

    /// A real breathe block: the engine's updateValidatorSetV2 system tx.
    function _breathe() internal {
        IFLValidatorSet vs = IFLValidatorSet(VALIDATOR_CONTRACT_ADDR);
        if (!vsInit) {
            vs.init();
            vsInit = true;
        }
        uint64[] memory powers = new uint64[](consensusAddrs.length);
        bytes[] memory votes = new bytes[](consensusAddrs.length);
        for (uint256 i; i < consensusAddrs.length; ++i) {
            powers[i] = 1;
            votes[i] = _voteId(consensusAddrs[i]);
        }
        vm.prank(coinbase);
        vs.updateValidatorSetV2(consensusAddrs, powers, votes);
    }

    function _three() internal {
        for (uint256 i; i < 3; ++i) {
            _createValidator();
        }
        _setElected(consensusAddrs);
    }

    // H-2 regression: without the inflation tx the guard never settled.
    function testRotationSettlesAfterValidatorSetUpdate() public {
        _three();
        _breathe();
        vm.roll(block.number + stakeHub.ROTATION_FREEZE_BLOCKS() + 1);
        vm.warp(block.timestamp + 2 days);
        _rotate(0, 5000);
        vm.expectRevert(StakeHub.TooManyPendingRotations.selector);
        this.rotateExternal(1, 5001);
        vm.roll(block.number + 1);
        _breathe(); // records the update through BSCValidatorSet
        assertEq(stakeHub.lastValidatorSetUpdateBlock(), block.number);
        vm.expectRevert(StakeHub.RotationFrozen.selector);
        this.rotateExternal(1, 5001);
        vm.roll(block.number + stakeHub.ROTATION_FREEZE_BLOCKS() + 1);
        vm.warp(block.timestamp + 2 days);
        _rotate(1, 5001);
    }

    function testNoteValidatorSetUpdateOnlyFromValidatorContract() public {
        vm.prank(coinbase);
        vm.expectRevert();
        stakeHub.noteValidatorSetUpdate();
        vm.prank(VALIDATOR_CONTRACT_ADDR);
        stakeHub.noteValidatorSetUpdate();
        assertEq(stakeHub.lastValidatorSetUpdateBlock(), block.number);
    }

    // The coinbase can no longer call an inflation entry point (it minted on
    // DashEVM and let a rotated coinbase freeze rotations at will).
    function testNoInflationEntryPoint() public {
        vm.deal(coinbase, 1 ether);
        vm.prank(coinbase);
        (bool ok,) = STAKE_HUB_ADDR.call{ value: 1 ether }(abi.encodeWithSignature("distributeStakingInflation()"));
        assertFalse(ok);
    }

    // Half of every fee deposit goes to the FeeVault; nothing to 0xdEaD; no system reward share.
    function testFeesGoToFeeVaultNotBurned() public {
        vm.etch(FEE_VAULT, vm.getDeployedCode("FeeVault.sol:FeeVault"));
        _three();
        _breathe();
        IFLValidatorSet vs = IFLValidatorSet(VALIDATOR_CONTRACT_ADDR);
        uint256 deadBefore = address(0xdEaD).balance;
        vm.deal(coinbase, 10 ether);
        vm.prank(coinbase);
        vs.deposit{ value: 10 ether }(consensusAddrs[0]);
        assertEq(FEE_VAULT.balance, 5 ether);
        assertEq(address(0xdEaD).balance, deadBefore);
        assertEq(vs.systemRewardBaseRatio(), 0);
        assertEq(vs.burnRatio(), 5000);
    }

    function testFeeVaultFlushOnlyToGovernanceTarget() public {
        vm.etch(FEE_VAULT, vm.getDeployedCode("FeeVault.sol:FeeVault"));
        vm.deal(FEE_VAULT, 3 ether);
        (bool ok,) = FEE_VAULT.call(abi.encodeWithSignature("flush()"));
        assertFalse(ok); // no target yet: the coins stay
        (ok,) = FEE_VAULT.call(abi.encodeWithSignature("setTarget(address)", address(this)));
        assertFalse(ok); // only the timelock
        vm.prank(0x0000000000000000000000000000000000002006);
        (ok,) = FEE_VAULT.call(abi.encodeWithSignature("setTarget(address)", address(0xBEEF)));
        assertTrue(ok);
        (ok,) = FEE_VAULT.call(abi.encodeWithSignature("flush()"));
        assertTrue(ok);
        assertEq(address(0xBEEF).balance, 3 ether);
    }

    // N-5: no APR is advertised and governance cannot turn one on.
    function testNoStakingApr() public {
        assertEq(stakeHub.stakingAprBps(), 0);
        assertEq(stakeHub.validatorRewardBps(), 0);
        vm.prank(GOV_HUB_ADDR);
        vm.expectRevert();
        stakeHub.updateParam("stakingAprBps", abi.encode(uint256(1200)));
    }
}
