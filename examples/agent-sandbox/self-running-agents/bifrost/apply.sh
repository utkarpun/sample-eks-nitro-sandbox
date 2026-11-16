#!/usr/bin/env bash
# Bring Bifrost up: the AWS side and its Kubernetes objects through kro and ACK
# (rgd.yaml), then the official Helm chart on top (values.yaml). Re-runnable:
# Secrets are made only when absent, so a re-run keeps the database password,
# the admin login, the encryption key and the agent's key.
source "$(dirname "$0")/lib.sh"

# 1. The controllers this needs are a shared install: check, never install.
for crd in resourcegraphdefinitions.kro.run securitygroups.ec2.services.k8s.aws \
           dbinstances.rds.services.k8s.aws dbsubnetgroups.rds.services.k8s.aws \
           roles.iam.services.k8s.aws podidentityassociations.eks.services.k8s.aws \
           applicationnetworkpolicies.networking.k8s.aws; do
  kc get crd "$crd" -o name >/dev/null 2>&1 \
    || die "CRD $crd is not on this cluster. Install kro and the ACK ec2, rds, iam and eks controllers first (README, Before you start)."
done

# 2. What the graph needs to know about the cluster, read, never changed.
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || die "could not read the account"
read -r VPC_ID SUBNETS < <(aws eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.resourcesVpcConfig.[vpcId, join(`,`, subnetIds)]' --output text) \
  || die "could not read cluster $CLUSTER_NAME in $AWS_REGION"
VPC_CIDR="$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].CidrBlock' --output text)" \
  || die "could not read VPC $VPC_ID"
echo "cluster $CLUSTER_NAME: account $ACCOUNT_ID, VPC $VPC_ID ($VPC_CIDR), subnets $SUBNETS"

# 3. Bifrost's namespace: made when absent, used only when it carries our label.
if [[ -z "$(kc get namespace "$BIFROST_NAMESPACE" --ignore-not-found -o name)" ]]; then
  kc create namespace "$BIFROST_NAMESPACE"
  kc label namespace "$BIFROST_NAMESPACE" "app.kubernetes.io/managed-by=$MANAGED_BY"
fi
namespace_is_ours "$BIFROST_NAMESPACE" || die "namespace $BIFROST_NAMESPACE is not labelled app.kubernetes.io/managed-by=$MANAGED_BY, so it is not this sample's"

# 4. Secrets, made once from random bytes. Values go through files, never the
#    command line.
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT; chmod 700 "$work"
rand() { openssl rand -hex 24; }
secret_once() {  # <namespace> <name> <key>=<file> ...
  local ns="$1" name="$2"; shift 2
  [[ -n "$(kc -n "$ns" get secret "$name" --ignore-not-found -o name)" ]] && return 0
  local args=(); for kv in "$@"; do args+=(--from-file="$kv"); done
  kc -n "$ns" create secret generic "$name" "${args[@]}" >/dev/null
  echo "secret $ns/$name made"
}
printf '%s' "$(rand)" > "$work/db"; printf '%s' "$(rand)" > "$work/enc"; printf '%s' "$(rand)" > "$work/admin"
printf '%s' "admin" > "$work/user"; printf 'sk-bf-%s' "$(rand)" > "$work/vk"
secret_once "$BIFROST_NAMESPACE" bifrost-db password="$work/db"
secret_once "$BIFROST_NAMESPACE" bifrost-encryption encryption-key="$work/enc"
secret_once "$BIFROST_NAMESPACE" bifrost-admin username="$work/user" password="$work/admin"
secret_once "$BIFROST_NAMESPACE" bifrost-agent-key key="$work/vk"
# The agent reads the same key from a Secret in its own namespace, when that
# namespace exists; the agent's setup makes it otherwise.
if [[ -n "$(kc get namespace "$AGENT_NAMESPACE" --ignore-not-found -o name)" ]]; then
  kc -n "$BIFROST_NAMESPACE" get secret bifrost-agent-key -o jsonpath='{.data.key}' \
    | python3 -c 'import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.read()).decode())' > "$work/vk-now"
  secret_once "$AGENT_NAMESPACE" bifrost-agent-key key="$work/vk-now"
fi
kc -n "$BIFROST_NAMESPACE" create configmap bifrost-pricing \
  --from-file="$BF_DIR/pricing/pricing.json" --from-file="$BF_DIR/pricing/model-parameters.json" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null

# 5. The graph definition, then this cluster's instance of it.
kc apply -f "$BF_DIR/kro-rbac.yaml" -f "$BF_DIR/rgd.yaml" >/dev/null
kc wait --for=jsonpath='{.status.state}'=Active rgd/bifrost-backend --timeout=120s >/dev/null \
  || die "kro did not accept rgd.yaml: kubectl get rgd bifrost-backend -o yaml"
subnet_list="$(printf '"%s",' ${SUBNETS//,/ })"
cat <<EOF | kc apply -f - >/dev/null
apiVersion: kro.run/v1alpha1
kind: BifrostBackend
metadata:
  name: bifrost
  namespace: $BIFROST_NAMESPACE
spec:
  prefix: $NAME_PREFIX
  managedBy: $MANAGED_BY
  clusterName: $CLUSTER_NAME
  accountID: "$ACCOUNT_ID"
  region: $AWS_REGION
  vpcID: $VPC_ID
  vpcCIDR: $VPC_CIDR
  subnetIDs: [${subnet_list%,}]
  agentNamespace: $AGENT_NAMESPACE
EOF
echo "waiting for the graph (RDS takes about 5 to 10 minutes)"
kc -n "$BIFROST_NAMESPACE" wait --for=jsonpath='{.status.state}'=ACTIVE bifrostbackend/bifrost --timeout=1200s >/dev/null \
  || die "the graph is not ACTIVE: kubectl -n $BIFROST_NAMESPACE get bifrostbackend bifrost -o yaml"
echo "database $(kc -n "$BIFROST_NAMESPACE" get bifrostbackend bifrost -o jsonpath='{.status.dbHost}')"

# 6. Bifrost itself, from the official chart.
hc upgrade --install bifrost bifrost --repo "$CHART_REPO" --version "$CHART_VERSION" \
  -n "$BIFROST_NAMESPACE" -f "$BF_DIR/values.yaml" --wait --timeout 10m >/dev/null \
  || die "the Bifrost release did not become ready: kubectl -n $BIFROST_NAMESPACE get pods"
echo "bifrost is up: http://bifrost.$BIFROST_NAMESPACE.svc.cluster.local:8080"
