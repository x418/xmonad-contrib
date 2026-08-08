#!/usr/bin/env bash
#
# Assert that this fork's API is the intended subset of upstream xmonad-contrib's.
#
# Usage: tests/api/check-subset.sh
#
# Reads two checked-in goldens; builds nothing.  They come from different
# places, and that asymmetry is the point:
#
#   tests/api/river/     this fork, dumped from its own build
#                        stack build xmonad-contrib:lib && tests/api/dump-api.sh tests/api/river
#
#   tests/api/upstream/  upstream xmonad-contrib, recorded from a real checkout
#                        tests/api/dump-api.sh tests/api/upstream ../xmonad-contrib
#
# This is ../xmonad-river/tests/api/check-subset.sh applied to contrib, with
# one assertion added.  The backend drops individual names; contrib mostly
# drops whole modules -- 47 of upstream's 328 are commented out of
# exposed-modules because they do not build -- so the module list is checked
# in its own right, and names are only compared for modules both sides expose.
#
#   1. Every module upstream exposes and this fork does not is justified in
#      disabled-modules.txt, and every module named there is genuinely absent.
#      The second half matters as much as the first: a module that starts
#      building and gets re-enabled should force its entry to be deleted, or
#      the file is describing a port that no longer exists.
#
#   2. Every name upstream exports from a module both sides expose, and this
#      fork does not, is justified in unportable.txt.  A `module:` line there
#      accounts for every drop in one module at once, for the cases where the
#      cause is one structural fact rather than N decisions.
#
#   3. Every name this fork exports that upstream does not is justified in
#      added.txt.  Upstream's own surface and its Graphics.X11 re-exports are
#      compared as a union, so a name that merely moves from Graphics.X11 into
#      XMonad.Util.River.Compat is not flagged.
#
# CAVEAT, and it is a real one: the two goldens are recorded against different
# toolchains -- this fork builds on lts-24.53 (GHC 9.10, base 4.20), the
# upstream checkout next door on the umbrella project's lts-22.4 (GHC 9.6,
# base 4.18).  A name that base gained in between shows up here as an addition
# by the fork, which it is not; `unsnoc` and `List` in XMonad.Prelude are
# exactly that and are marked as such in added.txt.  Putting both on one
# resolver would remove the whole category, and is worth doing.

set -euo pipefail

cd "$(dirname "$0")/../.."

api=tests/api
up_api=$api/upstream/contrib-api.golden
up_reexports=$api/upstream/contrib-reexports.golden
rv_api=$api/river/contrib-api.golden
rv_reexports=$api/river/contrib-reexports.golden

for f in "$up_api" "$up_reexports" "$rv_api" "$rv_reexports" \
         "$api/upstream/modules.txt" "$api/river/modules.txt"; do
    [ -f "$f" ] || { echo "check-subset: missing $f" >&2; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# A justification file is `name  reason`, with # comments and blank lines.
listed() { grep -vE '^\s*(#|$)' "$1" | awk '{print $1}' | sort -u; }

status=0

report() {
    local label=$1 actual=$2 claimed=$3 file=$4 verb=$5
    local undocumented documented_but_absent
    undocumented=$(comm -23 "$actual" "$claimed")
    documented_but_absent=$(comm -13 "$actual" "$claimed")

    if [ -n "$undocumented" ]; then
        echo "check-subset: $label not justified in $file:" >&2
        printf '  %s\n' $undocumented >&2
        status=1
    fi
    if [ -n "$documented_but_absent" ]; then
        echo "check-subset: $file lists entries that are $verb:" >&2
        printf '  %s\n' $documented_but_absent >&2
        status=1
    fi
    if [ -z "$undocumented$documented_but_absent" ]; then
        printf 'check-subset: %-38s OK (%d)\n' "$label" "$(wc -l < "$actual")"
    fi
}

# ---------------------------------------------------------------- 1. modules
sort "$api/upstream/modules.txt" > "$tmp/up-mods"
sort "$api/river/modules.txt"    > "$tmp/rv-mods"
comm -23 "$tmp/up-mods" "$tmp/rv-mods" > "$tmp/disabled"
comm -12 "$tmp/up-mods" "$tmp/rv-mods" > "$tmp/shared"
listed "$api/disabled-modules.txt" > "$tmp/disabled-claimed"

report "modules disabled by the fork" "$tmp/disabled" "$tmp/disabled-claimed" \
       "$api/disabled-modules.txt" "not actually disabled"

# ------------------------------------------------------------------ 2. names
# `module | name | decl` -> `module name`, restricted to modules both expose.
pairs() { cut -d'|' -f1,2 "$@" | tr -d ' ' | tr '|' ' ' | sort -u; }
pairs "$up_api" "$up_reexports" > "$tmp/up-pairs"
pairs "$rv_api" "$rv_reexports" > "$tmp/rv-pairs"

join_shared() { awk 'NR==FNR{s[$1];next} $1 in s' "$tmp/shared" "$1"; }
join_shared "$tmp/up-pairs" | sort > "$tmp/up-shared"
join_shared "$tmp/rv-pairs" | sort > "$tmp/rv-shared"

comm -23 "$tmp/up-shared" "$tmp/rv-shared" > "$tmp/dropped-pairs"

# A `module:M` entry in unportable.txt accounts for every drop in module M.
grep -E '^\s*module:' "$api/unportable.txt" 2>/dev/null \
    | sed 's/^\s*module://' | awk '{print $1}' | sort -u > "$tmp/blanket" || true
awk 'NR==FNR{b[$1];next} !($1 in b) {print $2}' "$tmp/blanket" "$tmp/dropped-pairs" \
    | sort -u > "$tmp/dropped"
# A blanket entry for a module that drops nothing is stale.
awk 'NR==FNR{d[$1];next} !($1 in d) {print $1}' \
    <(awk '{print $1}' "$tmp/dropped-pairs" | sort -u) "$tmp/blanket" > "$tmp/blanket-stale"
if [ -s "$tmp/blanket-stale" ]; then
    echo "check-subset: $api/unportable.txt has module: entries that drop nothing:" >&2
    sed 's/^/  /' "$tmp/blanket-stale" >&2
    status=1
fi

grep -vE '^\s*module:' "$api/unportable.txt" | grep -vE '^\s*(#|$)' \
    | awk '{print $1}' | sort -u > "$tmp/unportable"

report "names dropped from shared modules" "$tmp/dropped" "$tmp/unportable" \
       "$api/unportable.txt" "not actually dropped"

# ------------------------------------------------------------------ 3. added
names() { cut -d'|' -f2 "$@" | sed 's/^ *//; s/ *$//' | sort -u; }
names "$up_api" "$up_reexports" > "$tmp/up-all"
names "$rv_api" "$rv_reexports" > "$tmp/rv-all"
comm -13 "$tmp/up-all" "$tmp/rv-all" > "$tmp/added"
listed "$api/added.txt" > "$tmp/added-claimed"

report "names added by the fork" "$tmp/added" "$tmp/added-claimed" \
       "$api/added.txt" "not actually added"

exit "$status"
