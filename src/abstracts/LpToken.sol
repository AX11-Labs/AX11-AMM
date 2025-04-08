// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {ILpToken} from "../interfaces/ILpToken.sol";
import {IERC20} from "../interfaces/IERC20.sol";

abstract contract LpToken is ILpToken, IERC20 {
    //tokenId -> total supply
    mapping(uint256 => uint256) public override totalSupply;
    //account -> tokenId -> balance
    mapping(address => mapping(uint256 => uint256)) public override balanceOf;
    //owner -> spender -> tokenId -> value
    mapping(address => mapping(address => mapping(uint256 => uint256))) public override allowance;
    //owner -> tokenId -> nonce
    mapping(address => mapping(uint256 => uint256)) public override nonces;

    string public override name;
    string public override symbol;
    uint256 private immutable INITIAL_CHAIN_ID;
    bytes32 private immutable INITIAL_DOMAIN_SEPARATOR;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();

        _mint(address(0), 0, 512);
        _mint(address(0), 1, 512);
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function approve(address spender, uint256 tokenId, uint256 value) public override returns (bool) {
        address owner = msg.sender;
        allowance[owner][spender][tokenId] = value;
        emit Approval(owner, spender, tokenId, value);
        return true;
    }

    function transfer(address to, uint256 tokenId, uint256 value) public override returns (bool) {
        balanceOf[msg.sender][tokenId] -= value;
        unchecked {
            balanceOf[to][tokenId] += value;
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 tokenId, uint256 value) public override returns (bool) {
        address spender = msg.sender;
        allowance[from][spender][tokenId] -= value;
        balanceOf[from][tokenId] -= value;
        unchecked {
            balanceOf[to][tokenId] += value;
        }

        return true;
    }

    //-------------- EIP-2612 --------------
    function permit(
        address owner,
        address spender,
        uint256 tokenId,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override returns (bool) {
        require(deadline >= block.timestamp, "PERMIT_DEADLINE_EXPIRED");

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        "\x19\x01",
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                0x93037fc845480aac4c562d214e72cb9220787dd72ac4dca809b5c61e2d23a672, // keccak256("Permit(address owner,address spender,uint256 tokenId,uint256 value,uint256 nonce,uint256 deadline)")
                                owner,
                                spender,
                                tokenId,
                                value,
                                nonces[owner][tokenId]++,
                                deadline
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            require(recoveredAddress != address(0) && recoveredAddress == owner, "INVALID_SIGNER");

            allowance[owner][spender][tokenId] = value;
        }

        emit Approval(owner, spender, tokenId, value);
        return true;
    }

    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    function computeDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f, //keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                keccak256(bytes(name)),
                0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6, //keccak256("1")
                block.chainid,
                address(this)
            )
        );
    }

    // ------- mint & burn ------
    function _mint(address to, uint256 tokenId, uint256 value) internal {
        totalSupply[tokenId] += value;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to][tokenId] += value;
        }

        emit Transfer(address(0), to, tokenId, value);
    }

    function _burn(address from, uint256 tokenId, uint256 value) internal {
        balanceOf[from][tokenId] -= value;

        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            totalSupply[tokenId] -= value;
        }

        emit Transfer(from, address(0), tokenId, value);
    }
}
