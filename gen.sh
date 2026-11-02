#!/bin/bash
# Regenerate everything derived from SPEED2.EXE: relocs, lifted C, import args.
#   ./gen.sh [path/to/SPEED2.EXE]      (default: $NFSU2_DATA/SPEED2.EXE)
# The OVERRIDE list is derived from the runtime sources (every sub_X_orig the
# runtime references, plus the DX_WRAP(...) table in d3dx_hle.c), so it can
# never drift out of sync with runtime/overrides.c + runtime/d3dx_hle.c.
# When it has finished, gen/all/stamp.txt (and gen/server/stamp.txt) say what
# the lift was made from (tools/genstamp.sh): hashes of the override list,
# the hook list and the lifter, the exe, and the lift options; a build can
# then refuse a gen/all that is older than its runtime.
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"; cd "$ROOT"
EXE="${1:-${NFSU2_DATA:+$NFSU2_DATA/SPEED2.EXE}}"
[ -f "$EXE" ] || { echo "usage: ./gen.sh path/to/SPEED2.EXE"; exit 1; }
PY="$ROOT/.venv/bin/python"
# no stamp until this run has finished
mkdir -p gen/all
echo "incomplete: gen.sh has not finished (or failed)" > gen/all/stamp.txt
STAMP_SOURCES="$(tools/genstamp.sh sources)"
OV=$(tools/genstamp.sh overrides)
echo "OVERRIDE ($(echo "$OV" | tr ',' '\n' | wc -l | tr -d ' ')): $OV"
# Instruction hooks (guest_hook before the instruction): every HOOK_SITE(0x...)
# in the runtime sources, plus any extra HOOKS=... given for debugging.
HK=$( { tools/genstamp.sh hooks | tr ',' '\n'; echo "$HOOKS" | tr ',' '\n'; } | grep -E '^0x' | sort -u | paste -sd, -)
echo "HOOKS ($(echo "$HK" | tr ',' '\n' | grep -c .)): $HK"
# x87 precision control (tools/lift.py): on by
# default, so the game thread computes at PC=24 like on Windows; X87PC=0
# lifts plain doubles (the code before this option).
export X87PC="${X87PC:-1}"
echo "X87PC=$X87PC"
"$PY" tools/reloc2.py "$EXE"
OVERRIDE="$OV" HOOKS="$HK" "$PY" tools/genall.py "$EXE" "${NSHARD:-128}"
"$PY" tools/argcount.py "$EXE" > out/argcount.log
echo "gen OK -> gen/all ($(ls gen/all/shard_*.c | wc -l | tr -d ' ') shards)"

# Second guest module: EA's LAN server, server.dll next to SPEED2.EXE, lifted
# at the fixed guest base 0x00A00000 (runtime/module.c maps the original file
# there and checks its SHA-256 against the one recorded in gen/server).  The
# exe's output above does not depend on it.  Without server.dll a stub module
# is generated: the build links, and hosting a LAN game reports "unavailable".
SRV="$(dirname "$EXE")/server.dll"
mkdir -p gen/server && find gen/server/ -mindepth 1 -delete   # empties it; a worktree's link to the shared one stays a link
if [ -f "$SRV" ]; then
  "$PY" tools/prepare_module.py "$SRV" 0x00A00000 out/server gen/server srv_
  GENOUT=gen/server RELOCS=out/server/relocs.txt SEEDS=out/server/seeds.txt SYMPFX=srv_ \
    OVERRIDE="$OV" HOOKS="$HK" "$PY" tools/genall.py out/server/image.dll "${NSHARD_SRV:-8}" > out/server/genall.log
  grep -E "functions  *:|traps \(|truncated|MISSING" out/server/genall.log | sed 's/^/  server.dll: /'
  RELOCS=out/server/relocs.txt IMPOUT=gen/server/impargs.c SYMPFX=srv_ STRICT=1 IMPDLL="$SRV" \
    "$PY" tools/argcount.py out/server/image.dll > out/server/argcount.log
  echo "gen OK -> gen/server ($(ls gen/server/shard_*.c | wc -l | tr -d ' ') shards)"
else
  mkdir -p gen/server
  printf '#include "module.h"\nconst ModInfo g_srv_modinfo = { "server.dll", "", 0x00a00000u, 0, 0, 0, 0, 0, 0 };\n' > gen/server/modinfo.c
  printf '#include "cpu.h"\ntypedef void(*guest_fn)(CPU*);\nconst uint32_t g_srv_fn_count = 0;\nconst uint32_t g_srv_fn_addr[1] = {0};\nconst guest_fn g_srv_fn_ptr[1] = {0};\n' > gen/server/fntab.c
  printf '#include <stdint.h>\ntypedef struct { uint32_t iat; const char*dll; const char*name; int nargs; } ImpEnt;\nconst uint32_t g_srv_imp_count = 0;\nconst ImpEnt g_srv_imp[1] = {{0}};\n' > gen/server/impargs.c
  printf '#ifndef DECLS_H\n#define DECLS_H\n#include "cpu.h"\n#endif\n' > gen/server/decls.h
  echo "gen: no $SRV -> stub gen/server (LAN hosting unavailable in this build)"
fi

# what this lift was made from (tools/genstamp.sh)
h16(){ shasum -a 256 | cut -c1-16; }
STAMP="$(echo "# gen.sh $(date -u +%Y-%m-%dT%H:%M:%SZ): what gen/all and gen/server were lifted from"
  echo "$STAMP_SOURCES"
  echo "exe $(h16 < "$EXE")$( [ -f "$SRV" ] && echo " server.dll $(h16 < "$SRV")")"
  echo "options X87PC=$X87PC X87OPT=${X87OPT:-} JTSWITCH=${JTSWITCH:-} LREGS=${LREGS:-} FTOL2INL=${FTOL2INL:-} FLAGABI=$( [ -z "${FLAGABI:-}" ] && echo - || { [ -f "$FLAGABI" ] && h16 < "$FLAGABI" || echo missing; } )" \
       "FLAGOPT=${FLAGOPT:-} RETEIP=${RETEIP:-} INLINE=${INLINE:-} INLINE_LIST=$( [ -z "${INLINE_LIST:-}" ] && echo - || basename "$INLINE_LIST") NOCLOSURE=${NOCLOSURE:-} COMMENTS=${COMMENTS:-}" \
       "WATCH=${WATCH:-} COVERAGE=${COVERAGE:-} NSHARD=${NSHARD:-128}/${NSHARD_SRV:-8} HOOKS=${HOOKS:-}")"
echo "$STAMP" > gen/server/stamp.txt
echo "$STAMP" > gen/all/stamp.txt
