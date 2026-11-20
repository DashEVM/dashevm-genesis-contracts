// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.17;

/// @title FeeVault (DashEVM / CardanoEVM predeploy at 0x...5060)
/// @notice Receives the community share of every block's gas fees from
/// BSCValidatorSet.deposit (the slot upstream BSC used to burn). The native
/// coin is bridged DASH / ADA, so it is never burned: burning would strand
/// vault backing. Anyone may flush the balance to `target`, which on-chain
/// governance (the BSC timelock, after a vote and its delay) sets to the gas
/// fee RewardDistributor (60% of this share to ValidatorRewards for the working
/// validator set and their delegators, 40% to the treasury; SPEC section 6).
contract FeeVault {
    address public constant TIMELOCK = 0x0000000000000000000000000000000000002006;

    address public target;

    event TargetSet(address indexed target);
    event Flushed(address indexed target, uint256 amount);

    error OnlyTimelock();
    error NoTarget();
    error FlushFailed();

    /// Must stay cheap: BSCValidatorSet sends with the 2,300 gas stipend, and a
    /// revert here would make every block's fee deposit fail.
    receive() external payable {}

    function setTarget(address t) external {
        if (msg.sender != TIMELOCK) revert OnlyTimelock();
        target = t;
        emit TargetSet(t);
    }

    /// @notice Send the whole balance to the target. A failing target leaves
    /// the balance here for a later flush (or a new target).
    function flush() external {
        address t = target;
        if (t == address(0)) revert NoTarget();
        uint256 amount = address(this).balance;
        (bool ok,) = t.call{value: amount}("");
        if (!ok) revert FlushFailed();
        emit Flushed(t, amount);
    }
}
