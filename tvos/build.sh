#!/bin/bash
# Build the game for tvOS as a static library: out/tvos/libnfsu2.a
#   tvos/build.sh            (the shards in gen/ must exist: ./gen.sh "<game folder>/SPEED2.EXE")
#   SDK=appletvsimulator tvos/build.sh     for the simulator (out/tvos-sim)
# The same lifted shards and runtime C as the Mac build (build.sh, link.sh), compiled for
# tvOS; the Objective-C layer is the tvOS-capable part of runtime/*.m plus tvos/host/*.m.
# Not made here: the app itself (tvos/NFSU2.xcodeproj links this library).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
SDKNAME="${SDK:-appletvos}"
SDKPATH="$(xcrun --sdk "$SDKNAME" --show-sdk-path)"
MINOS="${MINOS:-17.0}"
# A10 (the A10X of the Apple TV 4K 1st generation) is the oldest supported chip; the newer ones
# run it too.  MCPU=apple-a15 for a build for the 3rd generation only.
MCPU="${MCPU:-apple-a10}"
case "$SDKNAME" in
  appletvsimulator) TARGET="arm64-apple-tvos$MINOS-simulator"; OUT="out/tvos-sim" ;;
  *)                TARGET="arm64-apple-tvos$MINOS";           OUT="out/tvos" ;;
esac
OPT="${OPT:--O3 -mcpu=$MCPU}"
CC="clang -target $TARGET -isysroot $SDKPATH"
J="${J:-$(sysctl -n hw.ncpu)}"
[ -f gen/all/fntab.c ] && [ -f gen/server/fntab.c ] || { echo "gen/ is missing: run ./gen.sh"; exit 1; }
mkdir -p "$OUT/obj" "$OUT/obj/srv" "$OUT/rt"

CSRC="mem dispatch genexec heap watchdog win32 win32_ext com debug res fileio overrides d3dx_hle vsemu enhance perflog autotest lifecycle widescreen framerate dinput_pad dikeys keyboard dinput_kbd career intro oracle drifttest discord roam roam_core roam_bsd roam_game mprace horn hornmenu optslider tonemenu radio powerunits drift carsfx racehorn racenet winsock online netrace net_vlan module modheap headlights language sms sponsors lobbyclick olfilter tunegraph menusize regional garage sndlead carshadow movie photo dxt_unpack"
MSRC="metal audio gamepad texrep"        # runtime/*.m that build for tvOS
HSRC="$(ls tvos/host/*.m tvos/host/*.c 2>/dev/null | tr '\n' ' ')"

# the lifted shards: an incremental build keyed on a digest, as build.sh does
export CC OPT ROOT OUT
export HDRSUM="$(cat runtime/cpu.h | shasum | cut -c1-16)"
{ (cd gen/all && ls shard_*.c fntab.c stubs.c 2>/dev/null | sed "s|^|all |")
  (cd gen/server && ls shard_*.c fntab.c stubs.c 2>/dev/null | sed "s|^|server |"); } | \
  xargs -P "$J" -n 2 sh -c '
    case "$1" in all) od="$ROOT/$OUT/obj"; pfx="" ;; *) od="$ROOT/$OUT/obj/srv"; pfx="srv_" ;; esac
    cd "$ROOT/gen/$1"; shift
    obj="$od/$pfx$(basename "$1" .c).o"
    sum=$( (cat "$1" decls.h; echo "$CC $OPT $HDRSUM") | shasum | cut -c1-40)
    if [ -f "$obj" ] && [ "$(cat "$obj.sum" 2>/dev/null)" = "$sum" ]; then exit 0; fi
    o=$($CC $OPT -c -I"$ROOT/runtime" -I. -Wno-unused-label -Wno-parentheses-equality -o "$obj" "$1" 2>&1); r=$?
    [ -z "$o" ] || printf "%s\n" "$o" | head -5
    [ $r -eq 0 ] || echo "DID NOT COMPILE: $1" >&2
    [ $r -eq 0 ] && echo "$sum" > "$obj.sum" && echo "  compiled: $1"
    exit $r' sh

# the runtime: C, then Objective-C, then the host; in parallel
pids=""
for f in $CSRC; do
  [ -f "runtime/$f.c" ] || continue
  fx=""; case "$f" in roam_core|roam_game) fx="-ffp-contract=off" ;; esac
  $CC $OPT $fx -DNFS_ENHANCED=0 -Iruntime -Igen/all -c -o "$OUT/rt/$f.o" "runtime/$f.c" & pids="$pids $!"
done
for f in $MSRC; do
  $CC $OPT -fobjc-arc -DNFS_ENHANCED=0 -Iruntime -Igen/all -c -o "$OUT/rt/$f.o" "runtime/$f.m" & pids="$pids $!"
done
for f in $HSRC; do
  b="$(basename "$f")"; b="${b%.*}"
  $CC $OPT -fobjc-arc -DNFS_ENHANCED=0 -Iruntime -Igen/all -Itvos/host -c -o "$OUT/rt/host_$b.o" "$f" & pids="$pids $!"
done
$CC $OPT -Iruntime -Igen/all -c -o "$OUT/rt/impargs.o" gen/all/impargs.c & pids="$pids $!"
$CC $OPT -Iruntime -c -o "$OUT/rt/srv_impargs.o" gen/server/impargs.c & pids="$pids $!"
$CC $OPT -Iruntime -c -o "$OUT/rt/srv_modinfo.o" gen/server/modinfo.c & pids="$pids $!"
# the game's own start-up (tests/boot.c): its main() becomes nfsu2_boot(), called by the host
$CC $OPT -DNFS_ENHANCED=0 -Dmain=nfsu2_boot -Iruntime -Igen/all -c -o "$OUT/rt/boot.o" tests/boot.c & pids="$pids $!"
for p in $pids; do wait "$p" || { echo "compile error"; exit 1; }; done

rm -f "$OUT/libnfsu2.a"
libtool -static -o "$OUT/libnfsu2.a" "$OUT"/obj/*.o "$OUT"/obj/srv/*.o "$OUT"/rt/*.o 2>&1 | grep -v "has no symbols" || true
echo "built $OUT/libnfsu2.a ($(du -h "$OUT/libnfsu2.a" | cut -f1))"
