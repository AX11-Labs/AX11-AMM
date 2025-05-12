// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity 0.8.28;

import {IAx11Lp} from '../interfaces/IAx11Lp.sol';

/**
 * @title Ax11Lp
 * @notice Implementation of the IAx11Lp interface for LP token management
 * @dev This contract implements a TTL (Time-To-Live) based token approval system instead of the standard ERC20 amount-based allowance.
 *      The allowance mapping stores block timestamps as values, where a timestamp greater than the current block.timestamp
 *      indicates an active approval. This provides a time-limited approval mechanism where approvals automatically expire.
 *      This differs from standard ERC20 where allowances are amount-based and must be explicitly revoked.
 */
abstract contract Ax11Lp is IAx11Lp {
    /*//////////////////////////////////////////////////////////////
                              ERC20 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Total supply of LP tokens
    LpInfo internal _totalSupply;

    /// @notice Mapping of account addresses to their LP token balances
    mapping(address => LpInfo) public override balanceOf;

    /// @notice Tracks the timestamp-based allowances for token transfers
    /// @dev Uses block.timestamp as the approval metric. A timestamp greater than current block.timestamp indicates an active approval.
    ///      This implements a TTL (Time-To-Live) based approval system where approvals automatically expire.
    mapping(address => mapping(address => uint256)) public override allowance;

    /// @notice Mapping of account addresses to their nonces for permit functionality
    mapping(address => uint256) public override nonces;

    /// @notice Name of the token
    string public override name;

    /// @notice Symbol of the token
    string public override symbol;

    /// @notice Number of decimals used by the token
    uint8 public constant override decimals = 18;

    /// @notice Initial chain ID for domain separator computation
    uint256 private immutable INITIAL_CHAIN_ID;

    /// @notice Initial domain separator for permit functionality
    bytes32 private immutable INITIAL_DOMAIN_SEPARATOR;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructs the Ax11Lp contract
    /// @param _name The name of the token
    /// @param _symbol The symbol of the token
    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();
    }

    /*//////////////////////////////////////////////////////////////
                              ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the total supply of LP tokens
    /// @return The total supply information containing long and short positions
    function totalSupply() public view override returns (LpInfo memory) {
        return _totalSupply;
    }

    /// @notice Approves or revokes permission for a spender to transfer tokens
    /// @param spender The address to approve or revoke permission for
    /// @param value block timstamp limit
    /// @return A boolean indicating whether the operation succeeded
    function approve(address spender, uint256 value) public returns (bool) {
        address owner = msg.sender;
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
        return true;
    }

    /// @notice Transfers LP tokens to another address
    /// @param to The address to transfer tokens to
    /// @param longX The amount of long position X tokens to transfer
    /// @param longY The amount of long position Y tokens to transfer
    /// @param shortX The amount of short position X tokens to transfer
    /// @param shortY The amount of short position Y tokens to transfer
    /// @return A boolean indicating whether the transfer succeeded
    function transfer(address to, uint256 longX, uint256 longY, uint256 shortX, uint256 shortY) public returns (bool) {
        require(to != address(this), INVALID_ADDRESS());

        LpInfo storage lpInfo_from = balanceOf[msg.sender];
        lpInfo_from.longX -= longX;
        lpInfo_from.longY -= longY;
        lpInfo_from.shortX -= shortX;
        lpInfo_from.shortY -= shortY;

        LpInfo storage lpInfo_to = balanceOf[to];
        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            lpInfo_to.longX += longX;
            lpInfo_to.longY += longY;
            lpInfo_to.shortX += shortX;
            lpInfo_to.shortY += shortY;
        }
        emit Transfer(msg.sender, to, longX, longY, shortX, shortY);

        return true;
    }

    /// @notice Transfers LP tokens from one address to another
    /// @param from The address to transfer tokens from
    /// @param to The address to transfer tokens to
    /// @param longX The amount of long position X tokens to transfer
    /// @param longY The amount of long position Y tokens to transfer
    /// @param shortX The amount of short position X tokens to transfer
    /// @param shortY The amount of short position Y tokens to transfer
    /// @return A boolean indicating whether the transfer succeeded
    function transferFrom(
        address from,
        address to,
        uint256 longX,
        uint256 longY,
        uint256 shortX,
        uint256 shortY
    ) public returns (bool) {
        require(to != address(this), INVALID_ADDRESS());
        require(allowance[from][msg.sender] >= block.timestamp, INSUFFICIENT_ALLOWANCE());

        LpInfo storage lpInfo_from = balanceOf[from];
        lpInfo_from.longX -= longX;
        lpInfo_from.longY -= longY;
        lpInfo_from.shortX -= shortX;
        lpInfo_from.shortY -= shortY;

        LpInfo storage lpInfo_to = balanceOf[to];
        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            lpInfo_to.longX += longX;
            lpInfo_to.longY += longY;
            lpInfo_to.shortX += shortX;
            lpInfo_to.shortY += shortY;
        }
        emit Transfer(from, to, longX, longY, shortX, shortY);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                              EIP-2612
    //////////////////////////////////////////////////////////////*/

    /// @notice Approves a spender to transfer tokens using a signature
    /// @param owner The address of the token owner
    /// @param spender The address to approve or revoke permission for
    /// @param value the block timestamp limit
    /// @param deadline The time at which the signature expires
    /// @param v The recovery byte of the signature
    /// @param r Half of the ECDSA signature pair
    /// @param s Half of the ECDSA signature pair
    /// @return A boolean indicating whether the operation succeeded
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override returns (bool) {
        require(deadline >= block.timestamp, EXPIRED());
        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            address recoveredAddress = ecrecover(
                keccak256(
                    abi.encodePacked(
                        '\x19\x01',
                        DOMAIN_SEPARATOR(),
                        keccak256(
                            abi.encode(
                                keccak256(
                                    'Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)'
                                ),
                                owner,
                                spender,
                                value,
                                nonces[owner]++,
                                deadline
                            )
                        )
                    )
                ),
                v,
                r,
                s
            );

            require(recoveredAddress != address(0) && recoveredAddress == owner, INVALID_ADDRESS());
            allowance[owner][spender] = value;
        }

        emit Approval(owner, spender, value);
        return true;
    }

    /// @notice Returns the domain separator used in the permit signature
    /// @return The domain separator
    function DOMAIN_SEPARATOR() public view override returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    /// @notice Computes the domain separator for permit functionality
    /// @return The computed domain separator
    function computeDomainSeparator() private view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f, //keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                    keccak256(bytes(name)),
                    0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6, //keccak256("1")
                    block.chainid,
                    address(this)
                )
            );
    }

    /*//////////////////////////////////////////////////////////////
                              Mint & Burn
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints new LP tokens to an address
    /// @param to The address to mint tokens to
    /// @param longX The amount of long position X tokens to mint
    /// @param longY The amount of long position Y tokens to mint
    /// @param shortX The amount of short position X tokens to mint
    /// @param shortY The amount of short position Y tokens to mint
    function _mint(address to, uint256 longX, uint256 longY, uint256 shortX, uint256 shortY) internal {
        LpInfo storage lpInfo_total = _totalSupply;
        lpInfo_total.longX += longX;
        lpInfo_total.longY += longY;
        lpInfo_total.shortX += shortX;
        lpInfo_total.shortY += shortY;

        LpInfo storage lpInfo_bal = balanceOf[to];
        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            lpInfo_bal.longX += longX;
            lpInfo_bal.longY += longY;
            lpInfo_bal.shortX += shortX;
            lpInfo_bal.shortY += shortY;
        }

        emit Transfer(address(0), to, longX, longY, shortX, shortY);
    }

    /// @notice Burns LP tokens from an address
    /// @param from The address to burn tokens from
    /// @param longX The amount of long position X tokens to burn
    /// @param longY The amount of long position Y tokens to burn
    /// @param shortX The amount of short position X tokens to burn
    /// @param shortY The amount of short position Y tokens to burn
    function _burn(address from, uint256 longX, uint256 longY, uint256 shortX, uint256 shortY) internal {
        LpInfo storage lpInfo_bal = balanceOf[from];
        lpInfo_bal.longX -= longX;
        lpInfo_bal.longY -= longY;
        lpInfo_bal.shortX -= shortX;
        lpInfo_bal.shortY -= shortY;

        LpInfo storage lpInfo_total = _totalSupply;
        // Cannot underflow because a user's balance
        // will never be larger than the total supply.
        unchecked {
            lpInfo_total.longX -= longX;
            lpInfo_total.longY -= longY;
            lpInfo_total.shortX -= shortX;
            lpInfo_total.shortY -= shortY;
        }

        emit Transfer(from, address(0), longX, longY, shortX, shortY);
    }
}
