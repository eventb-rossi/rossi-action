#!/usr/bin/env bash
#
# Run the requested rossi subcommands over the model paths and turn the JSON
# report into GitHub annotations, counts, and (optionally) a SARIF file.
#
# This script never exits nonzero on *findings* — it records them in its
# outputs so the SARIF upload step still runs, and lets the action's last step
# decide whether the job fails. It does exit nonzero when rossi itself could
# not be run.
#
# Inputs (environment):
#   ROSSI                binary to run (default `rossi`)
#   ROSSI_PATHS          space-separated paths/globs
#   ROSSI_COMMANDS       comma-separated: validate, fmt-check, build
#   ROSSI_DENY_WARNINGS  "true" to gate on advisory lints
#   ROSSI_ANNOTATIONS    "true" to emit ::error / ::warning lines
#   ROSSI_SARIF          "true" to write a SARIF report
#   ROSSI_SARIF_FILE     where to write it
#   ROSSI_CATEGORY       SARIF analysis category
set -euo pipefail

rossi="${ROSSI:-rossi}"
commands="${ROSSI_COMMANDS:-validate}"
sarif_out=""
errors=0
warnings=0
valid="true"

fail() { valid="false"; }

# fmt-check, build and "no components" are failures rossi did not itemise, so
# they have to be counted here or they publish error-count=0 beside valid=false.
count_failure() { errors=$((errors + 1)); fail; }

# Delimited form: a newline in a value would otherwise append further outputs,
# and a planted `valid=true` would override the gate.
delimiter="ROSSI_OUTPUT_${RANDOM}${RANDOM}${RANDOM}"
emit() { printf '%s<<%s\n%s\n%s\n' "$1" "$delimiter" "$2" "$delimiter"; }

# A relative `rossi-path` is relative to the workspace, but this script runs in
# `working-directory`. Fall back to the workspace before giving up.
case "$rossi" in
  */*)
    if [ ! -x "$rossi" ] && [ -n "${GITHUB_WORKSPACE:-}" ] && [ -x "${GITHUB_WORKSPACE}/${rossi}" ]; then
      rossi="${GITHUB_WORKSPACE}/${rossi}"
    fi
    ;;
esac

command -v "$rossi" >/dev/null 2>&1 || [ -x "$rossi" ] || {
  echo "::error::rossi not found at '${rossi}'" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "::error::jq is required to read rossi's report" >&2
  exit 1
}

# SARIF comes out of the validate pass, so asking for one without it would
# quietly produce nothing and leave the Security tab empty. Say so instead.
case ",$(printf '%s' "$commands" | tr -d '[:space:]')," in
  *,validate,*) ;;
  *)
    if [ "${ROSSI_SARIF:-false}" = "true" ]; then
      echo "::error::sarif: true needs 'validate' in commands (got: ${commands})" >&2
      exit 1
    fi
    ;;
esac

# Word splitting and globbing are the point here: `path` is a user-supplied
# list that may contain patterns.
# shellcheck disable=SC2206
paths=(${ROSSI_PATHS:-.})
if [ "${#paths[@]}" -eq 0 ]; then
  echo "::error::no models matched '${ROSSI_PATHS:-}'" >&2
  exit 1
fi
# A path that does not exist is left to rossi, which reports it as an error row
# — so it reaches the counts, the annotations and `fail-on-error` alike.

report="$(mktemp)"
trap 'rm -f "$report"' EXIT

# GitHub resolves annotation paths and SARIF URIs against the workspace root,
# but rossi reports them relative to the directory it ran in. Anything under
# `working-directory` therefore has to be re-anchored, or every finding points
# at a path that does not exist in the repository tree. Compare through `pwd`:
# on Windows `$GITHUB_WORKSPACE` is a `D:\` path and `$PWD` is not.
prefix=""
if [ -n "${GITHUB_WORKSPACE:-}" ]; then
  workspace="$(cd "$GITHUB_WORKSPACE" 2>/dev/null && pwd)" || workspace=""
  here="$(pwd)"
  if [ -n "$workspace" ] && [ "$here" != "$workspace" ]; then
    case "$here" in
      "$workspace"/*) prefix="${here#"$workspace"/}/" ;;
    esac
  fi
fi

# Turn one JSON report into annotations. `input` says how `file` and
# `inner_filename` join: a directory member is a real path GitHub can anchor
# to, an archive member is not, so the archive itself is annotated instead.
# An absolute path is already unambiguous and is left alone. A property value
# ends at the next `,` and its name at the next `:` — both legal in a path.
annotate() {
  jq -r --arg prefix "$prefix" '
    def loc:
      (if .inner_filename == null then .file
       elif .input == "archive" then .file
       else (.file | sub("/+$"; "")) + "/" + .inner_filename
       end)
      | if startswith("/") then . else $prefix + . end;
    def escdata: gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
    def escprop: escdata | gsub(":"; "%3A") | gsub(","; "%2C");
    .[]
    | select(.error != null)
    | (if .severity == "error" then "error"
       elif .severity == "warning" then "warning"
       else "notice" end) as $level
    | (if .region != null then
         ",line=\(.region.start_line),col=\(.region.start_column)" +
         ",endLine=\(.region.end_line),endColumn=\(.region.end_column)"
       else "" end) as $pos
    | "::\($level) file=\(loc | escprop)\($pos),title=rossi \(.rule_id // "" | escprop)::\(.error | escdata)"
  ' "$1"
}

run_validate() {
  local args=("validate" "--format" "json" "--output" "$report")
  [ "${ROSSI_DENY_WARNINGS:-false}" = "true" ] && args+=("--deny-warnings")
  "$rossi" "${args[@]}" "${paths[@]}" || fail

  # rossi exits nonzero on findings, which is expected; a missing or empty
  # report is not, and reading counts out of one would publish empty outputs
  # that break every consumer downstream.
  if [ ! -s "$report" ]; then
    echo "::error::rossi wrote no report" >&2
    exit 1
  fi

  if [ "${ROSSI_ANNOTATIONS:-true}" = "true" ]; then
    annotate "$report"
  fi
  # One pass for all three numbers: the report can run to thousands of rows and
  # re-parsing it per counter is the bulk of the cost.
  local n_errors n_warnings n_rows
  read -r n_errors n_warnings n_rows <<<"$(jq -r '
    [ ([.[] | select(.severity == "error")] | length),
      ([.[] | select(.severity == "warning" or .severity == "info")] | length),
      length ] | @tsv' "$report")"
  errors=$((errors + n_errors))
  warnings=$((warnings + n_warnings))

  # `rossi validate <dir>` is not recursive, so a `path` that holds no
  # components at all reports nothing and exits 0. Passing a job green without
  # having checked a single model is the worst outcome this action has. It is a
  # finding, not a failure to run, so `fail-on-error` gets to decide.
  if [ "$n_rows" -eq 0 ]; then
    echo "::error::no Event-B components found in: ${paths[*]}" >&2
    echo "::error::point 'path' at the directory holding your models" >&2
    count_failure
  fi

  if [ "${ROSSI_SARIF:-false}" = "true" ]; then
    local candidate status=0
    candidate="${ROSSI_SARIF_FILE:-rossi.sarif}"
    # `sarif-file` may name a directory that does not exist yet; rossi would
    # fail to open it and exit 1, indistinguishable from "there were findings".
    mkdir -p "$(dirname "$candidate")"
    # One run for every input, whatever the mix — code scanning rejects an
    # upload whose runs share a category, so this must stay a single call.
    "$rossi" validate --format sarif \
      --sarif-category "${ROSSI_CATEGORY:-rossi}" \
      --output "$candidate" "${paths[@]}" || status=$?
    # Exit 1 is "there were findings"; anything above it is rossi refusing to
    # run. Advertising a SARIF file that was never written would send the
    # upload step off to fail on a missing path instead of publishing them.
    # The re-anchoring pass doubles as the validity check — jq fails on a
    # missing or malformed document, and with no prefix it is the identity.
    if [ "$status" -ge 2 ] || ! jq --arg prefix "$prefix" '
          (.runs[]?.results[]?.locations[]?.physicalLocation.artifactLocation.uri)
            |= (if startswith("/") then . else $prefix + . end)
        ' "$candidate" > "${candidate}.tmp" 2>/dev/null; then
      echo "::error::rossi produced no usable SARIF report at ${candidate}" >&2
      rm -f "${candidate}.tmp"
      count_failure
    else
      mv "${candidate}.tmp" "$candidate"
      sarif_out="$candidate"
    fi
  fi
}

run_fmt_check() {
  # rossi prints what went wrong itself — a parse failure names the file and the
  # position — so the annotation stays neutral between "would reformat" and
  # "could not parse" instead of guessing from the message text.
  if ! "$rossi" fmt --check "${paths[@]}"; then
    echo "::error title=rossi fmt::rossi fmt --check failed; fix any parse errors above, then run 'rossi fmt --in-place'"
    count_failure
  fi
}

run_build() {
  local out p

  # `rossi build` takes one <INPUT> and its unit is a project: handed one
  # component at a time, which is what a glob expands to, every cross-component
  # reference dangles and a correct model comes back with EB009/EB018.
  if [ "${#paths[@]}" -gt 1 ]; then
    for p in "${paths[@]}"; do
      case "$p" in
        *.eventb|*.txt|*.buc|*.bum)
          echo "::error::rossi build wants a project root, not a component; try path: $(dirname "$p")/" >&2
          exit 1
          ;;
      esac
    done
  fi

  out="$(mktemp -d)"
  for p in "${paths[@]}"; do
    if ! "$rossi" build "$p" --output "$out/$(basename "$p").regen.zip"; then
      echo "::error title=rossi build::static check failed for ${p}"
      count_failure
    fi
  done
  rm -rf "$out"
}

for command in ${commands//,/ }; do
  case "$command" in
    validate)  run_validate ;;
    fmt-check) run_fmt_check ;;
    build)     run_build ;;
    "")        ;;
    *)
      echo "::error::unknown command '${command}' (want validate, fmt-check or build)" >&2
      exit 1
      ;;
  esac
done

{
  echo "valid=${valid}"
  echo "error-count=${errors}"
  echo "warning-count=${warnings}"
  emit "sarif-file" "${sarif_out}"
  emit "rossi-version" "$("$rossi" --version | awk '{print $NF}')"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

echo "rossi: ${errors} error(s), ${warnings} advisory finding(s)"
