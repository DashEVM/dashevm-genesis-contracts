pragma solidity 0.6.4;
pragma experimental ABIEncoderV2;

import "./System.sol";
import "./lib/0.6.x/BytesToTypes.sol";
import "./lib/0.6.x/TypesToBytes.sol";
import "./lib/0.6.x/BytesLib.sol";
import "./lib/0.6.x/Memory.sol";
import "./interface/0.6.x/ISlashIndicator.sol";
import "./interface/0.6.x/IApplication.sol";
import "./interface/0.6.x/IBSCValidatorSet.sol";
import "./interface/0.6.x/IParamSubscriber.sol";
import "./interface/0.6.x/ISystemReward.sol";
import "./interface/0.6.x/IStakeHub.sol";
import "./lib/0.6.x/RLPEncode.sol";

// DashEVM / CardanoEVM: the validator set views the conflicting seal evidence
// depth needs (BSCValidatorSet implements both).
interface IValidatorSetDepthView {
    function getTurnLength() external view returns (uint256);
}

contract SlashIndicator is ISlashIndicator, System, IParamSubscriber, IApplication {
    using RLPEncode for *;

    uint256 public constant MISDEMEANOR_THRESHOLD = 50;
    uint256 public constant FELONY_THRESHOLD = 150;
    uint256 public constant DECREASE_RATE = 4;

    // State of the contract
    address[] public validators;
    mapping(address => Indicator) public indicators;
    uint256 public previousHeight;

    // The BSC validators assign proper values for `misdemeanorThreshold` and `felonyThreshold` through governance.
    // The proper values depends on BSC network's tolerance for continuous missing blocks.
    uint256 public misdemeanorThreshold;
    uint256 public felonyThreshold;

    // BEP-126 Fast Finality
    // @notice change name from `INIT_FINALITY_SLASH_REWARD_RATIO` to `INIT_FELONY_SLASH_REWARD_RATIO` after BC-fusion
    uint256 public constant INIT_FELONY_SLASH_REWARD_RATIO = 20;

    // @notice change name from `finalitySlashRewardRatio` to `felonySlashRewardRatio` after BC-fusion
    uint256 public felonySlashRewardRatio;
    bool public enableMaliciousVoteSlash;

    uint256 public constant INIT_FELONY_SLASH_SCOPE = 28800; // 1 days(block number)

    uint256 public felonySlashScope;

    // DashEVM / CardanoEVM conflicting seal evidence (ICP-SPEC section 3,
    // "Repeat holds"; ICP review 4 N-M3). Precompile 0x0f02 exists only
    // from ParliaConfig.SealEvidenceBlock on; before that the call returns
    // nothing and every submission reverts.
    address public constant SEAL_EVIDENCE_PRECOMPILE = 0x0000000000000000000000000000000000000f02;
    // EIP-2935 history contract (block hashes of the last 8191 blocks).
    address public constant HISTORY_STORAGE_ADDR = 0x0000F90827F1C53a10cb7A02335B175320002935;
    // The conflict depth is a time (chain-guard review H-1): B must be
    // at least this many seconds of canonical chain below A. Canonical blocks
    // are at least BLOCK_INTERVAL apart (Parlia, 3 s on these chains), so
    // ceil(seconds / BLOCK_INTERVAL) blocks of depth are at least that long.
    uint256 public constant BLOCK_INTERVAL = 3;
    uint256 public constant INIT_SEAL_CONFLICT_SECONDS = 1 hours;
    uint256 public constant MIN_SEAL_CONFLICT_SECONDS = 10 minutes;
    // A must lie in the EIP-2935 history (8191 blocks, about 6.8 hours at
    // 3 s) when the evidence lands, so the depth stays well inside it.
    uint256 public constant MAX_SEAL_CONFLICT_SECONDS = 5 hours;
    // Upper bound of the consensus set size N (the epoch Extra set, pending
    // removals included, never exceeds the elected maximum of 50), so the
    // light client's finality depth 2 * N * turnLength is never undercut.
    uint256 public constant MAX_CONSENSUS_N = 50;
    uint256 public sealConflictSeconds; // 0 = INIT_SEAL_CONFLICT_SECONDS
    // false (default): jail only (StakeHub.conflictingSealJail). Governance
    // sets it to true (updateParam "conflictingSealFullPenalty") once the
    // light client counts competing branches only with recent timestamps;
    // then the double-sign penalty applies (slash, long jail, eviction).
    bool public conflictingSealFullPenalty;

    event validatorSlashed(address indexed validator);
    event indicatorCleaned();
    event paramChange(string key, bytes value);
    event failedFelony(address indexed validator, uint256 slashCount, bytes failReason);
    event conflictingSealSlashed(address indexed validator, uint256 canonicalNumber, uint256 conflictingNumber);

    event maliciousVoteSlashed(bytes32 indexed voteAddrSlice);  // @dev deprecated
    event knownResponse(uint32 code);  // @dev deprecated
    event unKnownResponse(uint32 code);  // @dev deprecated
    event crashResponse();  // @dev deprecated

    struct Indicator {
        uint256 height;
        uint256 count;
        bool exist;
    }

    // Proof that a validator misbehaved in fast finality
    struct VoteData {
        uint256 srcNum;
        bytes32 srcHash;
        uint256 tarNum;
        bytes32 tarHash;
        bytes sig;
    }

    struct FinalityEvidence {
        VoteData voteA;
        VoteData voteB;
        bytes voteAddr;
    }

    modifier oncePerBlock() {
        require(block.number > previousHeight, "can not slash twice in one block");
        _;
        previousHeight = block.number;
    }

    function init() external onlyNotInit {
        misdemeanorThreshold = MISDEMEANOR_THRESHOLD;
        felonyThreshold = FELONY_THRESHOLD;
        alreadyInit = true;
    }

    /*----------------- Implement cross chain app -----------------*/
    function handleSynPackage(
        uint8,
        bytes calldata
    ) external override onlyCrossChainContract onlyInit returns (bytes memory) {
        revert("deprecated");
    }

    function handleAckPackage(uint8, bytes calldata msgBytes) external override onlyCrossChainContract onlyInit {
        revert("deprecated");
    }

    function handleFailAckPackage(uint8, bytes calldata) external override onlyCrossChainContract onlyInit {
        revert("deprecated");
    }

    /*----------------- External func -----------------*/
    /**
     * @dev Slash the validator who should have produced the current block
     *
     * @param validator The validator who should have produced the current block
     */
    function slash(address validator) external onlyCoinbase onlyInit oncePerBlock onlyZeroGasPrice {
        if (!IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).isCurrentValidator(validator)) {
            return;
        }
        // DashEVM: a consensus key replaced through StakeHub.editConsensusAddress
        // may not seal any more (the node rejects it), and the new key only seals
        // after the next breathe block. Those missed slots are not downtime.
        if (IStakeHub(STAKE_HUB_ADDR).consensusExpiration(validator) != 0) {
            return;
        }
        Indicator memory indicator = indicators[validator];
        if (indicator.exist) {
            ++indicator.count;
        } else {
            indicator.exist = true;
            indicator.count = 1;
            validators.push(validator);
        }
        indicator.height = block.number;
        if (indicator.count % felonyThreshold == 0) {
            indicator.count = 0;
            IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).felony(validator);
            _downtimeSlash(validator, indicator.count, false);
        } else if (indicator.count % misdemeanorThreshold == 0) {
            IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).misdemeanor(validator);
        }
        indicators[validator] = indicator;
        emit validatorSlashed(validator);
    }

    // To prevent validator misbehaving and leaving, do not clean slash record to zero, but decrease by felonyThreshold/DECREASE_RATE .
    // Clean is an effective implement to reorganize "validators" and "indicators".
    function clean() external override(ISlashIndicator) onlyValidatorContract onlyInit {
        if (validators.length == 0) {
            return;
        }
        uint256 i;
        uint256 j = validators.length - 1;
        for (; i <= j;) {
            bool findLeft = false;
            bool findRight = false;
            for (; i < j; ++i) {
                Indicator memory leftIndicator = indicators[validators[i]];
                if (leftIndicator.count > felonyThreshold / DECREASE_RATE) {
                    leftIndicator.count = leftIndicator.count - felonyThreshold / DECREASE_RATE;
                    indicators[validators[i]] = leftIndicator;
                } else {
                    findLeft = true;
                    break;
                }
            }
            for (; i <= j; --j) {
                Indicator memory rightIndicator = indicators[validators[j]];
                if (rightIndicator.count > felonyThreshold / DECREASE_RATE) {
                    rightIndicator.count = rightIndicator.count - felonyThreshold / DECREASE_RATE;
                    indicators[validators[j]] = rightIndicator;
                    findRight = true;
                    break;
                } else {
                    delete indicators[validators[j]];
                    validators.pop();
                }
                // avoid underflow
                if (j == 0) {
                    break;
                }
            }
            // swap element in array
            if (findLeft && findRight) {
                delete indicators[validators[i]];
                validators[i] = validators[j];
                validators.pop();
            }
            // avoid underflow
            if (j == 0) {
                break;
            }
            // move to next
            ++i;
            --j;
        }
        emit indicatorCleaned();
    }

    function downtimeSlash(
        address validator,
        uint256 count,
        bool shouldRevert
    ) external override onlyValidatorContract {
        _downtimeSlash(validator, count, shouldRevert);
    }

    function _downtimeSlash(address validator, uint256 count, bool shouldRevert) internal {
        if (shouldRevert) {
            IStakeHub(STAKE_HUB_ADDR).downtimeSlash(validator);
        } else {
            try IStakeHub(STAKE_HUB_ADDR).downtimeSlash(validator) { }
            catch Error(string memory reason) {
                emit failedFelony(validator, count, bytes(reason));
            } catch (bytes memory lowLevelData) {
                emit failedFelony(validator, count, lowLevelData);
            }
        }
    }

    function submitFinalityViolationEvidence(FinalityEvidence memory _evidence) public onlyInit {
        require(enableMaliciousVoteSlash, "malicious vote slash not enabled");
        if (felonySlashRewardRatio == 0) {
            felonySlashRewardRatio = INIT_FELONY_SLASH_REWARD_RATIO;
        }
        if (felonySlashScope == 0) {
            felonySlashScope = INIT_FELONY_SLASH_SCOPE;
        }

        // Basic check
        require(
            _evidence.voteA.tarNum + felonySlashScope > block.number
                && _evidence.voteB.tarNum + felonySlashScope > block.number,
            "target block too old"
        );
        require(
            !(_evidence.voteA.srcHash == _evidence.voteB.srcHash && _evidence.voteA.tarHash == _evidence.voteB.tarHash),
            "two identical votes"
        );
        require(
            _evidence.voteA.srcNum < _evidence.voteA.tarNum && _evidence.voteB.srcNum < _evidence.voteB.tarNum,
            "srcNum bigger than tarNum"
        );

        // Vote rules check
        require(
            (_evidence.voteA.srcNum < _evidence.voteB.srcNum && _evidence.voteB.tarNum < _evidence.voteA.tarNum)
                || (_evidence.voteB.srcNum < _evidence.voteA.srcNum && _evidence.voteA.tarNum < _evidence.voteB.tarNum)
                || _evidence.voteA.tarNum == _evidence.voteB.tarNum,
            "no violation of vote rules"
        );

        // check voteAddr to protect validators from being slashed for old voteAddr
        require(
            IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).isMonitoredForMaliciousVote(_evidence.voteAddr),
            "voteAddr is not found"
        );

        // BLS verification
        require(
            _verifyBLSSignature(_evidence.voteA, _evidence.voteAddr)
                && _verifyBLSSignature(_evidence.voteB, _evidence.voteAddr),
            "verify signature failed"
        );

        // reward sender and felony validator if validator found
        (address[] memory vals, bytes[] memory voteAddrs) =
            IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).getLivingValidators();
        for (uint256 i; i < voteAddrs.length; ++i) {
            if (BytesLib.equal(voteAddrs[i], _evidence.voteAddr)) {
                uint256 amount = (address(SYSTEM_REWARD_ADDR).balance * felonySlashRewardRatio) / 100;
                ISystemReward(SYSTEM_REWARD_ADDR).claimRewards(msg.sender, amount);
                IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).felony(vals[i]);
                break;
            }
        }

        IStakeHub(STAKE_HUB_ADDR).maliciousVoteSlash(_evidence.voteAddr);
    }

    function submitDoubleSignEvidence(bytes memory header1, bytes memory header2) public onlyInit {
        if (felonySlashRewardRatio == 0) {
            felonySlashRewardRatio = INIT_FELONY_SLASH_REWARD_RATIO;
        }
        if (felonySlashScope == 0) {
            felonySlashScope = INIT_FELONY_SLASH_SCOPE;
        }

        require(header1.length != 0 && header2.length != 0, "empty header");

        // DashEVM: header seals commit to the real chain id (20261012), which
        // does not fit the uint16 bscChainID constant.
        uint256 sealChainId;
        assembly {
            sealChainId := chainid()
        }
        bytes[] memory elements = new bytes[](3);
        elements[0] = sealChainId.encodeUint();
        elements[1] = header1.encodeBytes();
        elements[2] = header2.encodeBytes();

        // call precompile contract to verify evidence
        bytes memory input = elements.encodeList();
        bytes memory output = new bytes(52);
        assembly {
            let len := mload(input)
            if iszero(staticcall(not(0), 0x68, add(input, 0x20), len, add(output, 0x20), 0x34)) { revert(0, 0) }
        }

        address signer;
        uint256 evidenceHeight;
        assembly {
            signer := mload(add(output, 0x14))
            evidenceHeight := mload(add(output, 0x34))
        }
        require(IStakeHub(STAKE_HUB_ADDR).consensusToOperator(signer) != address(0), "validator not migrated");
        require(evidenceHeight + felonySlashScope >= block.number, "evidence too old");

        // reward sender and felony validator
        IStakeHub(STAKE_HUB_ADDR).doubleSignSlash(signer);
        IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).felony(signer);

        uint256 amount = (address(SYSTEM_REWARD_ADDR).balance * felonySlashRewardRatio) / 100;
        ISystemReward(SYSTEM_REWARD_ADDR).claimRewards(msg.sender, amount);
    }

    /**
     * @notice DashEVM / CardanoEVM: slash a validator that sealed a block
     * conflicting with history it had itself built on (ICP-SPEC section 3).
     * Anyone may submit (the bridge guardian does). The evidence is two
     * headers sealed by the same ML-DSA key:
     * - `canonicalHeader` (A) is on this chain (its hash is the canonical hash
     *   at its height: blockhash or the EIP-2935 history, so within the last
     *   8191 blocks);
     * - `conflictingHeader` (B) is at least `sealConflictDepthNow()` blocks
     *   lower than A but stamped strictly later than A.
     * Canonical timestamps increase with height, so B is not the canonical
     * block at its height: the signer sealed a block conflicting with a hash
     * that was already that deep in the chain it had sealed on top of. The
     * precompile checks both seals and the order; this function checks A is
     * canonical and the depth, then JAILS the signer (StakeHub
     * conflictingSealJail: no stake slashed, no eviction). Only when
     * governance has set `conflictingSealFullPenalty` does it apply the
     * double-sign penalty (slash, long jail, eviction).
     */
    function submitConflictingSealEvidence(
        bytes memory canonicalHeader,
        bytes memory conflictingHeader
    ) public onlyInit {
        if (felonySlashRewardRatio == 0) {
            felonySlashRewardRatio = INIT_FELONY_SLASH_REWARD_RATIO;
        }
        require(canonicalHeader.length != 0 && conflictingHeader.length != 0, "empty header");

        uint256 sealChainId;
        assembly {
            sealChainId := chainid()
        }
        bytes[] memory elements = new bytes[](3);
        elements[0] = sealChainId.encodeUint();
        elements[1] = canonicalHeader.encodeBytes();
        elements[2] = conflictingHeader.encodeBytes();
        bytes memory input = elements.encodeList();

        bytes memory output = new bytes(160);
        address precompile = SEAL_EVIDENCE_PRECOMPILE;
        bool ok;
        uint256 size;
        assembly {
            ok := staticcall(gas(), precompile, add(input, 0x20), mload(input), add(output, 0x20), 160)
            size := returndatasize()
        }
        require(ok && size == 160, "invalid evidence");
        (address signer, uint256 canonicalNumber, bytes32 canonicalHash, uint256 conflictingNumber,) =
            abi.decode(output, (address, uint256, bytes32, uint256, bytes32));

        bytes32 known = _canonicalHash(canonicalNumber);
        require(known != bytes32(0) && known == canonicalHash, "not canonical");
        require(conflictingNumber + sealConflictDepthNow() <= canonicalNumber, "conflict not deep enough");
        require(IStakeHub(STAKE_HUB_ADDR).consensusToOperator(signer) != address(0), "validator not migrated");

        if (conflictingSealFullPenalty) {
            IStakeHub(STAKE_HUB_ADDR).doubleSignSlash(signer);
            IBSCValidatorSet(VALIDATOR_CONTRACT_ADDR).felony(signer);
        } else {
            IStakeHub(STAKE_HUB_ADDR).conflictingSealJail(signer);
        }
        emit conflictingSealSlashed(signer, canonicalNumber, conflictingNumber);

        uint256 amount = (address(SYSTEM_REWARD_ADDR).balance * felonySlashRewardRatio) / 100;
        ISystemReward(SYSTEM_REWARD_ADDR).claimRewards(msg.sender, amount);
    }

    /**
     * @notice The depth in blocks the conflicting header must lie below the
     * canonical one: `sealConflictSeconds` (default 1 hour) of 3 s blocks,
     * never below the light client's finality depth 2 * N * turnLength with N
     * at its maximum.
     */
    function sealConflictDepthNow() public view returns (uint256) {
        uint256 secs = sealConflictSeconds == 0 ? INIT_SEAL_CONFLICT_SECONDS : sealConflictSeconds;
        uint256 depth = (secs + BLOCK_INTERVAL - 1) / BLOCK_INTERVAL;
        uint256 finality = 2 * MAX_CONSENSUS_N * IValidatorSetDepthView(VALIDATOR_CONTRACT_ADDR).getTurnLength();
        return finality > depth ? finality : depth;
    }

    function _canonicalHash(uint256 number) internal view returns (bytes32 h) {
        if (number >= block.number) {
            return bytes32(0);
        }
        if (block.number - number <= 256) {
            return blockhash(number);
        }
        (bool ok, bytes memory ret) = HISTORY_STORAGE_ADDR.staticcall(abi.encode(number));
        if (ok && ret.length == 32) {
            h = abi.decode(ret, (bytes32));
        }
    }

    /**
     * @dev Send a felony cross-chain package to jail a validator
     *
     * @param validator Who will be jailed
     */
    function sendFelonyPackage(address validator) external override(ISlashIndicator) onlyValidatorContract onlyInit {
        emit failedFelony(validator, 0, "deprecated");
    }

    function _verifyBLSSignature(VoteData memory vote, bytes memory voteAddr) internal view returns (bool) {
        bytes[] memory elements = new bytes[](4);
        bytes memory _bytes = new bytes(32);
        elements[0] = vote.srcNum.encodeUint();
        TypesToBytes.bytes32ToBytes(32, vote.srcHash, _bytes);
        elements[1] = _bytes.encodeBytes();
        elements[2] = vote.tarNum.encodeUint();
        TypesToBytes.bytes32ToBytes(32, vote.tarHash, _bytes);
        elements[3] = _bytes.encodeBytes();

        TypesToBytes.bytes32ToBytes(32, keccak256(elements.encodeList()), _bytes);

        // assemble input data
        bytes memory input = new bytes(176);
        _bytesConcat(input, _bytes, 0, 32);
        _bytesConcat(input, vote.sig, 32, 96);
        _bytesConcat(input, voteAddr, 128, 48);

        // call the precompiled contract to verify the BLS signature
        // the precompiled contract's address is 0x66
        bytes memory output = new bytes(1);
        assembly {
            let len := mload(input)
            if iszero(staticcall(not(0), 0x66, add(input, 0x20), len, add(output, 0x20), 0x01)) { revert(0, 0) }
        }
        if (BytesLib.toUint8(output, 0) != uint8(1)) {
            return false;
        }
        return true;
    }

    function _bytesConcat(bytes memory data, bytes memory _bytes, uint256 index, uint256 len) internal pure {
        for (uint256 i; i < len; ++i) {
            data[index++] = _bytes[i];
        }
    }

    /*----------------- Param update -----------------*/
    function updateParam(string calldata key, bytes calldata value) external override onlyInit onlyGov {
        if (Memory.compareStrings(key, "misdemeanorThreshold")) {
            require(value.length == 32, "length of misdemeanorThreshold mismatch");
            uint256 newMisdemeanorThreshold = BytesToTypes.bytesToUint256(32, value);
            require(
                newMisdemeanorThreshold >= 1 && newMisdemeanorThreshold < felonyThreshold,
                "the misdemeanorThreshold out of range"
            );
            misdemeanorThreshold = newMisdemeanorThreshold;
        } else if (Memory.compareStrings(key, "felonyThreshold")) {
            require(value.length == 32, "length of felonyThreshold mismatch");
            uint256 newFelonyThreshold = BytesToTypes.bytesToUint256(32, value);
            require(
                newFelonyThreshold <= 1000 && newFelonyThreshold > misdemeanorThreshold,
                "the felonyThreshold out of range"
            );
            // DashEVM: clean() decays by felonyThreshold / DECREASE_RATE per
            // day; below DECREASE_RATE that is 0, entries never expire and the
            // breathe-block clean() grows without bound.
            require(newFelonyThreshold >= DECREASE_RATE, "the felonyThreshold must be at least DECREASE_RATE");
            felonyThreshold = newFelonyThreshold;
        } else if (Memory.compareStrings(key, "felonySlashRewardRatio")) {
            require(value.length == 32, "length of felonySlashRewardRatio mismatch");
            uint256 newFelonySlashRewardRatio = BytesToTypes.bytesToUint256(32, value);
            require(
                newFelonySlashRewardRatio >= 10 && newFelonySlashRewardRatio < 100,
                "the felony slash reward ratio out of range"
            );
            felonySlashRewardRatio = newFelonySlashRewardRatio;
        } else if (Memory.compareStrings(key, "enableMaliciousVoteSlash")) {
            require(value.length == 32, "length of enableMaliciousVoteSlash mismatch");
            enableMaliciousVoteSlash = BytesToTypes.bytesToBool(32, value);
        } else if (Memory.compareStrings(key, "felonySlashScope")) {
            require(value.length == 32, "length of felonySlashScope mismatch");
            uint256 newMaliciousVoteSlashScope = BytesToTypes.bytesToUint256(32, value);
            require(
                newMaliciousVoteSlashScope >= 28800 * 1 && newMaliciousVoteSlashScope < 28800 * 30,
                "the malicious vote slash scope out of range"
            );
            felonySlashScope = newMaliciousVoteSlashScope;
        } else if (Memory.compareStrings(key, "sealConflictSeconds")) {
            require(value.length == 32, "length of sealConflictSeconds mismatch");
            uint256 newSealConflictSeconds = BytesToTypes.bytesToUint256(32, value);
            require(
                newSealConflictSeconds >= MIN_SEAL_CONFLICT_SECONDS
                    && newSealConflictSeconds <= MAX_SEAL_CONFLICT_SECONDS,
                "the sealConflictSeconds out of range"
            );
            sealConflictSeconds = newSealConflictSeconds;
        } else if (Memory.compareStrings(key, "conflictingSealFullPenalty")) {
            require(value.length == 32, "length of conflictingSealFullPenalty mismatch");
            conflictingSealFullPenalty = BytesToTypes.bytesToBool(32, value);
        } else {
            require(false, "unknown param");
        }
        emit paramChange(key, value);
    }

    /*----------------- query api -----------------*/
    function getSlashIndicator(address validator) external view returns (uint256, uint256) {
        Indicator memory indicator = indicators[validator];
        return (indicator.height, indicator.count);
    }

    function encodeSlashPackage(address valAddr) internal view returns (bytes memory) {
        bytes[] memory elements = new bytes[](4);
        elements[0] = valAddr.encodeAddress();
        elements[1] = uint256(block.number).encodeUint();
        elements[2] = uint256(bscChainID).encodeUint();
        elements[3] = uint256(block.timestamp).encodeUint();
        return elements.encodeList();
    }

    function encodeVoteSlashPackage(bytes memory voteAddr) internal view returns (bytes memory) {
        bytes[] memory elements = new bytes[](4);
        elements[0] = voteAddr.encodeBytes();
        elements[1] = uint256(block.number).encodeUint();
        elements[2] = uint256(bscChainID).encodeUint();
        elements[3] = uint256(block.timestamp).encodeUint();
        return elements.encodeList();
    }

    function getSlashThresholds() external view override(ISlashIndicator) returns (uint256, uint256) {
        return (misdemeanorThreshold, felonyThreshold);
    }
}
