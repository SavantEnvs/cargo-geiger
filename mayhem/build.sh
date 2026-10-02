#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's cargo-fuzz target(s) as sanitized libFuzzer
# binaries (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS). EDIT per repo.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# The Rust toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo
# (pinned by the Dockerfile ENV — absolute, $HOME-independent).
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run so cargo won't try to refresh the
#     crates.io index over the (absent) network — so do NOT hard-code `--offline`
#     here (it would break this first, online build).
#   - For a FULLY self-contained image (no runtime flag needed) instead vendor:
#       cargo vendor --versioned-dirs vendor   # commit vendor/ + a .cargo/config.toml
#     with [source.crates-io] replace-with = "vendored-sources".
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# OSS-Fuzz Rust libFuzzer+ASan flags. cargo-fuzz sets the ASan flag itself, but we
# pin it explicitly. --cfg fuzzing matches libfuzzer-sys. ASan for Rust comes via
# RUSTFLAGS -Zsanitizer=address (the rustc equivalent of the C/C++ $SANITIZER_FLAGS
# contract — clang's $SANITIZER_FLAGS are ignored by rustc, so the sanitizer is
# threaded here instead). $RUST_DEBUG_FLAGS keeps DWARF < 4 symbols (§6.2 item 10).
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -Z dwarf-version=3}"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address $RUST_DEBUG_FLAGS"
# The libFuzzer runtime inside libfuzzer-sys is C++ compiled by the cc crate with
# clang (which emits DWARF-5 from plain -g) — pin those objects to DWARF-3 too.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export CFLAGS="${CFLAGS:-} $DEBUG_FLAGS" CXXFLAGS="${CXXFLAGS:-} $DEBUG_FLAGS"

# Rust's prebuilt ASan runtime (librustc-nightly_rt.asan.a) ships DWARF-5 CUs and is
# linked BEFORE project code — strip its debug sections so the binary's .debug_info
# starts at our DWARF-3 CUs (§6.2 item 10). Idempotent; the stripped .a is baked in.
ASAN_RT="$(find "$RUSTUP_HOME/toolchains" -name "librustc-nightly_rt.asan.a" 2>/dev/null | head -1)"
if [ -n "$ASAN_RT" ] && [ -f "$ASAN_RT" ]; then
  echo "stripping debug info from Rust ASan runtime: $ASAN_RT"
  objcopy --strip-debug "$ASAN_RT"
fi

# EDIT: the cargo-fuzz crate directory. Use upstream's own fuzz/ when it builds on
# the pinned nightly; otherwise add an ADDITIVE mayhem/fuzz/ crate (leaves upstream
# untouched) and point --fuzz-dir at it.
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

# This vintage (2022) pins proc-macro2 1.0.44 (both here and in the root
# Cargo.lock): its build.rs sets `cfg(proc_macro_span)` on ANY nightly, which
# gates `feature(proc_macro_span_shrink)` in lib.rs — a feature name the
# current nightly removed, so it fails to compile under ANY current
# toolchain. RUSTFLAGS="-Z allow-features=" (empty allow-list) makes its
# `feature_allowed()` probe return false and would skip the cfg cleanly, BUT
# cargo does not propagate RUSTFLAGS/CARGO_ENCODED_RUSTFLAGS to build-script
# (host) compilation when `cargo fuzz build` passes --target explicitly (even
# when target == host) — a known Cargo limitation — so the build script never
# sees it there. Patch the ONE line in the registry's (ephemeral, unpackaged)
# copy of build.rs instead: never a tracked file, and shared by both this fuzz
# build and the root workspace build below (same pinned version, same cache).
# (Needed verbatim — not bumped to a newer proc-macro2 — because the bug this
# backport reproduces is proc-macro2 1.0.44's OWN `fallback::validate_ident`
# panicking on raw identifiers like `r#Self`, fixed in later releases; see
# mayhem/fuzz/Cargo.toml.)
echo "=== patching vendored proc-macro2 1.0.44 build.rs (removed nightly feature probe) ==="
cargo fetch --manifest-path "$FUZZ_DIR/Cargo.toml" --target "$TRIPLE"
PM2_BUILD_RS="$(find "$CARGO_HOME/registry/src" -path '*/proc-macro2-1.0.44/build.rs' 2>/dev/null | head -1)"
[ -n "$PM2_BUILD_RS" ] || { echo "ERROR: vendored proc-macro2 1.0.44 build.rs not found after fetch" >&2; exit 1; }
chmod u+w "$PM2_BUILD_RS"
python3 - "$PM2_BUILD_RS" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "fn feature_allowed(feature: &str) -> bool {"
new = old + "\n    let _ = feature;\n    return false; // patched: see mayhem/build.sh"
if "patched: see mayhem/build.sh" in s:
    pass                          # build.sh re-run on an already-patched cache (§6.2 item 9)
elif old in s:
    s = s.replace(old, new, 1)
    open(p, "w").write(s)
else:
    raise AssertionError("feature_allowed() signature not found — proc-macro2 1.0.44 build.rs changed shape")
PY

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it). A `+toolchain`
# override would make rustup try to install another channel into the locked /opt/rust.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# Build the project's TEST suite with the project's NORMAL flags (clean, non-sanitized
# build in the workspace ./target dir) so mayhem/test.sh only RUNS it. The root
# Cargo.lock also pins proc-macro2 1.0.44 — already patched above (same $CARGO_HOME
# registry cache). The workspace crates separately carry #![deny(warnings)] /
# #![forbid(warnings)] (vintage 2022): the current nightly added lints unknown
# back then (dead_code on unread enum-variant fields, mismatched_lifetime_syntaxes)
# that now trip those denies. --cap-lints=warn downgrades every lint to at most a
# warning without touching the tracked source.
echo "=== building workspace test suite (normal flags) ==="
RUSTFLAGS="--cap-lints=warn" cargo test --workspace --no-run

echo "build.sh complete"
