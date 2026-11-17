# kro: the sample's own resources as three graphs

Every resource that belongs to the sample, in AWS and in the cluster, is defined here as a
kro ResourceGraphDefinition (a graph). A graph is a custom Kubernetes kind: you apply one
instance of it, and kro makes every resource the graph lists, in the order their references
imply. ACK makes the AWS ones. Both controllers come from [`bootstrap/`](../bootstrap/README.md).

| Graph | Instance | What it makes |
|---|---|---|
| `SraBase` (`base-rgd.yaml`) | `base.yaml`, one per cluster | The namespace `sra`, the run bucket `sra-runs-<account id>-<Region>` (public access blocked) and the ECR repository `sra` (scan on push) |
| `SraGateway` (`gateway-rgd.yaml`) | `gateway.yaml`, one per cluster | The AgentCore Gateway and its Cedar policy ([AGENTCORE.md](AGENTCORE.md)), the tool function, the agent's role and Pod Identity, the admission policy, the egress rule and the agent's ConfigMap |
| `SraRun` (`run-rgd.yaml`) | [`deploy/run.yaml`](../deploy/README.md), one per run | The run's Job |

`scripts/setup.sh` applies `SraGateway` only after it uploads the tool's code, because ACK's
Lambda function reads its code from S3 when it is created. `run.sh` makes one `SraRun` per
run. Bifrost has a fourth graph of its own, in [`bifrost/rgd.yaml`](../bifrost/README.md).

## What SraGateway makes

- **Three IAM roles**: `sra-agent` (the pod's), `sra-gateway` (the gateway's) and `sra-tool`
  (the function's).
- **The tool**: the Lambda function `sra-clock` and its log group (one-day retention), from
  [`tool/`](../tool/README.md).
- **AgentCore**: the policy engine `sra_policy` and its one policy, and the gateway `sra-gw`
  with its target `clock` ([AGENTCORE.md](AGENTCORE.md)).
- **The agent's identity**: the ServiceAccount `agent` and its Pod Identity association with
  `sra-agent`.
- **Admission**: a `ValidatingAdmissionPolicy` and its binding (cluster-scoped, named for the
  namespace and matching only it).
- **Egress**: the `ApplicationNetworkPolicy` `agent-egress`.
- **The agent's ConfigMap** `agent-config`: the bridge's `mcp.json` (the gateway's URL) and
  the prompt.

Each AWS resource that takes tags is tagged `Project=<PROJECT_TAG>` (`PROJECT_TAG` in
`.env`, default `self-running-agents`) and `ManagedBy=sra`; the target and the Cedar policy
take none. The names are fixed in `base.yaml` and `gateway.yaml` and match `bootstrap/`'s
`prefix`, which scopes the ACK role to them. ACK makes each resource by its name and fails
on a name that is taken (the graphs configure no adoption), so it never takes over another
demo's role.

## The agent's boundaries

**Identity.** `sra-agent` may call `bedrock-agentcore:InvokeGateway` on the one gateway and
`s3:PutObject` under `runs/` in the run bucket. It has no Bedrock statement. It trusts only
Pod Identity sessions tagged with this cluster, this namespace and the `agent`
ServiceAccount (EKS Best Practices Guide,
[*Identity and Access Management*](https://docs.aws.amazon.com/eks/latest/best-practices/identity-and-access-management.html)).

**No Kubernetes API token.** The ServiceAccount and the pod set
`automountServiceAccountToken: false` (same page), so code in the pod holds no credential
for the Kubernetes API. The only token in the pod is the one EKS Pod Identity projects for
its node agent
(`/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token`, audience
`pods.eks.amazonaws.com`), which the Pod Identity Agent exchanges for the role's
credentials; the Kubernetes API should refuse it, since its audience is not the API's
(reasoned, not tested). A pod that mounts a token on purpose, as a projected volume, still
gets one.

**Admission.** The policy refuses any pod in the namespace that does not turn token
automount off or does not run in `isolated-sandbox`. It checks only those two fields, so add
rules, or a policy engine, before anyone but you creates pods in the namespace.

**Egress.** `agent-egress` selects the pods labelled `app.kubernetes.io/name: agent`, which
isolates them, and allows DNS (port 53 to any address), the Pod Identity agent at
`169.254.170.23:80`, Bifrost's pods in `bfx` on TCP 8080, and TCP 443 to two names: the
gateway's host and the run bucket's host. The EKS Best Practices Guide starts from a
deny-all policy for every pod in the namespace ([*Network
security*](https://docs.aws.amazon.com/eks/latest/best-practices/network-security.html));
this rule applies that deny to the agent pods only. On an agent-sandbox `SandboxTemplate`,
the controller's default policy would open what this rule closes: set
`networkPolicyManagement: Unmanaged` or carry these rules in the template's own
`networkPolicy`.

## What SraRun makes

One Job in `sra`, the run's only child: Claude Code in the image from the `SraBase`
repository, with `runtimeClassName: isolated-sandbox`, a read-only root filesystem, 1 vCPU
and 2Gi, the run limits in [`agent/`](../agent/README.md#changing-it), and
`karpenter.sh/do-not-disrupt`, because Auto Mode consolidation otherwise evicts a sandbox pod
mid-run. Its model calls go to Bifrost (`ANTHROPIC_BASE_URL`) with the Secret
`bifrost-agent-key`, which Bifrost's graph makes in `sra`.

Two rules, because kro restores a child that was deleted:

- **Delete the `SraRun`, never its Job alone.** kro makes a deleted Job again, which starts
  a second run. Deleting the `SraRun` deletes the Job but not its pod
  ([kro#1330](https://github.com/kubernetes-sigs/kro/issues/1330)), so delete the pod after.
- **No `ttlSecondsAfterFinished`.** A TTL delete is a Job deleted alone.

Never edit an instance either: a Job's pod template is immutable, and kro reports a changed
immutable field as an error. One instance per run.

## Good to know

- **Order.** kro orders each graph by its references; the order of `SraGateway` is in the
  comment at the top of `gateway-rgd.yaml`. kro deletes in reverse; `SraBase` deletes the
  namespace last.
- **Changing a graph.** Never make a breaking schema change once the graph's CRD exists: one
  that removes or narrows what an instance may hold, such as removing a field, changing a
  type, adding a required field with no default, making a field required, or adding or
  tightening a pattern, enum or limit ([kro's full list](https://github.com/kubernetes-sigs/kro/blob/v0.10.0/pkg/graph/crd/compat/schema.go)).
  kro refuses the change and the instance stops reconciling, deletion included. Run
  `scripts/cleanup.sh` first.
- **A setup that never reaches ACTIVE.** `setup.sh` then prints each ACK object's state. One
  cause is IAM propagation ([`AGENTCORE.md`](AGENTCORE.md#things-to-know)). Run `cleanup.sh`,
  then `setup.sh` again.
- **Changing the prompt.** Edit the `prompt` field in `gateway.yaml`, which the graph puts
  in the agent's ConfigMap, then run `setup.sh`. `agent/prompt.txt` is a reference copy;
  editing it rebuilds the image but not the prompt.
