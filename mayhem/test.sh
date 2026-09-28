#!/usr/bin/env bash
#
# mayhem/test.sh — RUN cargo-geiger's own upstream test suite (already built by
# mayhem/build.sh via `cargo test --workspace --no-run`) and report CTRF counts.
#
# The suite invocation mirrors upstream CI exactly (.github/workflows/ci.yml):
#   cargo test -- --skip args::args_tests::update_config_test_color_choice::case_4 \
#                 --skip test_package
# The two skips are upstream's own: the color-choice case and the `test_package`
# insta snapshot cases are environment/rustc-version dependent and upstream CI
# skips them on every platform. Everything else (unit tests across the
# cargo-geiger / cargo-geiger-serde / geiger crates + the non-snapshot
# integration tests + doc tests) runs and asserts real behavior/output.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
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

LOG=/tmp/cargo-test.log
env -u RUSTFLAGS cargo test --workspace -- \
  --skip args::args_tests::update_config_test_color_choice::case_4 \
  --skip test_package >"$LOG" 2>&1
rc=$?
cat "$LOG"

# Sum the per-binary "test result: ok. N passed; M failed; K ignored; ... Z filtered out"
read -r PASSED FAILED SKIPPED <<<"$(awk '
  /^test result:/ {
    for (i = 1; i <= NF; i++) {
      if ($(i+1) ~ /^passed/)   p += $i
      if ($(i+1) ~ /^failed/)   f += $i
      if ($(i+1) ~ /^ignored/)  s += $i
      if ($(i+1) ~ /^filtered/) s += $i
    }
  }
  END { printf "%d %d %d", p+0, f+0, s+0 }' "$LOG")"

if ! grep -q '^test result:' "$LOG"; then
  echo "ERROR: no 'test result:' lines — the pre-built test suite did not run (build.sh bug?)" >&2
  emit_ctrf cargo-test 0 1 0
  exit 1
fi
[ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ] && FAILED=1   # non-zero cargo exit with no parsed failure still fails

emit_ctrf cargo-test "$PASSED" "$FAILED" "$SKIPPED"
