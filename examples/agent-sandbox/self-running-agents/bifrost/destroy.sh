#!/usr/bin/env bash
# Take Bifrost down: the Helm release, then the graph instance, which has ACK
# delete the database (no final snapshot), its subnet group and security group,
# the role and the Pod Identity association, then the namespace. Then read each
# one back, from the cluster and from AWS by name. Leaves kro and ACK alone: they
# come from bootstrap/.
source "$(dirname "$0")/lib.sh"
incomplete=0
fail() { echo "$*" >&2; incomplete=1; }

rc=0; resource_exists kc_cluster namespace "$BIFROST_NAMESPACE" || rc=$?
case $rc in
  2) fail "could not read namespace $BIFROST_NAMESPACE, so nothing in it was removed" ;;
  0)
    namespace_is_ours "$BIFROST_NAMESPACE" "$BF_MANAGED_BY" \
      || die "namespace $BIFROST_NAMESPACE is not labelled app.kubernetes.io/managed-by=$BF_MANAGED_BY, so nothing in it is touched"
    if hc -n "$BIFROST_NAMESPACE" status bifrost >/dev/null 2>&1; then
      if hc -n "$BIFROST_NAMESPACE" uninstall bifrost --wait --timeout 5m >/dev/null; then echo "release bifrost removed"
      else fail "the release bifrost was not removed"; fi
    fi
    if [[ -n "$(kb get bifrostbackend bifrost --ignore-not-found -o name 2>/dev/null)" ]]; then
      echo "deleting the graph (the RDS instance is most of the wait)"
      kb delete bifrostbackend bifrost --wait --timeout=1500s || fail "the graph instance was not deleted in time"
    fi
    if [[ $incomplete -eq 0 ]]; then
      if kc_cluster delete namespace "$BIFROST_NAMESPACE" --wait --timeout=300s >/dev/null; then echo "namespace $BIFROST_NAMESPACE removed"
      else fail "namespace $BIFROST_NAMESPACE was not removed"; fi
    fi
    ;;
esac

# The agent's copy of the key, only in the sample's own namespace.
rc=0; resource_exists kc_cluster namespace "$AGENT_NAMESPACE" || rc=$?
case $rc in
  0) if namespace_is_ours "$AGENT_NAMESPACE" "$SAMPLE"; then
       ka delete secret bifrost-agent-key --ignore-not-found >/dev/null || fail "Secret $AGENT_NAMESPACE/bifrost-agent-key was not removed"
     else fail "namespace $AGENT_NAMESPACE is not labelled app.kubernetes.io/managed-by=$SAMPLE, so its Secret bifrost-agent-key is left"; fi ;;
  2) fail "could not read namespace $AGENT_NAMESPACE, so its Secret bifrost-agent-key may be left" ;;
esac

# The graph definition is this sample's; remove it only when no instance is left.
rc=0; resource_exists kc_cluster rgd bifrost-backend || rc=$?
case $rc in
  0) if left="$(kc_cluster get bifrostbackends -A -o name 2>/dev/null)"; then
       if [[ -z "$left" ]]; then
         kc_cluster delete -f "$BF_DIR/rgd.yaml" >/dev/null || fail "the graph definition bifrost-backend was not removed"
       fi
     else fail "could not list BifrostBackends, so the graph definition bifrost-backend is left"; fi ;;
  2) fail "could not read the graph definition bifrost-backend" ;;
esac

# Read back. A failed lookup is "could not determine", never "gone".
echo "read back:"
k8s_gone() {  # <what> <get arguments...>
  local rc=0; resource_exists kc_cluster "${@:2}" || rc=$?
  case $rc in
    1) echo "  $1 is gone" ;;
    0) fail "  INCOMPLETE: $1 is still present" ;;
    *) fail "  INCOMPLETE: could not determine whether $1 is gone" ;;
  esac
}
k8s_gone "namespace $BIFROST_NAMESPACE" namespace "$BIFROST_NAMESPACE"
k8s_gone "Secret $AGENT_NAMESPACE/bifrost-agent-key" -n "$AGENT_NAMESPACE" secret bifrost-agent-key
# Counts are of IDs, so a paged list still sums to one number.
sg_count() {
  local vpc
  vpc="$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.resourcesVpcConfig.vpcId --output text)" || return 1
  aws ec2 describe-security-groups --filters "Name=group-name,Values=$BF_PREFIX-bifrost-db" "Name=vpc-id,Values=$vpc" \
    "Name=tag:ManagedBy,Values=$BF_MANAGED_BY" --query 'SecurityGroups[].GroupId' --output text | wc -w
}
pia_count() {
  aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --namespace "$BIFROST_NAMESPACE" \
    --service-account bifrost --query 'associations[].associationId' --output text | wc -w
}
aws_verify_absent "RDS instance $BF_PREFIX-bifrost" DBInstanceNotFound -- \
  aws rds describe-db-instances --db-instance-identifier "$BF_PREFIX-bifrost" || true
aws_verify_absent "DB subnet group $BF_PREFIX-bifrost" DBSubnetGroupNotFoundFault -- \
  aws rds describe-db-subnet-groups --db-subnet-group-name "$BF_PREFIX-bifrost" || true
aws_verify_absent "IAM role $BF_PREFIX-bifrost" NoSuchEntity -- aws iam get-role --role-name "$BF_PREFIX-bifrost" || true
aws_verify_none "security group $BF_PREFIX-bifrost-db" -- sg_count || true
aws_verify_none "Pod Identity association $BIFROST_NAMESPACE/bifrost" -- pia_count || true

if [[ $incomplete -eq 0 && $AWS_CLEAN_FAIL -eq 0 ]]; then echo "clean up complete"
else echo "clean up incomplete: see the lines above" >&2; exit 1; fi
