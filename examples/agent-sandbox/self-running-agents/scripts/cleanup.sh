#!/usr/bin/env bash
# Remove everything setup.sh and run.sh created, and say what could not be
# removed. Order: the runs and the namespace's objects, the Pod Identity
# association and the agent role, the Cedar policy, the target, the gateway and
# the policy engine, the gateway role, the tool function, its log group and role,
# the image repository, the run bucket, the admission policy, and the namespace
# last. Each AWS delete is read back; a read that fails is "could not determine",
# never "gone". It never touches a shared install or a cluster-wide setting.
source "$(dirname "$0")/common.sh" || exit 1
set +e
require_commands aws python3 "$KUBECTL"
show_context
resolve_account
[[ -n "$CLUSTER_NAME" ]] || die "CLUSTER_NAME is empty; set it in .env (the Pod Identity association is on that cluster)"
FAIL=0
fail() { echo "  INCOMPLETE: $*" >&2; FAIL=$((FAIL + 1)); }

step "1/8 the runs and the namespace's objects"
rc=0; namespace_is_ours || rc=$?
NS_OURS=$rc
case $rc in
  0) kc delete job -l app.kubernetes.io/name=agent --ignore-not-found --wait=true --timeout=120s || fail "agent jobs"
     kc delete configmap agent-config --ignore-not-found || fail "configmap agent-config"
     kc delete applicationnetworkpolicy agent-egress --ignore-not-found || fail "egress rule"
     kc delete serviceaccount agent --ignore-not-found || fail "serviceaccount agent" ;;
  1) fail "namespace $NAMESPACE is not labelled $NS_LABEL_KEY=$MANAGED_BY; nothing in it was touched" ;;
  2) fail "could not read namespace $NAMESPACE" ;;
  3) echo "  namespace $NAMESPACE is already gone" ;;
esac

step "2/8 Pod Identity association and agent role"
if [[ $NS_OURS -eq 1 || $NS_OURS -eq 2 ]]; then fail "namespace $NAMESPACE is not confirmed the sample's; its Pod Identity association was left in place"; else
  ASSOC="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --namespace "$NAMESPACE" \
    --service-account agent --query 'associations[0].associationId' --output text 2>&1)"
  if [[ $? -ne 0 ]]; then fail "could not list Pod Identity associations: $ASSOC"
  elif [[ "$ASSOC" != "None" && -n "$ASSOC" ]]; then
    # Only the association that points at the sample's role, as setup.sh checks.
    if [[ "$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$ASSOC" \
          --query association.roleArn --output text)" != "$AGENT_ROLE_ARN" ]]; then
      fail "the Pod Identity association $ASSOC for $NAMESPACE/agent points at another role (or could not be read); left in place"
    else
      aws eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$ASSOC" >/dev/null || fail "association $ASSOC"
      aws_verify_absent "Pod Identity association $ASSOC" ResourceNotFoundException -- \
        aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$ASSOC"
    fi
  fi
fi

# delete_role <role>: only a role tagged as the sample's
delete_role() {
  local role=$1 rc=0
  aws_exists NoSuchEntity -- aws iam get-role --role-name "$role" || rc=$?
  case $rc in
    1) echo "  role $role is already gone"; return ;;
    2) fail "could not read role $role: $AWS_LAST_ERROR"; return ;;
  esac
  [[ "$(aws iam list-role-tags --role-name "$role" --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text)" == "$MANAGED_BY" ]] \
    || { fail "role $role is not tagged ManagedBy=$MANAGED_BY; left in place"; return; }
  aws iam delete-role-policy --role-name "$role" --policy-name "$SAMPLE" 2>/dev/null
  aws iam delete-role --role-name "$role" || fail "role $role"
  aws_verify_absent "role $role" NoSuchEntity -- aws iam get-role --role-name "$role"
}
delete_role "$AGENT_ROLE"

step "3/8 gateway, its target and policy, and the policy engine"
GW_ID="$(gateway_id)"; [[ $? -ne 0 ]] && fail "could not list gateways"
PE_ID="$(policy_engine_id)"; [[ $? -ne 0 ]] && fail "could not list policy engines"
if [[ -n "$PE_ID" ]]; then
  PE_ARN="arn:aws:bedrock-agentcore:$AWS_REGION:$ACCOUNT_ID:policy-engine/$PE_ID"
  if tag_is_ours "$PE_ARN"; then
    for pid in $(aws bedrock-agentcore-control list-policies --policy-engine-id "$PE_ID" --query 'policies[].policyId' --output text); do
      aws bedrock-agentcore-control delete-policy --policy-engine-id "$PE_ID" --policy-id "$pid" >/dev/null || fail "policy $pid"
    done
  else fail "policy engine $PE_ID is not tagged as the sample's; left in place"; PE_ID=""; fi
fi
if [[ -n "$GW_ID" ]]; then
  if tag_is_ours "arn:aws:bedrock-agentcore:$AWS_REGION:$ACCOUNT_ID:gateway/$GW_ID"; then
    for tid in $(aws bedrock-agentcore-control list-gateway-targets --gateway-identifier "$GW_ID" --query 'items[].targetId' --output text); do
      aws bedrock-agentcore-control delete-gateway-target --gateway-identifier "$GW_ID" --target-id "$tid" >/dev/null || fail "target $tid"
    done
    for _ in $(seq 1 30); do
      [[ "$(aws bedrock-agentcore-control list-gateway-targets --gateway-identifier "$GW_ID" --query 'length(items)' --output text)" == "0" ]] && break
      sleep 5
    done
    aws bedrock-agentcore-control delete-gateway --gateway-identifier "$GW_ID" >/dev/null || fail "gateway $GW_ID"
    for _ in $(seq 1 30); do
      aws_exists ResourceNotFoundException -- aws bedrock-agentcore-control get-gateway --gateway-identifier "$GW_ID"; [[ $? -ne 0 ]] && break
      sleep 5
    done
    aws_verify_absent "gateway $GW_ID" ResourceNotFoundException -- aws bedrock-agentcore-control get-gateway --gateway-identifier "$GW_ID"
  else fail "gateway $GW_ID is not tagged as the sample's; left in place"; fi
else echo "  gateway $GATEWAY_NAME is already gone"; fi
if [[ -n "$PE_ID" ]]; then
  for _ in $(seq 1 30); do
    [[ "$(aws bedrock-agentcore-control list-policies --policy-engine-id "$PE_ID" --query 'length(policies)' --output text)" == "0" ]] && break
    sleep 5
  done
  aws bedrock-agentcore-control delete-policy-engine --policy-engine-id "$PE_ID" >/dev/null || fail "policy engine $PE_ID"
  for _ in $(seq 1 30); do
    aws_exists ResourceNotFoundException -- aws bedrock-agentcore-control get-policy-engine --policy-engine-id "$PE_ID"; [[ $? -ne 0 ]] && break
    sleep 5
  done
  aws_verify_absent "policy engine $PE_ID" ResourceNotFoundException -- aws bedrock-agentcore-control get-policy-engine --policy-engine-id "$PE_ID"
else echo "  policy engine $POLICY_ENGINE_NAME is already gone"; fi
delete_role "$GATEWAY_ROLE"

step "4/8 tool function, its log group and role"
rc=0; aws_exists ResourceNotFoundException -- aws lambda get-function --function-name "$TOOL_FUNCTION" || rc=$?
case $rc in
  0) if [[ "$(aws lambda list-tags --resource "$TOOL_FUNCTION_ARN" --query Tags.ManagedBy --output text)" == "$MANAGED_BY" ]]; then
       aws lambda delete-function --function-name "$TOOL_FUNCTION" >/dev/null || fail "function $TOOL_FUNCTION"
       aws_verify_absent "function $TOOL_FUNCTION" ResourceNotFoundException -- aws lambda get-function --function-name "$TOOL_FUNCTION"
     else fail "function $TOOL_FUNCTION is not tagged as the sample's; left in place"; fi ;;
  1) echo "  function $TOOL_FUNCTION is already gone" ;;
  2) fail "could not read function $TOOL_FUNCTION: $AWS_LAST_ERROR" ;;
esac
LG="$(aws logs describe-log-groups --log-group-name-prefix "$TOOL_LOG_GROUP" \
  --query "length(logGroups[?logGroupName=='$TOOL_LOG_GROUP'])" --output text)"
if [[ "$LG" == "1" ]]; then
  if [[ "$(aws logs list-tags-for-resource --resource-arn "arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:$TOOL_LOG_GROUP" --query tags.ManagedBy --output text)" == "$MANAGED_BY" ]]; then
    aws logs delete-log-group --log-group-name "$TOOL_LOG_GROUP" || fail "log group $TOOL_LOG_GROUP"
    LG="$(aws logs describe-log-groups --log-group-name-prefix "$TOOL_LOG_GROUP" --query "length(logGroups[?logGroupName=='$TOOL_LOG_GROUP'])" --output text)"
    [[ "$LG" == "0" ]] && echo "  log group $TOOL_LOG_GROUP is gone" || fail "log group $TOOL_LOG_GROUP still reads $LG"
  else fail "log group $TOOL_LOG_GROUP is not tagged as the sample's; left in place"; fi
elif [[ "$LG" == "0" ]]; then echo "  log group $TOOL_LOG_GROUP is already gone"
else fail "could not read log group $TOOL_LOG_GROUP"; fi
delete_role "$TOOL_ROLE"

step "5/8 image repository $ECR_REPOSITORY"
rc=0; aws_exists RepositoryNotFoundException -- aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" || rc=$?
case $rc in
  0) if [[ "$(aws ecr list-tags-for-resource --resource-arn "arn:aws:ecr:$AWS_REGION:$ACCOUNT_ID:repository/$ECR_REPOSITORY" --query "tags[?Key=='ManagedBy'].Value | [0]" --output text)" == "$MANAGED_BY" ]]; then
       aws ecr delete-repository --repository-name "$ECR_REPOSITORY" --force >/dev/null || fail "repository $ECR_REPOSITORY"
       aws_verify_absent "repository $ECR_REPOSITORY" RepositoryNotFoundException -- aws ecr describe-repositories --repository-names "$ECR_REPOSITORY"
     else fail "repository $ECR_REPOSITORY is not tagged as the sample's; left in place"; fi ;;
  1) echo "  repository $ECR_REPOSITORY is already gone" ;;
  2) fail "could not read repository $ECR_REPOSITORY: $AWS_LAST_ERROR" ;;
esac

step "6/8 run bucket $RUN_BUCKET"
rc=0; aws_exists 404 -- aws s3api head-bucket --bucket "$RUN_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" || rc=$?
case $rc in
  0) if [[ "$(aws s3api get-bucket-tagging --bucket "$RUN_BUCKET" --query "TagSet[?Key=='ManagedBy'].Value | [0]" --output text)" == "$MANAGED_BY" ]]; then
       aws s3 rm "s3://$RUN_BUCKET" --recursive --only-show-errors || fail "objects in $RUN_BUCKET"
       aws s3api delete-bucket --bucket "$RUN_BUCKET" || fail "bucket $RUN_BUCKET"
       aws_verify_absent "bucket $RUN_BUCKET" 404 -- aws s3api head-bucket --bucket "$RUN_BUCKET"
     else fail "bucket $RUN_BUCKET is not tagged as the sample's; left in place"; fi ;;
  1) echo "  bucket $RUN_BUCKET is already gone" ;;
  2) fail "could not read bucket $RUN_BUCKET: $AWS_LAST_ERROR" ;;
esac

step "7/8 admission policy"
for kind in validatingadmissionpolicybinding validatingadmissionpolicy; do
  name="$SAMPLE-$NAMESPACE"
  lbl="$(kc_cluster get "$kind" "$name" --ignore-not-found -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}')"
  if [[ $? -ne 0 ]]; then fail "could not read $kind $name"
  elif [[ "$lbl" == "$MANAGED_BY" ]]; then kc_cluster delete "$kind" "$name" || fail "$kind $name"
  elif [[ -n "$lbl" ]]; then fail "$kind $name is not the sample's; left in place"
  else echo "  $kind $name is gone"; fi
done

step "8/8 namespace $NAMESPACE"
FAIL=$((FAIL + AWS_CLEAN_FAIL))
if [[ $NS_OURS -eq 0 && $FAIL -eq 0 ]]; then
  kc_cluster delete namespace "$NAMESPACE" --wait=true --timeout=300s || fail "namespace $NAMESPACE"
  rc=0; resource_exists kc_cluster namespace "$NAMESPACE" || rc=$?
  [[ $rc -eq 1 ]] && echo "  namespace $NAMESPACE is gone" || fail "namespace $NAMESPACE is still there or could not be read"
elif [[ $NS_OURS -eq 0 ]]; then
  echo "  namespace $NAMESPACE kept, because $FAIL step(s) above did not finish; re-run this script"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "clean up complete"; exit 0; fi
echo "clean up INCOMPLETE: $FAIL item(s) above" >&2; exit 1
