#!/usr/bin/env bash
# Shell syntax + shellcheck, and a parse check on every Nix file.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
# shellcheck source=assert.sh
source "$HERE/assert.sh"
cd "$ROOT" || exit 1

SCRIPTS=(install-me.sh replace-boot-disk.sh add-data-pool.sh lib/common.sh
         tests/lint.sh tests/lib-unit.sh tests/disk-integration.sh
         tests/nix-eval.sh tests/run-all.sh tests/assert.sh)

section "bash -n"
for f in "${SCRIPTS[@]}"; do
    if bash -n "$f" 2>/dev/null; then _pass "$f"; else _fail "$f" "$(bash -n "$f" 2>&1)"; fi
done

section "shellcheck"
if command -v shellcheck >/dev/null; then
    for f in "${SCRIPTS[@]}"; do
        if out=$(shellcheck --severity=style -x -P "$ROOT:$ROOT/lib:$ROOT/tests" "$f" 2>&1); then
            _pass "$f"
        else
            _fail "$f" "$out"
        fi
    done
else
    skip "shellcheck" "not installed"
fi

section "nix parse"
if command -v nix-instantiate >/dev/null; then
    for f in ./*.nix tests/fixtures/*.nix; do
        if out=$(nix-instantiate --parse "$f" 2>&1 >/dev/null); then _pass "$f"
        else _fail "$f" "$out"; fi
    done
else
    skip "nix parse" "nix-instantiate not installed"
fi

section "repo hygiene"
# the scripts that run on an already-installed (possibly offline) machine must
# not depend on nix-shell fetching anything
for f in replace-boot-disk.sh add-data-pool.sh; do
    if head -1 "$f" | grep -q 'nix-shell'; then
        _fail "$f runs without nix-shell" "shebang is nix-shell; a degraded box may have no network"
    else
        _pass "$f runs without nix-shell"
    fi
done
if head -1 install-me.sh | grep -q 'env nix-shell'; then
    _pass "install-me.sh uses the nix-shell shebang (it always runs from an ISO)"
else
    _fail "install-me.sh uses the nix-shell shebang" "got: $(head -1 install-me.sh)"
fi
# disk-layout.nix must stay generic: no machine-specific disk ids in tracked Nix
hits=$(grep -n "/dev/disk/by-id/" ./*.nix 2>/dev/null | grep -v ':[[:space:]]*#' || true)
if [[ -n $hits ]]; then
    _fail "no disk ids hardcoded in Nix" "$(head -3 <<<"$hits")"
else
    _pass "no disk ids hardcoded in Nix (outside comments)"
fi

summary "lint"
