# scripts-to-rule-them-all

A [common-repo](https://github.com/common-repo/common-repo) upstream that
distributes a **pluggable** implementation of the
[Scripts to Rule Them All](https://github.com/github/scripts-to-rule-them-all)
pattern: normalized `script/*` entry points for every project.

Instead of shipping bespoke scripts, this upstream ships a **harness** and
seven **thin stubs**. The stubs discover and run *drop-ins* — small shell
functions contributed by other upstreams or the consumer — from hidden
per-phase directories:

```
script/
  bootstrap            # thin stub → runs script/.bootstrap/*.sh in order
  setup                # chains bootstrap, then runs script/.setup/*.sh
  update               # chains bootstrap, then runs script/.update/*.sh
  test                 # runs script/.test/*.sh
  cibuild              # runs script/.cibuild/*.sh, then script/test
  server               # runs exactly one provider from script/.server/
  console              # runs exactly one provider from script/.console/
  .harness             # the runner (machinery — do not edit)
  .bootstrap/…         # drop-in directories (hidden from script/* globs)
  .test/…
  …
```

Other upstreams composite their own drop-ins into these directories via
common-repo, and consumers can `exclude: script/**` wholesale if they don't
follow the pattern. Drop-in directories that don't exist are treated as
empty.

## Usage

Requires [common-repo](https://github.com/common-repo/common-repo) ≥ 0.37.0
(additive `include:` is needed for this upstream's source API).

Add to `.common-repo.yaml`:

```yaml
- repo:
    url: https://github.com/common-repo/scripts-to-rule-them-all
    ref: v0.1.0
```

Then `cr diff` to preview and `cr apply` to write.

The stubs are re-included with `if-exists: preserve`: a consumer with a
bespoke `script/test` (or any other stub name) keeps it across
re-propagations. `script/.harness` is machinery and always overwrites.
Partial adoption works — exclude individual stubs, or all of `script/**`.

## Writing a drop-in

A drop-in is a file `script/.<phase>/<NN>-<name>.sh` defining **one function
named exactly after its stem**:

```bash
# script/.test/30-lint.sh
30-lint() {
  info "linting"
  prek run --files
}
```

Rules:

- **`NN-` prefix, zero-padded two digits.** Drop-ins run in sorted order
  (`LC_ALL=C` byte order). The name after the prefix is yours; common-repo
  `rename:` ops can manage collisions between upstreams.
- **Top level defines the function and nothing else.** The harness
  syntax-checks and sources all selected drop-ins *before* running any —
  a file that does work at source time breaks that guarantee.
- **Fail fast.** Drop-ins run under `set -e` / `pipefail`: an unhandled
  failing command aborts the drop-in with that status. Handle errors you
  expect with `if`, `||`, etc.
- **No `exit`.** `return` only — `exit` is the harness's business.
- **Exports are the sharing channel.** Variables exported by one drop-in
  are visible to later drop-ins in the same phase. Non-exported and unset
  variables do not propagate. Env does not cross phase boundaries — chained
  phases are separate `script/` invocations; use files for cross-phase
  state.
- **Use `local`** inside the function for internal variables.
- **Don't rely on the working directory.** Drop-ins start at the repo root.
- **Tolerate unknown arguments.** Everything after the harness flags is
  passed through to every drop-in invoked.

### Severity and outcomes

| Phase | Default severity |
|---|---|
| `bootstrap`, `setup`, `update` | hard — first failure stops the phase |
| `test`, `cibuild` | soft — failures are recorded, all drop-ins run, exit is nonzero at the end |
| `server`, `console` | hard |

A *hard* failure aborts the remaining drop-ins immediately; a *soft*
failure continues. Override the default per drop-in with a header:

```bash
# severity: hard
```

For runtime control, use the outcome functions — **explicit outcomes
override the declared severity**:

```bash
30-integration() {
  curl -sf localhost:8080/health >/dev/null || return $(fail "service not up")
  [ -n "${SMOKE:-}" ] || return $(skip "smoke not requested")
}
```

Outcome functions print the message to stderr and the reserved code to
stdout, which is why they are used as `return $(fail "…")`. Reserved codes:
`pass` 0, `fail` 70, `soft_fail` 75, `skip` 77.

### The stdlib

Available inside every drop-in (append-only across versions; additions are
minor releases, removals/renames are majors):

| Function | Purpose |
|---|---|
| `info`, `warn`, `error` | log to stderr, prefixed with phase and stem |
| `debug` | log to stderr only when `DEBUG=1` |
| `pass`, `fail`, `soft_fail`, `skip` | outcome functions (see above) |

Drop-in file names must not shadow stdlib function names (no
`.test/info.sh` defining `info()`); stems are function names, and sourcing
is ordered.

Ambient context: `$HARNESS_PHASE` names the running phase; `$REPO_ROOT` is
the repository root; harness logging goes to stderr, so **stdout belongs to
drop-ins**.

## CLI

```
script/<phase> [--only <pattern>[,<pattern>...]] [--list] [--] [args...]
```

- `--only` filters drop-ins. A pattern matches a stem exactly, either fully
  qualified (`30-lint`) or by its suffix without the `NN-` prefix (`lint`).
  Comma-separated or repeated. All matches run — it is a filter, not a
  selector — and **zero matches is an error**. Note that every *discovered*
  drop-in must still pass the syntax check: a broken drop-in blocks even
  filtered runs until it is fixed or removed.
- `--list` prints the discovered drop-ins and their resolved severity
  without running anything.
- Everything else passes through to each drop-in invoked.

`setup`/`update` forward their arguments to the `script/bootstrap` they
chain; `cibuild` forwards to `script/test`.

## Server and console

Provider slots, not run-alls: exactly one drop-in may run. Zero drop-ins
fails loudly (a platform upstream should provide one — e.g. a Go upstream
shipping `script/.server/00-golang-serve` that runs `cmd/serve`); more than
one match fails loudly listing the candidates — disambiguate with `--only`.

## Empty phases

`bootstrap`, `setup`, `update`, `test`, and `cibuild` treat an empty
drop-in directory as a silent no-op — adopting this upstream never breaks a
repo that has no tests yet. `server` and `console` fail loudly because a
human invoking them wants a thing to happen.

## Requirements and notes

- Bash ≥ 3.2 (stock macOS) through 5.x (Linux CI). Drop-ins may rely on the
  stdlib, `set -e` fail-fast semantics, and bash function names containing
  dashes (e.g. `30-lint()`).
- The harness sets `LC_ALL=C` internally for deterministic ordering but does
  not export it — drop-in child processes run in the user's locale.
- Env values containing newlines do not propagate between drop-ins on
  bash 3.2 (an `export -p` round-trip limitation).
- Exit status: 0 when everything passed or skipped, 1 on any failure,
  2 on usage/configuration errors.
- This upstream is standalone: consume it directly; it composes no other
  upstreams. `upstream`, `semantic-release`, `conventional-commits`, and
  `pre-commit` are expected to adopt it in their `self:` blocks over time.

## License

[MIT](LICENSE)
