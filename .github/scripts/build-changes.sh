#!/bin/bash
# Decide which CI platforms a set of changed files touches, from .github/build-inputs.txt.
#   build-changes.sh [--inputs FILE] [--platforms] < changed-files     one platform per output line
#   build-changes.sh --patterns PLATFORM                                the globs of one platform
#   build-changes.sh --list                                           every platform named in the file
# With no stdin, or when stdin is "*", every platform is selected. An empty list selects none.
set -euo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
INPUTS="$here/../build-inputs.txt"
MODE=platforms
while [ $# -gt 0 ]; do
    case "$1" in
        --inputs) INPUTS="$2"; shift ;;
        --platforms) MODE=platforms ;;
        --patterns) MODE=patterns; PLATFORM="$2"; shift ;;
        --list) MODE=list ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

# "platform: glob" rows, comments and blank lines dropped.
rows() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$INPUTS" | sed -n 's/^\([a-z0-9]*\):[[:space:]]*\(.*\)$/\1 \2/p'; }
platforms() { rows | awk '{print $1}' | grep -vx all | sort -u; }

# A glob becomes an anchored ERE: `**/` may match nothing, `**` crosses directories, `*` does not.
glob_to_re() {
    printf '%s' "$1" | sed -e 's/[.+^$(){}|]/\\&/g' \
        -e 's#\*\*/#\x01#g' -e 's#\*\*#\x02#g' -e 's#\*#[^/]*#g' -e 's#?#[^/]#g' \
        -e 's#\x01#(.*/)?#g' -e 's#\x02#.*#g' -e 's#^#^#' -e 's#$#$#'
}

case "$MODE" in
    list) platforms; exit 0 ;;
    patterns) rows | awk -v f="$PLATFORM" '$1==f || $1=="all"{print $2}'; exit 0 ;;
esac

if [ -t 0 ]; then files="*"; else files=$(cat); fi
if [ "$files" = "*" ]; then platforms; exit 0; fi
[ -n "$files" ] || exit 0

selected=""
while read -r platform glob; do
    re=$(glob_to_re "$glob")
    if printf '%s\n' "$files" | grep -qE "$re"; then
        if [ "$platform" = all ]; then selected="$selected $(platforms | tr '\n' ' ')"
        else selected="$selected $platform"; fi
    fi
done < <(rows)
printf '%s\n' $selected | sort -u
