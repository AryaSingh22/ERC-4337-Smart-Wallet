// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

contract Script {
    function vm() internal pure returns (Vm) {
        return Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    }
}

interface Vm {
    function envUint(string calldata) external view returns (uint256);
    function addr(uint256) external pure returns (address);
    function startBroadcast(uint256) external;
    function stopBroadcast() external;
    function console_log(string calldata) external;
    function console_log(address) external;
}

contract console {
    function log(string memory p0) internal pure {
        // Console logging in Foundry
    }
    
    function log(address p0) internal pure {
        // Console logging in Foundry
    }
} 