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

/// @notice Answers the two Safe getters the deploy script reads; holds no other Safe logic.
contract MockSafe {
    address[] internal owners;
    uint256 internal threshold;

    constructor(address[] memory owners_, uint256 threshold_) {
        owners = owners_;
        threshold = threshold_;
    }

    function getOwners() external view returns (address[] memory) {
        return owners;
    }

    function getThreshold() external view returns (uint256) {
        return threshold;
    }
}

/// @notice An ERC-20 that also answers like a Safe, so a deploy-script check that runs after the
/// Safe-shape checks can be reached with the token as beneficiary.
contract SafeShapedToken is MockSafe {
    mapping(address => uint256) public balanceOf;

    constructor(address[] memory owners_, uint256 threshold_) MockSafe(owners_, threshold_) {}

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
