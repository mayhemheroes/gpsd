#!/usr/bin/env bash
#
# gpsd/mayhem/build.sh — build gpsd's five OSS-Fuzz harnesses (ada-fuzzers) as sanitized libFuzzer
# targets (+ standalone reproducers). gpsd is a GPS daemon; the harnesses drive its packet-stream
# parsers on attacker-controlled bytes:
#   FuzzPacket            — raw packet framing: lexer_init + packet_parse + packet_get over the
#                           auto-detecting state machine (NMEA / AIS / SiRF / UBX / RTCM / TSIP / ...).
#   FuzzDrivers           — full device demux: gps_context_init/gpsd_init + gpsd_poll() over a pipe,
#                           exercising every driver's get_packet()/parse path (auto-detect → driver).
#   FuzzDriversStructured — protocol-aware: builds VALID framed packets (correct SiRF/UBX/Zodiac/
#                           GeoStar/Navcom/NMEA/RTCM3/TSIP/GREIS/Skytraq checksums) from the input,
#                           then feeds gpsd_poll() — reaches deep driver parse code past framing.
#   FuzzJson              — JSON report parser: libgps_json_unpack() + json_toff_read().
#   FuzzClient            — client command parser: json_watch_read() / json_device_read() /
#                           parse_uri_dest() over ?WATCH / ?DEVICE JSON.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). gpsd builds with scons; scons honors CC/CFLAGS/LINKFLAGS from the
# environment (SConscript ~L605-633), so we fold $SANITIZER_FLAGS into the compiler/linker the same
# way OSS-Fuzz does (CC="$CC $CFLAGS"). That instruments the gpsd library ITSELF (libgps_static +
# libgpsd_static), not just the harness wrappers.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

SRC="${SRC:-$(pwd)}"
cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
OUT="/mayhem"
mkdir -p "$OUT"

# ── 1) Build gpsd WITH sanitizers via scons. scons reads CC/CFLAGS/LINKFLAGS from the env. We carry
#       $SANITIZER_FLAGS on the compiler (CC/CXX) and on LINKFLAGS so both the .o's and the link of
#       the static libs are instrumented. nostrip/debug keep symbols for ASan/UBSan reports. ────────
export CFLAGS="${CFLAGS:-} $SANITIZER_FLAGS"
export CXXFLAGS="${CXXFLAGS:-} $SANITIZER_FLAGS"
export LINKFLAGS="${LINKFLAGS:-} $SANITIZER_FLAGS"
# scons folds CC/CFLAGS the way OSS-Fuzz expects; mirror the ada-fuzzers recipe (CC carries flags,
# then clear CFLAGS so scons doesn't ALSO warn about CCFLAGS-from-environment overriding its tree).
export CC="$CC $CFLAGS"
export CXX="$CXX $CXXFLAGS"
export CFLAGS=""
export CXXFLAGS=""

# Build the static libs the harnesses link (libgps_static.a + libgpsd.a) plus generated headers.
# The lib targets live in the variantdir gpsd-<ver>~dev/; build them by their relative paths so we
# skip the daemon binaries/docs. Fall back to the full default build if the target names ever drift.
VDIR_REL="$(python3 -c "import re,io; s=open('SConstruct').read(); m=re.search(r'gpsd_version\s*=\s*\"([^\"]+)\"', s); print('gpsd-'+m.group(1))" 2>/dev/null || true)"
if [ -n "$VDIR_REL" ] && scons -j"$MAYHEM_JOBS" qt=no python=no manbuild=no \
     "$VDIR_REL/libgps_static.a" "$VDIR_REL/libgpsd.a"; then
  echo "built static libs via $VDIR_REL targets"
else
  echo "explicit lib targets failed/unknown — building scons default" >&2
  scons -j"$MAYHEM_JOBS" qt=no python=no manbuild=no
fi

# The scons variantdir is gpsd-<version>~dev/ (matches the ada-fuzzers Makefile `ls -d ../gpsd*~dev/`).
BUILDDIR="$(ls -d "$SRC"/gpsd-*~dev/ 2>/dev/null | head -1)"
BUILDDIR="${BUILDDIR%/}"
if [ -z "$BUILDDIR" ] || [ ! -d "$BUILDDIR" ]; then
  echo "ERROR: scons variant build dir gpsd-*~dev/ not found" >&2
  ls -d "$SRC"/gpsd* 2>&1 || true
  exit 1
fi
echo "gpsd built in $BUILDDIR"
INC="-I$BUILDDIR/include -I$BUILDDIR"

# ── 2) Standalone driver object (run-once reproducer; reads one input file). ──────────────────────
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$HARNESS_DIR/standalone_main.c" -o "$OUT/standalone_main.o"

# ── 3) Build each harness twice: libFuzzer (-> /mayhem/<name>) + standalone (-> /mayhem/<name>-standalone).
#       gpsd's harnesses need libgpsd + libgps_static (driver demux) and -lm/-lpthread/-lrt. ────────
LIBS="-L$BUILDDIR -lgpsd -lgps_static -lm -lpthread -lrt"
for harness in FuzzPacket FuzzDrivers FuzzDriversStructured FuzzJson FuzzClient; do
  # libFuzzer target. The harnesses lean on transitive libc includes pulled in by gpsd's headers;
  # force-include string.h so memcpy/strlen are declared regardless of header include order
  # (avoids -Wimplicit-function-declaration as a hard error under clang/C99).
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC -pthread -std=c99 -D_GNU_SOURCE -include string.h \
      "$HARNESS_DIR/$harness.c" -c -o "$OUT/$harness.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
      "$OUT/$harness.o" $LIB_FUZZING_ENGINE $LIBS \
      -o "$OUT/$harness"

  # standalone reproducer (no libFuzzer runtime)
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
      "$OUT/$harness.o" "$OUT/standalone_main.o" $LIBS \
      -o "$OUT/$harness-standalone"

  rm -f "$OUT/$harness.o"
  echo "built $harness (+ standalone)"
done
rm -f "$OUT/standalone_main.o"

echo "build.sh complete:"
ls -la "$OUT"/FuzzPacket "$OUT"/FuzzDrivers "$OUT"/FuzzDriversStructured "$OUT"/FuzzJson "$OUT"/FuzzClient \
       "$OUT"/FuzzPacket-standalone "$OUT"/FuzzDrivers-standalone "$OUT"/FuzzDriversStructured-standalone \
       "$OUT"/FuzzJson-standalone "$OUT"/FuzzClient-standalone 2>&1 || true
