# Regression test for the source API in .common-repo.yaml: applies this
# checkout as a local-path upstream into throwaway consumers and checks
# what lands. `common-repo validate` and `diff` only exercise the `self:`
# block, so nothing else covers this. Not distributed: consumers inherit
# src/ only.
20-source-api() {
  command -v common-repo >/dev/null 2>&1 || return $(fail "common-repo is not installed")

  local tmp failures=0 stub
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/stra-source-api.XXXXXX")"

  # consumer <name> — new repo consuming this checkout
  consumer() {
    C="$tmp/$1"
    mkdir -p "$C"
    git -C "$C" init -q
    printf -- '- repo:\n    url: %s\n    ref: main\n' "$REPO_ROOT" >"$C/.common-repo.yaml"
  }
  apply() {
    (cd "$C" && common-repo --quiet apply) || { not_ok "common-repo apply failed in ${C##*/}"; return 0; }
  }
  not_ok() {
    failures=$((failures + 1))
    error "not ok: $*"
  }
  # Everything this upstream should write, and nothing else.
  check_layout() {
    for stub in .harness bootstrap setup update test cibuild server console; do
      [ -x "$C/script/$stub" ] || not_ok "${C##*/}: script/$stub missing or not executable"
    done
    [ ! -e "$C/src" ] || not_ok "${C##*/}: src/ leaked into the consumer (issue #3)"
    local extra
    extra="$(cd "$C" && find . -path ./.git -prune -o -type f -print | sort |
      grep -v -x -e ./.common-repo.yaml -e './script/[a-z]*' -e ./script/.harness || true)"
    [ -z "$extra" ] || not_ok "${C##*/}: unexpected files: ${extra//$'\n'/ }"
  }

  # A fresh consumer gets the harness and the seven stubs.
  consumer fresh
  apply
  check_layout
  cmp -s "$C/script/test" "$REPO_ROOT/src/script/test" || not_ok "fresh: script/test is not the stub"

  # A consumer's own scripts survive (issue #3); the harness is overwritten.
  consumer bespoke
  mkdir -p "$C/script"
  printf '#!/bin/sh\necho bespoke\n' >"$C/script/test"
  printf '#!/bin/sh\necho stale\n' >"$C/script/.harness"
  chmod +x "$C/script/test" "$C/script/.harness"
  apply
  check_layout
  [ "$("$C/script/test" 2>&1)" = bespoke ] || not_ok "bespoke: script/test was not preserved (issue #3)"
  cmp -s "$C/script/.harness" "$REPO_ROOT/src/script/.harness" || not_ok "bespoke: script/.harness was not overwritten"

  # Applying again changes nothing.
  apply
  check_layout
  [ "$("$C/script/test" 2>&1)" = bespoke ] || not_ok "bespoke: script/test was not preserved on re-apply"

  rm -rf "$tmp"
  [ "$failures" -eq 0 ] || return $(fail "$failures source API check(s) failed")
}
