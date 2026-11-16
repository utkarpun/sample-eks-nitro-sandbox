#!/usr/bin/env bash
# Shared settings, readings and guards for the self-running-agents scripts.
# Sourced, never run on its own.
#
# Every AWS resource is made by ACK from the two kro graphs in kro/; these
# scripts only apply them, wait, read their status, and read AWS back.
# Every kubectl call goes through kc() or kc_cluster(), which pin --context, so
# a run never depends on the machine's current context.
set -euo pipefail

SAMPLE=self-running-agents
TARGET=clock                # the gateway target; its tools are clock___<tool>
# The names kro/base.yaml and kro/gateway.yaml set (prefix, namespace and the
# instance name), and bootstrap's var.prefix, which scopes the ACK role to them.
PREFIX=sra
NAMESPACE=sra
INSTANCE=sra
BIFROST_NAMESPACE=bfx       # where bifrost/ runs the model gateway (bifrost/lib.sh)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLE_DIR="$(cd "$HERE/.." && pwd)"

for _c in grep sed; do
  command -v "$_c" >/dev/null 2>&1 \
    || { echo "error: missing required command: $_c, which is needed to read .env" >&2; exit 1; }
done

# Load .env as defaults, never sourced: only the keys below are read. A value
# already set in the environment wins over the file.
_ENV_KEYS='CLUSTER_NAME|AWS_REGION|AWS_PROFILE|KUBE_CONTEXT|BEDROCK_MODEL_ID|PROJECT_TAG|KUBECTL'
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
      BEDROCK_MODEL_ID) BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-$_v}" ;;
      PROJECT_TAG)      PROJECT_TAG="${PROJECT_TAG:-$_v}" ;;
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
BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID:-us.anthropic.claude-sonnet-5-5}"
PROJECT_TAG="${PROJECT_TAG:-self-running-agents}"   # the Project tag on every AWS resource
KUBECTL="${KUBECTL:-kubectl}"

# Values go into sed substitutions, so keep them to safe shapes.
[[ "$BEDROCK_MODEL_ID" =~ ^[A-Za-z0-9._:-]+$ ]] \
  || { echo "error: BEDROCK_MODEL_ID has characters a model id does not have; got '$BEDROCK_MODEL_ID'" >&2; exit 1; }
[[ "$PROJECT_TAG" =~ ^[A-Za-z0-9._:/=+@-]{1,256}$ ]] \
  || { echo "error: PROJECT_TAG must be a tag value without spaces; got '$PROJECT_TAG'" >&2; exit 1; }
[[ "$CLUSTER_NAME" =~ ^[A-Za-z0-9_-]*$ ]] \
  || { echo "error: CLUSTER_NAME has characters a cluster name does not have; got '$CLUSTER_NAME'" >&2; exit 1; }
[[ "$AWS_REGION" =~ ^[a-z0-9-]+$ ]] \
  || { echo "error: AWS_REGION is not a Region name; got '$AWS_REGION'" >&2; exit 1; }

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

# The account the AWS CLI is pointed at.
resolve_account() {
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" \
    || die "could not read the AWS account (aws sts get-caller-identity failed)"
  [[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "aws sts get-caller-identity returned '$ACCOUNT_ID', not an account id"
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
  local v cm=0 rc=0 crd=0
  local off="It is a cluster-wide setting, so this script does not change it. Turn it on yourself:"
  resource_exists kc_cluster -n kube-system configmap amazon-vpc-cni || cm=$?
  case $cm in
    1) die "network policy enforcement is off on this cluster (there is no amazon-vpc-cni ConfigMap in kube-system). $off
  kubectl -n kube-system create configmap amazon-vpc-cni --from-literal=enable-network-policy-controller=true" ;;
    2) die "could not read the amazon-vpc-cni ConfigMap in kube-system, so whether network policy enforcement is on could not be determined" ;;
  esac
  v="$(kc_cluster -n kube-system get configmap amazon-vpc-cni \
    -o jsonpath='{.data.enable-network-policy-controller}' 2>/dev/null)" || rc=$?
  [[ $rc -ne 0 ]] && die "could not read the amazon-vpc-cni ConfigMap in kube-system, so whether network policy enforcement is on could not be determined"
  [[ "$v" == "true" ]] || die "network policy enforcement is off on this cluster (enable-network-policy-controller is '${v:-<unset>}'). $off
  kubectl -n kube-system patch configmap amazon-vpc-cni --type merge -p '{\"data\":{\"enable-network-policy-controller\":\"true\"}}'"
  resource_exists kc_cluster crd applicationnetworkpolicies.networking.k8s.aws || crd=$?
  case $crd in
    1) die "the ApplicationNetworkPolicy CRD is not on this cluster, so the agent's egress rule cannot be applied. This sample needs EKS Auto Mode." ;;
    2) die "could not read the cluster's CRDs; stopping rather than guess" ;;
  esac
  echo "network policy enforcement is on, and ApplicationNetworkPolicy is available"
}

# instance_field <kind> <jsonpath>: one field of the sample's kro instance.
instance_field() { kc_cluster get "$1" "$INSTANCE" -o "jsonpath=$2" 2>/dev/null; }

# load_status: what run.sh and test.sh need, read from the two instances.
load_status() {
  local b g st gst
  b="$(instance_field srabase '{.status.state}|{.status.namespace}|{.status.bucketName}|{.status.repositoryURI}|{.spec.region}')" \
    || die "could not read SraBase $INSTANCE; run ./scripts/setup.sh first"
  IFS='|' read -r st NAMESPACE RUN_BUCKET REPOSITORY_URI AWS_REGION <<<"$b"
  g="$(instance_field sragateway '{.status.state}|{.spec.inferenceProfileARN}')" \
    || die "could not read SraGateway $INSTANCE; run ./scripts/setup.sh first"
  IFS='|' read -r gst BEDROCK_MODEL_ID <<<"$g"
  BEDROCK_MODEL_ID="${BEDROCK_MODEL_ID##*/}"
  [[ "$st" == ACTIVE && "$gst" == ACTIVE ]] \
    || die "SraBase reads '${st:-<none>}' and SraGateway '${gst:-<none>}', not both ACTIVE; run ./scripts/setup.sh"
  [[ -n "$NAMESPACE" && -n "$RUN_BUCKET" && -n "$REPOSITORY_URI" && -n "$BEDROCK_MODEL_ID" ]] \
    || die "an instance status field is empty; run ./scripts/setup.sh"
  # A run's model calls need the key bifrost/apply.sh puts here (deploy/run-job.yaml).
  resource_exists kc secret bifrost-agent-key \
    || die "Secret $NAMESPACE/bifrost-agent-key is missing or unreadable; run ./bifrost/apply.sh first"
}

# wait_active <kind> <seconds>: wait for the instance's state ACTIVE; on a
# timeout print what ACK reports for each object in the namespace.
wait_active() {
  if kc_cluster wait --for=jsonpath='{.status.state}'=ACTIVE "$1/$INSTANCE" --timeout="$2s"; then return 0; fi
  echo "$1 $INSTANCE is not ACTIVE after $2 s. Its conditions, then each AWS object as ACK sees it:" >&2
  instance_field "$1" '{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}' >&2 || true
  kc get "$(ack_kinds)" -o 'custom-columns=KIND:.kind,NAME:.metadata.name,SYNCED:.status.conditions[?(@.type=="ACK.ResourceSynced")].status,TERMINAL:.status.conditions[?(@.type=="ACK.Terminal")].message' >&2 || true
  die "$1 $INSTANCE did not become ACTIVE"
}
ack_kinds() {
  echo buckets.s3.services.k8s.aws,repositories.ecr.services.k8s.aws,roles.iam.services.k8s.aws,loggroups.cloudwatchlogs.services.k8s.aws,functions.lambda.services.k8s.aws,policyengines.bedrockagentcorecontrol.services.k8s.aws,gateways.bedrockagentcorecontrol.services.k8s.aws,gatewaytargets.bedrockagentcorecontrol.services.k8s.aws,policies.bedrockagentcorecontrol.services.k8s.aws,podidentityassociations.eks.services.k8s.aws
}

# ---------------------------------------------------------------------------
# AWS read-back with three outcomes: the service's own "not found" error (or a
# count of 0) means gone; success (or a count above 0) means still there; any
# other failure means could not determine.
# ---------------------------------------------------------------------------
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
# aws_verify_none <what> -- <command printing a count>: re-reads for up to 60 s,
# because AgentCore deletes finish after the call returns.
aws_verify_none() {
  local what=$1; shift
  [[ "$1" == "--" ]] && shift
  local n i
  for i in $(seq 1 12); do
    n="$("$@" 2>&1)" || { echo "  INCOMPLETE: could not determine whether $what is gone: $(tr '\n' ' ' <<<"$n")" >&2
                          AWS_CLEAN_FAIL=$((AWS_CLEAN_FAIL + 1)); return 1; }
    [[ "$n" == "0" ]] && { echo "  $what is gone"; return 0; }
    [[ $i -lt 12 ]] && sleep 5
  done
  echo "  INCOMPLETE: $what is still present (count $n)" >&2
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
# image_uri <repository URI>
image_uri() { local t; t="$(image_tag)" || exit 1; echo "$1:$t"; }

# render <file> [extra sed expressions...]: print a manifest with the sample's
# placeholders filled in. Files are rendered and then applied from a file.
render() {
  local f=$1; shift
  sed -e "s|<NAMESPACE>|$NAMESPACE|g" -e "s|<AWS_REGION>|$AWS_REGION|g" \
      -e "s|<RUN_BUCKET>|${RUN_BUCKET:-}|g" -e "s|<BEDROCK_MODEL_ID>|$BEDROCK_MODEL_ID|g" \
      -e "s|<ACCOUNT_ID>|${ACCOUNT_ID:-}|g" -e "s|<CLUSTER_NAME>|${CLUSTER_NAME:-}|g" \
      -e "s|<BIFROST_NAMESPACE>|$BIFROST_NAMESPACE|g" "$@" "$f"
}
