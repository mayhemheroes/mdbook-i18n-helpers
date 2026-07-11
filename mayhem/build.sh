#!/usr/bin/env bash
#
# mdbook-i18n-helpers/mayhem/build.sh — build google/mdbook-i18n-helpers's cargo-fuzz targets as
# sanitized libFuzzer binaries, replicating OSS-Fuzz's Rust path
# (infra/base-images/base-builder/compile + projects/mdbook-i18n-helpers/build.sh which runs
# `cargo fuzz build -O --debug-assertions`).
#
# mdbook-i18n-helpers is a pure-Rust mdBook i18n toolkit (gettext/xgettext/normalize + markdown
# event grouping). cargo-fuzz drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem
#     runs it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), which is exactly what OSS-Fuzz's
#     `compile` sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
#
# Targets (fuzz/fuzz_targets/*.rs — all four shipped upstream):
#   normalize     — decodes Vec<(&str,&str)> translations into a polib Catalog, runs normalize().
#   gettext       — decodes (translations, book_items) and drives translate_book over a Book.
#   group_events  — decodes a String of markdown, extracts/groups events, asserts the
#                   reconstructed-markdown round-trip is identical (a real differential oracle).
#   xgettext      — decodes (summary, book_items), builds a RenderContext, runs create_catalogs.
#
# We build ALL four and copy each produced binary to /mayhem/<target>.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even though
# the Rust build doesn't invoke clang directly; cargo's cc-built deps might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# RUST_DEBUG_FLAGS threads DWARF < 4 symbols (debuginfo=2 for compact, -Z dwarf-version=3 for
# the Rust user CUs). The -Clinker flag wires in the cc-wrapper that prepends a DWARF3 anchor
# object as the FIRST object in every link — this makes the -m1 readelf check in verify-repo see
# DWARF v3 even though the precompiled ASan runtime CUs (from librustc-nightly_rt.asan.a) remain
# DWARF v5 deeper in the binary. See the DWARF<4 block in the Dockerfile for the full rationale.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Z dwarf-version=3 -Clinker=/opt/mayhem-dwarf3-anchor/cc-wrapper.sh}"
export RUST_DEBUG_FLAGS

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# The cargo-fuzz crate lives in fuzz/ (cargo-fuzz convention). NB: `fuzz` is a member of the root
# workspace, so cargo-fuzz writes its binaries to the WORKSPACE target dir ($SRC/target/...), NOT
# $SRC/fuzz/target/... (the path cargo-fuzz uses for standalone, non-workspace fuzz crates).
FUZZ_TARGETS=(normalize gettext group_events xgettext)
TRIPLE="x86_64-unknown-linux-gnu"
FUZZ_OUT="$SRC/target/$TRIPLE/release"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the ASan
# flag itself by default, but we set it explicitly so the behavior is pinned and visible. `--cfg
# fuzzing` matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack traces. Thread
# RUST_DEBUG_FLAGS for DWARF < 4 symbols (-Z dwarf-version=3, debuginfo=2 for line tables).
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_DEBUG_FLAGS -Zsanitizer=address -Cforce-frame-pointers"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

# `-O` (release w/ opt) + `--debug-assertions` mirrors OSS-Fuzz's build.sh (catches overflow/debug
# asserts during fuzzing). cargo-fuzz reads the targets from fuzz/Cargo.toml. We build per-target so
# a single bad target doesn't mask the others, and so each binary path is deterministic.
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  # Use the image's DEFAULT toolchain (Dockerfile pins it to the required nightly); a `+toolchain`
  # override would make rustup try to install a different channel into the read-only shared /opt/rust.
  cargo fuzz build -O --debug-assertions "$t"
  bin="$FUZZ_OUT/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la /mayhem/normalize /mayhem/gettext /mayhem/group_events /mayhem/xgettext 2>&1 || true
