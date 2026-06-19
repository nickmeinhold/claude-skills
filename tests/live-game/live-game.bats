#!/usr/bin/env bats
# tests/live-game/live-game.bats — smoke/contract tests for the zero-dependency
# realtime audience quiz-game server (skills/live-game/server.mjs).
#
# These pin the game's load-bearing invariants so a future edit can't silently
# break them: (A) counts/correct are HIDDEN during a live question and revealed
# only at reveal, (B) the speed bonus orders faster-correct above slower-correct,
# (C) a vote locks (no answer-switching), (D) host mutations require the token,
# and (E) the public-hardening trust boundary: identity is server-issued and a
# vote/self-read needs the matching secret.

load ../helpers

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SERVER="${REPO_ROOT}/skills/live-game/server.mjs"
  PORT=7399
  B="http://localhost:${PORT}"
  TOKEN="bats-token"
  LIVE_GAME_HOST_TOKEN="$TOKEN" node "$SERVER" --port "$PORT" >/tmp/live-game-bats.log 2>&1 &
  SERVER_PID=$!
  # wait for the port to accept connections (max ~3s)
  for _ in $(seq 1 30); do
    curl -s "$B/state" >/dev/null 2>&1 && break
    sleep 0.1
  done
}

teardown() {
  [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "${AUX_PID:-}" ] && kill "$AUX_PID" 2>/dev/null || true
}

# POST helper: post <path> <json-body>
post() { curl -s -X POST "$B$1" -H 'content-type: application/json' -d "$2"; }
# field <json> <js-expr-on-s> — parse JSON from stdin-arg and print a field
field() { node -e 'const s=JSON.parse(process.argv[1]);console.log(eval(process.argv[2]))' "$1" "$2"; }
# join <name> -> echoes "<playerId> <secret>" (server-issued identity).
# NOTE the trailing newline (console.log): `read ... < <(join X)` returns
# non-zero on EOF-without-newline, which would abort the test under set -e.
join() {
  local resp; resp=$(post /join "{\"name\":\"$1\"}")
  node -e 'const d=JSON.parse(process.argv[1]);console.log((d.playerId||"")+" "+(d.secret||""))' "$resp"
}

@test "server boots and serves a lobby snapshot" {
  run curl -s "$B/state"
  [ "$status" -eq 0 ] || fail "status=$status"
  [ "$(field "$output" 's.phase')" = "lobby" ] || fail "output=$output"
}

@test "host view and play view are served as HTML" {
  run curl -s "$B/"
  [[ "$output" == *"Live Game"* ]] || fail "output=$output"
  run curl -s "$B/play"
  [[ "$output" == *"Join the game"* ]] || fail "output=$output"
}

@test "join issues a server-minted playerId + secret (not client-asserted)" {
  run post /join '{"name":"Ada"}'
  [ "$(field "$output" 's.ok')" = "true" ] || fail "output=$output"
  [ -n "$(field "$output" 's.playerId')" ] || fail "no playerId issued: $output"
  [ -n "$(field "$output" 's.secret')" ] || fail "no secret issued: $output"
}

@test "the host screen does not call an external QR service (offline / no leak)" {
  run curl -s "$B/"
  [[ "$output" != *"api.qrserver.com"* ]] || fail "host page still calls api.qrserver.com"
  [[ "$output" != *"qrserver"* ]] || fail "host page still references an external QR host"
}

@test "counts and correct are hidden during a live question, revealed at reveal" {
  read AID ASEC < <(join Ada)
  post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y","z"],"correct":1}' >/dev/null
  post /vote "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\",\"option\":1}" >/dev/null

  run curl -s "$B/state"
  [ "$(field "$output" 's.counts')" = "null" ] || fail "output=$output"
  [ "$(field "$output" 's.correct')" = "null" ] || fail "output=$output"

  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  run curl -s "$B/state"
  [ "$(field "$output" 's.correct')" = "1" ] || fail "output=$output"
  [ "$(field "$output" 's.counts[1]')" = "1" ] || fail "output=$output"
}

@test "speed bonus: faster correct answer outscores slower correct answer" {
  read AID ASEC < <(join Ada)
  read BID BSEC < <(join Bo)
  post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y"],"correct":0,"timeLimit":20}' >/dev/null
  post /vote "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\",\"option\":0}" >/dev/null   # Ada fast
  sleep 1
  post /vote "{\"playerId\":\"$BID\",\"secret\":\"$BSEC\",\"option\":0}" >/dev/null   # Bo ~1s later
  run post "/host/reveal?token=$TOKEN" '{}'
  local ada bo
  ada=$(field "$output" 's.leaderboard.find(p=>p.name==="Ada").score')
  bo=$(field "$output" 's.leaderboard.find(p=>p.name==="Bo").score')
  [ "$ada" -gt "$bo" ] || fail "ada=$ada bo=$bo"
  [ "$ada" -eq 1000 ] || fail "ada=$ada"
}

@test "a vote locks — answer cannot be changed" {
  read AID ASEC < <(join Ada)
  post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y","z"],"correct":0}' >/dev/null
  post /vote "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\",\"option\":2}" >/dev/null  # first = z (wrong)
  run post /vote "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\",\"option\":0}"         # try switch to x
  [ "$(field "$output" 's.locked')" = "true" ] || fail "output=$output"
  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  run curl -s "$B/state"
  [ "$(field "$output" 's.leaderboard.find(p=>p.name==="Ada").score')" = "0" ] || fail "output=$output"
}

@test "host mutations require the token" {
  run post "/host/ask?token=WRONG" '{"question":"Q","options":["x","y"],"correct":0}'
  [ "$(field "$output" 's.error')" = "bad host token" ] || fail "output=$output"
  run curl -s "$B/state"
  [ "$(field "$output" 's.phase')" = "lobby" ] || fail "output=$output"   # state untouched
}

@test "voting requires an active question" {
  read AID ASEC < <(join Ada)
  run post /vote "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\",\"option\":0}"
  [ "$(field "$output" 's.error')" = "no live question" ] || fail "output=$output"
}

@test "host/ask rejects an out-of-range correct index" {
  run post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y"],"correct":5}'
  [[ "$(field "$output" 's.error')" == correct\ must\ be* ]] || fail "output=$output"
  run curl -s "$B/state"
  [ "$(field "$output" 's.phase')" = "lobby" ] || fail "output=$output"   # rejected → state untouched
}

@test "host/ask clamps an extreme timeLimit into range" {
  post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y"],"correct":0,"timeLimit":99999}' >/dev/null
  run curl -s "$B/state"
  [ "$(field "$output" 's.timeLimit')" = "300" ] || fail "output=$output"   # clamped to MAX_TIME_LIMIT
}

# --- trust boundary: server-issued identity --------------------------------
@test "a vote with a wrong secret is rejected (no identity hijack)" {
  read AID ASEC < <(join Ada)
  post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y"],"correct":0}' >/dev/null
  run post /vote "{\"playerId\":\"$AID\",\"secret\":\"forged\",\"option\":0}"
  [ "$(field "$output" 's.error')" = "bad credentials" ] || fail "output=$output"
  # Ada cast no real vote, so nobody has answered.
  run curl -s "$B/state"
  [ "$(field "$output" 's.answered')" = "0" ] || fail "output=$output"
}

@test "credentials must be strings — an array-wrapped secret is rejected, not coerced" {
  read AID ASEC < <(join Ada)
  post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y"],"correct":0}' >/dev/null
  # {"secret":["<real secret>"]} must NOT authenticate even though String() of it
  # would equal the real secret — the bearer contract is string-typed at the gate.
  run post /vote "{\"playerId\":\"$AID\",\"secret\":[\"$ASEC\"],\"option\":0}"
  [ "$(field "$output" 's.error')" = "bad credentials" ] || fail "output=$output"
  run post /me "{\"playerId\":[\"$AID\"],\"secret\":\"$ASEC\"}"
  [ "$(field "$output" 's.error')" = "bad credentials" ] || fail "output=$output"
  # Ada cast no real vote.
  run curl -s "$B/state"
  [ "$(field "$output" 's.answered')" = "0" ] || fail "output=$output"
}

@test "a vote with an unknown playerId is rejected" {
  post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y"],"correct":0}' >/dev/null
  run post /vote '{"playerId":"nope","secret":"nope","option":0}'
  [ "$(field "$output" 's.error')" = "bad credentials" ] || fail "output=$output"
}

@test "a peer cannot rename another player by reusing their playerId without the secret" {
  read AID ASEC < <(join Ada)
  # Attacker knows AID but not ASEC; tries to reclaim+rename the identity.
  run post /join "{\"name\":\"Eve\",\"playerId\":\"$AID\",\"secret\":\"forged\"}"
  # They are NOT given Ada's identity — they get a fresh, different one.
  [ "$(field "$output" 's.playerId')" != "$AID" ] || fail "attacker reclaimed Ada's id: $output"
  # And Ada's identity still reads back as Ada via her authenticated /me.
  run post /me "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\"}"
  [ "$(field "$output" 's.name')" = "Ada" ] || fail "Ada was renamed: $output"
}

@test "re-join with the correct secret reclaims the same identity and keeps score" {
  read AID ASEC < <(join Ada)
  post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y"],"correct":0,"timeLimit":20}' >/dev/null
  post /vote "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\",\"option\":0}" >/dev/null
  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  # Reconnect with the SAME creds (e.g. phone refresh) -> same id, score intact.
  run post /join "{\"name\":\"Ada\",\"playerId\":\"$AID\",\"secret\":\"$ASEC\"}"
  [ "$(field "$output" 's.playerId')" = "$AID" ] || fail "did not reclaim id: $output"
  run post /me "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\"}"
  [ "$(field "$output" 's.score')" -gt 0 ] || fail "score lost on reconnect: $output"
}

@test "/me returns the caller's own authoritative score+verdict, secret-gated" {
  read AID ASEC < <(join Ada)
  post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y"],"correct":0}' >/dev/null
  post /vote "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\",\"option\":0}" >/dev/null
  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  run post /me "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\"}"
  [ "$(field "$output" 's.correct')" = "true" ] || fail "output=$output"
  [ "$(field "$output" 's.lastGain')" -gt 0 ] || fail "output=$output"
  # wrong secret cannot read someone's score
  run post /me "{\"playerId\":\"$AID\",\"secret\":\"forged\"}"
  [ "$(field "$output" 's.error')" = "bad credentials" ] || fail "output=$output"
}

# --- per-IP rate limiting (own low-limit server) ---------------------------
@test "the audience endpoints are per-IP rate limited" {
  local aux_port=7398
  LIVE_GAME_HOST_TOKEN="$TOKEN" LIVE_GAME_RATE_MAX=3 LIVE_GAME_RATE_WINDOW_MS=60000 \
    node "$SERVER" --port "$aux_port" >/tmp/live-game-bats-aux.log 2>&1 &
  AUX_PID=$!
  for _ in $(seq 1 30); do curl -s "http://localhost:$aux_port/state" >/dev/null 2>&1 && break; sleep 0.1; done
  # 3 joins allowed, the 4th in the same window is throttled.
  local last
  for i in $(seq 1 4); do
    last=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:$aux_port/join" \
      -H 'content-type: application/json' -d "{\"name\":\"p$i\"}")
  done
  [ "$last" = "429" ] || fail "expected 429 on the 4th join, got $last"
}
