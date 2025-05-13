// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.28;

library PriceMath {
    error FullMulDivFailed();
    error DivFailed();
    error powFailed();
    /// @dev Calculates `floor(x * y / d)` with full precision.
    /// Throws if result overflows a uint256 or when `d` is zero.
    /// Credit to Remco Bloemen under MIT license: https://2π.com/21/muldiv
    function fullMulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            // 512-bit multiply `[p1 p0] = x * y`.
            // Compute the product mod `2**256` and mod `2**256 - 1`
            // then use the Chinese Remainder Theorem to reconstruct
            // the 512 bit result. The result is stored in two 256
            // variables such that `product = p1 * 2**256 + p0`.

            // Temporarily use `z` as `p0` to save gas.
            z := mul(x, y) // Lower 256 bits of `x * y`.
            for {

            } 1 {

            } {
                // If overflows.
                if iszero(mul(or(iszero(x), eq(div(z, x), y)), d)) {
                    let mm := mulmod(x, y, not(0))
                    let p1 := sub(mm, add(z, lt(mm, z))) // Upper 256 bits of `x * y`.

                    /*------------------- 512 by 256 division --------------------*/

                    // Make division exact by subtracting the remainder from `[p1 p0]`.
                    let r := mulmod(x, y, d) // Compute remainder using mulmod.
                    let t := and(d, sub(0, d)) // The least significant bit of `d`. `t >= 1`.
                    // Make sure `z` is less than `2**256`. Also prevents `d == 0`.
                    // Placing the check here seems to give more optimal stack operations.
                    if iszero(gt(d, p1)) {
                        mstore(0x00, 0xae47f702) // `FullMulDivFailed()`.
                        revert(0x1c, 0x04)
                    }
                    d := div(d, t) // Divide `d` by `t`, which is a power of two.
                    // Invert `d mod 2**256`
                    // Now that `d` is an odd number, it has an inverse
                    // modulo `2**256` such that `d * inv = 1 mod 2**256`.
                    // Compute the inverse by starting with a seed that is correct
                    // correct for four bits. That is, `d * inv = 1 mod 2**4`.
                    let inv := xor(2, mul(3, d))
                    // Now use Newton-Raphson iteration to improve the precision.
                    // Thanks to Hensel's lifting lemma, this also works in modular
                    // arithmetic, doubling the correct bits in each step.
                    inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**8
                    inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**16
                    inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**32
                    inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**64
                    inv := mul(inv, sub(2, mul(d, inv))) // inverse mod 2**128
                    z := mul(
                        // Divide [p1 p0] by the factors of two.
                        // Shift in bits from `p1` into `p0`. For this we need
                        // to flip `t` such that it is `2**256 / t`.
                        or(mul(sub(p1, gt(r, z)), add(div(sub(0, t), t), 1)), div(sub(z, r), t)),
                        mul(sub(2, mul(d, inv)), inv) // inverse mod 2**256
                    )
                    break
                }
                z := div(z, d)
                break
            }
        }
    }

    /// @dev Calculates `floor(x * y / d)` with full precision, rounded up.
    /// Throws if result overflows a uint256 or when `d` is zero.
    /// Credit to Uniswap-v3-core under MIT license:
    /// https://github.com/Uniswap/v3-core/blob/main/contracts/libraries/FullMath.sol
    function fullMulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        z = fullMulDiv(x, y, d);
        /// @solidity memory-safe-assembly
        assembly {
            if mulmod(x, y, d) {
                z := add(z, 1)
                if iszero(z) {
                    mstore(0x00, 0xae47f702) // `FullMulDivFailed()`.
                    revert(0x1c, 0x04)
                }
            }
        }
    }

    /// @dev Returns `ceil(x / d)`.
    /// Reverts if `d` is zero.
    function divUp(uint256 x, uint256 d) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            if iszero(d) {
                mstore(0x00, 0x65244e4e) // `DivFailed()`.
                revert(0x1c, 0x04)
            }
            z := add(iszero(iszero(mod(x, d))), div(x, d))
        }
    }

    /**
     * @notice Returns the value of x^y. It calculates `1 / x^abs(y)` if x is bigger than 2^128.
     * At the end of the operations, we invert the result if needed.
     * @param x The unsigned 128.128-binary fixed-point number for which to calculate the power
     * @param y A relative number without any decimals, needs to be between ]2^21; 2^21[
     */
    function pow(uint256 x, int256 y) internal pure returns (uint256 result) {
        uint256 scale = 340622649287859401926837982039199979667;
        bool invert;
        uint256 absY;

        if (y == 0) return scale;

        assembly {
            absY := y
            if slt(absY, 0) {
                absY := sub(0, absY)
                invert := iszero(invert)
            }
        }

        if (absY < 0x100000) {
            result = scale;
            assembly {
                let squared := x
                if gt(x, 0xffffffffffffffffffffffffffffffff) {
                    squared := div(not(0), squared)
                    invert := iszero(invert)
                }

                if and(absY, 0x1) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x2) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x4) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x8) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x10) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x20) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x40) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x80) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x100) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x200) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x400) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x800) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x1000) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x2000) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x4000) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x8000) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x10000) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x20000) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x40000) {
                    result := shr(128, mul(result, squared))
                }
                squared := shr(128, mul(squared, squared))
                if and(absY, 0x80000) {
                    result := shr(128, mul(result, squared))
                }
            }
        }

        // revert if y is too big or if x^y underflowed
        if (result == 0) revert powFailed();

        return invert ? type(uint256).max / result : result;
    }
}
