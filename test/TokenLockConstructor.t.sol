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

    function test_constructorRefusesItselfAsBeneficiary() public {
        MockERC20 token = new MockERC20();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(TokenLock.BeneficiaryIsLock.selector);
        new TokenLock(IERC20(address(token)), predicted, block.timestamp + 1 days);
    }
}
