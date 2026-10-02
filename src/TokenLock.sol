// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TokenLock
/// @notice Holds one ERC-20 (`token`) for one `beneficiary` until `unlockTime`. Any other
/// ERC-20 sent to this contract can be collected by the beneficiary at any time.
/// @dev No owner, admin, proxy, pause or upgrade, and no way to receive ETH. There is no
/// reentrancy guard: every state-changing function requires `msg.sender == beneficiary`
/// and pays only the beneficiary. `block.timestamp` may run ahead of wall-clock time on
/// some chains; choose `unlockTime` with that margin.
contract TokenLock {
    using SafeERC20 for IERC20;

    /// @notice How far past the deployment `unlockTime` may ever be set (3650 days, unix seconds).
    uint256 public constant MAX_LOCK_DURATION = 3650 days;

    IERC20 public immutable token;
    address public immutable beneficiary;
    /// @notice The latest `unlockTime` this lock can ever have: deployment time + `MAX_LOCK_DURATION`.
    uint256 public immutable maxUnlockTime;
    uint256 public unlockTime;

    event Withdrawn(uint256 amount);
    event Swept(address indexed otherToken, uint256 amount);
    event Extended(uint256 oldUnlockTime, uint256 newUnlockTime);

    error NotBeneficiary();
    error ZeroAddress();
    error NotAContract();
    error BeneficiaryIsLock();
    error BeneficiaryIsToken();
    error StillLocked(uint256 unlockTime);
    error LockedToken();
    error BadUnlockTime();

    /// @param token_ The locked token. Must be a deployed contract.
    /// @param beneficiary_ The only address that can call this contract. Must not be this contract or the token.
    /// @param unlockTime_ Unix seconds; in the future and at most `MAX_LOCK_DURATION` ahead.
    constructor(IERC20 token_, address beneficiary_, uint256 unlockTime_) {
        if (address(token_) == address(0) || beneficiary_ == address(0)) revert ZeroAddress();
        if (address(token_).code.length == 0) revert NotAContract();
        if (beneficiary_ == address(this)) revert BeneficiaryIsLock();
        if (beneficiary_ == address(token_)) revert BeneficiaryIsToken();
        uint256 ceiling = block.timestamp + MAX_LOCK_DURATION;
        if (unlockTime_ <= block.timestamp || unlockTime_ > ceiling) revert BadUnlockTime();
        token = token_;
        beneficiary = beneficiary_;
        maxUnlockTime = ceiling;
        unlockTime = unlockTime_;
    }

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) revert NotBeneficiary();
        _;
    }

    /// @notice Sends `amount` of the locked token to the beneficiary. Reverts before `unlockTime`.
    function withdraw(uint256 amount) external onlyBeneficiary {
        if (block.timestamp < unlockTime) revert StillLocked(unlockTime);
        token.safeTransfer(beneficiary, amount);
        emit Withdrawn(amount);
    }

    /// @notice Sends this contract's whole balance of `otherToken` to the beneficiary.
    /// Callable at any time. Reverts if `otherToken` is the locked token.
    function sweep(IERC20 otherToken) external onlyBeneficiary returns (uint256 amount) {
        if (otherToken == token) revert LockedToken();
        amount = otherToken.balanceOf(address(this));
        otherToken.safeTransfer(beneficiary, amount);
        emit Swept(address(otherToken), amount);
    }

    /// @notice Sets a later `unlockTime`. It must be after the current one, in the future, and at
    /// most `maxUnlockTime`. Calling this on an expired lock locks it again, never past that ceiling.
    function extend(uint256 newUnlockTime) external onlyBeneficiary {
        if (newUnlockTime <= unlockTime || newUnlockTime <= block.timestamp || newUnlockTime > maxUnlockTime) {
            revert BadUnlockTime();
        }
        emit Extended(unlockTime, newUnlockTime);
        unlockTime = newUnlockTime;
    }
}
