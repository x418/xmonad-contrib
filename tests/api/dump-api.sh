#!/usr/bin/env bash
#
# Record the exported interface of every module the library exposes.
#
# Usage: tests/api/dump-api.sh OUTDIR [UPSTREAM_CHECKOUT]
#
#   tests/api/dump-api.sh tests/api/river
#       Dump this fork, from its own build.
#
#   tests/api/dump-api.sh tests/api/upstream ../xmonad-contrib
#       Dump upstream xmonad-contrib, from a real checkout, and record the
#       commit it came from beside the goldens.
#
# The two goldens are recorded the same way and compared by
# tests/api/check-subset.sh.  This mirrors ../xmonad-river/tests/api/, and the
# output format is deliberately identical -- `module | name | declaration` --
# so the two checks read the same and a fix learned in one transfers.
#
# Where it differs from the backend's is the module list.  The backend has
# eight modules and names them; contrib has hundreds and disables the ones that
# do not build, so the list has to come from the cabal file being dumped.  That
# is also what makes the module-level assertion in check-subset.sh possible: a
# module vanishing from exposed-modules is the main way this fork drops API.
#
# :browse is batched through one ghci rather than one `ghc -e` per module.  At
# 328 modules the per-invocation cost dominates everything else -- the batched
# run is seconds, the unbatched one is minutes.

set -euo pipefail

cd "$(dirname "$0")/../.."

outdir=${1:?usage: dump-api.sh OUTDIR [UPSTREAM_CHECKOUT]}
checkout=${2:-}

# Names whose defining module is the X11-shaped compatibility surface.  Only
# one of these exists in a given build: upstream re-exports Graphics.X11
# directly, this fork re-exports its own equivalents.  A name that merely moves
# between the two is not a difference, which is why check-subset.sh compares
# the union of the api and reexport goldens rather than the api file alone.
compat_prefixes='Graphics\.X11|XMonad\.Util\.River\.Compat'

cabal=xmonad-contrib.cabal
run_from=.

if [ -n "$checkout" ]; then
    [ -d "$checkout" ] || { echo "dump-api: no such checkout: $checkout" >&2; exit 1; }
    sha=$(git -C "$checkout" rev-parse HEAD)
    if ! git -C "$checkout" diff --quiet HEAD; then
        echo "dump-api: $checkout has uncommitted changes;" >&2
        echo "          the recording will include them" >&2
    fi
    cabal=$checkout/xmonad-contrib.cabal
    # Upstream contrib is a package of the umbrella project one level up, so
    # ghci has to run from there with the package named explicitly.
    run_from=$(cd "$checkout/.." && pwd)
fi

mkdir -p "$outdir"

# The exposed-modules block, minus the ones commented out.  A module the cabal
# does not name is not part of the library's interface however much source is
# on disk, which is exactly the property being recorded.
modules=$(awk '
    /^[ \t]*exposed-modules:/ { inblk=1 }
    inblk && /^[ \t]*(other-modules|build-depends|hs-source-dirs|ghc-options|default-language|if )/ { inblk=0 }
    inblk {
        line=$0
        sub(/^[ \t]*exposed-modules:[ \t]*/, "", line)
        gsub(/[ \t]/, "", line)
        if (line ~ /^[A-Z][A-Za-z0-9_.]*$/) print line
    }
' "$cabal" | sort -u)

# This fork's own modules are excluded, as XMonad.River is in the backend's
# check: they have no upstream counterpart by design, and comparing them
# against one would only ever report that they are new.  What they export
# still reaches the comparison wherever a shared module re-exports it.
modules=$(printf '%s\n' "$modules" | grep -v '^XMonad\.Util\.River\.' || true)

count=$(printf '%s\n' "$modules" | grep -c . || true)
printf 'dump-api: %s modules from %s\n' "$count" "$cabal" >&2
printf '%s\n' "$modules" > "$outdir/modules.txt"

if [ -n "$checkout" ]; then
    printf '%s\n' \
      "# The commit whose interface is recorded beside this file." \
      "#" \
      "# Written by tests/api/dump-api.sh when given a checkout to read." \
      "# Nothing forces a re-record when that checkout moves on, so this is how" \
      "# a reviewer tells how old the comparison in check-subset.sh has become." \
      "$sha" > "$outdir/source.sha"
fi

script=$(mktemp); raw=$(mktemp)
trap 'rm -f "$script" "$raw"' EXIT

# A marker line before each :browse is what attributes the output to a module;
# ghci gives no other clue where one listing ends and the next begins.
while read -r m; do
    [ -n "$m" ] || continue
    printf 'putStrLn "###MOD %s"\n:browse %s\n' "$m" "$m"
done <<< "$modules" > "$script"
echo ':quit' >> "$script"

( cd "$run_from" && stack exec --package xmonad-contrib -- \
      ghci -v0 -ignore-dot-ghci -package xmonad-contrib < "$script" ) > "$raw" || {
    echo "dump-api: ghci failed; is the library built?" >&2; exit 1; }

perl -e '
    my ($compat, $api_out, $reexport_out) = @ARGV[0..2];
    my (@api, @reexports);
    my ($module, $entry);

    my $flush = sub {
        return unless defined $entry;
        my $is_reexport = 0;
        if ($entry =~ /(?:[A-Za-z0-9_.-]+:)?((?:[A-Z][A-Za-z0-9_\x27]*\.)+)/) {
            my $mod = $1;
            $mod =~ s/\.$//;
            $is_reexport = 1 if $mod =~ /^(?:$compat)(?:\.|$)/;
        }

        my $text = $entry;
        $text =~ s/(?:[A-Za-z0-9_.-]+:)?(?:[A-Z][A-Za-z0-9_\x27]*\.)+//g;
        $text =~ s/\{-# UNPACK #-\}//g;
        $text =~ s/\(N:[^)]*\)//g;
        $text =~ s/!\s*//g;
        $text =~ s/\s+/ /g;
        $text =~ s/^ | $//g;

        my $name;
        if    ($text =~ /^(?:type|data|newtype) (?:family |instance |role )?(\S+)/) { $name = $1 }
        elsif ($text =~ /^class (?:.*=> )?(\S+)/)                                   { $name = $1 }
        elsif ($text =~ /^(\(.*?\)|[^\s:]+) ::/)                                    { $name = $1 }
        else                                                                        { $name = $text }

        push @{ $is_reexport ? \@reexports : \@api }, "$module | $name | $text\n";
        $entry = undef;
    };

    while (my $line = <STDIN>) {
        chomp $line;
        if ($line =~ /^###MOD (\S+)/) { $flush->(); $module = $1; next; }
        next if $line =~ /^\s*$/;
        next unless defined $module;
        if ($line =~ /^\s/) { $entry .= " $line" if defined $entry; }
        else                { $flush->(); $entry = $line; }
    }
    $flush->();

    for my $spec ([$api_out, \@api], [$reexport_out, \@reexports]) {
        my ($path, $lines) = @$spec;
        open my $fh, ">", $path or die "$path: $!";
        print $fh $_ for sort @$lines;
        close $fh;
    }
' "$compat_prefixes" "$outdir/contrib-api.golden" "$outdir/contrib-reexports.golden" < "$raw"

printf 'api:       %6d entries -> %s\n' \
    "$(wc -l < "$outdir/contrib-api.golden")" "$outdir/contrib-api.golden"
printf 'reexports: %6d entries -> %s\n' \
    "$(wc -l < "$outdir/contrib-reexports.golden")" "$outdir/contrib-reexports.golden"
printf 'modules:   %6d         -> %s\n' "$count" "$outdir/modules.txt"
