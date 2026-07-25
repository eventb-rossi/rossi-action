# Rossi Event-B Validator — GitHub Action

Check Event-B models in CI with [rossi](https://github.com/eventb-rossi/rossi):
install a verified binary, run `validate` / `fmt --check` / `build` over your
models, annotate every finding inline, and optionally upload one SARIF run to
code scanning.

```yaml
- uses: eventb-rossi/rossi-action@v1
  with:
    path: models/
```

That installs the latest rossi release, validates `models/`, annotates each
finding on the offending line, and fails the step on any error.

## Usage

### Gate on advisory lints too

The advisory lints (`EB011` dead variable, `EB012` unmodified variable,
`EB014` incomplete initialisation, `EB023` shadowed name) are warnings and do
not fail a run by default:

```yaml
- uses: eventb-rossi/rossi-action@v1
  with:
    path: models/
    deny-warnings: "true"
```

### Upload findings to code scanning

```yaml
permissions:
  contents: read
  security-events: write

steps:
  - uses: actions/checkout@v7
  - uses: eventb-rossi/rossi-action@v1
    with:
      path: models/
      sarif: "true"
      upload-sarif: "true"
      category: rossi
```

rossi emits **exactly one SARIF run** however many files, directories and
archives it is given, which is what
[code scanning requires][sarif-runs] — an upload whose runs share a category is
rejected. If you upload more than one analysis from the same repository, give
each its own `category`.

`sarif` is produced by the validate pass, so `commands` must include `validate`.
Asking for a report without it is an error rather than a silently empty
Security tab.

The upload is skipped for pull requests **from** a fork, which cannot be granted
`security-events: write`; findings still appear as annotations there.

### Check formatting and the static build as well

```yaml
- uses: eventb-rossi/rossi-action@v1
  with:
    path: models/
    commands: validate,fmt-check,build
```

`build`'s unit is a **project**: point it at a project directory or a `.zip`,
not at a glob of components, or every cross-component reference dangles. The
action refuses that split rather than report a correct model as broken.

For a project directory or a `.zip`, `validate` already runs the same semantic
checks as `build`, and reports them with a rule id and a position where `build`
prints plain text — so adding `build` there mostly buys a second pass over the
same models. `build` earns its place for a **loose** `.eventb` file: `validate`
has no project to resolve it against and skips those checks, so an unresolved
`SEES` is reported by `build` alone.

### Collect findings without failing the job

```yaml
- uses: eventb-rossi/rossi-action@v1
  id: rossi
  with:
    path: models/
    fail-on-error: "false"
- run: echo "${{ steps.rossi.outputs.error-count }} errors"
```

## Inputs

| Input | Default | Description |
|---|---|---|
| `path` | `.` | Models to check: files, unzipped project directories, or Rodin `.zip` archives. Space-separated; globs are expanded. |
| `version` | latest | rossi version to install, without the leading `v`. |
| `rossi-path` | – | Use an existing binary instead of downloading one. A relative path is resolved against the workspace root, so it keeps working with `working-directory`. |
| `commands` | `validate` | Comma-separated: `validate`, `fmt-check`, `build`. `build` wants a project root. |
| `deny-warnings` | `false` | Fail on advisory lints as well as errors. |
| `annotations` | `true` | Emit inline `::error` / `::warning` annotations. |
| `sarif` | `false` | Write a SARIF report. Requires `validate` in `commands`. |
| `sarif-file` | `rossi.sarif` | Where to write it. |
| `category` | `rossi` | Analysis category for the SARIF run. |
| `upload-sarif` | `false` | Upload the report to code scanning. |
| `working-directory` | `.` | Directory to run rossi in; `path` is relative to it. |
| `fail-on-error` | `true` | Fail the step on findings, including "no Event-B components found under `path`". |

## Outputs

| Output | Description |
|---|---|
| `valid` | `"true"` when rossi reported no failures. |
| `error-count` | Number of error-severity findings. |
| `warning-count` | Number of advisory findings. |
| `sarif-file` | Path to the SARIF report, empty when `sarif` was off. |
| `rossi-version` | The rossi version that ran. |

## How the version is chosen

The action installs the latest rossi release, verified against that release's
`SHA256SUMS`; a release with no checksum manifest is refused rather than
installed unverified. Set `version:` to install an exact one instead.

## Requirements

`bash`, `curl` and `jq` — all present on GitHub-hosted runners for Linux, macOS
and Windows. Prebuilt binaries exist for x86-64 and arm64 on all three.

## Licence

Dual-licensed under [Apache 2.0](LICENSE-APACHE) and [MIT](LICENSE-MIT), the
same as rossi.

[sarif-runs]: https://github.blog/changelog/2025-07-21-code-scanning-will-stop-combining-multiple-sarif-runs-uploaded-in-the-same-sarif-file/
