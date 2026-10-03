# shellcheck shell=bash
# Sourced (BASH_ENV) by the upstream theme install scripts that install.sh runs.
#
# 1. Under iSH a process whose argv+envp exceed ~68 KB segfaults at startup (the
#    kernel's own limit is 128 KB), and the scripts pass globs of 1000+ icon paths to
#    sed and cp. As shell functions, sed and cp receive any number of arguments without
#    an exec; they hand them to the real tools in batches of 200.
# 2. The fakefs lives on case-insensitive APFS (the iPad's too), so icon aliases that
#    differ only in case ("Cheese.svg" -> "cheese.svg") cannot be created. cp ignores
#    exactly that error; GTK finds the other spelling anyway.

ish_batch=200

# 3. busybox rm has no --one-file-system and busybox ln no -r (Fluent uses both). GNU coreutils is not installed
#    instead: iSH lets open(O_DIRECTORY) succeed on a regular file, so GNU cp/install
#    mistake existing files for directories.
rm() {
    local args=() a
    for a in "$@"; do
        [ "$a" = --one-file-system ] || args+=("$a")
    done
    command rm "${args[@]}"
}

sed() {
    if [ "$1" = -i ] && [ $# -gt $((ish_batch + 2)) ]; then
        local expr=$2
        shift 2
        printf '%s\0' "$@" | xargs -0 -n $ish_batch sed -i "$expr"
        return
    else
        command sed "$@"
    fi
}

cp() {
    local opts=() err status rest
    while [ $# -gt 0 ] && [ "${1#-}" != "$1" ]; do
        opts+=("$1")
        shift
    done
    # "|| status=$?" keeps a failed copy from tripping the callers' `set -e` before the
    # case-collision errors are filtered out.
    status=0
    if [ $# -gt $((ish_batch + 1)) ]; then
        local dest=${!#}
        set -- "${@:1:$#-1}"
        err=$(printf '%s\0' "$@" | xargs -0 -n $ish_batch \
            sh -c 'dest=$1; shift; exec cp "$@" "$dest"' sh "$dest" "${opts[@]}" 2>&1 >/dev/null) || status=$?
    else
        err=$(command cp "${opts[@]}" "$@" 2>&1 >/dev/null) || status=$?
    fi
    [ $status -eq 0 ] && return 0
    rest=$(printf '%s\n' "$err" | grep -v -e "can't create symlink .*File exists" \
        -e "cannot create symbolic link .*File exists" -e '^$') || true
    if [ -z "$rest" ]; then
        return 0
    fi
    printf '%s\n' "$rest" >&2
    return $status
}

ish_relpath() { # target-abs from-dir-abs -> target relative to from-dir
    local -a t f
    IFS=/ read -r -a t <<< "${1#/}"
    IFS=/ read -r -a f <<< "${2#/}"
    local i=0 out=
    while [ $i -lt ${#t[@]} ] && [ $i -lt ${#f[@]} ] && [ "${t[$i]}" = "${f[$i]}" ]; do
        i=$((i + 1))
    done
    local j
    for ((j = i; j < ${#f[@]}; j++)); do out+="../"; done
    for ((j = i; j < ${#t[@]}; j++)); do out+="${t[$j]}/"; done
    out=${out%/}
    printf '%s\n' "${out:-.}"
}

ln() {
    local args=() a relative=
    for a in "$@"; do
        case $a in
        -[a-zA-Z]*r*)
            relative=1
            a=${a//r/}
            [ "$a" = - ] || args+=("$a") ;;
        *) args+=("$a") ;;
        esac
    done
    if [ -n "$relative" ] && [ ${#args[@]} -ge 2 ]; then
        local n=${#args[@]}
        local target=${args[$((n - 2))]} link=${args[$((n - 1))]}
        case $target in /*) ;; *) target=$PWD/$target ;; esac
        case $link in /*) ;; *) link=$PWD/$link ;; esac
        args[$((n - 2))]=$(ish_relpath "$target" "$(dirname "$link")")
    fi
    command ln "${args[@]}"
}
