#!/usr/bin/env bash
#
# gpsd/mayhem/test.sh — build gpsd's OWN self-contained unit / known-answer tests with NORMAL flags
# (a clean scons tree, no sanitizers) and RUN them, emitting a CTRF summary. exit 0 iff none failed.
#
# PATCH-grade oracle: these are gpsd's real regression unit tests (tests/test_*.c). Each one is a
# known-answer test that calls exit(EXIT_FAILURE) on any mismatch:
#   test_packet  — drives the packet lexer over a fixed table of NMEA/AIS/binary packets and prints
#                  per-case results; we diff its output against the committed golden test/packet.test.chk
#                  (BYTE-EXACT), so a no-op / "return success" patch to the lexer cannot pass.
#   test_json    — round-trips JSON reports through the parser and asserts every decoded field.
#   test_bits    — bitfield extraction KAT (ubits/sbits/...); nonzero exit on any failure.
#   test_crc     — RTCM/NMEA/etc checksum KAT.   test_mktime/test_timespec — time math KAT.
#   test_geoid   — geoid/variation model KAT.     test_matrix/test_trig — DOP/trig math KAT.
#   test_libgps  — libgps state-machine KAT.
# They assert concrete values / byte-exact output, so they're a genuine functional oracle, not a stub.
#
# This script BUILDS the tests itself (separate clean tree) with normal flags so it stays an honest
# oracle independent of the sanitized fuzz build, then RUNS them.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
SRC="${SRC:-$(pwd)}"
cd "$SRC"

: "${MAYHEM_JOBS:=$(nproc)}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if ! command -v scons >/dev/null 2>&1; then
  echo "scons not available — cannot build gpsd's test suite" >&2
  emit_ctrf "gpsd-unit" 0 1 0; exit 2
fi

# scons builds into a variantdir gpsd-<version>~dev/; targets must be named with that prefix.
VDIR_REL="$(python3 -c "import re; s=open('SConstruct').read(); m=re.search(r'gpsd_version\s*=\s*\"([^\"]+)\"', s); print('gpsd-'+m.group(1))" 2>/dev/null || true)"
[ -n "$VDIR_REL" ] || VDIR_REL="$(basename "$(ls -d "$SRC"/gpsd-*~dev/ 2>/dev/null | head -1)")"

TESTS="test_bits test_crc test_json test_packet test_mktime test_geoid test_matrix test_timespec test_trig test_libgps"

# Build the unit tests with NORMAL flags (env clean of sanitizer flags) so this oracle is honest and
# independent of the sanitized fuzz build. scons builds into the gpsd-*~dev/ variant dir.
echo "=== building gpsd unit tests (normal flags) in $VDIR_REL ==="
TGTS=""; for t in $TESTS; do TGTS="$TGTS $VDIR_REL/tests/$t"; done
env -u CFLAGS -u CXXFLAGS -u LINKFLAGS -u SANITIZER_FLAGS -u CC -u CXX \
  scons -j"$MAYHEM_JOBS" qt=no python=no manbuild=no $TGTS \
  >/tmp/gpsd-test-build.log 2>&1
build_rc=$?
if [ "$build_rc" -ne 0 ]; then
  echo "test build failed (rc=$build_rc); tail:" >&2
  tail -30 /tmp/gpsd-test-build.log >&2
fi

BUILDDIR="$(ls -d "$SRC"/gpsd-*~dev/ 2>/dev/null | head -1)"
BUILDDIR="${BUILDDIR%/}"

PASSED=0; FAILED=0
run_case() {
  # run_case <name> <command...>
  local name="$1"; shift
  if [ ! -x "$BUILDDIR/tests/$name" ] && [ "${1:-}" = "__bin__" ]; then
    echo "MISS  $name (binary not built)"; FAILED=$((FAILED+1)); return
  fi
  echo "--- $name ---"
  if "$@" >/tmp/test-$name.out 2>&1; then
    echo "PASS  $name"; PASSED=$((PASSED+1))
  else
    echo "FAIL  $name (rc=$?)"; tail -15 /tmp/test-$name.out; FAILED=$((FAILED+1))
  fi
}

TB="$BUILDDIR/tests"

# test_packet: byte-exact golden-output KAT — diff its output vs committed test/packet.test.chk.
run_case test_packet bash -c '"'"$TB"'/test_packet" | diff -u "'"$SRC"'/test/packet.test.chk" -'

# The rest exit nonzero on any KAT mismatch.
run_case test_bits     "$TB/test_bits" --quiet
run_case test_crc      "$TB/test_crc"
run_case test_json     "$TB/test_json"
run_case test_mktime   "$TB/test_mktime"
run_case test_geoid    "$TB/test_geoid"
run_case test_matrix   "$TB/test_matrix" --quiet
run_case test_timespec "$TB/test_timespec" --quiet
run_case test_trig     "$TB/test_trig"
# test_libgps with -b runs the SELF-CONTAINED built-in gps_unpack() KAT (no live gpsd daemon/socket);
# without -b it tries to connect to a running daemon (Connection refused), which we must not require.
run_case test_libgps   "$TB/test_libgps" -b

emit_ctrf "gpsd-unit" "$PASSED" "$FAILED" 0
