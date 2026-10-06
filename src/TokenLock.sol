// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TokenLock
/// @notice Holds one ERC-20 (`token`) for one `beneficiary` until `unlockTime`. Any other
/// ERC-20 sent to this contract can be collected by the beneficiary at any time.
/// @dev No owner, admin, proxy, pause or upgrade, and no way to receive ETH. No reentrancy
/// guard is needed: none of this contract's storage is read after an external call (the
/// delivered amount is read from the token, and nothing here depends on it), `unlockTime` only
/// grows, every payment goes to the one immutable `beneficiary`, and during a transfer the only
/// contract that can call back is the token, which can never be the beneficiary (refused at
/// deployment for `token`, on every call for a swept token). `msg.sender == beneficiary` is an
/// identity check, not authorisation: the beneficiary must be an account whose own code
/// authorises its callers (a Safe), never a multicall, batcher or open relay, and it must keep
/// what it receives during the call, since delivery is measured on its balance.
/// `block.timestamp` may run ahead of wall-clock time on some chains; choose `unlockTime` with
/// that margin.
contract TokenLock {
    using SafeERC20 for IERC20;

    /// @notice How far past the deployment `unlockTime` may ever be set (3650 days, unix seconds).
    uint256 public constant MAX_LOCK_DURATION = 3650 days;

    IERC20 public immutable token;
    address public immutable beneficiary;
    /// @notice The latest `unlockTime` this lock can ever have: deployment time + `MAX_LOCK_DURATION`.
    uint256 public immutable maxUnlockTime;
    /// @notice The chain this lock was deployed on; every beneficiary action reverts elsewhere.
    uint256 public immutable deployChainId;
    /// @notice The code hash at `token` when this lock was deployed; `withdraw` refuses if it changed,
    /// so a token destroyed and re-created at the same address cannot be withdrawn as the old one.
    bytes32 public immutable tokenCodehash;
    uint256 public unlockTime;

    /// @notice Emitted once, at deployment, so a log-only reader learns the lock's starting terms.
    event Locked(address indexed token, address indexed beneficiary, uint256 unlockTime, uint256 maxUnlockTime);
    /// @notice `amount` is what the beneficiary's balance rose by, not what was requested.
    event Withdrawn(uint256 amount);
    /// @notice `amount` is what the beneficiary's balance rose by, not this contract's balance.
    event Swept(address indexed otherToken, uint256 amount);
    event Extended(uint256 oldUnlockTime, uint256 newUnlockTime);

    error NotBeneficiary();
    error ZeroAddress();
    error NotAContract();
    error BeneficiaryIsLock();
    error BeneficiaryIsToken();
    error StillLocked(uint256 unlockTime);
    error LockedToken();
    error NotSweepable();
    error BadUnlockTime();
    error WrongChain(uint256 deployChainId, uint256 chainId);
    error NothingDelivered();
    error TokenCodeChanged(bytes32 deployed, bytes32 current);

    /// @param token_ The locked token. Must have code and answer `balanceOf` with a word. Neither
    /// alone is enough: a wallet with an EIP-7702 delegation or a one-byte stub has code, and a
    /// precompile answers with a word but has none.
    /// @param beneficiary_ The only address that can call this contract. Must not be this contract or the token.
    /// @param unlockTime_ Unix seconds; in the future and at most `MAX_LOCK_DURATION` ahead.
    constructor(IERC20 token_, address beneficiary_, uint256 unlockTime_) {
        if (address(token_) == address(0) || beneficiary_ == address(0)) revert ZeroAddress();
        if (address(token_).code.length == 0) revert NotAContract();
        (bool ok, bytes memory ret) = address(token_).staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!ok || ret.length < 32) revert NotAContract();
        if (beneficiary_ == address(this)) revert BeneficiaryIsLock();
        if (beneficiary_ == address(token_)) revert BeneficiaryIsToken();
        uint256 ceiling = block.timestamp + MAX_LOCK_DURATION;
        if (unlockTime_ <= block.timestamp || unlockTime_ > ceiling) revert BadUnlockTime();
        token = token_;
        beneficiary = beneficiary_;
        maxUnlockTime = ceiling;
        deployChainId = block.chainid;
        tokenCodehash = address(token_).codehash;
        unlockTime = unlockTime_;
        emit Locked(address(token_), beneficiary_, unlockTime_, ceiling);
    }

    modifier onlyBeneficiary() {
        if (block.chainid != deployChainId) revert WrongChain(deployChainId, block.chainid);
        if (msg.sender != beneficiary) revert NotBeneficiary();
        _;
    }

    /// @notice Sends `amount` of the locked token to the beneficiary and reports what arrived.
    /// Reverts `TokenCodeChanged` if the code at `token` changed since deployment, checked before
    /// the time gate so a lock that can never pay out reports it while still locked. Otherwise
    /// reverts before `unlockTime`.
    function withdraw(uint256 amount) external onlyBeneficiary {
        bytes32 current = address(token).codehash;
        if (current != tokenCodehash) revert TokenCodeChanged(tokenCodehash, current);
        if (block.timestamp < unlockTime) revert StillLocked(unlockTime);
        emit Withdrawn(_deliver(token, amount));
    }

    /// @notice Sends this contract's whole balance of `otherToken` to the beneficiary and returns
    /// what arrived.
    /// Callable at any time. Reverts if `otherToken` is the locked token, the beneficiary or this
    /// contract: a beneficiary can gain code after deployment, so this is checked on every call.
    /// An address with no code (an EOA or a precompile) reverts `NotAContract` before any call.
    function sweep(IERC20 otherToken) external onlyBeneficiary returns (uint256 delivered) {
        if (otherToken == token) revert LockedToken();
        if (address(otherToken) == beneficiary || address(otherToken) == address(this)) revert NotSweepable();
        if (address(otherToken).code.length == 0) revert NotAContract();
        delivered = _deliver(otherToken, otherToken.balanceOf(address(this)));
        emit Swept(address(otherToken), delivered);
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

    /// @dev Transfers `amount` of `t` to the beneficiary and returns what its balance rose by.
    /// A fee-on-transfer token delivers less and that smaller figure is returned; a non-zero
    /// request that delivers nothing reverts, because that is a transfer that did not transfer.
    function _deliver(IERC20 t, uint256 amount) private returns (uint256 delivered) {
        uint256 balanceBefore = t.balanceOf(beneficiary);
        t.safeTransfer(beneficiary, amount);
        uint256 balanceAfter = t.balanceOf(beneficiary);
        delivered = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        if (amount != 0 && delivered == 0) revert NothingDelivered();
    }
}
