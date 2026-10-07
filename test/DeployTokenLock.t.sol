// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenLock} from "../src/TokenLock.sol";
import {DeployTokenLock, ISafe} from "../script/DeployTokenLock.s.sol";
import {MockERC20, MockSafe, SafeShapedToken} from "./mocks/Mocks.sol";

/// @notice Runs the real deploy script: `run()` end to end and a full lock lifecycle on what it
/// deployed, then every refusal of `preflight` and `postflight`.
/// The script reads `LOCK_*` from the process environment, which every test in the run shares
/// while they execute in parallel. `setUp` therefore sets the same values in every test (its
/// addresses and clock are deterministic) and a scenario that needs other inputs calls
/// `preflight`/`postflight` with arguments, or changes the chain id, never the environment.
contract DeployTokenLockTest is Test {
    uint256 constant T0 = 1_750_000_000;
    uint256 constant LOCKED = 1_000_000 ether;

    DeployTokenLock script;
    MockERC20 token;
    MockERC20 reward;
    MockSafe safe;
    address owner1 = makeAddr("owner1");
    address owner2 = makeAddr("owner2");
    address owner3 = makeAddr("owner3");
    address depositor = makeAddr("depositor");
    uint256 unlock;

    event Locked(address indexed token, address indexed beneficiary, uint256 unlockTime, uint256 maxUnlockTime);
    event Withdrawn(uint256 amount);
    event Swept(address indexed otherToken, uint256 amount);
    event Extended(uint256 oldUnlockTime, uint256 newUnlockTime);

    function setUp() public {
        vm.warp(T0);
        token = new MockERC20();
        reward = new MockERC20();
        safe = new MockSafe(_owners(owner1, owner2, owner3), 2);
        unlock = T0 + 90 days;
        script = new DeployTokenLock();
        vm.setEnv("LOCK_CHAIN_ID", vm.toString(block.chainid));
        vm.setEnv("LOCK_TOKEN", vm.toString(address(token)));
        vm.setEnv("LOCK_BENEFICIARY", vm.toString(address(safe)));
        vm.setEnv("LOCK_UNLOCK_TIME", vm.toString(unlock));
        vm.setEnv("LOCK_EXPECTED_OWNER", vm.toString(owner2));
    }

    // ── run(): deploy, then use the lock it deployed ────────────────────────

    function test_run_deploysTheEnvTerms_andTheLockWorksEndToEnd() public {
        vm.recordLogs();
        TokenLock lock = script.run();
        _assertLockedEvent(vm.getRecordedLogs(), address(lock));

        assertEq(address(lock.token()), address(token));
        assertEq(lock.beneficiary(), address(safe));
        assertEq(lock.unlockTime(), unlock);
        assertEq(lock.maxUnlockTime(), T0 + 3650 days);
        assertEq(lock.deployChainId(), block.chainid);
        assertEq(lock.tokenCodehash(), address(token).codehash);

        // deposit: a plain transfer in, from anyone
        token.mint(depositor, LOCKED);
        vm.prank(depositor);
        token.transfer(address(lock), LOCKED);

        // extend
        uint256 later = unlock + 30 days;
        vm.prank(address(safe));
        vm.expectEmit(address(lock));
        emit Extended(unlock, later);
        lock.extend(later);

        // the old unlock time no longer opens it
        vm.warp(unlock);
        vm.prank(address(safe));
        vm.expectRevert(abi.encodeWithSelector(TokenLock.StillLocked.selector, later));
        lock.withdraw(1);

        // another token is collectable while locked; the locked token is not
        reward.mint(address(lock), 5 ether);
        vm.prank(address(safe));
        vm.expectEmit(address(lock));
        emit Swept(address(reward), 5 ether);
        assertEq(lock.sweep(IERC20(address(reward))), 5 ether);
        vm.prank(address(safe));
        vm.expectRevert(TokenLock.LockedToken.selector);
        lock.sweep(IERC20(address(token)));

        // only the beneficiary can act
        vm.prank(owner1);
        vm.expectRevert(TokenLock.NotBeneficiary.selector);
        lock.withdraw(1);

        // at the new unlock time everything comes out
        vm.warp(later);
        vm.prank(address(safe));
        vm.expectEmit(address(lock));
        emit Withdrawn(LOCKED);
        lock.withdraw(LOCKED);

        assertEq(token.balanceOf(address(safe)), LOCKED);
        assertEq(token.balanceOf(address(lock)), 0);
        assertEq(reward.balanceOf(address(safe)), 5 ether);
    }

    function test_run_onAnotherChain_refuses() public {
        vm.chainId(block.chainid + 1);
        vm.expectRevert(bytes("unexpected chain id (LOCK_CHAIN_ID)"));
        script.run();
    }

    // ── preflight: every refusal, and its boundary ──────────────────────────

    function test_preflight_acceptsTheEnvTerms() public view {
        script.preflight(IERC20(address(token)), address(safe), unlock);
    }

    function test_preflight_refusesATokenWithNoCode() public {
        vm.expectRevert(bytes("token has no code on this chain"));
        script.preflight(IERC20(makeAddr("pasted-wallet")), address(safe), unlock);
    }

    function test_preflight_refusesABeneficiaryWithNoCode() public {
        vm.expectRevert(bytes("beneficiary has no code on this chain: not a Safe here"));
        script.preflight(IERC20(address(token)), owner1, unlock);
    }

    function test_preflight_refusesABeneficiaryWithoutGetThreshold() public {
        vm.expectRevert(bytes("beneficiary does not answer like a Safe"));
        script.preflight(IERC20(address(token)), address(reward), unlock);
    }

    function test_preflight_refusesABeneficiaryWithoutGetOwners() public {
        vm.mockCallRevert(address(safe), abi.encodeWithSelector(ISafe.getOwners.selector), "");
        vm.expectRevert(bytes("beneficiary does not answer like a Safe"));
        script.preflight(IERC20(address(token)), address(safe), unlock);
    }

    function test_preflight_refusesAZeroThreshold() public {
        MockSafe s = new MockSafe(_owners(owner1, owner2, owner3), 0);
        vm.expectRevert(bytes("beneficiary does not answer like a Safe"));
        script.preflight(IERC20(address(token)), address(s), unlock);
    }

    function test_preflight_refusesAThresholdAboveTheOwnerCount() public {
        address[] memory one = new address[](1);
        one[0] = owner2;
        MockSafe s = new MockSafe(one, 2);
        vm.expectRevert(bytes("beneficiary does not answer like a Safe"));
        script.preflight(IERC20(address(token)), address(s), unlock);
    }

    function test_preflight_refusesASafeWithoutTheExpectedOwner() public {
        MockSafe other = new MockSafe(_owners(owner1, owner3, makeAddr("owner4")), 2);
        vm.expectRevert(bytes("LOCK_EXPECTED_OWNER is not an owner of this Safe"));
        script.preflight(IERC20(address(token)), address(other), unlock);
    }

    function test_preflight_refusesAnUnlockWithinTwoHours_andAcceptsExactlyTwo() public {
        vm.expectRevert(bytes("unlock is in the past or within 2 h"));
        script.preflight(IERC20(address(token)), address(safe), block.timestamp + 2 hours - 1);
        script.preflight(IERC20(address(token)), address(safe), block.timestamp + 2 hours);
    }

    function test_preflight_refusesAnUnlockInThePast() public {
        vm.expectRevert(bytes("unlock is in the past or within 2 h"));
        script.preflight(IERC20(address(token)), address(safe), block.timestamp - 1);
    }

    function test_preflight_refusesAnUnlockBeyond3650Days_andAcceptsExactly3650() public {
        vm.expectRevert(bytes("unlock beyond 3650 days (seconds, not ms?)"));
        script.preflight(IERC20(address(token)), address(safe), block.timestamp + 3650 days + 1);
        script.preflight(IERC20(address(token)), address(safe), block.timestamp + 3650 days);
    }

    function test_preflight_refusesAMillisecondUnlock() public {
        vm.expectRevert(bytes("unlock beyond 3650 days (seconds, not ms?)"));
        script.preflight(IERC20(address(token)), address(safe), unlock * 1000);
    }

    function test_preflight_refusesTheTokenAsBeneficiary() public {
        SafeShapedToken both = new SafeShapedToken(_owners(owner1, owner2, owner3), 2);
        vm.expectRevert(bytes("beneficiary is the token"));
        script.preflight(IERC20(address(both)), address(both), unlock);
    }

    function test_preflight_onAnotherChain_refuses() public {
        vm.chainId(block.chainid + 1);
        vm.expectRevert(bytes("unexpected chain id (LOCK_CHAIN_ID)"));
        script.preflight(IERC20(address(token)), address(safe), unlock);
    }

    // ── postflight: the read-back catches a lock with other terms ───────────

    function test_postflight_acceptsALockWithTheIntendedTerms() public {
        TokenLock lock = new TokenLock(IERC20(address(token)), address(safe), unlock);
        script.postflight(lock, IERC20(address(token)), address(safe), unlock);
    }

    function test_postflight_refusesAnotherToken() public {
        TokenLock lock = new TokenLock(IERC20(address(reward)), address(safe), unlock);
        vm.expectRevert(bytes("read-back token mismatch"));
        script.postflight(lock, IERC20(address(token)), address(safe), unlock);
    }

    function test_postflight_refusesAnotherBeneficiary() public {
        TokenLock lock = new TokenLock(IERC20(address(token)), owner1, unlock);
        vm.expectRevert(bytes("read-back beneficiary mismatch"));
        script.postflight(lock, IERC20(address(token)), address(safe), unlock);
    }

    function test_postflight_refusesAnotherUnlockTime() public {
        TokenLock lock = new TokenLock(IERC20(address(token)), address(safe), unlock + 1);
        vm.expectRevert(bytes("read-back unlockTime mismatch"));
        script.postflight(lock, IERC20(address(token)), address(safe), unlock);
    }

    function test_postflight_refusesALockBoundToAnotherChain() public {
        TokenLock lock = new TokenLock(IERC20(address(token)), address(safe), unlock);
        vm.chainId(block.chainid + 1);
        vm.expectRevert(bytes("read-back deployChainId mismatch"));
        script.postflight(lock, IERC20(address(token)), address(safe), unlock);
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    function _owners(address a, address b, address c) internal pure returns (address[] memory o) {
        o = new address[](3);
        o[0] = a;
        o[1] = b;
        o[2] = c;
    }

    function _assertLockedEvent(Vm.Log[] memory logs, address lock) internal view {
        bytes32 sig = keccak256("Locked(address,address,uint256,uint256)");
        uint256 found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != lock || logs[i].topics[0] != sig) continue;
            found++;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(address(token)))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(address(safe)))));
            (uint256 u, uint256 ceiling) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(u, unlock);
            assertEq(ceiling, T0 + 3650 days);
        }
        assertEq(found, 1, "exactly one Locked event, from the deployed lock");
    }
}
