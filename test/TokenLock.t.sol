// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenLock} from "../src/TokenLock.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @notice transfer() returns nothing (the USDT shape): SafeERC20 must still work.
contract NoReturnERC20 {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice transfer() returns false without moving anything: a sweep must REVERT, never
/// report a sweep that did not happen.
contract FalseERC20 {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address, uint256) external pure returns (bool) { return false; }
}

/// @notice A hostile token: on transfer it re-enters the lock and tries every exit.
contract ReentrantERC20 {
    mapping(address => uint256) public balanceOf;
    TokenLock public lock;
    bool public reentryBlocked;
    function setLock(TokenLock l) external { lock = l; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        (bool w,) = address(lock).call(abi.encodeCall(TokenLock.withdraw, (1)));
        (bool s,) = address(lock).call(abi.encodeCall(TokenLock.sweep, (IERC20(address(this)))));
        (bool e,) = address(lock).call(abi.encodeCall(TokenLock.extend, (type(uint64).max)));
        reentryBlocked = !w && !s && !e;
        return true;
    }
}

contract TokenLockTest is Test {
    MockERC20 locked;
    MockERC20 reward;
    TokenLock lock;
    address safe = makeAddr("safe");
    address stranger = makeAddr("stranger");
    uint256 unlock;

    uint256 constant LOCKED = 1_000_000 ether;

    event Withdrawn(uint256 amount);
    event Swept(address indexed otherToken, uint256 amount);
    event Extended(uint256 oldUnlockTime, uint256 newUnlockTime);

    function setUp() public {
        vm.warp(1_750_000_000);
        locked = new MockERC20();
        reward = new MockERC20();
        unlock = block.timestamp + 90 days;
        lock = new TokenLock(IERC20(address(locked)), safe, unlock);
        locked.mint(address(lock), LOCKED); // locking = a plain transfer in
    }

    // ── constructor ─────────────────────────────────────────────────────────

    function test_constructor_setsImmutables() public view {
        assertEq(address(lock.token()), address(locked));
        assertEq(lock.beneficiary(), safe);
        assertEq(lock.unlockTime(), unlock);
    }

    function test_constructor_rejectsZeroToken() public {
        vm.expectRevert(TokenLock.ZeroAddress.selector);
        new TokenLock(IERC20(address(0)), safe, unlock);
    }

    function test_constructor_rejectsZeroBeneficiary() public {
        vm.expectRevert(TokenLock.ZeroAddress.selector);
        new TokenLock(IERC20(address(locked)), address(0), unlock);
    }

    function test_constructor_rejectsNowOrPast() public {
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        new TokenLock(IERC20(address(locked)), safe, block.timestamp);
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        new TokenLock(IERC20(address(locked)), safe, block.timestamp - 1);
    }

    function test_constructor_rejectsMillisecondTypo() public {
        uint256 ms = (block.timestamp + 90 days) * 1000;
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        new TokenLock(IERC20(address(locked)), safe, ms);
    }

    function test_constructor_acceptsExactlyMaxDuration() public {
        TokenLock l = new TokenLock(IERC20(address(locked)), safe, block.timestamp + 3650 days);
        assertEq(l.unlockTime(), block.timestamp + 3650 days);
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        new TokenLock(IERC20(address(locked)), safe, block.timestamp + 3650 days + 1);
    }

    // ── withdraw ────────────────────────────────────────────────────────────

    function test_withdraw_beforeUnlock_reverts() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TokenLock.StillLocked.selector, unlock));
        lock.withdraw(1);
    }

    function test_withdraw_oneSecondBeforeUnlock_reverts() public {
        vm.warp(unlock - 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TokenLock.StillLocked.selector, unlock));
        lock.withdraw(1);
    }

    function test_withdraw_atUnlock_paysBeneficiary() public {
        vm.warp(unlock);
        vm.prank(safe);
        vm.expectEmit(address(lock));
        emit Withdrawn(LOCKED);
        lock.withdraw(LOCKED);
        assertEq(locked.balanceOf(safe), LOCKED);
        assertEq(locked.balanceOf(address(lock)), 0);
    }

    function test_withdraw_partial() public {
        vm.warp(unlock);
        vm.startPrank(safe);
        lock.withdraw(400 ether);
        lock.withdraw(600 ether);
        vm.stopPrank();
        assertEq(locked.balanceOf(safe), 1000 ether);
        assertEq(locked.balanceOf(address(lock)), LOCKED - 1000 ether);
    }

    /// There is no deposit function: the lock holds whatever balance it has, so a later
    /// transfer is locked under the same unlockTime the moment it arrives — from anyone.
    function test_topUp_afterDeploy_isLockedUnderTheSameDate() public {
        uint256 extra = 250 ether;
        locked.mint(safe, extra);
        vm.prank(safe);
        locked.transfer(address(lock), extra);
        assertEq(locked.balanceOf(address(lock)), LOCKED + extra, "the top-up landed");

        // still no early exit for ANY of it
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TokenLock.StillLocked.selector, unlock));
        lock.withdraw(extra);

        // and at expiry the whole balance, original + top-up, comes out
        vm.warp(unlock);
        vm.prank(safe);
        lock.withdraw(LOCKED + extra);
        assertEq(locked.balanceOf(address(lock)), 0);
        assertEq(locked.balanceOf(safe), LOCKED + extra);
    }

    function test_topUp_fromAStranger_isLockedAndBelongsToTheBeneficiary() public {
        address stranger = makeAddr("stranger");
        locked.mint(stranger, 10 ether);
        vm.prank(stranger);
        locked.transfer(address(lock), 10 ether);
        vm.prank(stranger);
        vm.expectRevert(TokenLock.NotBeneficiary.selector);
        lock.withdraw(10 ether);
        vm.warp(unlock);
        vm.prank(safe);
        lock.withdraw(LOCKED + 10 ether);
        assertEq(locked.balanceOf(safe), LOCKED + 10 ether, "a stranger's top-up pays the beneficiary");
    }

    function test_withdraw_moreThanHeld_reverts() public {
        vm.warp(unlock);
        vm.prank(safe);
        vm.expectRevert();
        lock.withdraw(LOCKED + 1);
    }

    function test_withdraw_stranger_revertsEvenAfterUnlock() public {
        vm.warp(unlock + 365 days);
        vm.prank(stranger);
        vm.expectRevert(TokenLock.NotBeneficiary.selector);
        lock.withdraw(1);
    }

    function test_withdraw_tokenArrivingLaterIsLockedToo() public {
        locked.mint(address(lock), 5 ether); // a later top-up, or locked token someone sends by mistake
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TokenLock.StillLocked.selector, unlock));
        lock.withdraw(5 ether);
        vm.prank(safe);
        vm.expectRevert(TokenLock.LockedToken.selector);
        lock.sweep(IERC20(address(locked)));
        assertEq(locked.balanceOf(address(lock)), LOCKED + 5 ether);
    }

    // ── sweep ───────────────────────────────────────────────────────────────

    function test_sweep_otherTokenAnytime() public {
        reward.mint(address(lock), 1.234 ether);
        vm.prank(safe);
        vm.expectEmit(address(lock));
        emit Swept(address(reward), 1.234 ether);
        uint256 got = lock.sweep(IERC20(address(reward)));
        assertEq(got, 1.234 ether);
        assertEq(reward.balanceOf(safe), 1.234 ether);
        assertEq(reward.balanceOf(address(lock)), 0);
        assertEq(locked.balanceOf(address(lock)), LOCKED, "the lock is untouched");
    }

    function test_sweep_repeatedRounds() public {
        vm.startPrank(safe);
        for (uint256 i = 1; i <= 5; i++) {
            reward.mint(address(lock), i * 0.01 ether);
            assertEq(lock.sweep(IERC20(address(reward))), i * 0.01 ether);
        }
        vm.stopPrank();
        assertEq(reward.balanceOf(safe), 0.15 ether);
    }

    function test_sweep_empty_isHarmlessZero() public {
        vm.prank(safe);
        assertEq(lock.sweep(IERC20(address(reward))), 0);
    }

    function test_sweep_lockedToken_reverts() public {
        vm.prank(safe);
        vm.expectRevert(TokenLock.LockedToken.selector);
        lock.sweep(IERC20(address(locked)));
    }

    function test_sweep_lockedToken_revertsAfterUnlockToo() public {
        vm.warp(unlock);
        vm.prank(safe);
        vm.expectRevert(TokenLock.LockedToken.selector);
        lock.sweep(IERC20(address(locked)));
    }

    function test_sweep_stranger_reverts() public {
        reward.mint(address(lock), 1 ether);
        vm.prank(stranger);
        vm.expectRevert(TokenLock.NotBeneficiary.selector);
        lock.sweep(IERC20(address(reward)));
    }

    /// A stranger holding 1 wei of the reward token cannot claim any of the lock's balance:
    /// there are no shares to buy into.
    function test_strangerDustCannotTakeRewards() public {
        reward.mint(address(lock), 0.01 ether);
        reward.mint(stranger, 1);
        vm.startPrank(stranger);
        reward.transfer(address(lock), 1);
        vm.expectRevert(TokenLock.NotBeneficiary.selector);
        lock.sweep(IERC20(address(reward)));
        vm.expectRevert(TokenLock.NotBeneficiary.selector);
        lock.withdraw(1);
        vm.stopPrank();
        vm.prank(safe);
        assertEq(lock.sweep(IERC20(address(reward))), 0.01 ether + 1, "the stranger's wei is a donation");
        assertEq(reward.balanceOf(stranger), 0);
    }

    function test_sweep_noReturnToken_works() public {
        NoReturnERC20 usdtLike = new NoReturnERC20();
        usdtLike.mint(address(lock), 7);
        vm.prank(safe);
        assertEq(lock.sweep(IERC20(address(usdtLike))), 7);
        assertEq(usdtLike.balanceOf(safe), 7);
    }

    function test_sweep_falseReturningToken_reverts() public {
        FalseERC20 f = new FalseERC20();
        f.mint(address(lock), 7);
        vm.prank(safe);
        vm.expectRevert();
        lock.sweep(IERC20(address(f)));
    }

    function test_reentrantTokenCannotCallBack() public {
        ReentrantERC20 evil = new ReentrantERC20();
        evil.setLock(lock);
        evil.mint(address(lock), 3);
        vm.prank(safe);
        lock.sweep(IERC20(address(evil)));
        assertTrue(evil.reentryBlocked(), "withdraw, sweep and extend all refused the re-entering token");
        assertEq(evil.balanceOf(safe), 3);
        assertEq(lock.unlockTime(), unlock);
        assertEq(locked.balanceOf(address(lock)), LOCKED);
    }

    // ── extend ──────────────────────────────────────────────────────────────

    function test_extend_later_moves() public {
        vm.prank(safe);
        vm.expectEmit(address(lock));
        emit Extended(unlock, unlock + 30 days);
        lock.extend(unlock + 30 days);
        assertEq(lock.unlockTime(), unlock + 30 days);

        vm.warp(unlock); // the OLD unlock no longer opens it
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TokenLock.StillLocked.selector, unlock + 30 days));
        lock.withdraw(1);
    }

    function test_extend_sameOrEarlier_reverts() public {
        vm.startPrank(safe);
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        lock.extend(unlock);
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        lock.extend(unlock - 1);
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        lock.extend(0);
        vm.stopPrank();
    }

    function test_extend_millisecondTypo_reverts() public {
        vm.prank(safe);
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        lock.extend(unlock * 1000);
    }

    function test_extend_stranger_reverts() public {
        vm.prank(stranger);
        vm.expectRevert(TokenLock.NotBeneficiary.selector);
        lock.extend(unlock + 1);
    }

    function test_extend_afterExpiry_relocks() public {
        vm.warp(unlock + 1 days);
        vm.prank(safe);
        lock.extend(block.timestamp + 30 days);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TokenLock.StillLocked.selector, block.timestamp + 30 days));
        lock.withdraw(1);
    }

    /// After expiry, an "extension" to a time that has already passed would emit Extended while
    /// leaving the lock open — refused.
    function test_extend_afterExpiry_toAPastTime_reverts() public {
        vm.warp(unlock + 10 days);
        vm.prank(safe);
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        lock.extend(unlock + 5 days);
        vm.prank(safe);
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        lock.extend(block.timestamp);
    }

    function test_extend_beyondTenYearsByRepeatedSteps() public {
        vm.startPrank(safe);
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + 3000 days);
            lock.extend(block.timestamp + 3650 days);
        }
        vm.stopPrank();
        assertGt(lock.unlockTime(), block.timestamp);
    }

    // ── ETH ─────────────────────────────────────────────────────────────────

    function test_plainEthSend_reverts() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(lock).call{value: 1 ether}("");
        assertFalse(ok, "no receive(): ETH cannot be stranded by a plain send");
        assertEq(address(lock).balance, 0);
    }

    // ── fuzz ────────────────────────────────────────────────────────────────

    /// Before unlockTime, no caller, amount or time can move a single unit of the locked token.
    function testFuzz_lockedTokenNeverLeavesBeforeUnlock(address caller, uint256 amount, uint256 t) public {
        t = bound(t, block.timestamp, unlock - 1);
        vm.warp(t);
        vm.startPrank(caller);
        try lock.withdraw(amount) {} catch {}
        try lock.sweep(IERC20(address(locked))) {} catch {}
        vm.stopPrank();
        assertEq(locked.balanceOf(address(lock)), LOCKED);
    }

    /// Only the beneficiary can ever take anything, at any time.
    function testFuzz_strangerTakesNothing(address caller, uint256 amount, uint256 t) public {
        vm.assume(caller != safe);
        t = bound(t, block.timestamp, block.timestamp + 20 * 365 days);
        vm.warp(t);
        reward.mint(address(lock), 1 ether);
        vm.startPrank(caller);
        vm.expectRevert(TokenLock.NotBeneficiary.selector);
        lock.withdraw(amount);
        vm.expectRevert(TokenLock.NotBeneficiary.selector);
        lock.sweep(IERC20(address(reward)));
        vm.expectRevert(TokenLock.NotBeneficiary.selector);
        lock.extend(amount);
        vm.stopPrank();
        assertEq(locked.balanceOf(address(lock)), LOCKED);
        assertEq(reward.balanceOf(address(lock)), 1 ether);
    }

    /// unlockTime is monotonic under any sequence of extend attempts.
    function testFuzz_extendNeverShortens(uint256 a, uint256 b) public {
        uint256 before = lock.unlockTime();
        vm.startPrank(safe);
        try lock.extend(a) {} catch {}
        uint256 mid = lock.unlockTime();
        try lock.extend(b) {} catch {}
        vm.stopPrank();
        assertGe(mid, before);
        assertGe(lock.unlockTime(), mid);
    }
}
