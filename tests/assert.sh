# shellcheck shell=bash
# Minimal assertion helpers. Sourced by the test scripts.

TESTS=0; FAILED=0; SKIPPED=0
_c_g="\033[32m"; _c_r="\033[31m"; _c_y="\033[33m"; _c_b="\033[1m"; _c_0="\033[0m"

section () { printf "\n${_c_b}%s${_c_0}\n" "$1"; }
_pass ()  { TESTS=$((TESTS+1)); printf "  ${_c_g}ok${_c_0}   %s\n" "$1"; }
_fail ()  { TESTS=$((TESTS+1)); FAILED=$((FAILED+1)); printf "  ${_c_r}FAIL${_c_0} %s\n       %s\n" "$1" "$2"; }
skip ()   { SKIPPED=$((SKIPPED+1)); printf "  ${_c_y}skip${_c_0} %s (%s)\n" "$1" "$2"; }

eq ()       { if [ "$2" = "$3" ];  then _pass "$1"; else _fail "$1" "got [$2] want [$3]"; fi; }
ne ()       { if [ "$2" != "$3" ]; then _pass "$1"; else _fail "$1" "both are [$2]"; fi; }
contains () { case "$2" in *"$3"*) _pass "$1" ;; *) _fail "$1" "[$2] lacks [$3]" ;; esac; }
lacks ()    { case "$2" in *"$3"*) _fail "$1" "[$2] contains [$3]" ;; *) _pass "$1" ;; esac; }
between ()  { # between NAME VALUE LO HI
    if [ "$2" -ge "$3" ] && [ "$2" -le "$4" ]; then _pass "$1"
    else _fail "$1" "$2 not in [$3..$4]"; fi; }

# Run a command that is expected to abort (calls die / returns non-zero).
expect_fail () {
    local name=$1; shift
    local out
    if out=$( set +e; trap - ERR; "$@" 2>&1 ); then
        _fail "$name" "expected failure, succeeded with: $out"
    else
        _pass "$name"
    fi
}

expect_ok () {
    local name=$1; shift
    local out
    if out=$( set +e; trap - ERR; "$@" 2>&1 ); then _pass "$name"
    else _fail "$name" "expected success, failed with: $out"; fi
}

summary () {
    printf "\n${_c_b}%s${_c_0}: %d checks, %d failed, %d skipped\n" "${1:-tests}" "$TESTS" "$FAILED" "$SKIPPED"
    [ "$FAILED" -eq 0 ]
}
