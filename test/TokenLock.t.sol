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

/// @notice Takes `feeBps` of every transfer unless the sender or the receiver is excluded;
/// the fee leaves circulation.
contract FeeOnTransferERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) public excluded;
    uint256 public feeBps;
    constructor(uint256 feeBps_) { feeBps = feeBps_; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function exclude(address a) external { excluded[a] = true; }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        uint256 fee = excluded[msg.sender] || excluded[to] ? 0 : amount * feeBps / 10_000;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount - fee;
        return true;
    }
}

/// @notice Answers `balanceOf` and returns true from `transfer` without moving anything.
contract PhantomERC20 {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address, uint256) external pure returns (bool) { return true; }
}

/// @notice Forwards any call from anyone: identity without authorisation.
contract OpenRelay {
    function forward(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "forwarded call reverted");
        return ret;
    }
}

interface ITokenReceiver {
    function onTokenReceived(uint256 amount) external;
}

/// @notice Notifies a receiving contract inside `transfer`, so the receiver can act before the
/// transfer returns.
contract HookERC20 {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (to.code.length > 0) ITokenReceiver(to).onTokenReceived(amount);
        return true;
    }
}

/// @notice Passes on everything it receives the moment it arrives.
contract ForwardingBeneficiary is ITokenReceiver {
    HookERC20 public immutable token;
    address public immutable sink;
    constructor(HookERC20 token_, address sink_) { token = token_; sink = sink_; }
    function onTokenReceived(uint256 amount) external { token.transfer(sink, amount); }
    function call(address target, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) assembly { revert(add(ret, 32), mload(ret)) }
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

    event Locked(address indexed token, address indexed beneficiary, uint256 unlockTime, uint256 maxUnlockTime);
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

    /// The token as beneficiary would seal every exit: only the token could call, and it never does.
    function test_constructor_rejectsTheTokenAsBeneficiary() public {
        vm.expectRevert(TokenLock.BeneficiaryIsToken.selector);
        new TokenLock(IERC20(address(locked)), address(locked), unlock);
    }

    function test_constructor_rejectsNowOrPast() public {
        bytes memory bad = abi.encodeWithSelector(TokenLock.BadUnlockTime.selector);
        assertEq(_deployRevertData(block.timestamp), bad, "now");
        assertEq(_deployRevertData(block.timestamp - 1), bad, "one second ago");
    }

    /// A deployment that must revert mid-test goes through try/catch: with forge's dynamic test
    /// linking on, `vm.expectRevert` before a `new` ends the test at that revert and skips the rest.
    function _deployRevertData(uint256 unlockTime_) internal returns (bytes memory) {
        try new TokenLock(IERC20(address(locked)), safe, unlockTime_) {
            revert("deployed");
        } catch (bytes memory err) {
            return err;
        }
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

    /// sweep never calls into its own beneficiary or into itself.
    function test_sweep_beneficiaryOrSelfAsToken_reverts() public {
        vm.startPrank(safe);
        vm.expectRevert(TokenLock.NotSweepable.selector);
        lock.sweep(IERC20(safe));
        vm.expectRevert(TokenLock.NotSweepable.selector);
        lock.sweep(IERC20(address(lock)));
        vm.stopPrank();
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

    /// An address with no code is refused by name before any call, including a precompile
    /// that would otherwise consume the whole gas allowance.
    function test_sweep_addressWithoutCode_revertsNotAContract() public {
        vm.startPrank(safe);
        vm.expectRevert(TokenLock.NotAContract.selector);
        lock.sweep(IERC20(stranger));
        vm.expectRevert(TokenLock.NotAContract.selector);
        lock.sweep(IERC20(address(0x05)));
        vm.stopPrank();
    }

    /// The zero address, every precompile and an EOA are refused by name, and none of them is
    /// called, so a precompile that burns all forwarded gas on malformed input costs nothing.
    function test_sweep_everyAddressWithoutCode_revertsNotAContractWithoutCallingIt() public {
        address[] memory targets = new address[](12);
        targets[0] = address(0);
        for (uint160 i = 1; i <= 10; i++) targets[i] = address(i);
        targets[11] = stranger;
        vm.startPrank(safe);
        for (uint256 i; i < targets.length; i++) {
            assertEq(targets[i].code.length, 0);
            uint256 before = gasleft();
            try lock.sweep(IERC20(targets[i])) {
                fail();
            } catch (bytes memory err) {
                assertEq(err, abi.encodeWithSelector(TokenLock.NotAContract.selector));
            }
            assertLt(before - gasleft(), 50_000, "refused without forwarding gas to the target");
        }
        vm.stopPrank();
    }

    /// The beneficiary may have no code at deployment and gain it later (an EIP-7702 delegation,
    /// a counterfactual deployment); `sweep` still refuses it, without calling it.
    function test_sweep_beneficiaryThatGainsCodeLater_isStillRefused() public {
        assertEq(safe.code.length, 0, "codeless at deployment");
        vm.etch(safe, type(ReentrantERC20).runtimeCode);
        ReentrantERC20(safe).setLock(lock);
        ReentrantERC20(safe).mint(address(lock), 5);

        vm.expectCall(safe, abi.encodeWithSelector(IERC20.balanceOf.selector), 0);
        vm.expectCall(safe, abi.encodeWithSelector(IERC20.transfer.selector), 0);
        vm.prank(safe);
        vm.expectRevert(TokenLock.NotSweepable.selector);
        lock.sweep(IERC20(safe));

        reward.mint(address(lock), 1);
        vm.prank(safe);
        assertEq(lock.sweep(IERC20(address(reward))), 1, "the beneficiary still operates the lock");
    }

    /// An address argument with dirty upper bits is refused by the ABI decoder before any check.
    function test_sweep_dirtyAddressBits_revert() public {
        bytes memory data =
            abi.encodePacked(TokenLock.sweep.selector, bytes32(uint256(uint160(address(locked))) | (uint256(1) << 160)));
        vm.prank(safe);
        (bool ok, bytes memory ret) = address(lock).call(data);
        assertFalse(ok);
        assertEq(ret.length, 0, "the decoder reverts with no data");
        assertEq(locked.balanceOf(address(lock)), LOCKED);
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

    // ── token code pin ──────────────────────────────────────────────────────

    function test_constructor_emitsTheStartingTerms() public {
        vm.expectEmit(true, true, false, true);
        emit Locked(address(locked), safe, unlock, block.timestamp + 3650 days);
        new TokenLock(IERC20(address(locked)), safe, unlock);
    }

    function test_constructor_pinsTheTokenCodehash() public view {
        assertEq(lock.tokenCodehash(), address(locked).codehash);
    }

    /// Code replaced at the token's address (possible where SELFDESTRUCT still deletes code)
    /// makes withdraw refuse, naming both hashes.
    function test_withdraw_tokenCodeChanged_reverts() public {
        bytes32 deployed = address(locked).codehash;
        vm.etch(address(locked), type(PhantomERC20).runtimeCode);
        bytes32 current = address(locked).codehash;
        vm.warp(unlock);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TokenLock.TokenCodeChanged.selector, deployed, current));
        lock.withdraw(1);
    }

    /// The pin is checked before the time gate, so a lock whose token changed reports it during
    /// the locked period instead of looking healthy until unlockTime.
    function test_withdraw_tokenCodeChanged_beforeUnlock_reportsTheChange() public {
        bytes32 deployed = address(locked).codehash;
        vm.etch(address(locked), type(PhantomERC20).runtimeCode);
        bytes32 current = address(locked).codehash;
        assertLt(block.timestamp, unlock);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TokenLock.TokenCodeChanged.selector, deployed, current));
        lock.withdraw(1);
    }

    /// Ether at the token's address leaves a contract's code hash alone. `vm.deal` stands in for a
    /// forced send, since the token has no payable function.
    function test_withdraw_oneWeiSentToTheToken_changesNothing() public {
        bytes32 deployed = address(locked).codehash;
        vm.deal(address(locked), 1);
        assertEq(address(locked).codehash, deployed);
        assertEq(lock.tokenCodehash(), deployed);

        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TokenLock.StillLocked.selector, unlock));
        lock.withdraw(1);

        vm.warp(unlock);
        vm.prank(safe);
        vm.expectEmit(address(lock));
        emit Withdrawn(LOCKED);
        lock.withdraw(LOCKED);
        assertEq(locked.balanceOf(safe), LOCKED);
    }

    // ── measured delivery ───────────────────────────────────────────────────

    function _lockOf(address tokenAddr) internal returns (TokenLock l) {
        l = new TokenLock(IERC20(tokenAddr), safe, unlock);
    }

    function test_withdraw_feeOnTransfer_reportsWhatArrived() public {
        FeeOnTransferERC20 taxed = new FeeOnTransferERC20(300);
        TokenLock l = _lockOf(address(taxed));
        taxed.mint(address(l), 1000);
        vm.warp(unlock);
        vm.expectEmit(address(l));
        emit Withdrawn(970);
        vm.prank(safe);
        l.withdraw(1000);
        assertEq(taxed.balanceOf(safe), 970);
        assertEq(taxed.balanceOf(address(l)), 0);
    }

    function test_withdraw_feeOnTransfer_excludedLock_deliversInFull() public {
        FeeOnTransferERC20 taxed = new FeeOnTransferERC20(300);
        TokenLock l = _lockOf(address(taxed));
        taxed.exclude(address(l));
        taxed.mint(address(l), 1000);
        vm.warp(unlock);
        vm.expectEmit(address(l));
        emit Withdrawn(1000);
        vm.prank(safe);
        l.withdraw(1000);
        assertEq(taxed.balanceOf(safe), 1000);
    }

    /// A transfer that delivers nothing reverts, so the tokens stay in the lock.
    function test_withdraw_fullTax_revertsAndKeepsTheBalance() public {
        FeeOnTransferERC20 taxed = new FeeOnTransferERC20(10_000);
        TokenLock l = _lockOf(address(taxed));
        taxed.mint(address(l), 1000);
        vm.warp(unlock);
        vm.prank(safe);
        vm.expectRevert(TokenLock.NothingDelivered.selector);
        l.withdraw(1000);
        assertEq(taxed.balanceOf(address(l)), 1000);
    }

    function test_withdraw_phantomTransfer_reverts() public {
        PhantomERC20 phantom = new PhantomERC20();
        TokenLock l = _lockOf(address(phantom));
        phantom.mint(address(l), 1000);
        vm.warp(unlock);
        vm.prank(safe);
        vm.expectRevert(TokenLock.NothingDelivered.selector);
        l.withdraw(1000);
    }

    function test_withdraw_zero_isAllowedAndReportsZero() public {
        vm.warp(unlock);
        vm.expectEmit(address(lock));
        emit Withdrawn(0);
        vm.prank(safe);
        lock.withdraw(0);
        assertEq(locked.balanceOf(address(lock)), LOCKED);
    }

    function test_sweep_feeOnTransferReward_returnsWhatArrived() public {
        FeeOnTransferERC20 taxedReward = new FeeOnTransferERC20(300);
        taxedReward.mint(address(lock), 1000);
        vm.expectEmit(address(lock));
        emit Swept(address(taxedReward), 970);
        vm.prank(safe);
        assertEq(lock.sweep(IERC20(address(taxedReward))), 970);
        assertEq(taxedReward.balanceOf(safe), 970);
    }

    function test_sweep_phantomTransfer_reverts() public {
        PhantomERC20 phantom = new PhantomERC20();
        phantom.mint(address(lock), 5);
        vm.prank(safe);
        vm.expectRevert(TokenLock.NothingDelivered.selector);
        lock.sweep(IERC20(address(phantom)));
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

    function test_constructor_setsTheCeilingAtDeploy() public view {
        assertEq(lock.maxUnlockTime(), 1_750_000_000 + 3650 days);
    }

    function test_extend_toTheCeiling_succeeds_andOneSecondMore_reverts() public {
        uint256 ceiling = lock.maxUnlockTime();
        vm.startPrank(safe);
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        lock.extend(ceiling + 1);
        lock.extend(ceiling);
        vm.stopPrank();
        assertEq(lock.unlockTime(), ceiling);
    }

    /// Repeated extensions over time can never carry the lock past the ceiling fixed at deploy.
    function test_extend_repeatedStepsStopAtTheCeiling() public {
        uint256 ceiling = lock.maxUnlockTime();
        vm.startPrank(safe);
        vm.warp(block.timestamp + 3000 days);
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        lock.extend(block.timestamp + 3650 days);
        lock.extend(ceiling);
        vm.warp(ceiling + 1);
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        lock.extend(block.timestamp + 1);
        lock.withdraw(LOCKED);
        vm.stopPrank();
        assertEq(locked.balanceOf(safe), LOCKED);
    }

    /// An expired lock can be re-locked, but only up to the ceiling — never a fresh 3650 days.
    function test_extend_afterExpiry_relockIsBoundedByTheCeiling() public {
        vm.warp(unlock + 1 days);
        uint256 ceiling = lock.maxUnlockTime();
        vm.startPrank(safe);
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        lock.extend(block.timestamp + 3650 days);
        lock.extend(ceiling);
        vm.stopPrank();
        assertEq(lock.unlockTime(), ceiling);
    }

    /// The contract has no minimum duration: an expired lock can be re-locked for one second.
    function test_extend_afterExpiry_acceptsAOneSecondRelock() public {
        vm.warp(unlock + 1 days);
        vm.prank(safe);
        lock.extend(block.timestamp + 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TokenLock.StillLocked.selector, block.timestamp + 1));
        lock.withdraw(1);
        vm.warp(block.timestamp + 1);
        vm.prank(safe);
        lock.withdraw(1);
        assertEq(locked.balanceOf(safe), 1);
    }

    /// Opening is not latched: if the chain's clock moves back below `unlockTime` (a reorg), the
    /// lock is closed again until the clock passes it once more.
    function test_withdraw_isNotLatched_aClockThatMovesBackClosesTheLockAgain() public {
        vm.warp(unlock);
        vm.prank(safe);
        lock.withdraw(1);
        vm.warp(unlock - 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TokenLock.StillLocked.selector, unlock));
        lock.withdraw(1);
        vm.warp(unlock);
        vm.prank(safe);
        lock.withdraw(1);
        assertEq(locked.balanceOf(safe), 2);
    }

    // ── what the beneficiary must be ────────────────────────────────────────

    /// `msg.sender == beneficiary` is an identity check: a beneficiary that forwards anyone's
    /// call lets anyone extend, and after unlock withdraw and take the balance.
    function test_openRelayBeneficiary_letsAnyoneActThroughIt() public {
        OpenRelay relay = new OpenRelay();
        TokenLock l = new TokenLock(IERC20(address(locked)), address(relay), unlock);
        locked.mint(address(l), 100);

        vm.startPrank(stranger);
        relay.forward(address(l), abi.encodeCall(TokenLock.extend, (unlock + 1 days)));
        assertEq(l.unlockTime(), unlock + 1 days, "a stranger moved the unlock");
        vm.warp(unlock + 1 days);
        relay.forward(address(l), abi.encodeCall(TokenLock.withdraw, (100)));
        relay.forward(address(locked), abi.encodeCall(MockERC20.transfer, (stranger, 100)));
        vm.stopPrank();
        assertEq(locked.balanceOf(stranger), 100, "a stranger took the balance");
    }

    /// Delivery is measured on the beneficiary's balance, so a beneficiary that passes tokens on
    /// as they arrive shows no increase and the withdrawal reverts with the tokens still locked.
    function test_beneficiaryThatForwardsOnReceipt_cannotWithdraw() public {
        HookERC20 hooked = new HookERC20();
        ForwardingBeneficiary fwd = new ForwardingBeneficiary(hooked, stranger);
        TokenLock l = new TokenLock(IERC20(address(hooked)), address(fwd), unlock);
        hooked.mint(address(l), 100);
        vm.warp(unlock);
        vm.expectRevert(TokenLock.NothingDelivered.selector);
        fwd.call(address(l), abi.encodeCall(TokenLock.withdraw, (100)));
        assertEq(hooked.balanceOf(address(l)), 100);
    }

    // ── chain binding ───────────────────────────────────────────────────────

    /// A lock at the same address on another chain is a different contract's state: every
    /// beneficiary action reverts there.
    function test_everyAction_onAnotherChain_reverts() public {
        uint256 home = block.chainid;
        assertEq(lock.deployChainId(), home);
        vm.warp(unlock);
        vm.chainId(home + 1);
        bytes memory err = abi.encodeWithSelector(TokenLock.WrongChain.selector, home, home + 1);
        vm.startPrank(safe);
        vm.expectRevert(err);
        lock.withdraw(1);
        vm.expectRevert(err);
        lock.sweep(IERC20(address(reward)));
        vm.expectRevert(err);
        lock.extend(unlock + 1 days);
        vm.chainId(home);
        lock.withdraw(1);
        vm.stopPrank();
        assertEq(locked.balanceOf(safe), 1);
    }

    // ── ETH ─────────────────────────────────────────────────────────────────

    function test_unknownSelector_reverts() public {
        vm.deal(safe, 1 ether);
        vm.prank(safe);
        (bool ok,) = address(lock).call(abi.encodeWithSignature("transferOwnership(address)", stranger));
        assertFalse(ok, "no fallback");
        vm.prank(safe);
        (ok,) = address(lock).call{value: 1}(abi.encodeCall(TokenLock.extend, (unlock + 1)));
        assertFalse(ok, "no payable function");
        assertEq(lock.unlockTime(), unlock);
    }

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

    /// Any time between now and the current unlockTime is refused, at any moment before unlock.
    function testFuzz_extendToAnEarlierFutureTimeIsRefused(uint256 t, uint256 a) public {
        vm.warp(bound(t, block.timestamp, unlock - 2));
        a = bound(a, block.timestamp + 1, unlock - 1);
        vm.prank(safe);
        vm.expectRevert(TokenLock.BadUnlockTime.selector);
        lock.extend(a);
        assertEq(lock.unlockTime(), unlock);
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
        assertLe(lock.unlockTime(), lock.maxUnlockTime());
    }
}
