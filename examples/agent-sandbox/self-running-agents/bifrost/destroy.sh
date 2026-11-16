#!/usr/bin/env bash
# Take Bifrost down: the Helm release, then the graph instance, which has ACK
# delete the database (no final snapshot), its subnet group and security group,
# the role and the Pod Identity association. Then read each one back from AWS by
# name. Leaves kro and the ACK controllers alone: they are a shared install.
source "$(dirname "$0")/lib.sh"
incomplete=0

if [[ -n "$(kc get namespace "$BIFROST_NAMESPACE" --ignore-not-found -o name)" ]]; then
  namespace_is_ours "$BIFROST_NAMESPACE" || die "namespace $BIFROST_NAMESPACE is not labelled app.kubernetes.io/managed-by=$MANAGED_BY, so nothing in it is touched"
  if hc -n "$BIFROST_NAMESPACE" status bifrost >/dev/null 2>&1; then
    hc -n "$BIFROST_NAMESPACE" uninstall bifrost --wait --timeout 5m >/dev/null && echo "release bifrost removed"
  fi
  if [[ -n "$(kc -n "$BIFROST_NAMESPACE" get bifrostbackend bifrost --ignore-not-found -o name 2>/dev/null)" ]]; then
    echo "deleting the graph (RDS takes about 5 to 10 minutes)"
    kc -n "$BIFROST_NAMESPACE" delete bifrostbackend bifrost --wait --timeout=1500s \
      || { echo "the graph instance was not deleted in time" >&2; incomplete=1; }
  fi
  [[ $incomplete -eq 0 ]] && kc delete namespace "$BIFROST_NAMESPACE" --wait --timeout=300s >/dev/null && echo "namespace $BIFROST_NAMESPACE removed"
fi
kc -n "$AGENT_NAMESPACE" delete secret bifrost-agent-key --ignore-not-found >/dev/null 2>&1

# The graph definition is this sample's; remove it only when no instance is left.
if [[ -z "$(kc get bifrostbackends -A -o name 2>/dev/null)" ]]; then
  kc delete -f "$BF_DIR/rgd.yaml" -f "$BF_DIR/kro-rbac.yaml" --ignore-not-found >/dev/null 2>&1
fi

# Read back from AWS. A failed lookup is "could not determine", never "gone".
gone() {  # <what> <command...>: the command prints the count still there
  local n; n="$("${@:2}" 2>/dev/null)" || { echo "$1: could not determine"; incomplete=1; return; }
  if [[ "$n" == 0 ]]; then echo "$1: gone"; else echo "$1: still there ($n)"; incomplete=1; fi
}
# A list call pages, and a --query runs once per page, so each name is looked up by itself.
left_by_name() {  # <not-found code> <aws command...>: 1 when it is there, 0 when AWS says not found
  local e
  if e="$("${@:2}" 2>&1)"; then echo 1
  elif [[ "$e" == *"$1"* ]]; then echo 0
  else return 1; fi
}
db_left() { left_by_name DBInstanceNotFound aws rds describe-db-instances --db-instance-identifier "$NAME_PREFIX-bifrost"; }
sng_left() { left_by_name DBSubnetGroupNotFoundFault aws rds describe-db-subnet-groups --db-subnet-group-name "$NAME_PREFIX-bifrost"; }
sg_left() { aws ec2 describe-security-groups --filters "Name=group-name,Values=$NAME_PREFIX-bifrost-db" --query 'length(SecurityGroups)' --output text; }
role_left() { left_by_name NoSuchEntity aws iam get-role --role-name "$NAME_PREFIX-bifrost"; }
pia_left() { aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --namespace "$BIFROST_NAMESPACE" --service-account bifrost --query 'length(associations)' --output text; }
gone "RDS instance $NAME_PREFIX-bifrost" db_left
gone "DB subnet group $NAME_PREFIX-bifrost" sng_left
gone "security group $NAME_PREFIX-bifrost-db" sg_left
gone "IAM role $NAME_PREFIX-bifrost" role_left
gone "Pod Identity association $BIFROST_NAMESPACE/bifrost" pia_left
[[ $incomplete -eq 0 ]] && echo "clean up complete" || { echo "clean up incomplete: see the lines above" >&2; exit 1; }
