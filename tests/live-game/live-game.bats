#!/usr/bin/env bats
# tests/live-game/live-game.bats — smoke/contract tests for the zero-dependency
# realtime audience quiz-game server (skills/live-game/server.mjs).
#
# These pin the game's load-bearing invariants so a future edit can't silently
# break them: (A) counts/correct are HIDDEN during a live question and revealed
# only at reveal, (B) the speed bonus orders faster-correct above slower-correct,
# (C) a vote locks (no answer-switching), (D) host mutations require the token.

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
}

# POST helper: post <path> <json-body>
post() { curl -s -X POST "$B$1" -H 'content-type: application/json' -d "$2"; }
# field <json> <js-expr-on-s> — parse JSON from stdin-arg and print a field
field() { node -e 'const s=JSON.parse(process.argv[1]);console.log(eval(process.argv[2]))' "$1" "$2"; }

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

@test "counts and correct are hidden during a live question, revealed at reveal" {
  post /join '{"clientId":"a","name":"Ada"}' >/dev/null
  post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y","z"],"correct":1}' >/dev/null
  post /vote '{"clientId":"a","option":1}' >/dev/null

  run curl -s "$B/state"
  [ "$(field "$output" 's.counts')" = "null" ] || fail "output=$output"
  [ "$(field "$output" 's.correct')" = "null" ] || fail "output=$output"

  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  run curl -s "$B/state"
  [ "$(field "$output" 's.correct')" = "1" ] || fail "output=$output"
  [ "$(field "$output" 's.counts[1]')" = "1" ] || fail "output=$output"
}

@test "speed bonus: faster correct answer outscores slower correct answer" {
  post /join '{"clientId":"a","name":"Ada"}' >/dev/null
  post /join '{"clientId":"b","name":"Bo"}' >/dev/null
  post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y"],"correct":0,"timeLimit":20}' >/dev/null
  post /vote '{"clientId":"a","option":0}' >/dev/null   # Ada fast
  sleep 1
  post /vote '{"clientId":"b","option":0}' >/dev/null   # Bo ~1s later, also correct
  run post "/host/reveal?token=$TOKEN" '{}'
  local ada bo
  ada=$(field "$output" 's.leaderboard.find(p=>p.name==="Ada").score')
  bo=$(field "$output" 's.leaderboard.find(p=>p.name==="Bo").score')
  [ "$ada" -gt "$bo" ] || fail
  [ "$ada" -eq 1000 ] || fail
}

@test "a vote locks — answer cannot be changed" {
  post /join '{"clientId":"a","name":"Ada"}' >/dev/null
  post "/host/ask?token=$TOKEN" '{"question":"Q","options":["x","y","z"],"correct":0}' >/dev/null
  post /vote '{"clientId":"a","option":2}' >/dev/null    # first answer = z (wrong)
  run post /vote '{"clientId":"a","option":0}'           # try to switch to x (correct)
  [ "$(field "$output" 's.locked')" = "true" ] || fail "output=$output"
  post "/host/reveal?token=$TOKEN" '{}' >/dev/null
  run curl -s "$B/state"
  # locked on the wrong answer → zero score
  [ "$(field "$output" 's.leaderboard.find(p=>p.name==="Ada").score')" = "0" ] || fail "output=$output"
}

@test "host mutations require the token" {
  run post "/host/ask?token=WRONG" '{"question":"Q","options":["x","y"],"correct":0}'
  [ "$(field "$output" 's.error')" = "bad host token" ] || fail "output=$output"
  run curl -s "$B/state"
  [ "$(field "$output" 's.phase')" = "lobby" ] || fail "output=$output"   # state untouched
}

@test "voting requires an active question" {
  post /join '{"clientId":"a","name":"Ada"}' >/dev/null
  run post /vote '{"clientId":"a","option":0}'
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

# NOTE: the name/option HTML-attribute escaping (esc() incl. quotes) runs
# CLIENT-SIDE in the browser, so it can't be exercised by a server-side curl
# here — it would need a headless-browser test, out of scope for this suite.
