#!/usr/bin/env bash
# Shared settings for the bifrost/ scripts. Sourced, never run on its own.
# Every value comes from the environment; kubectl always gets --context when
# KUBE_CONTEXT is set, so a run never depends on the machine's current context.
set -euo pipefail

BF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-west-2}"; export AWS_REGION
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
# Bifrost's own namespace, and the agent namespace whose agent pods may call it.
BIFROST_NAMESPACE="${BIFROST_NAMESPACE:-self-running-agents-bifrost}"
AGENT_NAMESPACE="${AGENT_NAMESPACE:-self-running-agents}"
NAME_PREFIX="${NAME_PREFIX:-self-running-agents}"
MANAGED_BY="${MANAGED_BY:-self-running-agents}"
CHART_VERSION=2.1.48
CHART_REPO=https://maximhq.github.io/bifrost/helm-charts

die() { echo "error: $*" >&2; exit 1; }
[[ -n "$CLUSTER_NAME" ]] || die "set CLUSTER_NAME to your EKS Auto Mode cluster"
for _n in "$BIFROST_NAMESPACE" "$AGENT_NAMESPACE"; do
  [[ "$_n" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "namespace must be a DNS label; got '$_n'"
done
[[ "$NAME_PREFIX" =~ ^[a-z][-a-z0-9]{0,40}$ ]] \
  || die "NAME_PREFIX must be lower case letters, digits and dashes, at most 41 characters (RDS and IAM names); got '$NAME_PREFIX'"
for _c in aws kubectl helm python3 openssl; do
  command -v "$_c" >/dev/null 2>&1 || die "missing required command: $_c"
done

kc() { if [[ -n "$KUBE_CONTEXT" ]]; then kubectl --context "$KUBE_CONTEXT" "$@"; else kubectl "$@"; fi; }
hc() { if [[ -n "$KUBE_CONTEXT" ]]; then helm --kube-context "$KUBE_CONTEXT" "$@"; else helm "$@"; fi; }

# The namespace is the sample's only when it carries the sample's label.
namespace_is_ours() {
  local v
  v="$(kc get namespace "$1" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" || return 2
  [[ "$v" == "$MANAGED_BY" ]]
}
