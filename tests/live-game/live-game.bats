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
  # LEAD_MS=0 so a question goes live immediately on /host/ask — these contract
  # tests vote right after asking. The 3·2·1 lead-in is covered by its own test
  # (which boots a second server with a lead).
  LIVE_GAME_HOST_TOKEN="$TOKEN" LIVE_GAME_LEAD_MS=0 node "$SERVER" --port "$PORT" >/tmp/live-game-bats.log 2>&1 &
  SERVER_PID=$!
  # block until ready; fail-loud on timeout so a slow boot can't masquerade as a
  # status=7 assertion failure downstream (the PR #92 CI flake).
  wait_for_server "$B" /tmp/live-game-bats.log
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

# wait_for_server <base-url> [<logfile>] — block until /state answers, with a
# generous budget for a cold/loaded CI runner, then FAIL LOUDLY (dump the log)
# if it never comes up. A silent 3s fall-through is what let a slow boot surface
# as an opaque `status=7` (connection refused) three lines into a test — the CI
# flake on the PR #92 merge commit. 100×0.1s ≈ 10s headroom; a real boot failure
# now prints the server log instead of masquerading as a flaky assertion.
wait_for_server() {
  local base="$1" logf="${2:-}"
  for _ in $(seq 1 100); do
    curl -s "$base/state" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  echo "live-game server did not become ready on $base within ~10s" >&2
  [ -n "$logf" ] && [ -f "$logf" ] && { echo "--- $logf ---" >&2; cat "$logf" >&2; }
  return 1
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
  wait_for_server "http://localhost:$aux_port" /tmp/live-game-bats-aux.log || fail "aux server did not boot"
  # 3 joins allowed, the 4th in the same window is throttled.
  local last
  for i in $(seq 1 4); do
    last=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:$aux_port/join" \
      -H 'content-type: application/json' -d "{\"name\":\"p$i\"}")
  done
  [ "$last" = "429" ] || fail "expected 429 on the 4th join, got $last"
}

# --- global SSE connection cap (own low-cap server) ------------------------
@test "the /events stream count is globally capped (503 over the cap)" {
  local cp=7395 cb="http://localhost:7395"
  LIVE_GAME_HOST_TOKEN="$TOKEN" LIVE_GAME_MAX_SSE_CLIENTS=2 \
    node "$SERVER" --port "$cp" >/tmp/live-game-bats-cap.log 2>&1 &
  AUX_PID=$!
  wait_for_server "$cb" /tmp/live-game-bats-cap.log || fail "cap-test server did not boot"
  # Hold two streams open in the background (curl -N keeps the connection alive,
  # so each occupies a slot in sseClients).
  curl -N -s "$cb/events" >/dev/null & local s1=$!
  curl -N -s "$cb/events" >/dev/null & local s2=$!
  sleep 0.5  # let both register
  # The 3rd stream is over the cap → 503 (json end, so curl returns at once;
  # --max-time guards against a hang if the cap ever regresses to a live stream).
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$cb/events")
  kill "$s1" "$s2" 2>/dev/null || true
  [ "$code" = "503" ] || fail "expected 503 over the SSE cap, got $code"
}

# --- engagement: 3·2·1 lead-in, streaks, podium ----------------------------
@test "a lead-in delays the question (countdown phase) then it goes live" {
  local p=7397 cb
  LIVE_GAME_HOST_TOKEN="$TOKEN" LIVE_GAME_LEAD_MS=600 node "$SERVER" --port "$p" >/tmp/live-game-bats-cd.log 2>&1 &
  AUX_PID=$!
  wait_for_server "http://localhost:$p" /tmp/live-game-bats-cd.log || fail "lead-in server did not boot"
  cb="http://localhost:$p"
  curl -s -X POST "$cb/host/ask?token=$TOKEN" -H 'content-type: application/json' \
    -d '{"question":"Q","options":["x","y"],"correct":0}' >/dev/null
  run curl -s "$cb/state"
  [ "$(field "$output" 's.phase')" = "countdown" ] || fail "not counting down: $output"
  [ "$(field "$output" 's.countdownTo')" -gt 0 ] || fail "no countdownTo: $output"
  sleep 0.9
  run curl -s "$cb/state"
  [ "$(field "$output" 's.phase')" = "question" ] || fail "did not go live: $output"
}

@test "host/next during the lead-in cancels the pending question start" {
  local p=7396 cb
  LIVE_GAME_HOST_TOKEN="$TOKEN" LIVE_GAME_LEAD_MS=600 node "$SERVER" --port "$p" >/tmp/live-game-bats-cancel.log 2>&1 &
  AUX_PID=$!
  wait_for_server "http://localhost:$p" /tmp/live-game-bats-cancel.log || fail "cancel-test server did not boot"
  cb="http://localhost:$p"
  curl -s -X POST "$cb/host/ask?token=$TOKEN" -H 'content-type: application/json' \
    -d '{"question":"Q","options":["x","y"],"correct":0}' >/dev/null
  curl -s -X POST "$cb/host/next?token=$TOKEN" -d '{}' >/dev/null   # pre-empt mid-countdown
  sleep 0.9   # past the original lead window
  run curl -s "$cb/state"
  [ "$(field "$output" 's.phase')" = "lobby" ] || fail "stale timer flipped a reset game live: $output"
}

@test "streak bonus rewards consecutive correct answers" {
  read AID ASEC < <(join Ada)
  post "/host/ask?token=$TOKEN" '{"question":"Q1","options":["x","y"],"correct":0,"timeLimit":20}' >/dev/null
  post /vote "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\",\"option\":0}" >/dev/null
  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  post "/host/next?token=$TOKEN" '{}' >/dev/null
  post "/host/ask?token=$TOKEN" '{"question":"Q2","options":["x","y"],"correct":0,"timeLimit":20}' >/dev/null
  post /vote "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\",\"option\":0}" >/dev/null
  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  run post /me "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\"}"
  [ "$(field "$output" 's.streak')" = "2" ] || fail "streak: $output"
  [ "$(field "$output" 's.streakBonus')" = "100" ] || fail "bonus: $output"
}

@test "a wrong answer resets the streak to zero" {
  read AID ASEC < <(join Ada)
  post "/host/ask?token=$TOKEN" '{"question":"Q1","options":["x","y"],"correct":0,"timeLimit":20}' >/dev/null
  post /vote "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\",\"option\":0}" >/dev/null   # correct
  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  post "/host/next?token=$TOKEN" '{}' >/dev/null
  post "/host/ask?token=$TOKEN" '{"question":"Q2","options":["x","y"],"correct":0,"timeLimit":20}' >/dev/null
  post /vote "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\",\"option\":1}" >/dev/null   # wrong
  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  run post /me "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\"}"
  [ "$(field "$output" 's.streak')" = "0" ] || fail "streak not reset: $output"
}

@test "host/end shows a podium and keeps scores" {
  read AID ASEC < <(join Ada)
  post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y"],"correct":0,"timeLimit":20}' >/dev/null
  post /vote "{\"playerId\":\"$AID\",\"secret\":\"$ASEC\",\"option\":0}" >/dev/null
  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  run post "/host/end?token=$TOKEN" '{}'
  [ "$(field "$output" 's.ok')" = "true" ] || fail "end: $output"
  run curl -s "$B/state"
  [ "$(field "$output" 's.phase')" = "podium" ] || fail "phase: $output"
  [ "$(field "$output" 's.leaderboard.find(p=>p.name==="Ada").score')" -gt 0 ] || fail "score lost: $output"
}

@test "host/end requires the token" {
  run post "/host/end?token=WRONG" '{}'
  [ "$(field "$output" 's.error')" = "bad host token" ] || fail "output=$output"
}

# --- staging slot (lookahead-1 prefetch): /host/stage + /host/advance ---------

@test "stage parks the next question without leaking it into public state (anti-peek)" {
  post "/host/ask?token=$TOKEN" '{"question":"Q1","options":["a","b"],"correct":0}' >/dev/null
  run post "/host/stage?token=$TOKEN" '{"question":"Q2SECRET","options":["x","y"],"correct":1}'
  [ "$(field "$output" 's.staged')" = "true" ] || fail "stage not acknowledged: $output"
  # the live question is unchanged and the staged one must be invisible in /state
  run curl -s "$B/state"
  [ "$(field "$output" 's.question')" = "Q1" ] || fail "live question changed by stage: $output"
  [ "$(field "$output" 's.phase')" = "question" ] || fail "phase changed by stage: $output"
  [ "$(field "$output" 's.correct')" = "null" ] || fail "correct leaked during live question: $output"
  if curl -s "$B/state" | grep -q "Q2SECRET"; then fail "staged question leaked into /state"; fi
}

@test "advance promotes the staged question live and consumes the slot" {
  post "/host/ask?token=$TOKEN" '{"question":"Q1","options":["a","b"],"correct":0}' >/dev/null
  post "/host/stage?token=$TOKEN" '{"question":"Q2","options":["x","y"],"correct":1}' >/dev/null
  # Reveal the live question first — advance is a between-questions beat, not a
  # mid-question one (see the phase-guard test below).
  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  run post "/host/advance?token=$TOKEN" '{}'
  [ "$(field "$output" 's.advanced')" = "true" ] || fail "advance failed: $output"
  run curl -s "$B/state"
  [ "$(field "$output" 's.question')" = "Q2" ] || fail "advance did not promote Q2: $output"
  # slot is single-use: a second advance with nothing staged is a 409
  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  run post "/host/advance?token=$TOKEN" '{}'
  [ "$(field "$output" 's.error')" = "nothing staged" ] || fail "slot not consumed: $output"
}

@test "advance during a live question is rejected (must reveal first)" {
  post "/host/ask?token=$TOKEN" '{"question":"Q1","options":["a","b"],"correct":0}' >/dev/null
  post "/host/stage?token=$TOKEN" '{"question":"Q2","options":["x","y"],"correct":1}' >/dev/null
  # Q1 is LIVE. Advancing now would wipe players' in-flight answers and desync a
  # subsequent /host/reveal onto Q2 (the advance/reveal race Carnot caught).
  run post "/host/advance?token=$TOKEN" '{}'
  [ "$(field "$output" 's.error')" = "reveal the live question before advancing" ] \
    || fail "advance not phase-guarded during a live question: $output"
  # the rejected advance left the live question untouched AND preserved the slot
  run curl -s "$B/state"
  [ "$(field "$output" 's.question')" = "Q1" ] || fail "rejected advance mutated the live question: $output"
  # once revealed, the still-staged Q2 promotes normally
  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  run post "/host/advance?token=$TOKEN" '{}'
  [ "$(field "$output" 's.advanced')" = "true" ] || fail "advance after reveal failed (slot lost?): $output"
}

@test "advance with nothing staged returns an error" {
  run post "/host/advance?token=$TOKEN" '{}'
  [ "$(field "$output" 's.error')" = "nothing staged" ] || fail "expected 'nothing staged': $output"
}

@test "stage and advance require the host token" {
  run post "/host/stage?token=WRONG" '{"question":"Q","options":["x","y"],"correct":0}'
  [ "$(field "$output" 's.error')" = "bad host token" ] || fail "stage not token-gated: $output"
  run post "/host/advance?token=WRONG" '{}'
  [ "$(field "$output" 's.error')" = "bad host token" ] || fail "advance not token-gated: $output"
}

@test "stage rejects an out-of-range correct index (validated like ask)" {
  run post "/host/stage?token=$TOKEN" '{"question":"Q","options":["x","y"],"correct":5}'
  [ "$(field "$output" 's.error')" = "correct must be 0..1" ] || fail "stage did not range-check: $output"
}

@test "reset clears the staged slot" {
  post "/host/stage?token=$TOKEN" '{"question":"Q2","options":["x","y"],"correct":1}' >/dev/null
  post "/host/reset?token=$TOKEN" '{}' >/dev/null
  run post "/host/advance?token=$TOKEN" '{}'
  [ "$(field "$output" 's.error')" = "nothing staged" ] || fail "reset did not clear staged slot: $output"
}

@test "asking a question directly clears any staged question" {
  post "/host/stage?token=$TOKEN" '{"question":"Q2","options":["x","y"],"correct":1}' >/dev/null
  post "/host/ask?token=$TOKEN" '{"question":"Q1","options":["a","b"],"correct":0}' >/dev/null
  run post "/host/advance?token=$TOKEN" '{}'
  [ "$(field "$output" 's.error')" = "nothing staged" ] || fail "ask did not clear staged slot: $output"
}
