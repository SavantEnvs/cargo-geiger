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

# cargo-geiger/cargo-geiger-serde/geiger all carry `#![deny(warnings)]`; the pinned
# nightly's newer default lints (e.g. mismatched_lifetime_syntaxes) turn into hard
# errors under that attribute when building/running the workspace test suite below.
# --cap-lints=allow caps every lint level regardless of in-source deny attributes;
# set it via cargo config (not RUSTFLAGS) so it also reaches mayhem/test.sh's later
# `cargo test --workspace` run, which unsets RUSTFLAGS to avoid the ASan fuzz flags.
mkdir -p .cargo
cat > .cargo/config.toml <<'EOF'
[build]
rustflags = ["--cap-lints=allow"]
EOF

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
# geiger::find_unsafe_in_string recurses through syn's recursive-descent expr/type
# parser with no depth limit: a deeply nested input overflows the stack (the bug
# this backport reproduces). A `-O` release build inlines/shrinks those parser
# frames enough that the mayhemheroes-era crashers (built without that inlining)
# no longer reach the guard page within the default 8 MiB stack — `--dev` restores
# the original per-frame stack cost so the same inputs overflow again.
PROFILE_DIR="debug"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it). A `+toolchain`
# override would make rustup try to install another channel into the locked /opt/rust.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" --dev --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/$PROFILE_DIR/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# time 0.3.30 (pinned in the root Cargo.lock, pulled in by cargo-geiger's own
# `cargo` dependency) hits an rustc type-inference regression (E0282 in
# format_description/parse/mod.rs) under the pinned nightly; bump to a release
# carrying the upstream fix (an explicit `Box<_>` annotation) before the workspace
# test build. The pinned nightly's cargo rewrites the whole lock file to format
# v4 on any update, which the project's OWN `cargo-lock`-reading test code (built
# against an older release of that crate) cannot parse ("lock file version 4
# requires -Znext-lockfile-bump") — restore the v3 header `cargo update` shipped
# the file with so only the `time` entry actually changes.
LOCKFILE_VERSION="$(sed -n 's/^version = //p' Cargo.lock | head -1)"
# --offline first: a plain `cargo update` always refreshes the registry index
# over the network even when the target crate is already cached, which breaks
# the air-gapped PATCH re-run (§6.5) once this FIRST (online) build has already
# populated $CARGO_HOME with time-0.3.37. Fall back to a networked update only
# when that cache doesn't exist yet (this first build).
cargo update -p time --precise 0.3.37 --offline 2>/dev/null \
  || cargo update -p time --precise 0.3.37
sed -i "0,/^version = /{s/^version = .*/version = ${LOCKFILE_VERSION}/}" Cargo.lock

# Build the project's TEST suite with the project's NORMAL flags (clean, non-sanitized
# build in the workspace ./target dir) so mayhem/test.sh only RUNS it.
echo "=== building workspace test suite (normal flags) ==="
env -u RUSTFLAGS cargo test --workspace --no-run

echo "build.sh complete"
