#!/usr/bin/env bash
#
# Run the requested rossi subcommands over the model paths and turn their
# structured report into GitHub annotations, counts, and (optionally) SARIF.
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

# fmt-check and build report failures rossi did not itemise into a structured
# report, so they have to be counted here or they publish error-count=0 beside
# valid=false.
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
rossi_version="$("$rossi" --version | awk '{print $NF}')"

# 0.1.8 is the floor for the action as a whole, not just for SARIF: it is the
# first release whose JSON rows carry `path`, whose SARIF retains rule-less
# failures, and which itemises a directory holding no components. Every reader
# below assumes all three.
# Ordering is by the numeric triple alone, so a pre-release or a build suffix
# (`0.2.0-rc1`) is not refused for carrying one.
if ! jq -en --arg version "$rossi_version" '
  $version
  | capture("^(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.(?<patch>[0-9]+)([-+].*)?$")
  | [.major, .minor, .patch]
  | map(tonumber)
  | . >= [0, 1, 8]
' >/dev/null 2>&1; then
  echo "::error::rossi 0.1.8 or newer is required (got: ${rossi_version})" >&2
  exit 1
fi

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

# Normalize either structured report just far enough to share the GitHub
# annotation renderer. rossi joins and normalises the member path itself in both
# formats, so both read it the same way; an archive member is not a file on
# disk, so an archive finding points at the archive itself.
annotate() {
  local format="$1"
  jq -r --arg format "$format" --arg prefix "$prefix" '
    def rows:
      if $format == "sarif" then
        .runs[].results[]
        | {
            level: (if .level == "error" then "error"
                    elif .level == "warning" then "warning"
                    else "notice" end),
            path: (.locations[0].physicalLocation.artifactLocation.uri
                   | sub("!/.*$"; "")),
            region: ((.locations[0].physicalLocation.region // null)
                     | if . == null then null else {
                         start_line: .startLine,
                         start_column: .startColumn,
                         end_line: .endLine,
                         end_column: .endColumn
                       } end),
            rule: (.ruleId // ""),
            message: .message.text
          }
      else
        .[]
        | select(.error != null)
        | {
            level: (if .severity == "error" then "error"
                    elif .severity == "warning" then "warning"
                    else "notice" end),
            path: (.path | sub("!/.*$"; "")),
            region,
            rule: (.rule_id // ""),
            message: .error
          }
      end;
    def escdata: gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
    def escprop: escdata | gsub(":"; "%3A") | gsub(","; "%2C");
    rows
    | .path |= (if startswith("/") or $format == "sarif" then .
                else $prefix + . end)
    | (if .region != null then
         ",line=\(.region.start_line),col=\(.region.start_column)" +
         ",endLine=\(.region.end_line),endColumn=\(.region.end_column)"
       else "" end) as $pos
    | "::\(.level) file=\(.path | escprop)\($pos),title=rossi \(.rule | escprop)::\(.message | escdata)"
  ' "$2"
}

run_validate() {
  local args candidate n_errors n_warnings status=0

  if [ "${ROSSI_SARIF:-false}" = "true" ]; then
    candidate="${ROSSI_SARIF_FILE:-rossi.sarif}"
    mkdir -p "$(dirname "$candidate")"
    args=(
      "validate" "--format" "sarif"
      "--sarif-category" "${ROSSI_CATEGORY:-rossi}"
      "--output" "$report"
    )
  else
    args=("validate" "--format" "json" "--output" "$report")
  fi
  [ "${ROSSI_DENY_WARNINGS:-false}" = "true" ] && args+=("--deny-warnings")
  "$rossi" "${args[@]}" "${paths[@]}" || status=$?
  [ "$status" -ne 0 ] && fail

  # rossi exits nonzero on findings, which is expected; a missing or empty
  # report is not, and reading counts out of one would publish empty outputs
  # that break every consumer downstream.
  if [ "$status" -ge 2 ] || [ ! -s "$report" ]; then
    echo "::error::rossi wrote no report" >&2
    exit 1
  fi

  if [ "${ROSSI_SARIF:-false}" = "true" ]; then
    # The re-anchoring pass doubles as the validity check — jq fails on a
    # missing or malformed document, and with no prefix it is the identity.
    if ! jq --arg prefix "$prefix" '
          (.runs[]?.results[]?.locations[]?.physicalLocation.artifactLocation.uri)
            |= (if startswith("/") then . else $prefix + . end)
        ' "$report" > "${candidate}.tmp" 2>/dev/null; then
      echo "::error::rossi produced no usable SARIF report at ${candidate}" >&2
      rm -f "${candidate}.tmp"
      exit 1
    fi
    mv "${candidate}.tmp" "$candidate"
    sarif_out="$candidate"

    if [ "${ROSSI_ANNOTATIONS:-true}" = "true" ]; then
      annotate sarif "$candidate"
    fi
    read -r n_errors n_warnings <<<"$(jq -r '
      [ ([.runs[].results[] | select(.level == "error")] | length),
        ([.runs[].results[] | select(.level == "warning" or .level == "note")] | length)
      ] | @tsv' "$candidate")"
  else
    if [ "${ROSSI_ANNOTATIONS:-true}" = "true" ]; then
      annotate json "$report"
    fi
    # A directory or archive holding no components is rossi's own error row, so
    # it needs no fallback here: it reaches the counts, the annotations and
    # `fail-on-error` like any other finding.
    read -r n_errors n_warnings <<<"$(jq -r '
      [ ([.[] | select(.severity == "error")] | length),
        ([.[] | select(.severity == "warning" or .severity == "info")] | length)
      ] | @tsv' "$report")"
  fi

  errors=$((errors + n_errors))
  warnings=$((warnings + n_warnings))
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
  emit "rossi-version" "$rossi_version"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

echo "rossi: ${errors} error(s), ${warnings} advisory finding(s)"
