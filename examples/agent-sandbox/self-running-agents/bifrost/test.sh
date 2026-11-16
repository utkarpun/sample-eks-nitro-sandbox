#!/usr/bin/env bash
# Prove Bifrost both ways. Each check prints PASS or FAIL; raw output is kept in
# LOG_DIR. One model call in total (T-B0).
#
#   BQ-3   Bifrost is Ready with its ingress rule in force (kubelet probes get in)
#   CALLER a pod with Bifrost's ServiceAccount is Bifrost's role, not the node's
#   IAM    Bifrost's role may call the one profile, and a model only through it
#   NC-B2  a request with no key, or a wrong key, is refused 401; the agent's key gets past auth
#   T-B0   the agent's key gets a model answer through /anthropic
#   NC-B7  an admin write without the admin login is refused 401, and nothing changed
#   NC-B5  only agent-labelled pods in the agent namespace reach Bifrost on 8080
#   T-B2   a new pod keeps the state in Postgres (the key's token count), config.json
#          wins (a key made only in the database is gone), and with 0 replicas
#          nothing answers, with 1 it answers again
source "$(dirname "$0")/lib.sh" || exit 1
set +e
LOG_DIR="${LOG_DIR:-$BF_DIR/../../../../tmp/bifrost}"; mkdir -p "$LOG_DIR"
MODEL="${BEDROCK_MODEL_ID:-us.anthropic.claude-sonnet-5-5}"
OTHER_MODEL="us.anthropic.claude-haiku-4-5-20251001-v1:0"   # not in the key's allow-list
PROBE_IMAGE="docker.io/maximhq/bifrost:v2.5.1@sha256:5ec9873acaf1687556b6e4dd854b92b539d9debf87a5a683b66338648b84d3c8"
AWSCLI_IMAGE="public.ecr.aws/aws-cli/aws-cli:2.40.3@sha256:33a16c53ea442e918b58df67301ad76a8fb57082c39f7e78753b898c3f3e87c2"
PROBE_RUNTIME_CLASS="${PROBE_RUNTIME_CLASS:-isolated-sandbox}"
PORT="${PORT:-18580}"; B="http://127.0.0.1:$PORT"
PASSES=0; FAILS=0
verdict() { if [[ $2 -eq 0 ]]; then echo "$1 PASS: $3"; PASSES=$((PASSES+1)); else echo "$1 FAIL: $3"; FAILS=$((FAILS+1)); fi; }

# Secrets go to curl through files in a private directory, never the command line.
work="$(mktemp -d)"; chmod 700 "$work"; PF=""
cleanup() { [[ -n "$PF" ]] && kill "$PF" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
sec() { kc -n "$BIFROST_NAMESPACE" get secret "$1" -o jsonpath="{.data.$2}" | python3 -c 'import base64,sys; sys.stdout.write(base64.b64decode(sys.stdin.read()).decode())'; }
printf 'user = "%s:%s"\n' "$(sec bifrost-admin username)" "$(sec bifrost-admin password)" > "$work/admin.curl"
printf 'x-api-key: %s\n' "$(sec bifrost-agent-key key)" > "$work/vk.hdr"
printf 'x-api-key: sk-bf-%s\n' "$(openssl rand -hex 24)" > "$work/wrong.hdr"
body() { printf '{"model":"bedrock/%s","max_tokens":%s,"messages":[{"role":"user","content":"%s"}]}' "$1" "$2" "$3"; }
msg() {  # <header file or -> <body>: prints the HTTP code, keeps the body in $work/out
  local h=(); [[ "$1" != - ]] && h=(-H "@$1")
  curl -s -m 60 -o "$work/out" -w '%{http_code}' -X POST "$B/anthropic/v1/messages" \
    -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' "${h[@]}" -d "$2"
}
admin() { curl -s -m 20 -K "$work/admin.curl" "$@"; }
vks() { admin "$B/api/governance/virtual-keys" | python3 -c 'import json,sys; v=json.load(sys.stdin).get("virtual_keys",[]); print(" ".join(sorted(x.get("name","") for x in v)))'; }
usage() { admin "$B/api/governance/virtual-keys" | python3 -c '
import json,sys
for x in json.load(sys.stdin).get("virtual_keys",[]):
    if x.get("name")=="agent": print((x.get("rate_limit") or {}).get("token_current_usage","none"))'; }
pf_start() {
  kc -n "$BIFROST_NAMESPACE" port-forward svc/bifrost "$PORT:8080" >"$LOG_DIR/port-forward.log" 2>&1 & PF=$!
  for _ in $(seq 20); do curl -s -m 2 -o /dev/null "$B/health" && return 0; sleep 1; done; return 1
}
pf_stop() { [[ -n "$PF" ]] && kill "$PF" 2>/dev/null; wait "$PF" 2>/dev/null; PF=""; }
pod_name() { kc -n "$BIFROST_NAMESPACE" get pod -l app.kubernetes.io/name=bifrost -o jsonpath='{.items[0].metadata.name}'; }
probe() {  # <pod name> <labels json>: prints REACHED or REFUSED from inside the agent namespace
  local n="$1"
  kc -n "$AGENT_NAMESPACE" delete pod "$n" --ignore-not-found --wait >/dev/null 2>&1
  kc -n "$AGENT_NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: { name: $n, labels: $2 }
spec:
  runtimeClassName: $PROBE_RUNTIME_CLASS
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 1000, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: $PROBE_IMAGE
      command: [sh, -c, "r=REFUSED; for i in 1 2 3; do wget -q -T 5 -O /dev/null http://bifrost.$BIFROST_NAMESPACE.svc.cluster.local:8080/health && { r=REACHED; break; }; sleep 3; done; echo \$r > /dev/termination-log"]
      securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
EOF
  kc -n "$AGENT_NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$n" --timeout=300s >/dev/null 2>&1
  # The result comes back in the pod status, so no kubelet log read is needed.
  kc -n "$AGENT_NAMESPACE" get pod "$n" -o jsonpath='{.status.containerStatuses[0].state.terminated.message}' 2>&1
  kc -n "$AGENT_NAMESPACE" delete pod "$n" --ignore-not-found >/dev/null 2>&1
}

# BQ-3
r="$(kc -n "$BIFROST_NAMESPACE" get deploy bifrost -o jsonpath='{.status.readyReplicas}')"
kc -n "$BIFROST_NAMESPACE" get applicationnetworkpolicy bifrost -o name > "$LOG_DIR/BQ-3.log" 2>&1; np=$?
verdict BQ-3 $([[ "$r" == 1 && $np -eq 0 ]]; echo $?) "ready replicas ${r:-0} with ApplicationNetworkPolicy bifrost in force"

# CALLER
kc -n "$BIFROST_NAMESPACE" delete pod bifrost-caller --ignore-not-found --wait >/dev/null 2>&1
kc -n "$BIFROST_NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: { name: bifrost-caller }
spec:
  serviceAccountName: bifrost
  automountServiceAccountToken: false
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 1000, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: caller
      image: $AWSCLI_IMAGE
      args: [sts, get-caller-identity, --query, Arn, --output, text]
      env: [ { name: AWS_EC2_METADATA_DISABLED, value: "true" }, { name: HOME, value: /tmp } ]
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
EOF
kc -n "$BIFROST_NAMESPACE" wait --for=jsonpath='{.status.phase}'=Succeeded pod/bifrost-caller --timeout=300s >/dev/null 2>&1
kc -n "$BIFROST_NAMESPACE" logs bifrost-caller > "$LOG_DIR/CALLER.log" 2>&1
kc -n "$BIFROST_NAMESPACE" delete pod bifrost-caller --ignore-not-found >/dev/null 2>&1
/usr/bin/grep -q ":assumed-role/$NAME_PREFIX-bifrost/" "$LOG_DIR/CALLER.log"
verdict CALLER $? "caller is $(tail -1 "$LOG_DIR/CALLER.log" | sed -E 's/[0-9]{12}/<ACCOUNT_ID>/')"

# IAM: the role's own policy, simulated; no call is made.
acct="$(aws sts get-caller-identity --query Account --output text)"
prof="arn:aws:bedrock:$AWS_REGION:$acct:inference-profile/$MODEL"
fm="arn:aws:bedrock:$AWS_REGION::foundation-model/${MODEL#*.}"
sim() { aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::$acct:role/$NAME_PREFIX-bifrost" \
  --action-names bedrock:InvokeModel --resource-arns "$1" "${@:2}" --query 'EvaluationResults[0].EvalDecision' --output text; }
a="$(sim "$prof")"; b="$(sim "$fm")"
c="$(sim "$fm" --context-entries "ContextKeyName=bedrock:InferenceProfileArn,ContextKeyValues=$prof,ContextKeyType=string")"
echo "profile $a; model alone $b; model through the profile $c" > "$LOG_DIR/IAM.log"
verdict IAM $([[ "$a" == allowed && "$b" == implicitDeny && "$c" == allowed ]]; echo $?) "$(cat "$LOG_DIR/IAM.log")"

pf_start || { echo "error: could not reach Bifrost through port-forward" >&2; exit 1; }

# NC-B2, with the model outside the allow-list, so a broken auth check makes no model call.
n1="$(msg - "$(body "$OTHER_MODEL" 8 hi)")"; n2="$(msg "$work/wrong.hdr" "$(body "$OTHER_MODEL" 8 hi)")"
n3="$(msg "$work/vk.hdr" "$(body "$OTHER_MODEL" 8 hi)")"; cp "$work/out" "$LOG_DIR/NC-B2-control.json"
verdict NC-B2 $([[ "$n1" == 401 && "$n2" == 401 && "$n3" == 403 ]]; echo $?) "no key $n1, wrong key $n2; the agent's key on a model outside its list $n3"

# T-B0: the one model call.
t="$(msg "$work/vk.hdr" "$(body "$MODEL" 8 'Reply with the single word: ok')")"; cp "$work/out" "$LOG_DIR/T-B0.json"
ans="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("".join(c.get("text","") for c in d.get("content",[])).strip())' "$LOG_DIR/T-B0.json" 2>/dev/null)"
verdict T-B0 $([[ "$t" == 200 && -n "$ans" ]]; echo $?) "HTTP $t, answer '$ans'"

# NC-B7
before="$(vks)"
w="$(curl -s -m 20 -o /dev/null -w '%{http_code}' -X POST "$B/api/governance/virtual-keys" -H 'content-type: application/json' -d '{"name":"nc-b7","is_active":true}')"
after="$(vks)"
verdict NC-B7 $([[ "$w" == 401 && -n "$before" && "$before" == "$after" ]]; echo $?) "write without login $w; keys before '$before', after '$after'"

# NC-B5
p1="$(probe bifrost-probe-agent '{ app.kubernetes.io/name: agent }')"
p2="$(probe bifrost-probe-other '{ app.kubernetes.io/name: other }')"
verdict NC-B5 $([[ "$p1" == REACHED && "$p2" == REFUSED ]]; echo $?) "agent-labelled pod $p1, other pod $p2"

# T-B2
c=$(admin -o /dev/null -w '%{http_code}' -X POST "$B/api/governance/virtual-keys" -H 'content-type: application/json' -d '{"name":"db-only","is_active":true}')
sleep 12   # the usage counters reach the store every 10 s
u1="$(usage)"; k1="$(vks)"; old="$(pod_name)"
pf_stop; kc -n "$BIFROST_NAMESPACE" delete pod "$old" --wait >/dev/null
kc -n "$BIFROST_NAMESPACE" rollout status deploy/bifrost --timeout=300s >/dev/null; new="$(pod_name)"
pf_start; u2="$(usage)"; k2="$(vks)"
s="$(msg "$work/vk.hdr" "$(body "$OTHER_MODEL" 8 hi)")"
kc -n "$BIFROST_NAMESPACE" get pod "$new" -o wide > "$LOG_DIR/T-B2-pods.log" 2>&1
echo "db-only create $c; count $u1 -> $u2; keys '$k1' -> '$k2'; pod $old -> $new; key check $s" > "$LOG_DIR/T-B2.log"
pf_stop; kc -n "$BIFROST_NAMESPACE" scale deploy/bifrost --replicas=0 >/dev/null
kc -n "$BIFROST_NAMESPACE" wait --for=delete pod/"$new" --timeout=120s >/dev/null 2>&1
z="$(probe bifrost-probe-agent '{ app.kubernetes.io/name: agent }')"
kc -n "$BIFROST_NAMESPACE" scale deploy/bifrost --replicas=1 >/dev/null
kc -n "$BIFROST_NAMESPACE" rollout status deploy/bifrost --timeout=300s >/dev/null
o="$(probe bifrost-probe-agent '{ app.kubernetes.io/name: agent }')"
echo "replicas 0: $z; replicas 1: $o" >> "$LOG_DIR/T-B2.log"
verdict T-B2 $([[ "$c" == 200 && "$old" != "$new" && "$u1" =~ ^[1-9] && "$u2" == "$u1" && "$k1" == *db-only* && "$k2" != *db-only* && "$s" == 403 && "$z" == REFUSED && "$o" == REACHED ]]; echo $?) "$(tr '\n' ' ' < "$LOG_DIR/T-B2.log")"

echo "$PASSES passed, $FAILS failed"
[[ $FAILS -eq 0 ]]
