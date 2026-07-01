#!/usr/bin/env bash
#
# mayhem/test.sh — RUN sc2reader's own pytest suite (already built into /mayhem/test-venv by
# mayhem/build.sh). exit 0 = pass. Asserts real BEHAVIOR: test_replays/test_replays.py and
# test_s2gs/test_all.py parse real .SC2Replay/.s2gs fixtures and assert specific decoded values
# (player names, APM, build orders, unit counts, ...) — a PATCH that "fixes" a bug by making
# load_replay()/load_game_summary() a no-op fails these assertions, not just "didn't crash".
#
# A handful of upstream tests fetch a map/localization resource from Blizzard's live depot
# (us-s2-depot.classic.blizzard.com) over the network — unreachable in this air-gapped, offline
# build/test environment (and simply flaky even online), so they are deselected here rather than
# built into an oracle that depends on outside network access.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x /mayhem/test-venv/bin/python ]; then
  echo "missing /mayhem/test-venv — build.sh should have built the oracle venv" >&2
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

# Tests that need the live Blizzard depot (no network in this environment) — deselected, not
# deleted, so they still run for anyone testing online.
NETWORK_TESTS=(
  "test_replays/test_replays.py::TestReplays::test_30_map"
  "test_replays/test_replays.py::TestReplays::test_creepTracker"
  "test_replays/test_replays.py::TestReplays::test_funny_minerals"
  "test_replays/test_replays.py::TestReplays::test_lotv_creepTracker"
  "test_replays/test_replays.py::TestReplays::test_lotv_map"
  "test_s2gs/test_all.py::TestSummaries::test_a_LotV_s2gs"
  "test_s2gs/test_all.py::TestSummaries::test_a_WoL_s2gs"
)
deselect_args=()
for t in "${NETWORK_TESTS[@]}"; do deselect_args+=(--deselect "$t"); done

report="/tmp/pytest-report.txt"
rc=0
/mayhem/test-venv/bin/python -m pytest -q "${deselect_args[@]}" > "$report" 2>&1 || rc=$?
cat "$report"

summary_line="$(grep -E '^[0-9]+ (passed|failed|error|skipped|xfailed|xpassed)' "$report" | tail -1 || true)"
passed=$(grep -oE '[0-9]+ passed'   <<<"$summary_line" | grep -oE '[0-9]+' || echo 0)
failed=$(grep -oE '[0-9]+ failed'   <<<"$summary_line" | grep -oE '[0-9]+' || echo 0)
errors=$(grep -oE '[0-9]+ error'    <<<"$summary_line" | grep -oE '[0-9]+' || echo 0)
skipped=$(grep -oE '[0-9]+ skipped' <<<"$summary_line" | grep -oE '[0-9]+' || echo 0)
xfailed=$(grep -oE '[0-9]+ xfailed' <<<"$summary_line" | grep -oE '[0-9]+' || echo 0)
xpassed=$(grep -oE '[0-9]+ xpassed' <<<"$summary_line" | grep -oE '[0-9]+' || echo 0)
failed=$(( failed + errors ))
skipped=$(( skipped + xfailed + xpassed ))

if [ -z "$summary_line" ]; then
  # pytest itself didn't even get to a summary line (collection error, etc.) — a real failure.
  emit_ctrf "pytest" 0 1 0
  exit 1
fi

emit_ctrf "pytest" "$passed" "$failed" "$skipped"
