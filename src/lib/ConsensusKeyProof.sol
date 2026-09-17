// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Proofs that a proposer controls the published consensus keys.
/// @dev SECP: ECDSA over `digest` must recover to the 33-byte compressed pubkey.
///      BLS: 48-byte G1 pubkey must be a valid compressed on-curve point; 96-byte
///      G2 signature must be compressed. The staking precompile checks BLS binding
///      of the executed `addValidator` payload.
library ConsensusKeyProof {
    uint256 internal constant SECP_P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F;
    uint256 internal constant SECP_PUBKEY_LENGTH = 33;
    uint256 internal constant BLS_PUBKEY_LENGTH = 48;
    uint256 internal constant BLS_SIG_LENGTH = 96;

    bytes internal constant BLS_P =
        hex"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab";
    bytes internal constant BLS_SQRT_EXP =
        hex"0680447a8e5ff9a692c6e9ed90d2eb35d91dd2e13ce144afd9cc34a83dac3d8907aaffffac54ffffee7fbfffffffeaab";
    bytes internal constant BLS_HALF_P =
        hex"0d0088f51cbff34d258dd3db21a5d66bb23ba5c279c2895fb39869507b587b120f55ffff58a9ffffdcff7fffffffd555";

    error InvalidSecpPubkey();
    error InvalidSecpSignature();
    error InvalidBlsPubkey();
    error InvalidBlsSignature();

    function verifySecp(bytes memory pubkey, bytes32 digest, bytes memory signature) internal view {
        address expected = secpAddress(pubkey);
        (bytes32 r, bytes32 s, uint8 v) = _parseSecpSig(signature);
        if (uint256(r) == 0 || uint256(s) == 0) revert InvalidSecpSignature();

        if (v == 0) {
            if (_ecrecover(digest, 27, r, s) != expected && _ecrecover(digest, 28, r, s) != expected) {
                revert InvalidSecpSignature();
            }
            return;
        }
        if (_ecrecover(digest, v, r, s) != expected) revert InvalidSecpSignature();
    }

    function verifyBls(bytes memory pubkey, bytes memory signature) internal view {
        if (signature.length != BLS_SIG_LENGTH) revert InvalidBlsSignature();
        uint8 sigFlags = uint8(signature[0]);
        if ((sigFlags & 0x80) == 0) revert InvalidBlsSignature();
        if ((sigFlags & 0x40) != 0) revert InvalidBlsSignature();
        _assertValidG1(pubkey);
    }

    function secpAddress(bytes memory pubkey) internal view returns (address) {
        if (pubkey.length != SECP_PUBKEY_LENGTH) revert InvalidSecpPubkey();
        uint8 prefix = uint8(pubkey[0]);
        if (prefix != 2 && prefix != 3) revert InvalidSecpPubkey();

        uint256 x;
        assembly {
            x := mload(add(pubkey, 33))
        }
        if (x == 0 || x >= SECP_P) revert InvalidSecpPubkey();

        uint256 y2 = addmod(mulmod(mulmod(x, x, SECP_P), x, SECP_P), 7, SECP_P);
        uint256 y = _modexp256(y2, (SECP_P + 1) / 4, SECP_P);
        if (mulmod(y, y, SECP_P) != y2) revert InvalidSecpPubkey();
        if ((y & 1) != (prefix == 3 ? 1 : 0)) y = SECP_P - y;

        return address(uint160(uint256(keccak256(abi.encodePacked(bytes32(x), bytes32(y))))));
    }

    function _parseSecpSig(bytes memory signature) private pure returns (bytes32 r, bytes32 s, uint8 v) {
        if (signature.length == 64) {
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
            }
            return (r, s, 0);
        }
        if (signature.length == 65) {
            assembly {
                r := mload(add(signature, 0x20))
                s := mload(add(signature, 0x40))
                v := byte(0, mload(add(signature, 0x60)))
            }
            if (v < 27) v += 27;
            if (v != 27 && v != 28) revert InvalidSecpSignature();
            return (r, s, v);
        }
        revert InvalidSecpSignature();
    }

    function _ecrecover(bytes32 digest, uint8 v, bytes32 r, bytes32 s) private pure returns (address) {
        // forge-lint: disable-next-line(ecrecover)
        return ecrecover(digest, v, r, s);
    }

    function _assertValidG1(bytes memory compressed) private view {
        if (compressed.length != BLS_PUBKEY_LENGTH) revert InvalidBlsPubkey();
        uint8 flags = uint8(compressed[0]);
        if ((flags & 0x80) == 0) revert InvalidBlsPubkey();
        if ((flags & 0x40) != 0) revert InvalidBlsPubkey();

        bytes memory x = new bytes(48);
        for (uint256 i; i < 48; ++i) {
            x[i] = compressed[i];
        }
        x[0] = bytes1(flags & 0x1f);
        if (!_fpLt(x, BLS_P) || _fpIsZero(x)) revert InvalidBlsPubkey();

        bytes memory y2 = _fpAddSmall(_modexp(x, _fpFromUint(3)), 4);
        bytes memory y = _modexp(y2, BLS_SQRT_EXP);
        if (keccak256(_modexp(y, _fpFromUint(2))) != keccak256(y2)) revert InvalidBlsPubkey();

        bool wantLarger = (flags & 0x20) != 0;
        bool isLarger = _fpLt(BLS_HALF_P, y);
        if (wantLarger != isLarger) y = _fpSub(BLS_P, y);
        if (keccak256(_modexp(y, _fpFromUint(2))) != keccak256(y2)) revert InvalidBlsPubkey();
    }

    function _modexp256(uint256 base, uint256 exponent, uint256 modulus) private view returns (uint256 result) {
        assembly {
            let p := mload(0x40)
            mstore(p, 0x20)
            mstore(add(p, 0x20), 0x20)
            mstore(add(p, 0x40), 0x20)
            mstore(add(p, 0x60), base)
            mstore(add(p, 0x80), exponent)
            mstore(add(p, 0xa0), modulus)
            if iszero(staticcall(gas(), 0x05, p, 0xc0, p, 0x20)) { revert(0, 0) }
            result := mload(p)
        }
    }

    function _modexp(bytes memory base, bytes memory exponent) private view returns (bytes memory) {
        bytes memory input = bytes.concat(abi.encode(base.length, exponent.length, uint256(48)), base, exponent, BLS_P);
        (bool ok, bytes memory out) = address(0x05).staticcall(input);
        if (!ok) revert InvalidBlsPubkey();
        return _fpPad48(out);
    }

    function _fpFromUint(uint256 v) private pure returns (bytes memory out) {
        out = new bytes(48);
        assembly {
            mstore(add(out, 48), v)
        }
    }

    function _fpPad48(bytes memory raw) private pure returns (bytes memory out) {
        if (raw.length == 48) return raw;
        out = new bytes(48);
        if (raw.length > 48) {
            uint256 skip = raw.length - 48;
            for (uint256 i; i < 48; ++i) {
                out[i] = raw[skip + i];
            }
            return out;
        }
        uint256 offset = 48 - raw.length;
        for (uint256 i; i < raw.length; ++i) {
            out[offset + i] = raw[i];
        }
    }

    function _fpIsZero(bytes memory a) private pure returns (bool) {
        for (uint256 i; i < 48; ++i) {
            if (a[i] != 0) return false;
        }
        return true;
    }

    function _fpLt(bytes memory a, bytes memory b) private pure returns (bool) {
        for (uint256 i; i < 48; ++i) {
            if (uint8(a[i]) < uint8(b[i])) return true;
            if (uint8(a[i]) > uint8(b[i])) return false;
        }
        return false;
    }

    function _fpAddSmall(bytes memory a, uint8 n) private pure returns (bytes memory out) {
        out = new bytes(48);
        for (uint256 i; i < 48; ++i) {
            out[i] = a[i];
        }
        uint256 carry = n;
        for (uint256 i = 48; i > 0 && carry != 0;) {
            unchecked {
                --i;
                uint256 sum = uint8(out[i]) + carry;
                // forge-lint: disable-next-line(unsafe-typecast)
                out[i] = bytes1(uint8(sum));
                carry = sum >> 8;
            }
        }
        if (!_fpLt(out, BLS_P)) out = _fpSub(out, BLS_P);
    }

    function _fpSub(bytes memory a, bytes memory b) private pure returns (bytes memory out) {
        out = new bytes(48);
        uint256 borrow = 0;
        for (uint256 i = 48; i > 0;) {
            unchecked {
                --i;
                uint256 av = uint8(a[i]);
                uint256 bv = uint8(b[i]) + borrow;
                if (av < bv) {
                    // forge-lint: disable-next-line(unsafe-typecast)
                    out[i] = bytes1(uint8(av + 256 - bv));
                    borrow = 1;
                } else {
                    // forge-lint: disable-next-line(unsafe-typecast)
                    out[i] = bytes1(uint8(av - bv));
                    borrow = 0;
                }
            }
        }
        if (borrow != 0) revert InvalidBlsPubkey();
    }
}
