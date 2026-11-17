#!/usr/bin/env bash
# Remove everything setup.sh and run.sh created, and say what could not be
# removed. Every AWS object is ACK's, made by a kro instance, so the clean up
# deletes the instances and kro deletes their objects in reverse order: the
# SraGateway instance first, then the run bucket's objects (data, which ACK does
# not delete), then the SraBase instance (the namespace goes last), then the two
# graphs. It then reads AWS and the cluster back; a read that fails is "could
# not determine", never "gone". It never touches a shared install, a cluster-wide
# setting or the controllers from bootstrap/.
source "$(dirname "$0")/common.sh" || exit 1
set +e
require_commands aws "$KUBECTL"
show_context
resolve_account
[[ -n "$CLUSTER_NAME" ]] || die "CLUSTER_NAME is empty; set it in .env (the Pod Identity association is on that cluster)"
FAIL=0
fail() { echo "  INCOMPLETE: $*" >&2; FAIL=$((FAIL + 1)); }

# instance_gone <kind>: 0 gone (or its kind is not on the cluster), 1 present, 2 could not read
instance_gone() {
  local rc=0
  resource_exists kc_cluster crd "${1}s.kro.run" || rc=$?
  case $rc in 1) return 0 ;; 2) return 2 ;; esac
  rc=0; resource_exists kc_cluster "$1" "$INSTANCE" || rc=$?
  case $rc in 0) return 1 ;; 1) return 0 ;; *) return 2 ;; esac
}
# delete_instance <kind> <seconds>
delete_instance() {
  local rc=0
  instance_gone "$1" || rc=$?
  case $rc in
    0) echo "  $1 $INSTANCE is already gone"; return 0 ;;
    2) fail "could not read $1 $INSTANCE"; return 1 ;;
  esac
  kc_cluster delete "$1" "$INSTANCE" --wait=true --timeout="$2s" || true
  rc=0; instance_gone "$1" || rc=$?
  [[ $rc -eq 0 ]] && { echo "  $1 $INSTANCE is gone"; return 0; }
  fail "$1 $INSTANCE is still there after $2 s, or could not be read (kubectl$CTX_ARG get $1 $INSTANCE -o yaml shows why)"
  return 1
}

step "1/5 the runs"
BASE_GONE=0; instance_gone srabase || BASE_GONE=$?
if [[ $BASE_GONE -eq 1 ]]; then
  kc delete job -l app.kubernetes.io/name=agent --ignore-not-found --wait=true --timeout=120s || fail "agent jobs"
else echo "  no SraBase $INSTANCE, so no namespace of the sample's to clean"; fi

step "2/5 the SraGateway instance"
delete_instance sragateway 900; GW_OK=$?

step "3/5 the run bucket's objects"
RUN_BUCKET=""
[[ $BASE_GONE -eq 1 ]] && RUN_BUCKET="$(instance_field srabase '{.status.bucketName}')"
if [[ -n "$RUN_BUCKET" ]]; then
  aws s3 rm "s3://$RUN_BUCKET" --recursive --only-show-errors && echo "  $RUN_BUCKET is empty" || fail "objects in $RUN_BUCKET"
else echo "  no bucket reported by SraBase $INSTANCE"; fi

step "4/5 the SraBase instance"
if [[ $GW_OK -eq 0 ]]; then delete_instance srabase 600; BASE_OK=$?
else fail "SraBase $INSTANCE kept, because the SraGateway instance is not gone; re-run this script"; BASE_OK=1; fi

step "5/5 the graphs"
if [[ $GW_OK -eq 0 && $BASE_OK -eq 0 ]]; then
  kc_cluster delete rgd sra-gateway sra-base --ignore-not-found --wait=true --timeout=120s || fail "the graphs"
  # kro leaves an instance kind's CRD behind when its graph is deleted.
  kc_cluster delete crd sragateways.kro.run srabases.kro.run --ignore-not-found || fail "the instance CRDs"
else fail "the graphs kept, because an instance is not gone"; fi

step "read back"
for r in rgd/sra-gateway rgd/sra-base crd/sragateways.kro.run crd/srabases.kro.run namespace/"$NAMESPACE" \
         validatingadmissionpolicy/"$SAMPLE-$NAMESPACE" validatingadmissionpolicybinding/"$SAMPLE-$NAMESPACE"; do
  rc=0; resource_exists kc_cluster "$r" || rc=$?
  case $rc in
    1) echo "  $r is gone" ;;
    0) fail "$r is still there" ;;
    *) fail "could not read $r" ;;
  esac
done
LG=/aws/lambda/$PREFIX-clock
aws_verify_absent "function $PREFIX-clock" ResourceNotFoundException -- aws lambda get-function --function-name "$PREFIX-clock"
for role in agent gateway tool; do
  aws_verify_absent "role $PREFIX-$role" NoSuchEntity -- aws iam get-role --role-name "$PREFIX-$role"
done
aws_verify_absent "repository $PREFIX" RepositoryNotFoundException -- aws ecr describe-repositories --repository-names "$PREFIX"
aws_verify_absent "bucket $PREFIX-runs-$ACCOUNT_ID-$AWS_REGION" 404 -- aws s3api head-bucket --bucket "$PREFIX-runs-$ACCOUNT_ID-$AWS_REGION"
aws_verify_none "log group $LG" -- aws logs describe-log-groups --log-group-name-prefix "$LG" \
  --query "length(logGroups[?logGroupName=='$LG'])" --output text
aws_verify_none "gateway $PREFIX-gw" -- aws bedrock-agentcore-control list-gateways \
  --query "length(items[?name=='$PREFIX-gw'])" --output text
aws_verify_none "policy engine ${PREFIX}_policy" -- aws bedrock-agentcore-control list-policy-engines \
  --query "length(policyEngines[?name=='${PREFIX}_policy'])" --output text
aws_verify_none "Pod Identity association for $NAMESPACE/agent" -- aws eks list-pod-identity-associations \
  --cluster-name "$CLUSTER_NAME" --namespace "$NAMESPACE" --service-account agent --query 'length(associations)' --output text

FAIL=$((FAIL + AWS_CLEAN_FAIL))
echo
if [[ $FAIL -eq 0 ]]; then echo "clean up complete"; exit 0; fi
echo "clean up INCOMPLETE: $FAIL item(s) above" >&2; exit 1
