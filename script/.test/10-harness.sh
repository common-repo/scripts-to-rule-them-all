# Regression tests for the harness itself. Each case builds a throwaway
# script/ tree from src/script, adds fixture drop-ins, and checks the exit
# status and output of a stub. Not distributed: consumers inherit src/ only.
10-harness() {
  local tmp failures=0 out rc
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/stra-harness.XXXXXX")"

  # fixture <case> — fresh copy of the distributed scripts at $tmp/<case>
  fixture() {
    mkdir -p "$tmp/$1"
    cp -R "$REPO_ROOT/src/script" "$tmp/$1/script"
    S="$tmp/$1/script"
  }
  # dropin <phase> <stem> <body> — add a fixture drop-in
  dropin() {
    mkdir -p "$S/.$1"
    printf '%s() { %s; }\n' "$2" "$3" >"$S/.$1/$2.sh"
  }
  # run <stub> [args...] — capture combined output and exit status
  run() {
    local stub="$1"
    shift
    rc=0
    out="$(env -u DEBUG "$S/$stub" "$@" 2>&1)" || rc=$?
  }
  check() {
    local name="$1" want_rc="$2"
    shift 2
    local ok=1 arg
    [ "$rc" -eq "$want_rc" ] || ok=0
    for arg in "$@"; do
      case "$arg" in
        !*) case "$out" in *"${arg#!}"*) ok=0 ;; esac ;;
        *)  case "$out" in *"$arg"*) ;; *) ok=0 ;; esac ;;
      esac
    done
    if [ "$ok" -eq 1 ]; then
      debug "ok: $name"
    else
      failures=$((failures + 1))
      error "not ok: $name (exit $rc, wanted $want_rc)"
      printf '%s\n' "$out" | sed 's/^/    | /' >&2
    fi
  }

  # -- empty phases ---------------------------------------------------------
  fixture empty
  run test;      check "empty test is a silent no-op" 0
  [ -z "$out" ] || { failures=$((failures + 1)); error "not ok: empty test printed output"; }
  run cibuild;   check "empty cibuild and empty test is a silent no-op" 0
  [ -z "$out" ] || { failures=$((failures + 1)); error "not ok: empty cibuild printed output"; }
  run server;    check "empty provider phase fails" 1 "no server drop-in"
  run test --only nope; check "--only with no match is a usage error" 2
  run test --only '';  check "--only with an empty pattern is a usage error" 2 "non-empty pattern"
  run test --only=;    check "--only= with an empty pattern is a usage error" 2 "non-empty pattern"
  run test --only ,;   check "--only with only commas is a usage error" 2 "non-empty pattern"

  # -- cibuild chains to test (issue #4) ------------------------------------
  fixture chain
  dropin test 10-ok 'info "ok ran $*"'
  run cibuild a b
  check "empty cibuild runs test and forwards args" 0 "ok ran a b"
  dropin test 20-bad 'false'
  run cibuild
  check "empty cibuild fails when a test drop-in fails" 1 "ok ran" "FAIL   20-bad"
  dropin cibuild 10-build 'info "build ran"'
  run cibuild
  check "populated cibuild still runs test" 1 "build ran" "ok ran" "FAIL   20-bad"

  # -- cibuild --only filters across both phases ----------------------------
  fixture only
  dropin test 10-ok 'info "ok ran"'
  run cibuild --only ok
  check "--only reaches test when cibuild is empty" 0 "ok ran"
  dropin cibuild 10-build 'info "build ran"'
  run cibuild --only ok
  check "--only matching only test skips cibuild drop-ins" 0 "ok ran" "!build ran"
  run cibuild --only build
  check "--only matching only cibuild skips test" 0 "build ran" "!ok ran"
  run cibuild --only build,ok
  check "--only matching both runs both" 0 "build ran" "ok ran"
  run cibuild --only nope
  check "--only matching neither is a usage error" 2 "script/.cibuild/ or script/.test/" "!ran"
  run cibuild --list --only ok
  check "cibuild --list shows the test drop-ins it chains" 0 "10-ok" "!10-build" "!ran"
  run cibuild --list
  check "cibuild --list shows both phases" 0 "10-build" "10-ok" "!ran"
  run cibuild --list --only build
  check "cibuild --list skips test when --only matches no test drop-in" 0 "10-build" "!10-ok"

  # -- setup/update chain to bootstrap --------------------------------------
  fixture bootstrap
  # shellcheck disable=SC2016  # expands in the drop-in
  dropin bootstrap 10-deps 'info "deps ran $*"'
  run setup;  check "empty setup still bootstraps" 0 "deps ran"
  run update; check "empty update still bootstraps" 0 "deps ran"
  dropin setup 20-foo 'info "foo ran"'
  run setup --only foo
  check "setup --only runs a full bootstrap, then the match" 0 "deps ran" "foo ran"
  run setup --only foo -- extra
  check "setup passes passthrough args to bootstrap" 0 "deps ran extra" "foo ran"
  run setup --only nope
  check "setup --only with no match fails before bootstrap" 2 "!deps ran"

  # -- --list honours --only ---------------------------------------------------
  fixture list
  dropin test 10-ok ':'
  dropin test 20-lint ':'
  run test --list --only lint
  check "--list shows only --only matches" 0 "20-lint" "!10-ok"
  run test --list --only nope
  check "--list with no match is a usage error" 2 "matched no drop-ins" "!20-lint  "
  dropin cibuild 10-build ':'
  run cibuild --list --only ok
  check "cibuild --list accepts a match in script/.test/ only" 0 "!10-build"

  # -- drop-in exports cannot change harness state -------------------------------
  fixture state
  dropin test 10-bad 'false'
  dropin test 20-clobber 'export FAILED=0 phase=bogus stem=bogus SHARED=yes'
  # shellcheck disable=SC2016  # expands in the drop-in
  dropin test 30-after 'info "after saw SHARED=$SHARED"'
  run test
  check "exported harness variables are not re-imported" 1 \
    "after saw SHARED=yes" "FAIL   10-bad" "pass   20-clobber" "!bogus"

  # -- severity -------------------------------------------------------------
  fixture severity
  dropin test 10-bad 'false'
  dropin test 20-after 'info "after ran"'
  run test; check "soft failure continues, exits 1" 1 "after ran"
  dropin bootstrap 10-bad 'false'
  dropin bootstrap 20-after 'info "after ran"'
  run bootstrap; check "hard failure stops the phase" 1 "!after ran"

  # -- required tools -------------------------------------------------------
  fixture requires
  dropin test 10-ok ':'
  {
    echo '# requires: sh stra-missing-tool'
    echo '20-lint() { info "lint ran"; }'
  } >"$S/.test/20-lint.sh"
  run test
  check "a missing required tool skips the drop-in" 0 \
    "skip   20-lint" "requires stra-missing-tool" "!lint ran"
  run test --only lint
  check "--only fails a drop-in whose tool is missing" 1 \
    "FAIL   20-lint" "requires stra-missing-tool" "!lint ran"
  run test --list --only lint
  check "--list does not check required tools" 0 "20-lint" "!stra-missing-tool"
  echo '# requires: sh' >"$S/.test/20-lint.sh"
  echo '20-lint() { info "lint ran"; }' >>"$S/.test/20-lint.sh"
  run test --only lint
  check "a drop-in runs when its tools are on PATH" 0 "lint ran"

  rm -rf "$tmp"
  [ "$failures" -eq 0 ] || return $(fail "$failures harness regression check(s) failed")
}
