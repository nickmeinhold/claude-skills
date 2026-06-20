#!/usr/bin/env bats
# tests/live-game/qr.bats — contract tests for the offline QR encoder
# (skills/live-game/qr.mjs) that replaced the external api.qrserver.com call.
#
# Two tiers:
#   - qr-unit.mjs       : pure, no external tools — always runs (the CI floor).
#   - qr-matrixdiff.mjs : foreign-oracle gates (qrencode structural identity +
#                         zbarimg round-trip). Runs when both tools are present;
#                         skips LOUDLY otherwise so a missing tool can't read as
#                         a silent pass. CI installs both, so CI always runs it.

load ../helpers

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

@test "qr: pure unit checks (RS generator, format BCH, capacity, SVG render)" {
  run node "${REPO_ROOT}/tests/live-game/qr-unit.mjs"
  [[ "$status" -eq 0 ]] || fail "qr-unit.mjs failed:"$'\n'"$output"
}

@test "qr: structural identity vs qrencode + round-trip vs zbarimg" {
  command -v qrencode >/dev/null 2>&1 || skip "qrencode not installed"
  command -v zbarimg  >/dev/null 2>&1 || skip "zbarimg not installed"
  run node "${REPO_ROOT}/tests/live-game/qr-matrixdiff.mjs" --suite
  [[ "$status" -eq 0 ]] || fail "matrix-diff suite failed:"$'\n'"$output"
  [[ "$output" == *"structural (vs qrencode): "*" passed, 0 failed"* ]] || fail "structural gate not clean:"$'\n'"$output"
  [[ "$output" == *"round-trip (vs zbarimg):  "*" passed, 0 failed"* ]] || fail "round-trip gate not clean:"$'\n'"$output"
}

@test "qr: server serves /qr.mjs as a module exporting qrMatrix" {
  # The host page does `await import('/qr.mjs')`; the route must exist and carry
  # a javascript content-type, else the browser refuses the module.
  PORT=7401
  LIVE_GAME_HOST_TOKEN="qr-bats" node "${REPO_ROOT}/skills/live-game/server.mjs" --port "$PORT" >/tmp/qr-bats.log 2>&1 &
  local pid=$!
  local up=""
  for _ in $(seq 1 30); do curl -s "http://localhost:${PORT}/state" >/dev/null 2>&1 && { up=1; break; }; sleep 0.1; done
  if [[ -z "$up" ]]; then kill "$pid" 2>/dev/null; fail "server did not start"; fi

  run curl -s -D - "http://localhost:${PORT}/qr.mjs"
  kill "$pid" 2>/dev/null
  [[ "$status" -eq 0 ]] || fail "curl /qr.mjs failed"
  [[ "$output" == *"content-type: text/javascript"* ]] || fail "wrong content-type for /qr.mjs:"$'\n'"$output"
  [[ "$output" == *"export function qrMatrix"* ]] || fail "/qr.mjs missing qrMatrix export"
}
