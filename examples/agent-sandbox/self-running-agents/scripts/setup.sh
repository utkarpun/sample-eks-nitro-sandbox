#!/usr/bin/env bash
# Set up the self-running-agents sample: the tool door (an AgentCore Gateway with
# a Cedar policy engine and one read-only Lambda tool), the agent's image, IAM
# role and run bucket, and the namespace the agent runs in.
#
# It checks the shared installs and cluster-wide settings it relies on and never
# changes them. Every AWS resource it creates is tagged ManagedBy=self-running-agents
# and reused on a re-run only when it carries that tag. Safe to re-run.
source "$(dirname "$0")/common.sh"
require_commands aws docker python3 sha256sum "$KUBECTL"

step "0/9 checks"
show_context
[[ -n "$CLUSTER_NAME" ]] || die "CLUSTER_NAME is empty; set it in .env"
require_runtime_class
require_network_policy_enforcement
resolve_account
echo "account: $ACCOUNT_ID   cluster: $CLUSTER_NAME   run bucket: $RUN_BUCKET"
TAGS_KV="Key=ManagedBy,Value=$MANAGED_BY"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# role_is_ours <role>: 0 ours, 1 not, 2 could not read, 3 absent
role_is_ours() {
  local rc=0
  aws_exists NoSuchEntity -- aws iam get-role --role-name "$1" || rc=$?
  case $rc in 1) return 3 ;; 2) return 2 ;; esac
  [[ "$(aws iam list-role-tags --role-name "$1" --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)" == "$MANAGED_BY" ]]
}
# ensure_role <role> <trust file> <policy file> [extra sed expressions...]
ensure_role() {
  local role=$1 trust=$2 policy=$3; shift 3
  local rc=0
  role_is_ours "$role" || rc=$?
  case $rc in
    0) echo "  reusing role $role" ;;
    1) die "IAM role $role exists and is not tagged ManagedBy=$MANAGED_BY, so it is not this sample's; set NAME_PREFIX to another value" ;;
    2) die "could not read IAM role $role: $AWS_LAST_ERROR" ;;
    3) render "$trust" > "$WORK/trust.json"
       aws iam create-role --role-name "$role" --assume-role-policy-document "file://$WORK/trust.json" \
         --tags "$TAGS_KV" --query Role.Arn --output text ;;
  esac
  render "$policy" "$@" > "$WORK/policy.json"
  aws iam put-role-policy --role-name "$role" --policy-name "$SAMPLE" --policy-document "file://$WORK/policy.json"
}

step "1/9 namespace $NAMESPACE"
rc=0; namespace_is_ours || rc=$?
case $rc in
  0) echo "  reusing namespace $NAMESPACE" ;;
  1) die "namespace $NAMESPACE exists and is not labelled $NS_LABEL_KEY=$MANAGED_BY; set NAMESPACE to another value" ;;
  2) die "could not read namespace $NAMESPACE" ;;
  3) kc_cluster create namespace "$NAMESPACE"
     kc_cluster label namespace "$NAMESPACE" "$NS_LABEL_KEY=$MANAGED_BY" ;;
esac
render "$SAMPLE_DIR/deploy/admission.yaml" > "$WORK/admission.yaml"
kc_cluster apply -f "$WORK/admission.yaml"

step "2/9 run bucket $RUN_BUCKET"
rc=0; aws_exists 404 -- aws s3api head-bucket --bucket "$RUN_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" || rc=$?
case $rc in
  0) [[ "$(aws s3api get-bucket-tagging --bucket "$RUN_BUCKET" --query "TagSet[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)" == "$MANAGED_BY" ]] \
       || die "bucket $RUN_BUCKET exists and is not tagged ManagedBy=$MANAGED_BY; set RUN_BUCKET to another name"
     echo "  reusing bucket $RUN_BUCKET" ;;
  1) aws s3api create-bucket --bucket "$RUN_BUCKET" --create-bucket-configuration "LocationConstraint=$AWS_REGION" >/dev/null
     aws s3api put-public-access-block --bucket "$RUN_BUCKET" \
       --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
     aws s3api put-bucket-tagging --bucket "$RUN_BUCKET" --tagging "TagSet=[{$TAGS_KV}]"
     echo "  created bucket $RUN_BUCKET (public access blocked, SSE-S3 by default)" ;;
  2) die "could not read bucket $RUN_BUCKET: $AWS_LAST_ERROR" ;;
esac

step "3/9 agent image"
rc=0; aws_exists RepositoryNotFoundException -- aws ecr describe-repositories --repository-names "$ECR_REPOSITORY" || rc=$?
case $rc in
  0) [[ "$(aws ecr list-tags-for-resource --resource-arn "arn:aws:ecr:$AWS_REGION:$ACCOUNT_ID:repository/$ECR_REPOSITORY" --query "tags[?Key=='ManagedBy'].Value | [0]" --output text 2>/dev/null)" == "$MANAGED_BY" ]] \
       || die "ECR repository $ECR_REPOSITORY exists and is not tagged ManagedBy=$MANAGED_BY; set ECR_REPOSITORY to another name" ;;
  1) aws ecr create-repository --repository-name "$ECR_REPOSITORY" --image-scanning-configuration scanOnPush=true \
       --encryption-configuration encryptionType=AES256 --tags "$TAGS_KV" >/dev/null ;;
  2) die "could not read ECR repository $ECR_REPOSITORY: $AWS_LAST_ERROR" ;;
esac
IMAGE="$(image_uri)"
if aws ecr describe-images --repository-name "$ECR_REPOSITORY" --image-ids "imageTag=${IMAGE##*:}" >/dev/null 2>&1; then
  echo "  $IMAGE is already pushed"
else
  export DOCKER_CONFIG="$WORK/docker"
  aws ecr get-login-password | docker login --username AWS --password-stdin "${IMAGE%%/*}" >/dev/null
  docker build --platform linux/amd64 -t "$IMAGE" "$SAMPLE_DIR"
  docker push "$IMAGE"
fi

step "4/9 tool function $TOOL_FUNCTION"
ensure_role "$TOOL_ROLE" "$SAMPLE_DIR/iam/tool-trust.json" "$SAMPLE_DIR/iam/tool-policy.json" \
  -e "s|<TOOL_FUNCTION>|$TOOL_FUNCTION|g"
# The function's log group is created here, so it carries the tag and a one-day
# retention, and the clean up can delete it.
LG_COUNT="$(aws logs describe-log-groups --log-group-name-prefix "$TOOL_LOG_GROUP" \
  --query "length(logGroups[?logGroupName=='$TOOL_LOG_GROUP'])" --output text)" \
  || die "could not read log group $TOOL_LOG_GROUP"
if [[ "$LG_COUNT" == "0" ]]; then
  aws logs create-log-group --log-group-name "$TOOL_LOG_GROUP" --tags "ManagedBy=$MANAGED_BY"
  aws logs put-retention-policy --log-group-name "$TOOL_LOG_GROUP" --retention-in-days 1
fi
python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.write(sys.argv[2],"handler.py"); z.close()' \
  "$WORK/tool.zip" "$SAMPLE_DIR/tool/handler.py"
rc=0; aws_exists ResourceNotFoundException -- aws lambda get-function --function-name "$TOOL_FUNCTION" || rc=$?
case $rc in
  0) [[ "$(aws lambda list-tags --resource "$TOOL_FUNCTION_ARN" --query Tags.ManagedBy --output text 2>/dev/null)" == "$MANAGED_BY" ]] \
       || die "Lambda function $TOOL_FUNCTION exists and is not this sample's"
     aws lambda update-function-code --function-name "$TOOL_FUNCTION" --zip-file "fileb://$WORK/tool.zip" --query LastUpdateStatus --output text ;;
  1) # A new role takes a few seconds before Lambda can assume it.
     for i in 1 2 3 4 5 6 7 8 9 10; do
       aws lambda create-function --function-name "$TOOL_FUNCTION" --runtime python3.13 --handler handler.handler \
         --role "$TOOL_ROLE_ARN" --zip-file "fileb://$WORK/tool.zip" --timeout 10 --memory-size 128 \
         --tags "ManagedBy=$MANAGED_BY" --query FunctionArn --output text 2>"$WORK/err" && break
       [[ $i -eq 10 ]] && die "could not create $TOOL_FUNCTION: $(cat "$WORK/err")"
       sleep 6
     done ;;
  2) die "could not read Lambda function $TOOL_FUNCTION: $AWS_LAST_ERROR" ;;
esac
aws lambda wait function-active-v2 --function-name "$TOOL_FUNCTION"

step "5/9 policy engine $POLICY_ENGINE_NAME"
PE_ID="$(policy_engine_id)" || die "could not list policy engines"
if [[ -z "$PE_ID" ]]; then
  PE_ID="$(aws bedrock-agentcore-control create-policy-engine --name "$POLICY_ENGINE_NAME" \
    --description "Cedar policies for the $SAMPLE gateway" --tags "ManagedBy=$MANAGED_BY" \
    --query policyEngineId --output text)"
fi
PE_ARN="arn:aws:bedrock-agentcore:$AWS_REGION:$ACCOUNT_ID:policy-engine/$PE_ID"
rc=0; tag_is_ours "$PE_ARN" || rc=$?
[[ $rc -eq 0 ]] || die "policy engine $POLICY_ENGINE_NAME ($PE_ID) is not tagged ManagedBy=$MANAGED_BY"
wait_status "policy engine" aws bedrock-agentcore-control get-policy-engine --policy-engine-id "$PE_ID" --query status --output text

step "6/9 gateway $GATEWAY_NAME"
# The role first, with a placeholder policy: the gateway's ARN is known only after
# it exists, and the role's real policy names it.
ensure_role "$GATEWAY_ROLE" "$SAMPLE_DIR/iam/gateway-trust.json" "$SAMPLE_DIR/iam/gateway-policy.json" \
  -e "s|<TOOL_FUNCTION_ARN>|$TOOL_FUNCTION_ARN|g" -e "s|<POLICY_ENGINE_ARN>|$PE_ARN|g" \
  -e "s|<GATEWAY_ARN>|arn:aws:bedrock-agentcore:$AWS_REGION:$ACCOUNT_ID:gateway/$GATEWAY_NAME-*|g"
GW_ID="$(gateway_id)" || die "could not list gateways"
if [[ -z "$GW_ID" ]]; then
  # A new role takes a few seconds before the gateway service can assume it.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    GW_ID="$(aws bedrock-agentcore-control create-gateway --name "$GATEWAY_NAME" --role-arn "$GATEWAY_ROLE_ARN" \
      --protocol-type MCP --authorizer-type AWS_IAM \
      --policy-engine-configuration "{\"arn\":\"$PE_ARN\",\"mode\":\"ENFORCE\"}" \
      --tags "ManagedBy=$MANAGED_BY" --query gatewayId --output text 2>"$WORK/err")" && break
    [[ $i -eq 10 ]] && die "could not create gateway $GATEWAY_NAME: $(cat "$WORK/err")"
    sleep 6
  done
fi
GW_ARN="arn:aws:bedrock-agentcore:$AWS_REGION:$ACCOUNT_ID:gateway/$GW_ID"
rc=0; tag_is_ours "$GW_ARN" || rc=$?
[[ $rc -eq 0 ]] || die "gateway $GATEWAY_NAME ($GW_ID) is not tagged ManagedBy=$MANAGED_BY"
wait_status "gateway" aws bedrock-agentcore-control get-gateway --gateway-identifier "$GW_ID" --query status --output text
GW_URL="$(aws bedrock-agentcore-control get-gateway --gateway-identifier "$GW_ID" --query gatewayUrl --output text)"
GW_HOST="${GW_URL#https://}"; GW_HOST="${GW_HOST%%/*}"
echo "  gateway url: $GW_URL"
# Now the role's policy with the gateway's exact ARN.
render "$SAMPLE_DIR/iam/gateway-policy.json" -e "s|<TOOL_FUNCTION_ARN>|$TOOL_FUNCTION_ARN|g" \
  -e "s|<POLICY_ENGINE_ARN>|$PE_ARN|g" -e "s|<GATEWAY_ARN>|$GW_ARN|g" > "$WORK/gateway-policy.json"
aws iam put-role-policy --role-name "$GATEWAY_ROLE" --policy-name "$SAMPLE" --policy-document "file://$WORK/gateway-policy.json"

step "7/9 tool target $TARGET and the Cedar policy"
TARGET_ID="$(aws bedrock-agentcore-control list-gateway-targets --gateway-identifier "$GW_ID" \
  --query "items[?name=='$TARGET'] | [0].targetId" --output text)"
if [[ -z "$TARGET_ID" || "$TARGET_ID" == "None" ]]; then
  cat > "$WORK/target.json" <<EOF
{"mcp":{"lambda":{"lambdaArn":"$TOOL_FUNCTION_ARN","toolSchema":{"inlinePayload":[
 {"name":"get_time","description":"Read the current time in an IANA time zone. Read-only.",
  "inputSchema":{"type":"object","properties":{"timezone":{"type":"string","description":"IANA time zone, such as UTC"}},"required":["timezone"]}},
 {"name":"get_host_info","description":"Read the tool function's own name, Region and memory size. Read-only.",
  "inputSchema":{"type":"object","properties":{}}}]}}}}
EOF
  TARGET_ID="$(aws bedrock-agentcore-control create-gateway-target --gateway-identifier "$GW_ID" --name "$TARGET" \
    --target-configuration "file://$WORK/target.json" \
    --credential-provider-configurations '[{"credentialProviderType":"GATEWAY_IAM_ROLE"}]' \
    --query targetId --output text)"
fi
wait_status "target $TARGET" aws bedrock-agentcore-control get-gateway-target --gateway-identifier "$GW_ID" \
  --target-id "$TARGET_ID" --query status --output text
POLICY_ID="$(aws bedrock-agentcore-control list-policies --policy-engine-id "$PE_ID" \
  --query "policies[?name=='$POLICY_NAME'] | [0].policyId" --output text)"
if [[ -z "$POLICY_ID" || "$POLICY_ID" == "None" ]]; then
  render "$SAMPLE_DIR/policy/allow-get-time.cedar" -e "s|<AGENT_ROLE_NAME>|$AGENT_ROLE|g" -e "s|<GATEWAY_ARN>|$GW_ARN|g" \
    > "$WORK/policy.cedar"
  python3 -c 'import sys,json; print(json.dumps({"cedar":{"statement":open(sys.argv[1]).read()}}))' "$WORK/policy.cedar" \
    > "$WORK/definition.json"
  POLICY_ID="$(aws bedrock-agentcore-control create-policy --policy-engine-id "$PE_ID" --name "$POLICY_NAME" \
    --validation-mode FAIL_ON_ANY_FINDINGS --definition "file://$WORK/definition.json" --query policyId --output text)"
fi
wait_status "policy $POLICY_NAME" aws bedrock-agentcore-control get-policy --policy-engine-id "$PE_ID" \
  --policy-id "$POLICY_ID" --query status --output text

step "8/9 agent role $AGENT_ROLE and its Pod Identity association"
FM_ARNS="$(aws bedrock get-inference-profile --inference-profile-identifier "$BEDROCK_MODEL_ID" \
  --query 'models[].modelArn' --output text | tr '\t' '\n' | sed 's/.*/"&"/' | paste -sd, -)"
[[ -n "$FM_ARNS" ]] || die "could not read the foundation models behind $BEDROCK_MODEL_ID"
ensure_role "$AGENT_ROLE" "$SAMPLE_DIR/iam/agent-trust.json" "$SAMPLE_DIR/iam/agent-policy.json" \
  -e "s|\"<FOUNDATION_MODEL_ARNS>\"|$FM_ARNS|g" -e "s|<GATEWAY_ARN>|$GW_ARN|g"
ASSOC="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --namespace "$NAMESPACE" \
  --service-account agent --query 'associations[0].associationId' --output text)"
if [[ -z "$ASSOC" || "$ASSOC" == "None" ]]; then
  aws eks create-pod-identity-association --cluster-name "$CLUSTER_NAME" --namespace "$NAMESPACE" \
    --service-account agent --role-arn "$AGENT_ROLE_ARN" --tags "ManagedBy=$MANAGED_BY" \
    --query association.associationId --output text
else
  [[ "$(aws eks describe-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$ASSOC" \
        --query association.roleArn --output text)" == "$AGENT_ROLE_ARN" ]] \
    || die "the Pod Identity association for $NAMESPACE/agent points at another role"
  echo "  reusing association $ASSOC"
fi

step "9/9 the agent's ServiceAccount, egress rule and configuration"
render "$SAMPLE_DIR/deploy/serviceaccount.yaml" > "$WORK/sa.yaml"
render "$SAMPLE_DIR/deploy/egress.yaml" -e "s|<GATEWAY_HOST>|$GW_HOST|g" > "$WORK/egress.yaml"
python3 -c 'import sys,json; print(json.dumps({"mcpServers":{"gateway":{"type":"stdio","command":"/opt/mcp/bin/mcp-proxy-for-aws-cli",
  "args":[sys.argv[1],"--service","bedrock-agentcore","--region",sys.argv[2],"--disable-telemetry","--log-level","WARNING"]}}},indent=2))' \
  "$GW_URL" "$AWS_REGION" > "$WORK/mcp.json"
cp "$SAMPLE_DIR/agent/prompt.txt" "$WORK/prompt.txt"
kc create configmap agent-config --from-file="$WORK/mcp.json" --from-file="$WORK/prompt.txt" \
  --dry-run=client -o yaml > "$WORK/cm.yaml"
kc apply -f "$WORK/sa.yaml" -f "$WORK/egress.yaml" -f "$WORK/cm.yaml"

echo
echo "setup complete: gateway $GW_ID ($GW_URL), image $IMAGE"
echo "start a run with: ./scripts/run.sh"
