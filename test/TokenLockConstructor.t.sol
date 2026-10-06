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
        for (uint160 i = 0x02; i <= 0x04; i++) {
            address p = address(i);
            _assertCodelessAndAnswersWithAWord(p);
            assertEq(p.codehash, bytes32(0), "empty account");
            vm.expectRevert(TokenLock.NotAContract.selector);
            new TokenLock(IERC20(p), alice, block.timestamp + 1 days);

            vm.deal(p, 1);
            assertEq(p.codehash, keccak256(""), "1 wei moves the code hash");
            vm.expectRevert(TokenLock.NotAContract.selector);
            new TokenLock(IERC20(p), alice, block.timestamp + 1 days);
        }
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
