// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenLock} from "../src/TokenLock.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @notice The constructor must refuse inputs that would make the locked token unrecoverable:
/// a token address that does not answer `balanceOf`, and the lock as its own beneficiary.
contract TokenLockConstructorTest is Test {
    address alice = makeAddr("alice");

    function test_constructorRefusesACodelessToken() public {
        vm.expectRevert(TokenLock.NotAContract.selector);
        new TokenLock(IERC20(makeAddr("typo-token")), alice, block.timestamp + 1 days);
    }

    /// An EOA with an EIP-7702 delegation has 23 bytes of code; code alone proves nothing.
    function test_constructorRefusesA7702DesignatedWallet() public {
        address wallet = makeAddr("pasted-wallet");
        vm.etch(wallet, abi.encodePacked(hex"ef0100", makeAddr("delegate")));
        assertEq(wallet.code.length, 23);
        vm.expectRevert(TokenLock.NotAContract.selector);
        new TokenLock(IERC20(wallet), alice, block.timestamp + 1 days);
    }

    function test_constructorRefusesAStopStub() public {
        address stub = makeAddr("stop-stub");
        vm.etch(stub, hex"00");
        vm.expectRevert(TokenLock.NotAContract.selector);
        new TokenLock(IERC20(stub), alice, block.timestamp + 1 days);
    }

    /// A precompile has no code yet answers any call, so the `balanceOf` probe alone would accept
    /// it: sha256 (0x02) and ripemd160 (0x03) return 32 bytes and identity (0x04) echoes the
    /// 36-byte calldata.
    function test_constructorRefusesTheSha256Precompile() public {
        _assertCodelessAndAnswersWithAWord(address(0x02));
        vm.expectRevert(TokenLock.NotAContract.selector);
        new TokenLock(IERC20(address(0x02)), alice, block.timestamp + 1 days);
    }

    function test_constructorRefusesTheIdentityPrecompile() public {
        _assertCodelessAndAnswersWithAWord(address(0x04));
        vm.expectRevert(TokenLock.NotAContract.selector);
        new TokenLock(IERC20(address(0x04)), alice, block.timestamp + 1 days);
    }

    function test_constructorRefusesTheRipemd160Precompile() public {
        _assertCodelessAndAnswersWithAWord(address(0x03));
        vm.expectRevert(TokenLock.NotAContract.selector);
        new TokenLock(IERC20(address(0x03)), alice, block.timestamp + 1 days);
    }

    /// The code hash of a codeless address moves from 0 to keccak256("") when it first receives
    /// ether, so a lock over one would pin 0 and anyone could brick `withdraw` with 1 wei. Such a
    /// lock cannot be built, whether or not the address already holds ether.
    function test_constructorRefusesAPrecompileBeforeAndAfterItHoldsEther() public {
        uint256 checked;
        for (uint160 i = 0x02; i <= 0x04; i++) {
            address p = address(i);
            _assertCodelessAndAnswersWithAWord(p);
            assertEq(p.codehash, bytes32(0), "empty account");
            assertEq(_deployRevertData(IERC20(p)), abi.encodeWithSelector(TokenLock.NotAContract.selector));

            vm.deal(p, 1);
            assertEq(p.codehash, keccak256(""), "1 wei moves the code hash");
            assertEq(_deployRevertData(IERC20(p)), abi.encodeWithSelector(TokenLock.NotAContract.selector));
            checked++;
        }
        assertEq(checked, 3, "every precompile was checked in both states");
    }

    /// A deployment that must revert mid-test goes through try/catch: with forge's dynamic test
    /// linking on, `vm.expectRevert` before a `new` ends the test at that revert and skips the rest.
    function _deployRevertData(IERC20 t) internal returns (bytes memory) {
        try new TokenLock(t, alice, block.timestamp + 1 days) {
            revert("deployed");
        } catch (bytes memory err) {
            return err;
        }
    }

    /// Every precompile is refused by name before any call is made, so one that burns the whole
    /// gas allowance on malformed input (modexp, the bn254 and blake2f precompiles) costs no more
    /// than any other refusal.
    function test_constructorRefusesEveryPrecompileByNameWithoutCallingIt() public {
        for (uint160 i = 0x01; i <= 0x0a; i++) {
            address p = address(i);
            assertEq(p.code.length, 0);
            uint256 before = gasleft();
            try new TokenLock(IERC20(p), alice, block.timestamp + 1 days) {
                fail();
            } catch (bytes memory err) {
                assertEq(bytes4(err), TokenLock.NotAContract.selector);
            }
            assertLt(before - gasleft(), 500_000, "refused without forwarding gas to the precompile");
        }
    }

    /// The contract has no minimum duration: a lock one second long is accepted and opens on time.
    function test_constructorAcceptsAOneSecondLock() public {
        MockERC20 token = new MockERC20();
        TokenLock l = new TokenLock(IERC20(address(token)), alice, block.timestamp + 1);
        token.mint(address(l), 5);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenLock.StillLocked.selector, block.timestamp + 1));
        l.withdraw(5);
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        l.withdraw(5);
        assertEq(token.balanceOf(alice), 5);
    }

    function _assertCodelessAndAnswersWithAWord(address a) internal view {
        assertEq(a.code.length, 0);
        (bool ok, bytes memory ret) = a.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        assertTrue(ok, "answers the probe");
        assertGe(ret.length, 32, "with at least a word");
    }

    function test_constructorRefusesItselfAsBeneficiary() public {
        MockERC20 token = new MockERC20();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(TokenLock.BeneficiaryIsLock.selector);
        new TokenLock(IERC20(address(token)), predicted, block.timestamp + 1 days);
    }
}
