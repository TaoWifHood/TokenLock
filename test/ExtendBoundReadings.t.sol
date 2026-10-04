// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// @notice Models the review's one-line `extend` bound (FIX-1) as pure predicates, next to the
/// bound the contract ships, so the response's two objections run as tests. Not the contract.
contract ExtendBoundReadings is Test {
    uint256 constant D = 3650 days;
    uint256 constant T0 = 1_000_000_000;

    /// The bound before the fix: at most D ahead of now.
    function original(uint256 nowTs, uint256 cur, uint256 next) internal pure returns (bool) {
        return next > cur && next > nowTs && next <= nowTs + D;
    }

    /// FIX-1 read as a replacement: at most D ahead of the current unlockTime.
    function fix1Replacement(uint256 nowTs, uint256 cur, uint256 next) internal pure returns (bool) {
        return next > cur && next > nowTs && next <= cur + D;
    }

    /// FIX-1 read as an addition to the original bound.
    function fix1Addition(uint256 nowTs, uint256 cur, uint256 next) internal pure returns (bool) {
        return original(nowTs, cur, next) && next <= cur + D;
    }

    /// The shipped bound: an absolute ceiling fixed at deployment.
    function shipped(uint256 nowTs, uint256 cur, uint256 next, uint256 deployedAt) internal pure returns (bool) {
        return next > cur && next > nowTs && next <= deployedAt + D;
    }

    /// As a replacement, ten calls in one block push the lock a century out.
    function test_replacement_stacksWithoutLimitInOneBlock() public pure {
        uint256 cur = T0 + 30 days;
        for (uint256 i; i < 10; ++i) {
            uint256 next = cur + D;
            assertTrue(fix1Replacement(T0, cur, next));
            cur = next;
        }
        assertEq(cur, T0 + 30 days + 10 * D);
        assertFalse(original(T0, T0 + 30 days + D, T0 + 30 days + 2 * D));
        assertFalse(shipped(T0, T0 + 30 days, T0 + 30 days + D, T0));
    }

    /// As an addition, it accepts exactly what the original accepts while the lock is live.
    function testFuzz_addition_neverBindsOnALiveLock(uint256 cur, uint256 next) public pure {
        cur = bound(cur, T0 + 1, T0 + D);
        next = bound(next, 0, T0 + 2 * D);
        assertEq(fix1Addition(T0, cur, next), original(T0, cur, next));
    }

    /// As an addition, a lock that expired ten days ago can still be re-locked for 3640 days.
    function test_addition_relocksAnExpiredLockNearlyFully() public pure {
        uint256 deployedAt = T0;
        uint256 unlock = T0 + 365 days;
        uint256 nowTs = unlock + 10 days;
        uint256 next = unlock + D;
        assertTrue(fix1Addition(nowTs, unlock, next));
        assertEq(next - nowTs, D - 10 days);
        assertFalse(shipped(nowTs, unlock, next, deployedAt));
        assertTrue(shipped(nowTs, unlock, deployedAt + D, deployedAt));
    }

    /// The shipped ceiling bounds any sequence of calls, however they are spaced in time.
    function testFuzz_shipped_neverPassesTheCeiling(uint256 gap, uint256 next) public pure {
        uint256 nowTs = T0 + bound(gap, 0, 2 * D);
        assertFalse(shipped(nowTs, T0 + 1, bound(next, T0 + D + 1, type(uint128).max), T0));
    }
}
