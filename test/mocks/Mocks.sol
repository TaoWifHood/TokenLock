// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal ERC-20 stand-in for the TokenLock tests: a balance map, `mint`, and a
/// `transfer` that returns true. Deliberately NOT a full ERC-20 — the lock only ever calls
/// `transfer` and `balanceOf` on a token.
contract MockERC20 {
    string public name = "Mock";
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
