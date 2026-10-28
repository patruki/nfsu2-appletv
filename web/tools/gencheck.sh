#!/bin/bash
# Is the lifted C (gen/all, gen/server) the one this checkout's runtime needs?
# web/build.sh runs this before it compiles anything; exit 1 with what to do.
#
#   web/tools/gencheck.sh                 check gen/all and gen/server
#   GEN=<dir> web/tools/gencheck.sh       check <dir>/all and <dir>/server (the check's own test)
#   GEN_STALE_OK=1 ...                    report a stale gen but pass (experiments)
#
# 1. Every sub_X_orig the runtime names is declared in gen/all/decls.h (gen.sh
#    renames the lifted function the runtime overrides; a gen/all older than
#    the runtime fails the link with duplicate or missing sub_X).
# 2. gen.sh's stamp (gen/all/stamp.txt, tools/genstamp.sh): the override list,
#    the hook list (a HOOK_SITE change does not break the link: the hook
#    silently goes) and the lifter of this checkout are the ones gen/all was
#    made from, the lift finished, and gen/server comes from the same run.  A
#    gen/all without a stamp (made before gen.sh wrote one) gets a note.
set -e -o pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT"
G="${GEN:-gen}"
[ -f "$G/all/decls.h" ] || { echo "$G/all missing: run web/gen.sh <path to SPEED2.EXE>"; exit 1; }
STALE=$(grep -ohE 'sub_00[0-9a-f]{6}_orig' runtime/*.c runtime/*.m | sort -u | while read -r f; do
  grep -q "void $f(" "$G/all/decls.h" || echo "$f"; done)
[ -z "$STALE" ] || { echo "$G/all is older than the runtime (not lifted as _orig: $(echo $STALE | tr '\n' ' ')): run web/gen.sh <SPEED2.EXE>"; exit 1; }
if [ ! -f "$G/all/stamp.txt" ]; then
  echo "note: $G/all has no stamp (made before gen.sh wrote one): only its _orig declarations were checked; web/gen.sh <SPEED2.EXE> makes a stamped one"
  exit 0
fi
if grep -q '^incomplete' "$G/all/stamp.txt"; then
  echo "$G/all is not a finished lift ($(head -1 "$G/all/stamp.txt")): run web/gen.sh <SPEED2.EXE>"; exit 1; fi
WANT="$(tools/genstamp.sh sources)"
HAVE="$(grep -E '^(overrides|hooks|lifter) ' "$G/all/stamp.txt" || true)"
if [ "$WANT" != "$HAVE" ]; then
  echo "$G/all is stale: it was made from another"
  for k in overrides hooks lifter; do
    [ "$(grep "^$k " <<< "$WANT" || true)" = "$(grep "^$k " <<< "$HAVE" || true)" ] && continue
    case $k in
      overrides) echo "  override list (sub_X_orig in runtime/, DX_WRAP in d3dx_hle.c: tools/genstamp.sh overrides)" ;;
      hooks) echo "  hook list (HOOK_SITE in runtime/: tools/genstamp.sh hooks)" ;;
      lifter) echo "  lifter (tools/lift.py, lregs.py, genall.py, inline_hot.txt, retpast.txt, reloc2.py, argcount.py, flagabi.py, prepare_module.py)" ;;
    esac
  done
  if [ "${GEN_STALE_OK:-}" = 1 ]; then echo "  GEN_STALE_OK=1: building anyway"
  else echo "  run web/gen.sh <path to SPEED2.EXE> (GEN_STALE_OK=1 builds anyway)"; exit 1; fi
fi
cmp -s "$G/all/stamp.txt" "$G/server/stamp.txt" || {
  echo "$G/server is not from the gen.sh run that made $G/all ($G/server/stamp.txt differs or is missing): run web/gen.sh <SPEED2.EXE>"; exit 1; }
