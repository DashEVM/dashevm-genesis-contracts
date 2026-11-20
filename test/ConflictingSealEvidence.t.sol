pragma solidity ^0.8.10;

import "forge-std/Test.sol";
import "./BridgeChainStakeHub.t.sol";

// DashEVM / CardanoEVM: slashable conflicting seal (ICP-SPEC section 3,
// "Repeat holds"). The real SlashIndicator runs against mocked neighbours:
// the 0x0f02 precompile (its ML-DSA checks are Go tests in
// core/vm/contracts_sealevidence_test.go), the EIP-2935 history contract,
// BSCValidatorSet, StakeHub and SystemReward.
interface ISlashIndicatorSeal {
    function init() external;
    function submitConflictingSealEvidence(bytes memory canonicalHeader, bytes memory conflictingHeader) external;
    function sealConflictSeconds() external view returns (uint256);
    function conflictingSealFullPenalty() external view returns (bool);
    function sealConflictDepthNow() external view returns (uint256);
    function updateParam(string calldata key, bytes calldata value) external;
}

interface IStakeHubSlash {
    function consensusToOperator(address) external view returns (address);
    function doubleSignSlash(address) external;
    function conflictingSealJail(address) external;
}

interface IValidatorSetSlash {
    function getMiningValidators() external view returns (address[] memory, bytes[] memory);
    function getTurnLength() external view returns (uint256);
    function felony(address) external;
}

interface ISystemRewardClaim {
    function claimRewards(address payable to, uint256 amount) external returns (uint256);
}

interface IBlockhashCheat {
    function setBlockhash(uint256 blockNumber, bytes32 blockHash) external;
}

contract ConflictingSealEvidenceTest is Test {
    event conflictingSealSlashed(address indexed validator, uint256 canonicalNumber, uint256 conflictingNumber);

    address constant VALIDATOR = 0x0000000000000000000000000000000000001000;
    address constant SLASH = 0x0000000000000000000000000000000000001001;
    address payable constant SYSTEM_REWARD = payable(0x0000000000000000000000000000000000001002);
    address constant GOV_HUB = 0x0000000000000000000000000000000000001007;
    address constant STAKE_HUB = 0x0000000000000000000000000000000000002002;
    address constant PRECOMPILE = address(0x0f02);
    address constant HISTORY = 0x0000F90827F1C53a10cb7A02335B175320002935;

    ISlashIndicatorSeal slash = ISlashIndicatorSeal(SLASH);
    address signer = address(0x5160);
    address submitter = address(0xA11CE);

    function setUp() public {
        vm.etch(SLASH, vm.getDeployedCode("SlashIndicator.sol:SlashIndicator"));
        vm.etch(PRECOMPILE, hex"00");
        vm.etch(HISTORY, hex"00");
        vm.etch(VALIDATOR, hex"00");
        vm.etch(STAKE_HUB, hex"00");
        vm.etch(SYSTEM_REWARD, hex"00");
        vm.deal(SYSTEM_REWARD, 100 ether);
        slash.init();
        vm.roll(50_000);
        _validators(3, 1);
        vm.mockCall(STAKE_HUB, abi.encodeCall(IStakeHubSlash.consensusToOperator, (signer)), abi.encode(address(0x0123)));
        vm.mockCall(STAKE_HUB, abi.encodeCall(IStakeHubSlash.doubleSignSlash, (signer)), "");
        vm.mockCall(STAKE_HUB, abi.encodeCall(IStakeHubSlash.conflictingSealJail, (signer)), "");
        vm.mockCall(VALIDATOR, abi.encodeCall(IValidatorSetSlash.felony, (signer)), "");
        vm.mockCall(SYSTEM_REWARD, abi.encodeWithSelector(ISystemRewardClaim.claimRewards.selector), abi.encode(uint256(0)));
    }

    function _validators(uint256 n, uint256 turnLength) internal {
        address[] memory vals = new address[](n);
        bytes[] memory votes = new bytes[](n);
        vm.mockCall(VALIDATOR, abi.encodeCall(IValidatorSetSlash.getMiningValidators, ()), abi.encode(vals, votes));
        vm.mockCall(VALIDATOR, abi.encodeCall(IValidatorSetSlash.getTurnLength, ()), abi.encode(turnLength));
    }

    function _evidence(address who, uint256 aNum, bytes32 aHash, uint256 bNum) internal {
        vm.mockCall(PRECOMPILE, bytes(""), abi.encode(who, aNum, aHash, bNum, keccak256("b")));
    }

    function _history(uint256 n, bytes32 h) internal {
        vm.mockCall(HISTORY, abi.encode(n), abi.encode(h));
    }

    function _setSeconds(uint256 secs) internal {
        vm.prank(GOV_HUB);
        slash.updateParam("sealConflictSeconds", abi.encode(secs));
    }

    function testDepthIsTimeWithLightClientFloor() public {
        // default 1 hour of 3 s blocks; light client floor 2 * 50 * 1 = 100
        assertEq(slash.sealConflictDepthNow(), 1200);
        _setSeconds(600);
        assertEq(slash.sealConflictDepthNow(), 200);
        // turnLength 4: floor 2 * 50 * 4 = 400 > 200
        _validators(21, 4);
        assertEq(slash.sealConflictDepthNow(), 400);
        _setSeconds(5 hours);
        assertEq(slash.sealConflictDepthNow(), 6000);
        vm.prank(GOV_HUB);
        vm.expectRevert("the sealConflictSeconds out of range");
        slash.updateParam("sealConflictSeconds", abi.encode(uint256(599)));
        vm.prank(GOV_HUB);
        vm.expectRevert("the sealConflictSeconds out of range");
        slash.updateParam("sealConflictSeconds", abi.encode(uint256(5 hours + 1)));
        vm.expectRevert();
        slash.updateParam("sealConflictSeconds", abi.encode(uint256(3600))); // not governance
    }

    // Default penalty: jail only (no stake slash, no eviction).
    function testConflictingSealJailsOnly() public {
        uint256 aNum = block.number - 1000; // EIP-2935 range
        bytes32 aHash = keccak256("canonical");
        uint256 bNum = aNum - slash.sealConflictDepthNow();
        _history(aNum, aHash);
        _evidence(signer, aNum, aHash, bNum);

        vm.expectCall(STAKE_HUB, abi.encodeCall(IStakeHubSlash.conflictingSealJail, (signer)));
        vm.expectCall(STAKE_HUB, abi.encodeCall(IStakeHubSlash.doubleSignSlash, (signer)), 0);
        vm.expectCall(VALIDATOR, abi.encodeCall(IValidatorSetSlash.felony, (signer)), 0);
        vm.expectCall(SYSTEM_REWARD, abi.encodeCall(ISystemRewardClaim.claimRewards, (payable(submitter), 20 ether)));
        vm.expectEmit(true, false, false, true, SLASH);
        emit conflictingSealSlashed(signer, aNum, bNum);
        vm.prank(submitter);
        slash.submitConflictingSealEvidence(hex"01", hex"02");
    }

    // Governance switches to the double-sign penalty once the light client
    // has its timestamp-recency rule.
    function testFullPenaltyByGovernance() public {
        vm.prank(GOV_HUB);
        slash.updateParam("conflictingSealFullPenalty", abi.encode(true));
        assertTrue(slash.conflictingSealFullPenalty());
        uint256 aNum = block.number - 1000;
        bytes32 aHash = keccak256("canonical");
        _history(aNum, aHash);
        _evidence(signer, aNum, aHash, aNum - slash.sealConflictDepthNow());
        vm.expectCall(STAKE_HUB, abi.encodeCall(IStakeHubSlash.doubleSignSlash, (signer)));
        vm.expectCall(VALIDATOR, abi.encodeCall(IValidatorSetSlash.felony, (signer)));
        vm.expectCall(STAKE_HUB, abi.encodeCall(IStakeHubSlash.conflictingSealJail, (signer)), 0);
        slash.submitConflictingSealEvidence(hex"01", hex"02");
    }

    function testRecentCanonicalUsesBlockhash() public {
        uint256 aNum = block.number - 10;
        bytes32 aHash = keccak256("recent");
        IBlockhashCheat(address(vm)).setBlockhash(aNum, aHash);
        _evidence(signer, aNum, aHash, aNum - 1200);
        vm.expectCall(STAKE_HUB, abi.encodeCall(IStakeHubSlash.conflictingSealJail, (signer)));
        slash.submitConflictingSealEvidence(hex"01", hex"02");
    }

    function testNotCanonicalReverts() public {
        uint256 aNum = block.number - 1000;
        _history(aNum, keccak256("other"));
        _evidence(signer, aNum, keccak256("canonical"), aNum - 1200);
        vm.expectRevert("not canonical");
        slash.submitConflictingSealEvidence(hex"01", hex"02");
    }

    function testOutsideHistoryReverts() public {
        // nothing recorded (older than 8191 blocks): the history call returns no data
        uint256 aNum = block.number - 9000;
        _evidence(signer, aNum, keccak256("canonical"), aNum - 1200);
        vm.expectRevert("not canonical");
        slash.submitConflictingSealEvidence(hex"01", hex"02");
        // the current block or later
        _evidence(signer, block.number, keccak256("canonical"), block.number - 1200);
        vm.expectRevert("not canonical");
        slash.submitConflictingSealEvidence(hex"01", hex"02");
    }

    function testNotDeepEnoughReverts() public {
        uint256 aNum = block.number - 1000;
        bytes32 aHash = keccak256("canonical");
        _history(aNum, aHash);
        _evidence(signer, aNum, aHash, aNum - slash.sealConflictDepthNow() + 1);
        vm.expectRevert("conflict not deep enough");
        slash.submitConflictingSealEvidence(hex"01", hex"02");
    }

    function testUnknownSignerReverts() public {
        uint256 aNum = block.number - 1000;
        bytes32 aHash = keccak256("canonical");
        _history(aNum, aHash);
        address stranger = address(0xBEEF);
        vm.mockCall(STAKE_HUB, abi.encodeCall(IStakeHubSlash.consensusToOperator, (stranger)), abi.encode(address(0)));
        _evidence(stranger, aNum, aHash, aNum - 1200);
        vm.expectRevert("validator not migrated");
        slash.submitConflictingSealEvidence(hex"01", hex"02");
    }

    function testPrecompileAbsentReverts() public {
        // before ParliaConfig.SealEvidenceBlock 0x0f02 has no precompile: no return data
        vm.expectRevert("invalid evidence");
        slash.submitConflictingSealEvidence(hex"01", hex"02");
        vm.expectRevert("empty header");
        slash.submitConflictingSealEvidence(hex"", hex"02");
    }

    function testStakeHubRevertBubbles() public {
        uint256 aNum = block.number - 1000;
        bytes32 aHash = keccak256("canonical");
        _history(aNum, aHash);
        _evidence(signer, aNum, aHash, aNum - 1200);
        vm.mockCallRevert(STAKE_HUB, abi.encodeCall(IStakeHubSlash.conflictingSealJail, (signer)), "AlreadySlashed");
        vm.expectRevert(bytes("AlreadySlashed"));
        slash.submitConflictingSealEvidence(hex"01", hex"02");
    }
}

// The real StakeHub penalty: jail only, no stake slashed, no eviction call.
contract ConflictingSealJailStakeHubTest is BridgeChainStakeHubTest {
    function testConflictingSealJailIsJailOnly() public {
        _three();
        address consensus = consensusAddrs[0];
        (, bool jailedBefore,) = stakeHub.getValidatorBasicInfo(operators[0]);
        assertFalse(jailedBefore);
        uint256 credit = address(stakeHub.getValidatorCreditContract(operators[0])).balance;
        vm.expectCall(VALIDATOR_CONTRACT_ADDR, abi.encodeWithSignature("felony(address)", consensus), 0);
        vm.prank(SLASH_ADDR);
        stakeHub.conflictingSealJail(consensus);
        (, bool jailed, uint256 jailUntil) = stakeHub.getValidatorBasicInfo(operators[0]);
        assertTrue(jailed);
        assertEq(jailUntil, block.timestamp + stakeHub.downtimeJailTime());
        assertEq(address(stakeHub.getValidatorCreditContract(operators[0])).balance, credit, "no stake slashed");
        assertTrue(stakeHub.isConsensusJailed(consensus));
        // the same offence again while jailed
        vm.prank(SLASH_ADDR);
        vm.expectRevert(StakeHub.AlreadySlashed.selector);
        stakeHub.conflictingSealJail(consensus);
        // only SlashIndicator
        vm.expectRevert();
        stakeHub.conflictingSealJail(consensusAddrs[1]);
    }
}
