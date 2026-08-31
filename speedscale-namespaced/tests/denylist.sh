#!/usr/bin/env bash
#
# S-12917 -- static-render denylist for the speedscale-namespaced chart.
#
# The chart's whole promise is that installing it grants Speedscale nothing
# outside one namespace. That promise is a property of the RENDERED output, not
# of anybody's intent, so it is checked here: `helm template` across a matrix of
# values permutations, and five assertions over every document that comes out.
#
# Usage:
#   tests/denylist.sh                 # check the real chart across the matrix
#   DENYLIST_SELFTEST=1 tests/denylist.sh
#                                     # prove every check actually fires, by
#                                     # running it against deliberately broken
#                                     # fixtures in tests/selftest/
#
# Requires: helm 3+, yq v4 (mikefarah).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$(dirname "$SCRIPT_DIR")"
CHART_NAME="$(basename "$CHART_DIR")"

# Release namespaces the matrix renders into. Two, deliberately: a check that
# compares metadata.namespace against a hard-coded "speedscale" would pass a
# single-namespace matrix while being completely wrong.
RELEASE_NAMESPACES=("speedscale" "acme-payments")

# --- the denylist -----------------------------------------------------------

# Kinds this chart must never render. Namespace and CRD because installing them
# needs cluster-scoped write; webhook configurations because they intercept
# every API call in the cluster; ClusterRole/binding because they are the exact
# grant a namespaced install exists to avoid; DaemonSet because it schedules on
# every node; SCC and PriorityClass because they are cluster-scoped policy.
FORBIDDEN_KINDS=(
  Namespace
  CustomResourceDefinition
  MutatingWebhookConfiguration
  ValidatingWebhookConfiguration
  ClusterRole
  ClusterRoleBinding
  DaemonSet
  SecurityContextConstraints
  PriorityClass
)

# Every apiVersion the chart is allowed to emit. This is the check that catches
# a third-party custom resource (a ServiceMonitor, a Cilium policy, an Istio
# VirtualService): those all live outside these six groups, so none of them can
# be added without this failing first.
ALLOWED_APIVERSIONS=(
  v1
  apps/v1
  batch/v1
  rbac.authorization.k8s.io/v1
  networking.k8s.io/v1
  policy/v1
)

# --- checks -----------------------------------------------------------------

VIOLATIONS=()

violation() { VIOLATIONS+=("[$1] $2"); }

in_list() {
  local needle=$1; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

# check_manifest <rendered-yaml> <expected-namespace> <label>
# Appends to VIOLATIONS. Returns 1 if this manifest produced any.
check_manifest() {
  local file=$1 expected_ns=$2 label=$3
  local before=${#VIOLATIONS[@]}

  # --- per-document checks: forbidden kind, namespace scope, apiVersion ---
  local line kind name ns apiversion
  while IFS='|' read -r kind name ns apiversion; do
    [[ "$kind" == "<nokind>" ]] && continue

    if in_list "$kind" "${FORBIDDEN_KINDS[@]}"; then
      violation forbidden-kind "$label: $kind/$name is a kind this chart must never render"
    fi

    if ! in_list "$apiversion" "${ALLOWED_APIVERSIONS[@]}"; then
      violation apiversion-allowlist \
        "$label: $kind/$name uses apiVersion '$apiversion', which is outside the allowlist (${ALLOWED_APIVERSIONS[*]})"
    fi

    # A cluster-scoped object legitimately has no namespace -- and this chart
    # renders no cluster-scoped objects, so a missing namespace is itself the
    # finding, not an exemption.
    if [[ "$ns" != "$expected_ns" ]]; then
      violation namespace-scope \
        "$label: $kind/$name has metadata.namespace '$ns', expected the release namespace '$expected_ns'"
    fi
  done < <(yq -N '[(.kind // "<nokind>"), (.metadata.name // "<noname>"), (.metadata.namespace // "<nonamespace>"), (.apiVersion // "<noapiversion>")] | join("|")' "$file")

  # --- whole-document text checks ---
  # Deliberately textual rather than structural: a reference to a ClusterRole
  # can appear as a kind, as a roleRef.kind, inside an aggregationRule, or in a
  # comment somebody is about to uncomment. All of them are findings.
  if grep -nE 'ClusterRole' "$file" >/dev/null 2>&1; then
    while IFS= read -r line; do
      violation clusterrole-reference "$label: $line"
    done < <(grep -nE 'ClusterRole' "$file")
  fi

  if grep -nE '^[[:space:]]*host(Network|PID)[[:space:]]*:[[:space:]]*(true|yes|"true")' "$file" >/dev/null 2>&1; then
    while IFS= read -r line; do
      violation host-namespace "$label: $line"
    done < <(grep -nE '^[[:space:]]*host(Network|PID)[[:space:]]*:[[:space:]]*(true|yes|"true")' "$file")
  fi

  [[ ${#VIOLATIONS[@]} -eq $before ]]
}

# --- modes ------------------------------------------------------------------

require_tools() {
  local missing=0
  command -v helm >/dev/null 2>&1 || { echo "denylist: helm not found on PATH" >&2; missing=1; }
  command -v yq   >/dev/null 2>&1 || { echo "denylist: yq (mikefarah v4) not found on PATH" >&2; missing=1; }
  [[ $missing -eq 0 ]] || exit 2
}

RENDER_DIR=""
cleanup() {
  local rc=$?
  [[ -n "$RENDER_DIR" ]] && rm -rf "$RENDER_DIR"
  return $rc
}
trap cleanup EXIT

run_matrix() {
  local tmp
  tmp="$(mktemp -d)"
  RENDER_DIR="$tmp"

  local values_files=("$SCRIPT_DIR"/values/*.yaml)
  if [[ ! -e "${values_files[0]}" ]]; then
    echo "denylist: no values permutations found in $SCRIPT_DIR/values" >&2
    exit 2
  fi

  local rendered=0 vf ns base out label
  for vf in "${values_files[@]}"; do
    base="$(basename "$vf" .yaml)"
    for ns in "${RELEASE_NAMESPACES[@]}"; do
      label="$base@$ns"
      out="$tmp/$base-$ns.yaml"
      if ! helm template "denylist-$base" "$CHART_DIR" \
            --namespace "$ns" --values "$vf" > "$out" 2>"$out.err"; then
        echo "FAIL  $label: helm template failed" >&2
        sed 's/^/      /' "$out.err" >&2
        exit 1
      fi
      if check_manifest "$out" "$ns" "$label"; then
        echo "ok    $label"
      else
        echo "FAIL  $label"
      fi
      rendered=$((rendered + 1))
    done
  done

  echo
  echo "rendered $rendered manifest(s) from ${#values_files[@]} values permutation(s) x ${#RELEASE_NAMESPACES[@]} namespace(s)"
}

# Self-test. Each fixture in tests/selftest/ is named for the ONE check it is
# built to trip. Passing here means the check is load-bearing; a check that
# silently stopped working (a renamed yq field, a broken regex) fails this
# before it can wave a real violation through.
run_selftest() {
  local fixtures=("$SCRIPT_DIR"/selftest/*.yaml)
  if [[ ! -e "${fixtures[0]}" ]]; then
    echo "denylist: no self-test fixtures found in $SCRIPT_DIR/selftest" >&2
    exit 2
  fi

  local failures=0 fx expect
  for fx in "${fixtures[@]}"; do
    expect="$(basename "$fx" .yaml)"
    VIOLATIONS=()

    if [[ "$expect" == "clean" ]]; then
      if check_manifest "$fx" "speedscale" "selftest/clean"; then
        echo "ok    clean fixture produced no violations"
      else
        echo "FAIL  clean fixture produced violations:"
        printf '        %s\n' "${VIOLATIONS[@]}"
        failures=$((failures + 1))
      fi
      continue
    fi

    check_manifest "$fx" "speedscale" "selftest/$expect" || true

    if [[ ${#VIOLATIONS[@]} -eq 0 ]]; then
      echo "FAIL  $expect: fixture tripped NO check -- the check is not firing"
      failures=$((failures + 1))
      continue
    fi

    if printf '%s\n' "${VIOLATIONS[@]}" | grep -q "^\[$expect\]"; then
      echo "ok    $expect fired: $(printf '%s\n' "${VIOLATIONS[@]}" | grep -m1 "^\[$expect\]")"
    else
      echo "FAIL  $expect: fixture tripped a check, but not [$expect]:"
      printf '        %s\n' "${VIOLATIONS[@]}"
      failures=$((failures + 1))
    fi
  done

  VIOLATIONS=()
  echo
  if [[ $failures -ne 0 ]]; then
    echo "denylist self-test: $failures check(s) did not behave as advertised" >&2
    exit 1
  fi
  echo "denylist self-test: every check fires on its fixture, and the clean fixture passes"
}

main() {
  require_tools
  if [[ -n "${DENYLIST_SELFTEST:-}" ]]; then
    echo "== denylist self-test ($CHART_NAME) =="
    run_selftest
    return
  fi

  echo "== denylist ($CHART_NAME) =="
  run_matrix

  if [[ ${#VIOLATIONS[@]} -ne 0 ]]; then
    echo
    echo "DENYLIST FAILED: ${#VIOLATIONS[@]} violation(s)" >&2
    printf '  %s\n' "${VIOLATIONS[@]}" >&2
    exit 1
  fi
  echo "denylist passed: no forbidden kinds, no out-of-namespace objects, no cluster-scoped references, no host namespaces, no unexpected apiVersions"
}

main "$@"
