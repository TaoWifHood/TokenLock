// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenLock} from "../src/TokenLock.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @notice The constructor must refuse the two inputs that would make the locked token
/// unrecoverable: a token address with no code, and the lock as its own beneficiary.
contract TokenLockConstructorTest is Test {
    address alice = makeAddr("alice");

    function test_constructorRefusesACodelessToken() public {
        vm.expectRevert(TokenLock.NotAContract.selector);
        new TokenLock(IERC20(makeAddr("typo-token")), alice, block.timestamp + 1 days);
    }

    function test_constructorRefusesItselfAsBeneficiary() public {
        MockERC20 token = new MockERC20();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(TokenLock.BeneficiaryIsLock.selector);
        new TokenLock(IERC20(address(token)), predicted, block.timestamp + 1 days);
    }
}
