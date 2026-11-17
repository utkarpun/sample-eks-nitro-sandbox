#!/usr/bin/env bash
# Bring Bifrost up: its namespace, the AWS side and its Kubernetes objects
# through kro and ACK (rgd.yaml, instance.yaml), the Secrets, then the official
# Helm chart on top (values.yaml). Re-runnable: Secrets are made only when absent, so
# a re-run keeps the database password, the admin login, the encryption key and
# the agent's key.
source "$(dirname "$0")/lib.sh"

# 1. kro and ACK come from the sample's bootstrap/ (the EKS managed capabilities):
#    check, never install.
for crd in resourcegraphdefinitions.kro.run securitygroups.ec2.services.k8s.aws \
           dbinstances.rds.services.k8s.aws dbsubnetgroups.rds.services.k8s.aws \
           roles.iam.services.k8s.aws podidentityassociations.eks.services.k8s.aws; do
  rc=0; resource_exists kc_cluster crd "$crd" || rc=$?
  case $rc in
    1) die "CRD $crd is not on this cluster. Turn on the sample's kro and ACK capabilities first (README, Before you start):
  terraform -chdir=bootstrap init && terraform -chdir=bootstrap apply -var cluster_name=$CLUSTER_NAME -var region=$AWS_REGION" ;;
    2) die "could not read the cluster's CRDs; stopping rather than guess" ;;
  esac
done
require_network_policy_enforcement

# 2. What the graph needs to know about the cluster, read, never changed. Every
#    cluster subnet is passed to the database's subnet group as it is.
resolve_account
read -r VPC_ID SUBNETS < <(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.[vpcId, join(`,`, subnetIds)]' --output text) \
  || die "could not read cluster $CLUSTER_NAME in $AWS_REGION"
VPC_CIDR="$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text)" \
  || die "could not read VPC $VPC_ID"
echo "cluster $CLUSTER_NAME: account $ACCOUNT_ID, VPC $VPC_ID ($VPC_CIDR), subnets $SUBNETS"

# 3. The graph definition. It makes Bifrost's namespace, so a namespace of that
#    name that is already there must carry the sample's label. The agent's
#    namespace must be the sample's (made by ./scripts/setup.sh).
kc_cluster apply -f "$BF_DIR/rgd.yaml" >/dev/null
kc_cluster wait --for=jsonpath='{.status.state}'=Active rgd/bifrost-backend --timeout=120s >/dev/null \
  || die "kro did not accept rgd.yaml: kubectl$CTX_ARG get rgd bifrost-backend -o yaml"
namespace_is_ours "$AGENT_NAMESPACE" "$SAMPLE" \
  || die "namespace $AGENT_NAMESPACE is missing or not labelled app.kubernetes.io/managed-by=$SAMPLE; run ./scripts/setup.sh first"
rc=0; resource_exists kc_cluster namespace "$BIFROST_NAMESPACE" || rc=$?
case $rc in
  0) namespace_is_ours "$BIFROST_NAMESPACE" "$BF_MANAGED_BY" \
       || die "namespace $BIFROST_NAMESPACE is not labelled app.kubernetes.io/managed-by=$BF_MANAGED_BY, so it is not this sample's" ;;
  2) die "could not read namespace $BIFROST_NAMESPACE; stopping rather than guess" ;;
esac

# 4. This cluster's instance. The pricing files go in as JSON strings, which
#    are valid YAML scalars, so no character in them needs a sed escape.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT; chmod 700 "$work"
subnet_list="$(printf '"%s",' ${SUBNETS//,/ })"
render "$BF_DIR/instance.yaml" -e "s|<VPC_ID>|$VPC_ID|g" -e "s|<VPC_CIDR>|$VPC_CIDR|g" \
  -e "s|<SUBNET_IDS>|${subnet_list%,}|g" -e "s|<FOUNDATION_MODEL_ID>|${BEDROCK_MODEL_ID#*.}|g" > "$work/instance.yaml"
python3 - "$work/instance.yaml" "$BF_DIR/pricing/pricing.json" "$BF_DIR/pricing/model-parameters.json" <<'PY2' \
  || die "could not put the pricing files into the instance"
import json, sys
path, pricing, params = sys.argv[1:]
text = open(path).read()
for mark, f in (("<PRICING_JSON>", pricing), ("<MODEL_PARAMETERS_JSON>", params)):
    assert text.count(mark) == 1, mark
    text = text.replace(mark, json.dumps(open(f).read()))
open(path, "w").write(text)
PY2
kc_cluster apply -f "$work/instance.yaml" >/dev/null
# The graph makes the namespace first; wait for it, labelled, before the Secrets.
for _ in $(seq 1 60); do namespace_is_ours "$BIFROST_NAMESPACE" "$BF_MANAGED_BY" && break; sleep 2; done
namespace_is_ours "$BIFROST_NAMESPACE" "$BF_MANAGED_BY" \
  || die "the graph did not make namespace $BIFROST_NAMESPACE, labelled, within 120 s: kubectl$CTX_ARG get bifrostbackend bifrost -o yaml"

# 5. Secrets, made once from random bytes. Values go through files, never the
#    command line. These stay in the script: their values must be secret, and kro's
#    generators (`random.seededString`, `random.seededInt`) are deterministic from
#    their seed, so a graph cannot make fresh random bytes; a secret value has to be
#    made outside it. The graph's database waits for
#    bifrost-db (rgd.yaml, dbSecret), and its copy of the agent's key in the
#    agent's namespace for bifrost-agent-key (agentKey).
rand() { openssl rand -hex 24; }
secret_once() {  # <namespace> <name> <key>=<file> ...
  local ns="$1" name="$2"; shift 2
  [[ -n "$(kc_cluster -n "$ns" get secret "$name" --ignore-not-found -o name)" ]] && return 0
  local args=(); for kv in "$@"; do args+=(--from-file="$kv"); done
  kc_cluster -n "$ns" create secret generic "$name" "${args[@]}" >/dev/null
  echo "secret $ns/$name made"
}
printf '%s' "$(rand)" > "$work/db"; printf '%s' "$(rand)" > "$work/enc"; printf '%s' "$(rand)" > "$work/admin"
printf '%s' "admin" > "$work/user"; printf 'sk-bf-%s' "$(rand)" > "$work/vk"
secret_once "$BIFROST_NAMESPACE" bifrost-db password="$work/db"
secret_once "$BIFROST_NAMESPACE" bifrost-encryption encryption-key="$work/enc"
secret_once "$BIFROST_NAMESPACE" bifrost-admin username="$work/user" password="$work/admin"
secret_once "$BIFROST_NAMESPACE" bifrost-agent-key key="$work/vk"

echo "waiting for the graph (the RDS instance is most of the wait)"
kc_cluster wait --for=jsonpath='{.status.state}'=ACTIVE bifrostbackend/bifrost --timeout=1200s >/dev/null \
  || die "the graph is not ACTIVE: kubectl$CTX_ARG get bifrostbackend bifrost -o yaml"
echo "database $(kc_cluster get bifrostbackend bifrost -o jsonpath='{.status.dbHost}')"

# 6. Bifrost itself, from the official chart, with the Region and model filled in.
render "$BF_DIR/values.yaml" > "$work/values.yaml"
hc upgrade --install bifrost bifrost --repo "$CHART_REPO" --version "$CHART_VERSION" \
  -n "$BIFROST_NAMESPACE" -f "$work/values.yaml" --wait --timeout 10m >/dev/null \
  || die "the Bifrost release did not become ready: kubectl$CTX_ARG -n $BIFROST_NAMESPACE get pods"
echo "bifrost is up: http://bifrost.$BIFROST_NAMESPACE.svc.cluster.local:8080"
