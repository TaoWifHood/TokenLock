// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TokenLock} from "../src/TokenLock.sol";

interface ISafe {
    function getThreshold() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
}

/// @notice Deploys ONE TokenLock. The contract cannot notice a wrong token or a wrong
/// beneficiary, so this script refuses them BEFORE anything is sent — every check runs in
/// simulation. A wrong beneficiary strands everything forever; a wrong token locks nothing.
///
///   dry run (simulation only, nothing broadcast):
///     LOCK_CHAIN_ID=<chain id> LOCK_TOKEN=0x… LOCK_BENEFICIARY=<the Safe> LOCK_UNLOCK_TIME=<unix seconds> \
///       LOCK_EXPECTED_OWNER=<an owner you can name> \
///       forge script script/DeployTokenLock.s.sol --rpc-url $RPC
///   broadcast (needs a funded key):
///     … --broadcast --private-key $KEY
///   then: verify the source on the chain's explorer, send a SMALL test amount first, and eth_call
///   sweep(token) from the Safe — it must revert LockedToken.
contract DeployTokenLock is Script {
    /// The sequencer may stamp blocks up to ~1 h ahead of wall-clock; an unlock closer than
    /// this is almost certainly a mistake.
    uint256 constant MIN_LEAD = 2 hours;

    function run() external returns (TokenLock lock) {
        IERC20 token = IERC20(vm.envAddress("LOCK_TOKEN"));
        address beneficiary = vm.envAddress("LOCK_BENEFICIARY");
        uint256 unlockTime = vm.envUint("LOCK_UNLOCK_TIME");
        preflight(token, beneficiary, unlockTime);
        vm.startBroadcast();
        lock = new TokenLock(token, beneficiary, unlockTime);
        vm.stopBroadcast();
        postflight(lock, token, beneficiary, unlockTime);
    }

    function preflight(IERC20 token, address beneficiary, uint256 unlockTime) public view {
        // Refuse a deploy to any chain other than the one LOCK_CHAIN_ID names.
        require(block.chainid == vm.envUint("LOCK_CHAIN_ID"), "unexpected chain id (LOCK_CHAIN_ID)");
        require(address(token).code.length > 0, "token has no code on this chain");
        require(beneficiary.code.length > 0, "beneficiary has no code on this chain: not a Safe here");
        uint256 threshold;
        address[] memory owners;
        try ISafe(beneficiary).getThreshold() returns (uint256 t) {
            threshold = t;
        } catch {
            revert("beneficiary does not answer like a Safe");
        }
        try ISafe(beneficiary).getOwners() returns (address[] memory o) {
            owners = o;
        } catch {
            revert("beneficiary does not answer like a Safe");
        }
        require(threshold >= 1 && owners.length >= threshold, "beneficiary does not answer like a Safe");

        // The checks above prove the beneficiary is a Safe on this chain, not that it is the
        // intended one. LOCK_EXPECTED_OWNER names an owner the Safe must carry; unset, the
        // owner set is printed but not checked.
        address expected = vm.envOr("LOCK_EXPECTED_OWNER", address(0));
        if (expected == address(0)) {
            console2.log("WARNING: LOCK_EXPECTED_OWNER unset - the owner set below is NOT checked, only its shape");
        } else {
            bool found;
            for (uint256 i = 0; i < owners.length; i++) {
                if (owners[i] == expected) {
                    found = true;
                    break;
                }
            }
            require(found, "LOCK_EXPECTED_OWNER is not an owner of this Safe");
        }
        require(unlockTime >= block.timestamp + MIN_LEAD, "unlock is in the past or within 2 h");
        require(unlockTime <= block.timestamp + 3650 days, "unlock beyond 10 years (seconds, not ms?)");

        console2.log("token       ", address(token));
        console2.log("beneficiary ", beneficiary);
        console2.log("  threshold ", threshold);
        for (uint256 i = 0; i < owners.length; i++) console2.log("  owner     ", owners[i]);
        console2.log("unlockTime  ", unlockTime);
        console2.log("  days from now", (unlockTime - block.timestamp) / 1 days);
    }

    function postflight(TokenLock lock, IERC20 token, address beneficiary, uint256 unlockTime) public view {
        require(address(lock.token()) == address(token), "read-back token mismatch");
        require(lock.beneficiary() == beneficiary, "read-back beneficiary mismatch");
        require(lock.unlockTime() == unlockTime, "read-back unlockTime mismatch");
        console2.log("TokenLock at", address(lock));
    }
}
