#!/usr/bin/env bash
# Shared settings, readings and guards for the self-running-agents scripts.
# Sourced, never run on its own.
#
# Every kubectl call goes through kc(), which pins --context and --namespace, so
# a run never depends on the machine's current context or on a default
# namespace. Cluster-scoped calls go through kc_cluster.
set -euo pipefail

SAMPLE=self-running-agents
TARGET=clock                # the gateway target; its tools are clock___<tool>

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "$HERE/.." && pwd)"

for _c in grep sed; do
  command -v "$_c" >/dev/null 2>&1 \
    || { echo "error: missing required command: $_c, which is needed to read .env" >&2; exit 1; }
done

# Load .env as defaults, never sourced: only the keys below are read. A value
# already set in the environment wins over the file.
_ENV_KEYS='CLUSTER_NAME|AWS_REGION|AWS_PROFILE|KUBE_CONTEXT|NAMESPACE|BEDROCK_MODEL_ID|ECR_REPOSITORY|NAME_PREFIX|RUN_BUCKET|KUBECTL'
if [[ -f "$SAMPLE_DIR/.env" && ! -r "$SAMPLE_DIR/.env" ]]; then
  echo "error: $SAMPLE_DIR/.env exists but is not readable; fix its permissions and re-run" >&2
  exit 1
fi
if [[ -f "$SAMPLE_DIR/.env" ]]; then
  while IFS='=' read -r _k _v; do
    case "$_k" in
      CLUSTER_NAME)     CLUSTER_NAME="${CLUSTER_NAME:-$_v}" ;;
      AWS_REGION)       AWS_REGION="${AWS_REGION:-$_v}" ;;
      AWS_PROFILE)      AWS_PROFILE="${AWS_PROFILE:-$_v}" ;;
      KUBE_CONTEXT)     KUBE_CONTEXT="${KUBE_CONTEXT:-$_v}" ;;
      NAMESPACE)        NAMESPACE="${NAMESPACE:-$_v}" ;;
      BEDROCK_MODEL_ID) BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-$_v}" ;;
      ECR_REPOSITORY)   ECR_REPOSITORY="${ECR_REPOSITORY:-$_v}" ;;
      NAME_PREFIX)      NAME_PREFIX="${NAME_PREFIX:-$_v}" ;;
      RUN_BUCKET)       RUN_BUCKET="${RUN_BUCKET:-$_v}" ;;
      KUBECTL)          KUBECTL="${KUBECTL:-$_v}" ;;
    esac
  done < <(grep -E "^[[:space:]]*($_ENV_KEYS)[[:space:]]*=" "$SAMPLE_DIR/.env" \
             | sed -E 's/\r$//; s/^[[:space:]]*//; s/[[:space:]]*=[[:space:]]*/=/')
fi

CLUSTER_NAME="${CLUSTER_NAME:-}"
AWS_REGION="${AWS_REGION:-us-west-2}"
export AWS_REGION
if [[ -n "${AWS_PROFILE:-}" ]]; then export AWS_PROFILE; else unset AWS_PROFILE; fi
KUBE_CONTEXT="${KUBE_CONTEXT:-}"
NAMESPACE="${NAMESPACE:-self-running-agents}"
BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-us.anthropic.claude-sonnet-5-5}"
ECR_REPOSITORY="${ECR_REPOSITORY:-self-running-agents}"
NAME_PREFIX="${NAME_PREFIX:-self-running-agents}"
RUN_BUCKET="${RUN_BUCKET:-}"
KUBECTL="${KUBECTL:-kubectl}"

# Names go into sed substitutions and AWS names, so keep them to safe shapes.
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$ ]] \
  || { echo "error: NAMESPACE must be a DNS label; got '$NAMESPACE'" >&2; exit 1; }
[[ "$NAME_PREFIX" =~ ^[a-z][a-z0-9-]{0,30}[a-z0-9]$ ]] \
  || { echo "error: NAME_PREFIX must be lower-case letters, digits and dashes, 2 to 32 characters, starting with a letter; got '$NAME_PREFIX'" >&2; exit 1; }
[[ "$BEDROCK_MODEL_ID" =~ ^[A-Za-z0-9._:-]+$ ]] \
  || { echo "error: BEDROCK_MODEL_ID has characters a model id does not have; got '$BEDROCK_MODEL_ID'" >&2; exit 1; }
[[ "$RUN_BUCKET" =~ ^([a-z0-9][a-z0-9.-]{1,61}[a-z0-9])?$ ]] \
  || { echo "error: RUN_BUCKET must be an S3 bucket name, or empty; got '$RUN_BUCKET'" >&2; exit 1; }
[[ "$ECR_REPOSITORY" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] \
  || { echo "error: ECR_REPOSITORY must be an ECR repository name; got '$ECR_REPOSITORY'" >&2; exit 1; }

# The AWS names, each derived from NAME_PREFIX so a second copy of the sample in
# the same account only needs a different prefix.
AGENT_ROLE="$NAME_PREFIX-agent"
GATEWAY_ROLE="$NAME_PREFIX-gateway"
TOOL_ROLE="$NAME_PREFIX-tool"
TOOL_FUNCTION="$NAME_PREFIX-clock"
GATEWAY_NAME="$NAME_PREFIX-gw"
POLICY_ENGINE_NAME="${NAME_PREFIX//-/_}_policy"   # policy engine names allow no dashes
POLICY_NAME="${NAME_PREFIX//-/_}_allow_get_time"
TOOL_LOG_GROUP="/aws/lambda/$TOOL_FUNCTION"

kc() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    "$KUBECTL" --context "$KUBE_CONTEXT" --namespace "$NAMESPACE" "$@"
  else
    "$KUBECTL" --namespace "$NAMESPACE" "$@"
  fi
}
kc_cluster() {
  if [[ -n "$KUBE_CONTEXT" ]]; then "$KUBECTL" --context "$KUBE_CONTEXT" "$@"; else "$KUBECTL" "$@"; fi
}

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }
require_commands() {
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"; done
}

show_context() {
  if [[ -n "$KUBE_CONTEXT" ]]; then
    echo "context: $KUBE_CONTEXT (pinned)   namespace: $NAMESPACE   region: $AWS_REGION"
  else
    echo "context: $(kc_cluster config current-context 2>/dev/null || echo '<none>') (current; set KUBE_CONTEXT in .env to pin it)   namespace: $NAMESPACE   region: $AWS_REGION"
  fi
}

# The account the AWS CLI is pointed at, and the names that depend on it.
resolve_account() {
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
    || die "could not read the AWS account (aws sts get-caller-identity failed)"
  [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "aws sts get-caller-identity returned '$ACCOUNT_ID', not an account id"
  RUN_BUCKET="${RUN_BUCKET:-$NAME_PREFIX-runs-$ACCOUNT_ID-$AWS_REGION}"
  AGENT_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$AGENT_ROLE"
  GATEWAY_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$GATEWAY_ROLE"
  TOOL_ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$TOOL_ROLE"
  TOOL_FUNCTION_ARN="arn:aws:lambda:$AWS_REGION:$ACCOUNT_ID:function:$TOOL_FUNCTION"
}

# ---------------------------------------------------------------------------
# What is the sample's. In the cluster the namespace label is the mark; in AWS
# the ManagedBy tag is. A read that fails means "could not determine".
# ---------------------------------------------------------------------------
NS_LABEL_KEY="app.kubernetes.io/managed-by"
MANAGED_BY="$SAMPLE"

# namespace_is_ours: 0 ours, 1 someone else's, 2 could not read, 3 absent
namespace_is_ours() {
  local out rc
  out="$(kc_cluster get namespace "$NAMESPACE" --ignore-not-found \
    -o "jsonpath={.metadata.labels.app\.kubernetes\.io/managed-by}{\"|\"}{.metadata.name}" 2>/dev/null)"
  rc=$?
  [[ $rc -ne 0 ]] && return 2
  [[ "$out" == "|" || -z "$out" ]] && return 3
  [[ "${out%%|*}" == "$MANAGED_BY" ]]
}

# resource_exists <runner> <kind/name...>: 0 exists, 1 absent, 2 read failed
resource_exists() {
  local runner=$1; shift
  local out rc
  out="$("$runner" get "$@" --ignore-not-found -o name 2>/dev/null)"
  rc=$?
  [[ $rc -ne 0 ]] && return 2
  [[ -n "$out" ]]
}

# The shared installs and cluster-wide settings this sample needs, read only.
require_runtime_class() {
  local rc=0
  resource_exists kc_cluster runtimeclass isolated-sandbox || rc=$?
  case $rc in
    1) die "runtimeclass isolated-sandbox is not on this cluster. Run the Hello sandbox sample first." ;;
    2) die "could not read the cluster's runtime classes; stopping rather than guess" ;;
  esac
}
require_network_policy_enforcement() {
  local v rc=0 crd=0
  v="$(kc_cluster -n kube-system get configmap amazon-vpc-cni \
    -o jsonpath='{.data.enable-network-policy-controller}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && die "could not read the amazon-vpc-cni ConfigMap in kube-system, so whether network policy enforcement is on could not be determined"
  [[ "$v" == "true" ]] || die "network policy enforcement is off on this cluster (enable-network-policy-controller is '${v:-<unset>}'). It is a cluster-wide setting, so this script does not change it. Turn it on yourself:
  kubectl -n kube-system patch configmap amazon-vpc-cni --type merge -p '{\"data\":{\"enable-network-policy-controller\":\"true\"}}'"
  resource_exists kc_cluster crd applicationnetworkpolicies.networking.k8s.aws || crd=$?
  case $crd in
    1) die "the ApplicationNetworkPolicy CRD is not on this cluster, so the agent's egress rule cannot be applied. This sample needs EKS Auto Mode." ;;
    2) die "could not read the cluster's CRDs; stopping rather than guess" ;;
  esac
  echo "network policy enforcement is on, and ApplicationNetworkPolicy is available"
}

# ---------------------------------------------------------------------------
# AgentCore readings. Each prints the id, or nothing when the name is absent;
# a failed list is a failure, never "absent".
# ---------------------------------------------------------------------------
gateway_id() {
  aws bedrock-agentcore-control list-gateways --output json \
    | python3 -c 'import sys,json; n=sys.argv[1]; print(next((g["gatewayId"] for g in json.load(sys.stdin).get("items",[]) if g.get("name")==n),""))' "$GATEWAY_NAME"
}
policy_engine_id() {
  aws bedrock-agentcore-control list-policy-engines --output json \
    | python3 -c 'import sys,json; n=sys.argv[1]; print(next((p["policyEngineId"] for p in json.load(sys.stdin).get("policyEngines",[]) if p.get("name")==n),""))' "$POLICY_ENGINE_NAME"
}
# tag_is_ours <arn>: 0 tagged ManagedBy=<sample>, 1 not, 2 could not read
tag_is_ours() {
  local v
  v="$(aws bedrock-agentcore-control list-tags-for-resource --resource-arn "$1" \
        --query 'tags.ManagedBy' --output text 2>/dev/null)" || return 2
  [[ "$v" == "$MANAGED_BY" ]]
}
# wait_status <what> <command...>: wait until the command prints READY or ACTIVE
wait_status() {
  local what=$1; shift
  local s deadline=$((SECONDS + 300))
  while :; do
    s="$("$@" 2>/dev/null || echo READ_FAILED)"
    case "$s" in
      READY|ACTIVE) echo "  $what is $s"; return 0 ;;
      READ_FAILED) ;;
      *FAILED*) die "$what reached $s" ;;
    esac
    ((SECONDS >= deadline)) && die "$what is still $s after 300 s"
    sleep 5
  done
}

# ---------------------------------------------------------------------------
# AWS teardown verification with three outcomes, as in the other samples: the
# service's own "not found" error means gone; success means still there; any
# other failure means could not determine.
# ---------------------------------------------------------------------------
aws_exists() {
  local pattern=$1; shift
  [[ "$1" == "--" ]] && shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  [[ $rc -eq 0 ]] && return 0
  grep -Fq "An error occurred ($pattern)" <<<"$out" && return 1
  AWS_LAST_ERROR="$(tr '\n' ' ' <<<"$out")"
  return 2
}
AWS_LAST_ERROR=""

AWS_CLEAN_FAIL=0
aws_verify_absent() {
  local what=$1 pattern=$2; shift 2
  [[ "$1" == "--" ]] && shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "  INCOMPLETE: $what is still present" >&2
    AWS_CLEAN_FAIL=$((AWS_CLEAN_FAIL + 1)); return 1
  fi
  if grep -Fq "An error occurred ($pattern)" <<<"$out"; then echo "  $what is gone"; return 0; fi
  echo "  INCOMPLETE: could not determine whether $what is gone: $(tr '\n' ' ' <<<"$out")" >&2
  AWS_CLEAN_FAIL=$((AWS_CLEAN_FAIL + 1)); return 1
}

# image_tag: the first 16 hex characters of the sha256 of the Dockerfile and
# every file under agent/, so a change to either builds a new image and the same
# content always has the same tag.
image_tag() {
  local t
  t="$(cd "$SAMPLE_DIR" && find Dockerfile agent -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)"
  [[ "$t" =~ ^[0-9a-f]{16}$ ]] || die "could not hash Dockerfile and agent/ (is sha256sum installed?)"
  echo "$t"
}
image_uri() { echo "$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPOSITORY:$(image_tag)"; }

# render <file> [extra sed expressions...]: print a manifest with the sample's
# placeholders filled in. Files are rendered and then applied from a file.
render() {
  local f=$1; shift
  sed -e "s|<NAMESPACE>|$NAMESPACE|g" -e "s|<AWS_REGION>|$AWS_REGION|g" \
      -e "s|<RUN_BUCKET>|${RUN_BUCKET:-}|g" -e "s|<BEDROCK_MODEL_ID>|$BEDROCK_MODEL_ID|g" \
      -e "s|<ACCOUNT_ID>|${ACCOUNT_ID:-}|g" -e "s|<CLUSTER_NAME>|${CLUSTER_NAME:-}|g" "$@" "$f"
}
