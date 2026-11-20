// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.17;

interface IVRToken {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IVRValidatorSet {
    function getElectedSet() external view returns (address[] memory, uint256);
    function isCurrentValidator(address) external view returns (bool);
}

interface IVRSlashIndicator {
    function felonyThreshold() external view returns (uint256);
    function getSlashIndicator(address) external view returns (uint256, uint256);
}

interface IVRStakeHub {
    struct Commission {
        uint64 rate;
        uint64 maxRate;
        uint64 maxChangeRate;
    }

    function consensusToOperator(address) external view returns (address);
    function getValidatorBasicInfo(address) external view returns (uint256, bool, uint256);
    function getValidatorCreditContract(address) external view returns (address);
    function getValidatorCommission(address) external view returns (Commission memory);
    function permissioned() external view returns (bool);
    function launchStakeCap() external view returns (uint256);
}

interface IVRStakeCredit {
    function totalPooledBNB() external view returns (uint256);
    function distributeReward(uint64 commissionRate) external payable;
    function notifyDeitReward(uint256 amount, uint64 commissionRate) external;
}

/// @title ValidatorRewards (DashEVM / CardanoEVM predeploy at 0x...5061)
/// @notice Pays rewards to the validators securing the chain and their delegators
/// (SPEC section 6), in two currencies:
/// - native DASH / ADA, LIVE from genesis: the validators' share of bridge fees (20%) and of
///   the FeeVault gas-fee share (60%), pushed here by the two RewardDistributors;
/// - DEIT, DEFERRED: the validators' 90% of each DEIT emission (EmissionController Transfer
///   recipient). Idle until governance calls setDeit when DEIT launches.
///
/// Once per day index (block.timestamp / 1 days, the StakeHub breathe day), and only after
/// that day's election (the breathe block's updateValidatorSetV2), anyone may call
/// distribute(). tokenomics review M-1, M-2:
/// - The denominator is the FULL set elected at that breathe block
///   (BSCValidatorSet.getElectedSet), including members later jailed, evicted by a felony or
///   in maintenance. Member weight = pooled stake, capped at launchStakeCap while StakeHub is
///   permissioned (as StakeHub._electionPower).
/// - A member earns weight * (felonyThreshold - missed) / felonyThreshold of that, and only
///   if it is a working validator right now (BSCValidatorSet.isCurrentValidator: not jailed,
///   not in maintenance, not evicted) and not jailed in StakeHub. Everything not earned
///   (non-earners, the missed-block part) STAYS here for the next day; it is never handed to
///   the other members.
/// - So the caller's choice of instant cannot move another member's share to anyone else,
///   and the day boundary is fixed (no phase shift by an early call). Residual: the caller
///   still picks the instant within the day, so a member can call while it is itself in
///   good standing, and a member in maintenance or jailed at that instant waits for the
///   next day (its share is kept, not lost).
/// - Post-election mismatch (documented, accepted): fees that arrived during day d-1 are paid
///   on day d to the set elected at day d's breathe block. With daily elections this shifts
///   at most about one day of fees between outgoing and incoming members.
///
/// Each member's part goes to its StakeCredit pool:
/// - native: StakeCredit.distributeReward, the same accounting as block fees (the commission
///   is minted as shares to the operator, the rest raises the value of every share). The
///   operator's govBNB is not synced here: it lags until the operator's next sync (any
///   StakeHub delegate, undelegate, redelegate or block reward to that pool, or
///   syncGovToken), which then mints votes for the new shares, clamped at launchStakeCap
///   while permissioned;
/// - DEIT: the pool owes the commission to the operator and shares the rest across all pool
///   shares (holders claim with StakeCredit.claimDeit). A failing DEIT token (balanceOf or
///   transfer) never blocks the native payout (review L-1).
contract ValidatorRewards {
    address public constant TIMELOCK = 0x0000000000000000000000000000000000002006;
    address public constant VALIDATOR_SET = 0x0000000000000000000000000000000000001000;
    address public constant SLASH_INDICATOR = 0x0000000000000000000000000000000000001001;
    address public constant STAKE_HUB = 0x0000000000000000000000000000000000002002;
    uint256 public constant INTERVAL = 1 days; // StakeHub.BREATHE_BLOCK_INTERVAL
    uint256 public constant MAX_VALIDATORS = 100;

    address public deit; // set once by governance after the DEIT token is deployed
    uint256 public lastDay; // day index of the last distribution (0 = never)

    event DeitSet(address indexed deit);
    event Distributed(uint256 indexed day, uint256 nativePaid, uint256 deitPaid, uint256 validators);

    error OnlyTimelock();
    error AlreadySet();
    error NotReady();
    error TooManyValidators();

    struct Member {
        address credit;
        uint64 rate;
        uint256 earned; // weight actually earned this round
    }

    /// @dev Must stay cheap: the RewardDistributors push with a 100k gas limit.
    receive() external payable {}

    function setDeit(address token) external {
        if (msg.sender != TIMELOCK) revert OnlyTimelock();
        if (deit != address(0) || token == address(0) || token.code.length == 0) revert AlreadySet();
        deit = token;
        emit DeitSet(token);
    }

    function _weight(address credit, bool capped, uint256 cap) internal view returns (uint256 w) {
        w = IVRStakeCredit(credit).totalPooledBNB();
        if (capped && w > cap) w = cap;
    }

    /// Weight of one elected member (counted in the denominator whatever its state) and what
    /// it earns now (zero unless it is working, not jailed and below the felony count).
    function _member(address cons, bool capped, uint256 cap, uint256 felony) internal view returns (uint256 w, Member memory mem) {
        address op = IVRStakeHub(STAKE_HUB).consensusToOperator(cons);
        if (op == address(0)) return (0, mem); // not registered: no pool, no weight
        address credit = IVRStakeHub(STAKE_HUB).getValidatorCreditContract(op);
        w = _weight(credit, capped, cap);
        if (w == 0 || felony == 0 || !IVRValidatorSet(VALIDATOR_SET).isCurrentValidator(cons)) return (w, mem);
        (, bool jailed,) = IVRStakeHub(STAKE_HUB).getValidatorBasicInfo(op);
        if (jailed) return (w, mem);
        (, uint256 missed) = IVRSlashIndicator(SLASH_INDICATOR).getSlashIndicator(cons);
        if (missed >= felony) return (w, mem);
        mem = Member(credit, IVRStakeHub(STAKE_HUB).getValidatorCommission(op).rate, (w * (felony - missed)) / felony);
    }

    function distribute() external {
        uint256 day = block.timestamp / INTERVAL;
        (address[] memory set, uint256 electedDay) = IVRValidatorSet(VALIDATOR_SET).getElectedSet();
        // Once per day, and only under that day's election.
        if (day <= lastDay || electedDay != day || set.length == 0) revert NotReady();
        uint256 n = set.length;
        if (n > MAX_VALIDATORS) revert TooManyValidators();

        address token = deit;
        uint256 nat = address(this).balance;
        uint256 bal;
        if (token != address(0)) {
            try IVRToken(token).balanceOf(address(this)) returns (uint256 b) {
                bal = b;
            } catch {}
        }
        if (nat == 0 && bal == 0) return; // nothing to pay: keep the day open

        uint256 felony = IVRSlashIndicator(SLASH_INDICATOR).felonyThreshold();
        uint256 cap = IVRStakeHub(STAKE_HUB).launchStakeCap();
        bool capped = cap != 0 && IVRStakeHub(STAKE_HUB).permissioned();
        Member[] memory m = new Member[](n);
        uint256 total; // weight of the FULL elected set
        for (uint256 i = 0; i < n; i++) {
            uint256 w;
            (w, m[i]) = _member(set[i], capped, cap, felony);
            total += w;
        }
        if (total == 0) return;
        lastDay = day;
        uint256 paidN;
        uint256 paidD;
        uint256 count;
        for (uint256 i = 0; i < n; i++) {
            if (m[i].earned == 0) continue;
            uint256 amtN = (nat * m[i].earned) / total;
            uint256 amt = (bal * m[i].earned) / total;
            if (amtN > 0) {
                IVRStakeCredit(m[i].credit).distributeReward{value: amtN}(m[i].rate);
                paidN += amtN;
            }
            if (amt > 0 && _payDeit(token, m[i].credit, amt, m[i].rate)) paidD += amt;
            count++;
        }
        emit Distributed(day, paidN, paidD, count);
    }

    /// The DEIT leg can never revert the native payout: a failed transfer keeps the DEIT here.
    function _payDeit(address token, address credit, uint256 amt, uint64 rate) internal returns (bool) {
        try IVRToken(token).transfer(credit, amt) returns (bool ok) {
            if (!ok) return false;
        } catch {
            return false;
        }
        IVRStakeCredit(credit).notifyDeitReward(amt, rate);
        return true;
    }
}
