#!/usr/bin/env python3
"""Generate consensus keys and Monad addValidator signatures.

Uses the same scheme as staking-sdk-cli:
  secp = ECDSA(blake3(payload), secp_privkey)  # 64-byte r||s
  bls  = G2ProofOfPossession.Sign(bls_privkey, payload)
"""

from __future__ import annotations

import json
import os
import sys

from blake3 import blake3
from eth_keys import keys
from py_ecc.bls import G2ProofOfPossession as bls
from py_ecc.optimized_bls12_381 import curve_order


def _strip0x(value: str) -> str:
    return value[2:] if value.startswith(("0x", "0X")) else value


def _env_hex(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None or value == "":
        raise SystemExit(f"missing required env var {name}")
    return _strip0x(value)


def _env_int(name: str, default: str | None = None) -> int:
    value = os.environ.get(name, default)
    if value is None or value == "":
        raise SystemExit(f"missing required env var {name}")
    return int(value, 0)


def _random_secp() -> keys.PrivateKey:
    while True:
        try:
            return keys.PrivateKey(os.urandom(32))
        except Exception:
            continue


def _random_bls() -> int:
    while True:
        sk = int.from_bytes(os.urandom(32), "big") % curve_order
        if sk != 0:
            return sk


def main() -> None:
    auth = _env_hex("AUTH_ADDRESS")
    if len(auth) != 40:
        raise SystemExit(f"AUTH_ADDRESS must be 20 bytes, got {len(auth) // 2}")

    amount = _env_int("AMOUNT")
    commission = _env_int("COMMISSION")

    secp_hex = os.environ.get("SECP_PRIVKEY")
    bls_hex = os.environ.get("BLS_PRIVKEY")
    if bool(secp_hex) != bool(bls_hex):
        raise SystemExit("SECP_PRIVKEY and BLS_PRIVKEY must both be set or both omitted")

    if secp_hex:
        secp_sk = keys.PrivateKey(bytes.fromhex(_strip0x(secp_hex)))
        bls_sk = int.from_bytes(bytes.fromhex(_strip0x(bls_hex)), "big")
    else:
        secp_sk = _random_secp()
        bls_sk = _random_bls()

    secp_pk = secp_sk.public_key.to_compressed_bytes()
    bls_pk = bls.SkToPk(bls_sk)

    payload = b"".join(
        [
            secp_pk,
            bls_pk,
            bytes.fromhex(auth),
            amount.to_bytes(32, "big"),
            commission.to_bytes(32, "big"),
        ]
    )
    if len(payload) != 165:
        raise SystemExit(f"payload must be 165 bytes, got {len(payload)}")

    secp_sig = secp_sk.sign_msg_hash_non_recoverable(blake3(payload).digest()).to_bytes()
    bls_sig = bls.Sign(bls_sk, payload)
    if len(secp_sig) != 64:
        raise SystemExit(f"secp signature must be 64 bytes, got {len(secp_sig)}")
    if len(bls_sig) != 96:
        raise SystemExit(f"bls signature must be 96 bytes, got {len(bls_sig)}")

    print(
        json.dumps(
            {
                "authAddress": "0x" + auth,
                "amount": str(amount),
                "commission": str(commission),
                "secpPrivkey": secp_sk.to_bytes().hex(),
                "blsPrivkey": bls_sk.to_bytes(32, "big").hex(),
                "secpPubkey": secp_pk.hex(),
                "blsPubkey": bls_pk.hex(),
                "secpSig": secp_sig.hex(),
                "blsSig": bls_sig.hex(),
                "payload": payload.hex(),
            }
        )
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 — CLI surface
        print(f"sign_payload failed: {exc}", file=sys.stderr)
        raise
