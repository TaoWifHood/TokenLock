// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenLock} from "../src/TokenLock.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @notice Random sequences of: top-ups, reward pushes, time jumps, beneficiary withdraw /
/// sweep / extend, and stranger attempts at every exit.
contract LockHandler is Test {
    TokenLock public lock;
    MockERC20 public locked;
    MockERC20 public reward;
    address public safe;
    address public stranger = makeAddr("stranger");

    uint256 public lockedIn;
    uint256 public rewardIn;
    uint256 public earlyWithdrawals; // a withdraw that succeeded while still locked — must stay 0
    uint256 public strangerSuccesses; // any stranger call that succeeded — must stay 0
    uint256 public lastUnlock;
    uint256 public shortenings; // an extend that left unlockTime earlier than before — must stay 0
    uint256 public calls;

    constructor(TokenLock lock_, MockERC20 locked_, MockERC20 reward_, address beneficiary_) {
        lock = lock_;
        locked = locked_;
        reward = reward_;
        safe = beneficiary_;
        lastUnlock = lock_.unlockTime();
    }

    function topUp(uint256 amt) external {
        amt = bound(amt, 0, 1e30);
        locked.mint(address(lock), amt);
        lockedIn += amt;
        calls++;
    }

    function pushReward(uint256 amt) external {
        amt = bound(amt, 0, 1e24);
        reward.mint(address(lock), amt);
        rewardIn += amt;
        calls++;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 400 days));
        calls++;
    }

    function withdraw(uint256 amt) external {
        amt = bound(amt, 0, locked.balanceOf(address(lock)));
        bool locked = block.timestamp < lock.unlockTime();
        vm.prank(safe);
        try lock.withdraw(amt) {
            if (locked) earlyWithdrawals++;
        } catch {}
        calls++;
    }

    function sweep() external {
        vm.prank(safe);
        lock.sweep(IERC20(address(reward)));
        calls++;
    }

    /// A failing assertion here would only revert this call, undoing the extend it should report, so
    /// a shortening is counted and `invariant_unlockNeverShortened` asserts the count.
    function extend(uint256 t) external {
        t = bound(t, 0, block.timestamp + 4000 days);
        vm.prank(safe);
        try lock.extend(t) {} catch {}
        if (lock.unlockTime() < lastUnlock) shortenings++;
        lastUnlock = lock.unlockTime();
        calls++;
    }

    function strangerTries(uint256 amt, uint8 which) external {
        vm.startPrank(stranger);
        bool ok;
        if (which % 4 == 0) ok = _try(abi.encodeCall(TokenLock.withdraw, (amt)));
        else if (which % 4 == 1) ok = _try(abi.encodeCall(TokenLock.sweep, (IERC20(address(reward)))));
        else if (which % 4 == 2) ok = _try(abi.encodeCall(TokenLock.sweep, (IERC20(address(locked)))));
        else ok = _try(abi.encodeCall(TokenLock.extend, (amt)));
        vm.stopPrank();
        if (ok) strangerSuccesses++;
        calls++;
    }

    function _try(bytes memory data) internal returns (bool ok) {
        (ok,) = address(lock).call(data);
    }
}

contract TokenLockInvariantTest is Test {
    LockHandler h;
    TokenLock lock;
    MockERC20 locked;
    MockERC20 reward;
    address safe = makeAddr("safe");

    function setUp() public {
        vm.warp(1_750_000_000);
        locked = new MockERC20();
        reward = new MockERC20();
        lock = new TokenLock(IERC20(address(locked)), safe, block.timestamp + 90 days);
        h = new LockHandler(lock, locked, reward, safe);
        targetContract(address(h));
    }

    /// Every locked token that went in is either still in the lock or with the beneficiary.
    function invariant_lockedTokenConserved() public view {
        assertEq(locked.balanceOf(address(lock)) + locked.balanceOf(safe), h.lockedIn());
        assertEq(locked.balanceOf(h.stranger()), 0);
    }

    /// Every reward that arrived is either still in the lock or with the beneficiary.
    function invariant_rewardConserved() public view {
        assertEq(reward.balanceOf(address(lock)) + reward.balanceOf(safe), h.rewardIn());
        assertEq(reward.balanceOf(h.stranger()), 0);
    }

    /// While locked, the beneficiary has received nothing of the locked token early.
    function invariant_noEarlyWithdrawal() public view {
        assertEq(h.earlyWithdrawals(), 0);
    }

    function invariant_strangerNeverSucceeds() public view {
        assertEq(h.strangerSuccesses(), 0);
    }

    function invariant_unlockMonotonic() public view {
        assertGe(lock.unlockTime(), h.lastUnlock());
    }

    function invariant_unlockNeverShortened() public view {
        assertEq(h.shortenings(), 0);
    }

    function invariant_unlockNeverPassesTheCeiling() public view {
        assertLe(lock.unlockTime(), lock.maxUnlockTime());
    }
}
