#!/usr/bin/env bash
# Register a real Solonet validator through ValidatorRegistry.
#
# Requires a running Solonet (RPC + docker container with staking-sdk-cli).
# Usage: pnpm --filter @quevra/contracts test:e2e
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

RPC_URL="${SOLONET_RPC:-http://localhost:8080}"
CONTAINER="${SOLONET_CONTAINER:-solonet}"
CHAIN_ID="${SOLONET_CHAIN_ID:-20143}"
# Anvil account 0 — funded on Solonet genesis.
PRIVATE_KEY="${PRIVATE_KEY:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
# Distinct from Solonet's default staking auth (account 1).
AUTH_ADDRESS="${AUTH_ADDRESS:-0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC}"
AMOUNT="${AMOUNT:-100000000000000000000000}"
COMMISSION="${COMMISSION:-100000000000000000}"
WAIT_SECS="${SOLONET_WAIT_SECS:-600}"
PYTHON_IN_CONTAINER="${SOLONET_PYTHON:-/root/staking-sdk-cli/cli-venv/bin/python}"
USE_DOCKER_RPC=0

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

rpc_payload() {
  local method="$1"
  local params="${2:-[]}"
  printf '{"jsonrpc":"2.0","id":1,"method":"%s","params":%s}' "$method" "$params"
}

rpc() {
  local method="$1"
  local params="${2:-[]}"
  if (( USE_DOCKER_RPC == 1 )); then
    docker exec "$CONTAINER" curl -sf --max-time 5 -X POST http://localhost:8080 \
      -H 'content-type: application/json' \
      -d "$(rpc_payload "$method" "$params")"
  else
    curl -sf --max-time 5 -X POST "$RPC_URL" \
      -H 'content-type: application/json' \
      -d "$(rpc_payload "$method" "$params")"
  fi
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" == "true" ]]
}

wait_for_rpc() {
  local i
  for i in $(seq 1 "$WAIT_SECS"); do
    if rpc eth_chainId >/dev/null 2>&1; then
      return 0
    fi
    if (( USE_DOCKER_RPC == 0 )) && container_running && docker exec "$CONTAINER" curl -sf --max-time 5 -X POST http://localhost:8080 \
      -H 'content-type: application/json' \
      -d "$(rpc_payload eth_chainId)" >/dev/null 2>&1; then
      USE_DOCKER_RPC=1
      RPC_URL="http://localhost:8080"
      log "host cannot reach ${SOLONET_RPC:-http://localhost:8080}; using docker exec ${CONTAINER}"
      return 0
    fi
    if ! container_running; then
      die "solonet container stopped while waiting for RPC"
    fi
    if (( i == 1 || i % 15 == 0 )); then
      log "waiting for Solonet RPC at ${RPC_URL} (${i}s)"
    fi
    sleep 1
  done
  die "Solonet RPC did not become ready at ${RPC_URL}"
}

hex_to_dec() {
  local hex="${1#0x}"
  python3 -c "print(int('${hex}', 16))"
}

json_field() {
  python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"
}

wait_for_rpc

onchain_id="$(rpc eth_chainId | python3 -c "import json,sys; print(json.load(sys.stdin)['result'])")"
onchain_id_dec="$(hex_to_dec "$onchain_id")"
[[ "$onchain_id_dec" == "$CHAIN_ID" ]] || die "expected chain id ${CHAIN_ID}, got ${onchain_id_dec} from ${RPC_URL}"

container_running || die "docker container '${CONTAINER}' is not running; start Solonet first"

log "signing addValidator payload in ${CONTAINER}"
KEYS_JSON="$(
  docker exec -i \
    -e "AUTH_ADDRESS=${AUTH_ADDRESS}" \
    -e "AMOUNT=${AMOUNT}" \
    -e "COMMISSION=${COMMISSION}" \
    ${SECP_PRIVKEY:+-e "SECP_PRIVKEY=${SECP_PRIVKEY}"} \
    ${BLS_PRIVKEY:+-e "BLS_PRIVKEY=${BLS_PRIVKEY}"} \
    "$CONTAINER" "$PYTHON_IN_CONTAINER" - \
    < "${ROOT}/script/e2e/sign_payload.py"
)"

SECP_PUBKEY="0x$(printf '%s' "$KEYS_JSON" | json_field secpPubkey)"
BLS_PUBKEY="0x$(printf '%s' "$KEYS_JSON" | json_field blsPubkey)"
SECP_SIG="0x$(printf '%s' "$KEYS_JSON" | json_field secpSig)"
BLS_SIG="0x$(printf '%s' "$KEYS_JSON" | json_field blsSig)"

log "secp pubkey ${SECP_PUBKEY}"
log "bls pubkey  ${BLS_PUBKEY}"
log "broadcasting ValidatorRegistry propose+execute"

export PRIVATE_KEY AUTH_ADDRESS AMOUNT COMMISSION SECP_PUBKEY BLS_PUBKEY SECP_SIG BLS_SIG

# Skip local simulation: addValidator lives in the staking precompile and is not
# present in Foundry's in-process EVM.
forge_cmd=(
  forge script script/e2e/AddValidatorOnSolonet.s.sol:AddValidatorOnSolonet
  --rpc-url "$RPC_URL"
  --chain-id "$CHAIN_ID"
  --broadcast
  --slow
  --skip-simulation
  --private-key "$PRIVATE_KEY"
  --gas-limit 3000000
  -vvv
)
if (( USE_DOCKER_RPC == 1 )); then
  docker exec -i \
    -e PRIVATE_KEY -e AUTH_ADDRESS -e AMOUNT -e COMMISSION \
    -e SECP_PUBKEY -e BLS_PUBKEY -e SECP_SIG -e BLS_SIG \
    -w /quevra-contracts \
    "$CONTAINER" "${forge_cmd[@]}"
else
  "${forge_cmd[@]}"
fi

BROADCAST_JSON="${ROOT}/broadcast/AddValidatorOnSolonet.s.sol/${CHAIN_ID}/run-latest.json"
[[ -f "$BROADCAST_JSON" ]] || die "missing broadcast artifact ${BROADCAST_JSON}"

python3 - "$BROADCAST_JSON" "$RPC_URL" "$CHAIN_ID" "$SECP_PUBKEY" "$BLS_PUBKEY" "$AUTH_ADDRESS" "$CONTAINER" "$USE_DOCKER_RPC" <<'PY'
import json, subprocess, sys

path, rpc, chain_id, secp, bls, auth, container, use_docker = sys.argv[1:]
data = json.load(open(path))
receipts = data.get("receipts") or []
if not receipts:
    raise SystemExit(f"no receipts in {path}")
for receipt in receipts:
    status = receipt.get("status")
    if status not in (1, "0x1", "1"):
        raise SystemExit(f"broadcast tx failed: status={status} hash={receipt.get('transactionHash')}")

def run(cmd):
    if use_docker == "1":
        cmd = ["docker", "exec", container, *cmd]
    return subprocess.check_output(cmd, text=True)

topic0 = run(
    ["cast", "sig-event", "ValidatorExecuted(uint256,address,uint64,address,uint256,uint256)"]
).strip()
validator_id = None
for receipt in receipts:
    for log in receipt.get("logs") or []:
        topics = log.get("topics") or []
        if topics and topics[0].lower() == topic0.lower() and len(topics) >= 4:
            validator_id = int(topics[3], 16)
if validator_id is None:
    raise SystemExit("ValidatorExecuted event not found")

out = run(
    [
        "cast", "call",
        "0x0000000000000000000000000000000000001000",
        "getValidator(uint64)(address,uint64,uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bytes,bytes)",
        str(validator_id),
        "--rpc-url", rpc,
        "--chain", chain_id,
    ]
)
print(out)
joined = "\n".join(line.strip().rstrip(",") for line in out.splitlines() if line.strip())
if auth.lower() not in joined.lower():
    raise SystemExit(f"getValidator auth mismatch\n{out}")
if secp.lower() not in joined.lower():
    raise SystemExit(f"getValidator secp pubkey mismatch\n{out}")
if bls.lower() not in joined.lower():
    raise SystemExit(f"getValidator bls pubkey mismatch\n{out}")
print(f"e2e ok: validatorId={validator_id} registered via ValidatorRegistry")
PY
