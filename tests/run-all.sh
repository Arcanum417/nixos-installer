#!/usr/bin/env bash
# Runs every suite that can run in this environment.
# A suite that exits 77 is reported as skipped, not failed.

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0; RAN=0; SKIPPED=0

run () {
    local name=$1; shift
    printf '\n\033[1m########## %s ##########\033[0m\n' "$name"
    "$@"
    local rc=$?
    case $rc in
        0)  RAN=$((RAN+1)) ;;
        77) SKIPPED=$((SKIPPED+1)); printf '\033[33m>> %s skipped\033[0m\n' "$name" ;;
        *)  FAILED=$((FAILED+1));   printf '\033[31m>> %s FAILED\033[0m\n' "$name" ;;
    esac
}

run lint             bash "$HERE/lint.sh"
run lib-unit         bash "$HERE/lib-unit.sh"
run nix-eval         bash "$HERE/nix-eval.sh"
if [[ $EUID -eq 0 ]]; then
    run disk-integration bash "$HERE/disk-integration.sh"
else
    SKIPPED=$((SKIPPED+1))
    printf '\n\033[33m>> disk-integration skipped (needs root)\033[0m\n'
fi

# tests/vm-boot.sh is macOS + UTM only and takes hours: the guest is x86_64 on
# what is almost certainly an arm64 host, so QEMU runs in TCG emulation. It is
# a deliberate release gate, not part of a routine run, so it is opt-in even on
# a machine that could run it. See tests/vm/README.md.
if [[ ${VM_TESTS-0} == 1 ]]; then
    run vm-boot      bash "$HERE/vm-boot.sh"
else
    SKIPPED=$((SKIPPED+1))
    printf '\n\033[33m>> vm-boot skipped (set VM_TESTS=1; needs macOS + UTM, takes hours)\033[0m\n'
fi

printf '\n\033[1m==========================================\033[0m\n'
printf 'suites: %d passed, %d failed, %d skipped\n' "$RAN" "$FAILED" "$SKIPPED"
[[ $FAILED -eq 0 ]]
