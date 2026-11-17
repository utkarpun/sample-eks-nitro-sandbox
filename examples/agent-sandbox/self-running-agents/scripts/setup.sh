#!/usr/bin/env bash
# Set up the self-running-agents sample from its IaC: the three kro graphs in
# kro/ (sra-run is the per-run graph scripts/run.sh uses), whose AWS objects the EKS managed ACK capability creates. This script
# makes no AWS resource itself. It checks what the sample needs, applies the
# graphs and the SraBase instance (namespace, run bucket, image repository),
# uploads the tool's code to the bucket and pushes the agent image (data and a
# build, not infrastructure), then applies the SraGateway instance (gateway,
# policy, tool, roles, Pod Identity, admission, egress, the agent's config).
#
# It never changes a shared install or a cluster-wide setting. Safe to re-run:
# kubectl apply of the same instances changes nothing, and a new tool zip or a
# new image is picked up.
source "$(dirname "$0")/common.sh" || exit 1
require_commands aws docker python3 sha256sum "$KUBECTL"
K="$SAMPLE_DIR/kro"

step "0/4 checks"
show_context
[[ -n "$CLUSTER_NAME" ]] || die "CLUSTER_NAME is empty; set it in .env"
aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.endpoint --output text >/dev/null \
  || die "could not describe EKS cluster $CLUSTER_NAME in $AWS_REGION; check CLUSTER_NAME and AWS_REGION in .env"
require_runtime_class
require_network_policy_enforcement
# The kro and ACK capabilities from bootstrap/ (Step 0 of the README).
for crd in resourcegraphdefinitions.kro.run $(ack_kinds | tr ',' ' '); do
  rc=0; resource_exists kc_cluster crd "$crd" || rc=$?
  case $rc in
    1) die "CRD $crd is not on this cluster: apply bootstrap/ first (README, Step 0)" ;;
    2) die "could not read the cluster's CRDs; stopping rather than guess" ;;
  esac
done
echo "kro and the ACK kinds the graphs use are installed"
resolve_account
echo "account: $ACCOUNT_ID   cluster: $CLUSTER_NAME"
# kro would adopt a namespace that is already there and delete it with the
# instance, so a namespace of that name is used only when the instance made it.
rc=0; resource_exists kc_cluster srabase "$INSTANCE" 2>/dev/null || rc=$?
if [[ $rc -ne 0 ]]; then
  nrc=0; resource_exists kc_cluster namespace "$NAMESPACE" || nrc=$?
  case $nrc in
    0) die "namespace $NAMESPACE exists and no SraBase $INSTANCE made it; it is not this sample's" ;;
    2) die "could not read namespace $NAMESPACE" ;;
  esac
fi
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# render_instance <file>: render, and set spec.project (the Project tag) when the
# file does not carry it already.
render_instance() {
  local f=$1; shift
  render "$f" -e "s|<PROJECT_TAG>|$PROJECT_TAG|g" "$@" > "$WORK/i.yaml"
  grep -q '^  project:' "$WORK/i.yaml" || sed -i "/^spec:\$/a\\  project: \"$PROJECT_TAG\"" "$WORK/i.yaml"
  cat "$WORK/i.yaml"
}

step "1/4 the graphs and the SraBase instance"
kc_cluster apply -f "$K/base-rgd.yaml" -f "$K/gateway-rgd.yaml" -f "$K/run-rgd.yaml"
kc_cluster wait --for=jsonpath='{.status.state}'=Active rgd/sra-base rgd/sra-gateway rgd/sra-run --timeout=120s
render_instance "$K/base.yaml" > "$WORK/base.yaml"
kc_cluster apply -f "$WORK/base.yaml"
wait_active srabase 300
RUN_BUCKET="$(instance_field srabase '{.status.bucketName}')"
REPOSITORY_URI="$(instance_field srabase '{.status.repositoryURI}')"
[[ -n "$RUN_BUCKET" && -n "$REPOSITORY_URI" ]] || die "SraBase $INSTANCE is ACTIVE but its bucketName or repositoryURI is empty"
echo "  run bucket: $RUN_BUCKET   repository: $REPOSITORY_URI"

step "2/4 the tool's code, into the run bucket"
# A fixed timestamp in the zip, so the same handler.py always gives the same
# zip, key and hash, and only a code change makes ACK update the function.
read -r CODE_HASH CODE_SHA256 < <(python3 - "$SAMPLE_DIR/tool/handler.py" "$WORK/tool.zip" <<'PY'
import base64, hashlib, sys, zipfile
src, dst = sys.argv[1:3]
info = zipfile.ZipInfo("handler.py", date_time=(1980, 1, 1, 0, 0, 0))
info.external_attr = 0o644 << 16
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr(info, open(src, "rb").read())
d = hashlib.sha256(open(dst, "rb").read()).digest()
print(d.hex()[:16], base64.b64encode(d).decode())
PY
)
[[ "$CODE_HASH" =~ ^[0-9a-f]{16}$ && -n "$CODE_SHA256" ]] || die "could not zip tool/handler.py"
CODE_KEY="tool/clock-$CODE_HASH.zip"
aws s3 cp "$WORK/tool.zip" "s3://$RUN_BUCKET/$CODE_KEY" --only-show-errors
echo "  s3://$RUN_BUCKET/$CODE_KEY (sha256 $CODE_SHA256)"

step "3/4 the agent image"
IMAGE="$(image_uri "$REPOSITORY_URI")" || exit 1
if aws ecr describe-images --repository-name "${REPOSITORY_URI#*/}" --image-ids "imageTag=${IMAGE##*:}" >/dev/null 2>&1; then
  echo "  $IMAGE is already pushed"
else
  export DOCKER_CONFIG="$WORK/docker"
  aws ecr get-login-password | docker login --username AWS --password-stdin "${IMAGE%%/*}" >/dev/null
  docker build --platform linux/amd64 -t "$IMAGE" "$SAMPLE_DIR"
  docker push "$IMAGE"
fi

step "4/4 the SraGateway instance"
render_instance "$K/gateway.yaml" \
  -e "s|<TOOL_CODE_KEY>|$CODE_KEY|g" -e "s|<TOOL_CODE_SHA256>|$CODE_SHA256|g" > "$WORK/gateway.yaml"
kc_cluster apply -f "$WORK/gateway.yaml"
wait_active sragateway 900
GW_URL="$(instance_field sragateway '{.status.gatewayURL}')"

echo
echo "setup complete: gateway $(instance_field sragateway '{.status.gatewayID}') ($GW_URL), image $IMAGE"
echo "start a run with: ./scripts/run.sh"
