#!/usr/bin/env bash
# Shared settings for the bifrost/ scripts. Sourced, never run on its own.
# It sources the sample's scripts/common.sh, so the bifrost/ scripts read the same
# .env (CLUSTER_NAME, AWS_REGION, KUBE_CONTEXT, BEDROCK_MODEL_ID) as the agent's,
# and use its kc_cluster, die, resolve_account, render and AWS read-back.

BF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/common.sh
source "$BF_DIR/../scripts/common.sh"

# Fixed names, inside bootstrap/'s scope (bootstrap/variables.tf): rds_prefix "bfx"
# (the RDS instance, its subnet group and the bfx-* role), secret_namespaces "bfx"
# (the rds controller reads the database password Secret only there) and the
# security group's ManagedBy "bfx". The namespace is common.sh's BIFROST_NAMESPACE,
# which instance.yaml gets as a placeholder; instance.yaml's prefix and managedBy
# and scripts/test.sh's BIFROST_ROLE carry the other two. Change them all together
# with those variables (bifrost/README.md lists every site).
BF_PREFIX=bfx
BF_MANAGED_BY=bfx
# The agent pods' namespace is the sample's own (common.sh NAMESPACE, made by kro/base.yaml).
AGENT_NAMESPACE="$NAMESPACE"
CHART_VERSION=2.1.48
CHART_REPO=https://maximhq.github.io/bifrost/helm-charts

[[ -n "$CLUSTER_NAME" ]] || die "set CLUSTER_NAME (in the sample's .env or your shell) to your EKS Auto Mode cluster"
require_commands aws "$KUBECTL" helm python3 openssl

kb() { kc_cluster -n "$BIFROST_NAMESPACE" "$@"; }
ka() { kc_cluster -n "$AGENT_NAMESPACE" "$@"; }
hc() { if [[ -n "$KUBE_CONTEXT" ]]; then helm --kube-context "$KUBE_CONTEXT" "$@"; else helm "$@"; fi; }

# namespace_is_ours <namespace> <mark>: the namespace carries
# app.kubernetes.io/managed-by=<mark>. common.sh has no such check at this tip.
namespace_is_ours() {
  local v
  v="$(kc_cluster get namespace "$1" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null)" || return 2
  [[ "$v" == "$2" ]]
}
