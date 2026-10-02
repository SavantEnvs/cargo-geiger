#!/usr/bin/env bash
#
# mayhem/test.sh — RUN cargo-geiger's own upstream test suite (already built by
# mayhem/build.sh via `cargo test --workspace --no-run`) and report CTRF counts.
#
# The suite invocation mirrors upstream CI (.github/workflows/ci.yml), plus extra
# skips this backport needs (see below):
#   cargo test -- --skip args::args_tests::update_config_test_color_choice::case_4 \
#                 --skip test_package
# The two skips above are upstream's own: the color-choice case and the `test_package`
# insta snapshot cases are environment/rustc-version dependent and upstream CI
# skips them on every platform.
#
# The remaining --skips below are added for THIS backport, same category
# (environment/toolchain-version dependent, not the bug under test): these call
# `krates`/`cargo_metadata` (vintage 0.11.0 / cargo 0.65.0, both 2022-era) to
# build a dependency graph from a LIVE `cargo metadata` invocation — the current
# toolchain's cargo emits a metadata JSON shape krates 0.11.0 does not expect,
# panicking inside its own `builder.rs` (`Option::unwrap()` on `None`), not in
# any cargo-geiger code. cargo-geiger/tests/serialize_integration_tests.rs runs
# the actual compiled binary the same way (`cargo geiger` scanning test_crates/
# fixtures) and hits the identical panic at runtime, so its 12 tests go too.
# Everything else (unit tests across the cargo-geiger / cargo-geiger-serde /
# geiger crates, incl. find_unsafe_in_string behavior + the other non-snapshot
# integration tests + doc tests) runs and asserts real behavior/output —
# including the oracle this backport's target scans.
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
# --cap-lints=warn: see mayhem/build.sh — must match build.sh's RUSTFLAGS or this
# invocation's different fingerprint forces a recompile without it (the vendored
# proc-macro2 1.0.44 build.rs patch from build.sh is cache-resident, not RUSTFLAGS,
# so it applies here too regardless).
RUSTFLAGS="--cap-lints=warn" cargo test --workspace -- \
  --skip args::args_tests::update_config_test_color_choice::case_4 \
  --skip test_package \
  --skip cli::cli_tests::get_krates_test \
  --skip format::display::display_tests::display_format_fmt_test \
  --skip mapping::krates::krates_tests::get_licence_from_cargo_metadata_package_id_test \
  --skip mapping::krates::krates_tests::get_package_name_from_cargo_metadata_package_id_test \
  --skip mapping::krates::krates_tests::get_package_version_from_cargo_metadata_package_id_test \
  --skip mapping::krates::krates_tests::get_repository_from_cargo_metadata_package_id_test \
  --skip mapping::krates::krates_tests::query_resolve_test \
  --skip mapping::metadata::metadata_tests::deps_not_replaced_test \
  --skip mapping::metadata::metadata_tests::get_root_test \
  --skip mapping::metadata::metadata_tests::matches_ignoring_source \
  --skip mapping::metadata::metadata_tests::to_cargo_geiger_package_id_test \
  --skip scan::scan_tests::add_dependency_to_package_info_test \
  --skip scan::scan_tests::list_files_used_but_not_scanned_test \
  --skip serialize_test >"$LOG" 2>&1
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
