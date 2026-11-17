# Self-running agents: a short-lived agent whose tools come only through an AgentCore Gateway

This blueprint runs an agent the way a self-running repository agent would: one headless
Claude Code run per job, in an isolated Nitro sandbox, started for the job and gone after
it, with everything it produced copied out of the pod before it exits. The agent holds no
tool of its own. Its only tools come through an Amazon Bedrock AgentCore Gateway, which
asks a Cedar policy engine about every call. Every tool call that leaves the pod is decided
outside the sandbox by a policy you can read. What the agent can do inside the pod is
decided by its own Claude Code configuration (`agent/settings.json` and the flags in
`agent/run.sh`): the built-in tools are off (`--tools ""`) and settings.json allows only
the gateway. The policy engine's mode (`ENFORCE`) is a field on the gateway; whoever holds
`bedrock-agentcore:UpdateGateway` can set it to `LOG_ONLY` or remove the engine, so that
permission is the real control. The agent's role has no such permission. Its gaps are listed under [What this blueprint does not limit](#what-this-blueprint-does-not-limit).

Every piece of infrastructure is code. The AWS resources and the sample's Kubernetes
objects are kro graphs (`kro/`), whose AWS objects the AWS Controllers for Kubernetes
(ACK) create; both controllers are EKS managed capabilities that a small Terraform stack
(`bootstrap/`) turns on. The scripts only apply the graphs, wait, upload the tool's code and
push the agent image, run, check and delete.

The agent's model calls go to [Bifrost](bifrost/README.md), an in-cluster model gateway
that calls Amazon Bedrock with a role of its own; the agent's role has no Bedrock
permission. Bifrost is set up after the sample (Step 2b).

Beyond the cluster, a run costs the Bedrock tokens the agent spends through Bifrost, the gateway's tool
calls, one Lambda invocation per tool call, and the node EKS Auto Mode launches for the
sandbox pod when no node has room (the pod requests 1 vCPU and 2Gi), which EKS Auto Mode removes once it is empty. Between runs you
pay for the image in ECR and the objects in the run bucket, which `cleanup.sh` removes, and
for Bifrost's PostgreSQL database on Amazon RDS, which bills until `bifrost/destroy.sh` ends
with `clean up complete` ([what it costs](bifrost/README.md#what-it-costs)).

```bash
git clone -b self-running-agents-sync-20261117 https://github.com/utkarpun/sample-eks-nitro-sandbox.git
cd sample-eks-nitro-sandbox/examples/agent-sandbox/self-running-agents
```

## Prerequisites

- An EKS Auto Mode cluster with Nitro sandboxes and network policy enforcement on, from
  either path:
  - **`cluster/`** makes one with Terraform: the VPC, the cluster and the network policy
    ConfigMap (the commands are below). Enforcement is then already on, so `setup.sh`'s
    stop for it never fires on this path.
  - **Your own cluster**, as the [Hello sandbox](../../getting-started/hello-sandbox/README.md)
    sample creates (see the [prerequisites](../../README.md#prerequisites)), with network
    policy enforcement turned on as the
    [coding agent blueprint](../../getting-started/coding-agent/README.md)'s step 1 does (one
    ConfigMap, cluster-wide); `setup.sh` checks it and stops if it is off.
- Terraform 1.5.7 or later (`cluster/versions.tf`; `bootstrap/` needs the AWS provider 6.73.0
  or later, the first with `aws_eks_capability`).
- Docker with `linux/amd64` builds, the AWS CLI v2 2.32.8 or later (the first with the
  `bedrock-agentcore-control` policy engine commands, which `cleanup.sh`'s read-back uses),
  `kubectl` within one minor version of the cluster, `python3` and `sha256sum` on your path.
- Credentials that may, for Step 0, create an IAM role and its inline policy, EKS
  capabilities and an access policy association, and a ClusterRole and its binding on the
  cluster; and for the scripts, read the cluster, push to the sample's ECR repository, put
  and delete objects in its run bucket, apply kro graphs and instances, and for `test.sh`
  simulate the agent's and Bifrost's IAM roles (`iam:SimulatePrincipalPolicy`). Every other
  AWS resource is created by the ACK capability's role.
- Access to the Bedrock model named in `.env`, and AgentCore Gateway and AgentCore Policy in
  your Region (this run used `us-west-2`).
- What [Bifrost](bifrost/README.md#before-you-start) needs as well: `helm` 3 and `openssl`.

**Make the cluster with `cluster/`.** Two applies, because the Kubernetes provider is
configured from the cluster and cannot reach it before it exists (`cluster/main.tf`). The
cluster's API endpoint is public and open only to `endpoint_public_access_cidrs`: give your
own address. `cluster_name` and `region` default to `sandbox-demo` and `us-west-2`. Then
point kubectl at it (with your own `cluster_name` and `region` if you set them).

```bash
cd cluster
terraform init
terraform apply -target=module.vpc -target=module.eks -var 'endpoint_public_access_cidrs=["<your IP>/32"]'
terraform apply -var 'endpoint_public_access_cidrs=["<your IP>/32"]'
aws eks update-kubeconfig --name sandbox-demo --region us-west-2
cd ..
```

```text
TODO: output from the fresh run
```

## Overview

| Piece | What it is | Where it runs |
|---|---|---|
| The agent run | An `SraRun` kro instance whose one child is a Kubernetes Job: Claude Code with `-p`, one prompt, then exit | An isolated Nitro sandbox pod in the sample's namespace |
| The bridge | `mcp-proxy-for-aws-cli`, a stdio MCP server that signs each request with SigV4 | Inside the agent pod, started by Claude Code |
| The tool door | An AgentCore Gateway, MCP protocol, inbound auth `AWS_IAM` | AWS, managed |
| The policy | A Cedar policy engine in `ENFORCE` mode on the gateway, with one `permit` | AWS, managed |
| The tool | A Lambda function with two read-only tools, `get_time` and `get_host_info` | AWS Lambda |
| The model gateway | Bifrost, which calls Bedrock with its own role for requests that carry the agent's key | A Deployment in the namespace `bfx` ([bifrost/](bifrost/README.md)) |
| The run's state | `runs/<run id>/` in a run bucket | Amazon S3 |
| The infrastructure | Three kro graphs, `SraBase` and `SraGateway` over ACK, and `SraRun`, one instance per run | The EKS managed kro and ACK capabilities |

A run goes like this:

1. `scripts/run.sh` creates an `SraRun` instance for the run, whose one child is the run's
   Job (`kro/run-rgd.yaml`), and follows its logs from the moment the pod starts.
2. Before anything else the pod waits until its egress rule is in force (the egress gate,
   below).
3. Claude Code starts the bridge, which lists the gateway's tools as the pod's IAM role.
   The gateway lists only the tools the Cedar policy permits that role: `clock___get_time`.
4. The model calls `clock___get_time`. The gateway asks the policy engine, the policy
   permits it, and the gateway invokes the Lambda function.
5. The pod copies the run's stream to the run bucket, exits, and `run.sh` deletes the
   `SraRun` instance, which deletes the Job, then the pod, which kro leaves (kro#1330).

Never delete a run's Job by hand, only its `SraRun`: kro makes a deleted Job again, which
starts a second run.

### Design

**Identity.** The pod's ServiceAccount maps to one IAM role through EKS Pod Identity. That
role may call `bedrock-agentcore:InvokeGateway` on the one gateway and put objects under
`runs/` in the run bucket. It holds nothing else, no Bedrock permission included: the model
calls go through Bifrost, whose own role holds it. This follows the EKS Best Practices Guide's "Use one IAM
role per application" (`latest/bpg/security/iam.adoc:1078-1084` at
`aws/aws-eks-best-practices` `edc514fac86518b50129401c0cffd1f7981d7ec5`). The role trusts
only Pod Identity sessions tagged with this cluster, this namespace and the `agent`
ServiceAccount (`iam.adoc:940-947`, same commit). ACK creates each resource by its name and
fails on a name that is already taken (the graphs configure no adoption), so it
never takes over another demo's role.

**The tool door.** The gateway authenticates the caller by its SigV4 signature, so the
Cedar principal is the pod's role:
`AgentCore::IamEntity::"arn:aws:sts::<ACCOUNT_ID>:assumed-role/sra-agent"`.
The one policy (the `policy` resource in `kro/gateway-rgd.yaml`) permits that principal to
call `clock___get_time` on that gateway. Cedar is default-deny, so `get_host_info` is
refused for the agent, and every tool is refused for any other caller. The gateway's own
role may invoke only the tool function and ask only policy engines and gateways named for
the sample (`sra_policy-*`, `sra-gw-*`): names, not exact ARNs, because the role is made
before the gateway, and kro cannot make the role and the gateway depend on each other. Its
trust lets any AgentCore gateway in the account assume it (`gateway/*`).

**No Kubernetes API token.** The pod spec sets `automountServiceAccountToken: false`, as the
EKS Best Practices Guide's "Disable auto-mounting of service account tokens" says
(`latest/bpg/security/iam.adoc:1104-1108`, same commit). The only token in the pod is the
one EKS Pod Identity projects for its node agent
(`/var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token`, audience
`pods.eks.amazonaws.com`); it is what the Pod Identity Agent exchanges for the role's AWS credentials,
and the Kubernetes API should refuse it, since its audience is not the API's (reasoned, not tested). An isolated Nitro sandbox does get the token
when automount is on, so that setting keeps the automatic token out; a pod that mounts a
token on purpose, as a projected volume, still gets one. A
`ValidatingAdmissionPolicy` (the `admission` resource in `kro/gateway-rgd.yaml`), built
into Kubernetes, refuses any pod in the namespace that does not turn automount off or does
not run in `isolated-sandbox`.

**Egress.** An `ApplicationNetworkPolicy` (the `egress` resource in `kro/gateway-rgd.yaml`)
selects the agent pods, which isolates them, and allows DNS, the Pod Identity agent at
`169.254.170.23:80`, Bifrost's pods (`app.kubernetes.io/name: bifrost` in `bfx`) on TCP 8080,
and TCP 443 to two names only: the gateway's host and the run bucket's host. The EKS Best Practices Guide starts from a
deny-all policy for every pod in the namespace (`podSelector: {}`,
`latest/bpg/security/network.adoc:71-90`, same commit); this rule applies that deny to the
agent pods only, with the allows layered on. Other pods in the namespace are not covered.
The run is a plain Job with the `isolated-sandbox` runtime class, not an agent-sandbox
`SandboxTemplate`, so no controller adds a network policy of its own. Network policies add
up: on a template, the controller's default policy would open what this rule closes, so
either set `networkPolicyManagement: Unmanaged` (as the coding-agents-for-developers and managed-agents samples do) or carry these
egress rules in the template's own `networkPolicy`. The price of a plain Job is cold start.

**The egress gate.** With the NodeClass's default `networkPolicy: DefaultAllow`, a new
pod's network policy is not in force the moment the pod starts. On this cluster the first
request of a fresh agent pod reached `example.com` and was answered `200`; the same request
about 8 s later was refused (raw lines under [Step 5](#step-5)). So `agent/run.sh` starts
nothing until a connection to a host the rule does not name (`example.com`, or
`EGRESS_CANARY`) fails three times in a row, and fails the run if that has not happened
after 90 s. Any failure to connect counts (refused, unreachable, timed out or not
resolvable), so the gate only means something when the canary is reachable before the rule
applies: on a cluster with no internet path, set `EGRESS_CANARY` to a host the pod can
otherwise reach, with `export EGRESS_CANARY=<host>` in your shell before you run
`run.sh` or `test.sh` (it is not read from `.env`).

**State outside the pod.** The pod's filesystem is read-only apart from three `emptyDir`
volumes. The run's output goes to standard output, which `run.sh` streams as it happens
(on this cluster EKS Auto Mode removed a node after a Job's pod finished and its logs went
with it), and to `s3://<run bucket>/runs/<run id>/` before the pod exits. A run may
overwrite earlier runs' objects; turn on bucket versioning if the record matters, and
empty the bucket in the S3 console first (Empty deletes every version), since `cleanup.sh`
removes only current objects. The
pod carries `karpenter.sh/do-not-disrupt`, because Auto Mode consolidation otherwise evicts
a sandbox pod mid-run.

**What the graphs create.** `SraBase` (`kro/base-rgd.yaml`): the namespace `sra`, the run
bucket `sra-runs-<account id>-<Region>` (public access blocked) and the ECR repository `sra`
(scan on push). `SraGateway` (`kro/gateway-rgd.yaml`): three IAM roles (`sra-agent`,
`sra-gateway`, `sra-tool`), the Lambda function `sra-clock` and its log group (one-day
retention), the policy engine `sra_policy` and its one policy, the gateway `sra-gw` and its
target `clock`, the Pod Identity association, and in the cluster a
`ValidatingAdmissionPolicy` and its binding (cluster-scoped, named for the namespace and
matching only it), the ServiceAccount, the egress rule and a ConfigMap with the bridge's
configuration and the prompt. `SraRun` (`kro/run-rgd.yaml`): one run's Job in `sra`, with no
`ttlSecondsAfterFinished`, since a TTL delete is a Job deleted alone. Each AWS resource that takes tags is tagged
`Project=<PROJECT_TAG>` (`PROJECT_TAG` in `.env`, default `self-running-agents`) and `ManagedBy=sra` (the target and the Cedar policy take none;
they belong to the tagged gateway and engine). The names are fixed in `kro/base.yaml` and
`kro/gateway.yaml` and match `bootstrap/`'s `prefix`, which scopes the ACK role to them.

**Order.** kro orders each graph by its references (the order is in the comment at the
top of `kro/gateway-rgd.yaml`). `SraBase` goes first, because the function's code is read
from its bucket. `cleanup.sh` deletes the `SraRun` instances, the `SraGateway` instance,
empties the bucket, deletes the `SraBase` instance (kro deletes each graph in reverse, the
namespace last) and the graphs, then reads every AWS resource back.

### What this blueprint does not limit

This list is not complete. Today the agent cannot use any of these, because it has no tool
that runs code or opens a connection; a repository agent that is given Bash, file tools or
a credential can use every one of them, so close them before you add such a tool, or let anyone else create pods in the namespace.

**Name rules match addresses.** The egress rule's names are resolved to addresses and the
rule matches the addresses (Amazon EKS User Guide,
[*Use Network Policies with EKS Auto Mode*](https://docs.aws.amazon.com/eks/latest/userguide/auto-net-pol.html):
resolved IPs go into an eBPF map and egress is filtered by IP), not the name a client sends inside TLS. A host that shares an address with
an allowed name is reachable too. On this cluster the learned addresses were shared by
every pod on the node, so a pod can reach a name another pod on the same node
is allowed. The run bucket's name is the clearest case: every S3 bucket in the Region is
served from the same addresses, so the rule lets the pod reach any bucket. The role can
write only under `runs/` in the run bucket, but public buckets are readable and writable
without a role.

**DNS is open.** Port 53 is allowed to any address. The same page documents a DNS filter for name
rules, but on this cluster every name still resolved from an agent pod, so treat DNS
as a channel that can carry data out. The EKS Best Practices Guide's example allows DNS only
to `kube-dns` in `kube-system`, UDP 53 (`latest/bpg/security/network.adoc:100-129`, same
commit); this rule is wider.

**The window before the policy.** The egress gate keeps the agent from starting during it
on a cluster where the canary is reachable, but the window exists for every pod in the
namespace. The NodeClass-wide (on the built-in NodePools, every node) way to close it is the
NodeClass's `networkPolicy: DefaultDeny` (the field the EKS Best Practices Guide shows, with
`DefaultAllow`, at `latest/bpg/security/automode.adoc:162-172`; the two values are listed in
the Amazon EKS User Guide's
[*Create a Node Class for Amazon EKS*](https://docs.aws.amazon.com/eks/latest/userguide/create-node-class.html),
and [*Restrict Pod network traffic with Kubernetes network policies*](https://docs.aws.amazon.com/eks/latest/userguide/cni-network-policy-configure.html)
documents the same deny-until-configured behavior for the VPC CNI as strict mode). Not exercised by this sample.

**The model call.** The agent sends its model calls to Bifrost with its key, which
`agent/settings.json`'s `apiKeyHelper` reads from the Secret `bifrost-agent-key`, and Bifrost
calls Bedrock as its own role. The key is limited to one model and a request and token rate,
with no spend budget ([Stop it](bifrost/README.md#stop-it)); nothing inspects prompts or
tool results. Bedrock still records the calls on its side, as Bifrost's role:
CloudTrail logs each `InvokeModel` call as a management event, CloudWatch counts
invocations and tokens per model (`AWS/Bedrock`), and model invocation logging, if you turn
it on, keeps the request and response bodies.

**No in-guest policy.** An isolated sandbox runs no in-guest policy unless one is supplied;
the Amazon EKS User Guide documents in-guest Cedar for both modes
([*Sandboxing on Amazon EKS with isolated and confidential pods*](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing.html)), our earlier test covered confidential mode only,
and this sample supplies none. Image signing (AWS Signer) was tested only in confidential
mode. The Cedar policy here is the gateway's, in AWS. It says nothing about what runs
inside the pod.

**Admission checks two fields.** The policy refuses a pod that leaves the token automount
on or runs outside `isolated-sandbox`. It does not refuse a privileged container, a
`hostPath` volume, `hostNetwork`, a Secret in `env` or a token mounted on purpose as a
projected volume, and an isolated sandbox does not refuse the first two either; a
`hostNetwork` pod fails to start in a sandbox (Amazon EKS User Guide,
[*Considerations*](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing-limitations.html)). Add
those rules, or a policy engine, before anyone but you creates pods in the
namespace.

**Only labelled pods are under the egress rule.** The rule selects
`app.kubernetes.io/name: agent`. Admission does not require that label or the `agent`
ServiceAccount, so a pod created in the namespace without the label but with
`serviceAccountName: agent` gets the agent's AWS credentials and the cluster's default
egress (`DefaultAllow` here). Keep `create pods` in the namespace to yourself.
Creating a `SraRun` gives the same: kro makes its Job, and any `image` runs as `agent` with its Pod Identity role and the Bifrost key. Keep `create` on `sraruns` to yourself too.

**Whoever can create ACK objects holds the ACK role.** The ACK capability acts with one
role for every namespace, and that role may manage any IAM role named `sra-*` and pass it
to Lambda, AgentCore and Pod Identity (`bootstrap/main.tf`, statements `WorkloadRoles` and
`PassWorkloadRoles`). A user who can create an ACK `Role` or `PodIdentityAssociation` in any
namespace can mint such a role and bind it to a pod. Keep the ACK kinds to cluster admins.

**Instance metadata.** An isolated sandbox runs its own IMDSv2 metadata service at
`169.254.169.254`, inside the sandbox, so the egress rule does not reach it. It serves only
the Region, Availability Zone, Availability Zone ID, services domain and partition, and 404
for everything else, credentials included (Amazon EKS User Guide, [*Pod Identity and credentials*](https://docs.aws.amazon.com/eks/latest/userguide/sandboxing-metadata-credentials.html)).
A sandbox Cedar policy generated with `--deny-imds` turns it off; generate it with
`--with-pod-identity` as well, or the pod's AWS calls fail.

**The role works without the gateway.** The pod's AWS credentials reach the run bucket
directly; only tool calls pass the gateway's policy. No remedy in this sample beyond
the role's narrow scope.

**Every allowed name is a public endpoint.** AgentCore Gateway, S3 and, for Bifrost, Bedrock each have
interface VPC endpoints (the gateway's is `com.amazonaws.<Region>.bedrock-agentcore.gateway`);
with them the pods need no route to the internet. This sample uses the public endpoints.

## Versions

| Component | Pin |
|---|---|
| Claude Code | `2.1.310` (Dockerfile) |
| `mcp-proxy-for-aws-cli` | `1.8.0` (Dockerfile; it pins its own dependency tree) |
| Base image | `public.ecr.aws/docker/library/node:22-bookworm-slim` (tag, not a digest) |
| Lambda runtime | `python3.13` |
| Terraform providers | `hashicorp/aws` 6.73.0, `hashicorp/kubernetes` 3.5.0 (`bootstrap/` and `cluster/` lock files) |
| Terraform modules (`cluster/`) | `terraform-aws-modules/vpc/aws` 6.7.3, `terraform-aws-modules/eks/aws` 21.29.0 |
| kro and ACK capabilities | EKS managed; this run: `TODO: output from the fresh run` (`terraform output kro_version ack_version`) |
| EKS | Auto Mode; this run: `TODO: output from the fresh run` |
| AWS CLI | `TODO: output from the fresh run` for this run |

## Files

| File | What it does |
|---|---|
| `.env.example` | The local values the scripts read; copy to `.env` |
| `cluster/*.tf` | The cluster path: the EKS Auto Mode cluster, its VPC and the network policy ConfigMap, applied in two phases (`cluster/main.tf`) |
| `bootstrap/*.tf` | Step 0: the EKS managed kro and ACK capabilities, their IAM role, and kro's RBAC for the ACK kinds and the run's Job |
| `kro/base-rgd.yaml`, `kro/base.yaml` | The `SraBase` graph (namespace, run bucket, image repository) and its one instance |
| `kro/gateway-rgd.yaml`, `kro/gateway.yaml` | The `SraGateway` graph (gateway, Cedar policy, tool, roles, Pod Identity, admission, egress, the agent's ConfigMap) and its one instance |
| `Dockerfile`, `.dockerignore` | The agent image: Claude Code, the bridge, and `agent/` |
| `agent/run.sh` | Runs in the pod: egress gate, then the agent or a tool listing, then stores the output |
| `agent/settings.json` | Built-in tools are off (`--tools ""` in agent/run.sh); settings.json allows only `mcp__gateway`, and its `apiKeyHelper` reads the Bifrost key |
| `agent/claude.json` | Marks `/work` trusted so a headless run does not stop at the trust prompt |
| `agent/prompt.txt` | The prompt's text; `kro/gateway.yaml` carries the copy a run uses |
| `agent/mcp_call.py` | Lists and calls the gateway's tools with no model in the loop |
| `tool/handler.py` | The Lambda function behind the gateway target |
| `kro/run-rgd.yaml`, `deploy/run.yaml` | The `SraRun` graph (one run's Job, its model calls pointed at Bifrost) and the instance `run.sh` renders per run |
| `bifrost/` | Bifrost, the model gateway, with its own apply, test and destroy ([README](bifrost/README.md)) |
| `scripts/setup.sh`, `run.sh`, `test.sh`, `cleanup.sh` | Apply, run, check and remove; `common.sh` is shared |

## Run it

The output on this page comes from one fresh run on a cluster that had none of the
sample's resources. The account id is replaced with `<ACCOUNT_ID>`, the cluster name
with `<CLUSTER_NAME>`, and the generated ids of the gateway, the policy engine and the Pod
Identity association with `<id>`; long blocks are abridged where marked. The `sra:` prefix
on the pod's own lines is fixed in `agent/run.sh`.

**Step 0: turn on kro and ACK.** Once per cluster, and again (`terraform apply` in
`bootstrap/`) after you pull a change to it, such as the run's Job rule. The stack makes one IAM role for both
capabilities, the ACK and kro capabilities, a Secret reader access policy in the namespaces
`secret_namespaces` names, and a ClusterRole that lets kro manage the ACK kinds and the
Kubernetes objects the graphs use, the run's Job (`batch` `jobs`) included. Its `rds_prefix` and RDS statements are for
[Bifrost](bifrost/README.md); they create nothing on their own.

```bash
cd bootstrap
terraform init
terraform plan -var cluster_name=<CLUSTER_NAME> -var region=us-west-2 -out tfplan
terraform apply tfplan
cd ..
```

On the `cluster/` path `<CLUSTER_NAME>` is `sandbox-demo`, unless you set `cluster_name`.

```text
TODO: output from the fresh run
```

If the cluster already runs its own kro or ACK controllers, read the Amazon EKS User Guide's
[*Comparing EKS Capability for kro to self-managed kro*](https://docs.aws.amazon.com/eks/latest/userguide/kro-comparison.html) and
[*Comparing EKS Capability for ACK to self-managed ACK*](https://docs.aws.amazon.com/eks/latest/userguide/ack-comparison.html)
first: the ACK capability installs the CRD versions it ships.

**Step 1: copy the settings and fill them in.**

```bash
cp .env.example .env
# set CLUSTER_NAME, and KUBE_CONTEXT (a context in your kubeconfig) to pin the cluster
```

`KUBE_CONTEXT` must be the context of `CLUSTER_NAME`: the Pod Identity association is made
on `CLUSTER_NAME`, the pods run on the context, and a mismatch is a run with no credentials.
After `aws eks update-kubeconfig`, the context is the cluster's ARN, which
`kubectl config current-context` prints. Set `AWS_PROFILE` too if the cluster's account is
not your CLI's default.

**Step 2: set everything up.** `setup.sh` checks the runtime class, network policy
enforcement and the kro and ACK kinds, and changes none of them. It applies the three graphs
and the `SraBase` instance and waits for it, uploads the tool's zip to the run bucket
(`tool/clock-<hash>.zip`) and pushes the agent image to the repository, then applies the
`SraGateway` instance and waits until it is `ACTIVE`. It stops if a namespace `sra` exists
that its `SraBase` instance did not make. If it stops part way, run it again.

```bash
./scripts/setup.sh
```

```text
TODO: output from the fresh run
```

**Step 2b: set up Bifrost.** Follow [Bifrost's README](bifrost/README.md). `bifrost/apply.sh`
needs the namespace `sra` that `setup.sh` made, and its graph copies the agent's key into it;
`run.sh` and `test.sh` stop until that key is there. Bifrost's four Secrets are made by
`apply.sh`, not its graph: a kro graph cannot make a secret value.

```bash
./bifrost/apply.sh
```

**Step 3: start one agent run.** (The output below is from the agent run `test.sh` starts
as its first check, T, in Step 4; `run.sh` prints the same.) The agent reads the time
through the gateway and reports it. The pod has no Kubernetes API token, and waits for its
egress rule before it starts. `run.sh` reads the namespace, bucket, repository, Region and
model from the two instances' status and spec.

```bash
./scripts/run.sh
```

```text
TODO: output from the fresh run
```

The tool calls and the result, read from that run's stream:

```text
TODO: output from the fresh run
```

**Step 4: check it both ways.** `test.sh` runs the agent once (the run shown in Step 3),
then each refusal.

```bash
./scripts/test.sh
```

```text
TODO: output from the fresh run
```

NC1 reads the gate line of T's own run, so it passes whenever T's run stopped at the gate;
the seven checks are six independent outcomes.

Not covered by these checks: callers other than the agent role, hosts other than
example.com, a pod without the agent label, a pod without
`runtimeClassName: isolated-sandbox`, and the Pod Identity token, which the pod does hold.

- **T2 and NC2** call the gateway directly as the pod's role, with no model in the loop
  (`agent/mcp_call.py`), so the refusal is the gateway's, not the model's choice and not
  the bridge's. The gateway lists only `clock___get_time` and refuses `get_host_info` with
  a JSON-RPC error. The tool function's own log shows that only `get_time` reached it (2 from `test.sh`, 3 if you ran Step 3 first):

  ```text
  TODO: output from the fresh run
  ```

- **NC4** shows the gate stops a run when its canary answers: pointed at a host the rule
  does allow (the run bucket's), the run stops before its tool call.
- **NC-B1** shows the agent cannot call Bedrock itself. IAM: a simulation of the agent's
  role on the model's inference profile reads `implicitDeny`, and the same on Bifrost's role
  reads `allowed`. Network: a run whose canary is `bedrock-runtime.<Region>.amazonaws.com`
  finds it unreachable and goes on. On EKS Auto Mode an allow learned for one pod is shared
  with every pod on its node, so on a node that also runs Bifrost the network leg can fail
  while the IAM leg holds.

<a id="step-5"></a>
**Step 5: the window the egress gate is for.** This block is from a separate, earlier run
of the same Job (the pod is unchanged) with the gate replaced by a loop that requests
`example.com` every few seconds from the moment the pod starts:

```text
0.1 answered 200
8.1 refused URLError
16.1 refused URLError
...
120.5 refused URLError
```

## Good to know

- **A denied tool call is a JSON-RPC error.** The gateway answers a call the policy does not
  permit with an MCP error, `Tool Execution Denied: ... [No policy applies to the request
  (denied by default).]`, not with a tool result.
- **The bridge only offers listed tools.** `mcp-proxy-for-aws-cli` exposes the tools the
  gateway listed, so a call to an unlisted tool fails inside the pod. To see the gateway
  refuse it, call the gateway directly, as `agent/mcp_call.py` does.
- **A setup that never reaches ACTIVE.** `setup.sh` then prints each ACK object's state. A
  gateway made a moment after its role can fail IAM propagation, and ACK does not retry an
  `ACK.Terminal` error; the graph makes the gateway role first to avoid it, which is a
  timing fix, not a guarantee. Run `cleanup.sh`, then `setup.sh` again.
- **Changing a graph.** Never remove a field from a graph's `spec.schema` while its
  instance exists: kro refuses the change and the instance stops reconciling, deletion
  included. Run `cleanup.sh` first.
- **Changing the tool.** Edit `tool/handler.py` and run `setup.sh`: a new zip has a new key
  and hash, and ACK updates the function's code.
- **The run's logs.** Read a past run from the bucket:
  `aws s3 cp s3://<run bucket>/runs/<run id>/stream.jsonl -`.
- **Limits.** A run is stopped at 15 minutes (`activeDeadlineSeconds`), is not retried, and
  the model gets at most 8 turns; change them in `kro/run-rgd.yaml` and `agent/run.sh`.
- **A failed run.** `run.sh` prints the Job's verdict and deletes the run's `SraRun`, so read the
  streamed output or, if the pod got past the egress gate, `runs/<run id>/` in the bucket; a pod exit of 3 means the egress gate
  failed and stored nothing. A run with no verdict 60 s after its logs end, or whose pod does not start within
  10 minutes, leaves its `SraRun` for `cleanup.sh`. To remove one run alone:
  `kubectl -n sra delete srarun <name>`, then the pod it leaves; never the Job.
- **Where a refusal is recorded.** The gateway's own logs do not carry policy decisions; the
  `DenyDecisions` metric in `AWS/Bedrock-AgentCore` does, by default:
  `aws cloudwatch get-metric-statistics --namespace AWS/Bedrock-AgentCore --metric-name DenyDecisions ...`.
  Per-call decisions need traces enabled on the gateway, which this sample does not do.
- **Quotas.** AgentCore Gateway and Policy have their own quotas: see
  [Quotas for Amazon Bedrock AgentCore](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/bedrock-agentcore-limits.html).

## Extending it

This is a base to build on, and it has three seams for your own pieces: your own prompt
(the `prompt` field in `kro/gateway.yaml`, which the graph puts in the run's ConfigMap), a
repository checkout for the agent to work in (a step in `agent/run.sh` before Claude Code
starts, with the repository's host added to the `egress` resource in
`kro/gateway-rgd.yaml`), and more tools as extra `GatewayTarget` resources in that graph,
each with its own Cedar `Policy` for the agent's role. Read
[What this blueprint does not limit](#what-this-blueprint-does-not-limit) before you give
the agent a tool that runs code or opens a connection.

## Clean up

Do these steps in order, from this folder (`examples/agent-sandbox/self-running-agents`)
of the clone that ran the setup, with the same `.env` and the same AWS credentials. Each
step needs the one before it to have ended clean, because each removes something the next
one depends on, and the Terraform state of `bootstrap/` and `cluster/` is only in this
clone. Every script below reads what it removed back from the cluster and from AWS, and a
read it could not make counts as not gone. Step 5 checks everything once more at the end.

**Step 1: note the cluster's KMS key.** On the `cluster/` path only, while the cluster is
still up. The destroy in step 4 removes the key's alias, so step 5 needs the key's ARN:

```bash
aws eks describe-cluster --name <CLUSTER_NAME> --region us-west-2 \
  --query 'cluster.encryptionConfig[0].provider.keyArn' --output text
```

**Step 2: remove Bifrost, then the sample.**

```bash
./bifrost/destroy.sh
./scripts/cleanup.sh
```

`bifrost/destroy.sh` uninstalls Bifrost's Helm release and deletes its graph instance, which
has ACK delete the RDS database (no final snapshot), its subnet group and security group,
Bifrost's IAM role and its Pod Identity association; it waits up to 25 minutes for that.
kro deletes the agent's copy of the key in `sra`, and the namespace `bfx` last, with the
Secrets in it. `cleanup.sh` then deletes the runs' `SraRun` instances
and their pods, and the `SraGateway` instance, empties the run bucket,
deletes the `SraBase` instance (the bucket, the image repository and the namespace `sra`)
and the three graphs. Each script is done when its last line is `clean up complete`. If one ends
`clean up incomplete` (Bifrost) or `clean up INCOMPLETE: <n> item(s) above` (the sample), the
lines above it name what is left: run that script again before you go on. A database left
behind keeps billing, and its security group blocks the VPC delete in step 4.

```text
TODO: output from the fresh run
```

**Step 3: remove kro and ACK.** Only if nothing else on the cluster uses the capabilities
(another sample's graphs). They are made with `delete_propagation_policy = "RETAIN"`
(`bootstrap/main.tf`), so deleting them does not delete what the graphs made: both scripts
in step 2 must have ended `clean up complete` first.

```bash
cd bootstrap
terraform destroy -var cluster_name=<CLUSTER_NAME> -var region=us-west-2
cd ..
aws eks list-capabilities --cluster-name <CLUSTER_NAME> --region us-west-2
```

Done when the destroy ends `Destroy complete!` and the last command lists no capability
(`"capabilities": []`).

```text
TODO: output from the fresh run
```

**Step 4: remove the cluster.** On the `cluster/` path only; on your own cluster, skip to
step 5. One destroy removes the network policy ConfigMap, then the cluster, its IAM roles and
log group, and the VPC with its three NAT gateways.

```bash
cd cluster
terraform destroy -var 'endpoint_public_access_cidrs=["<your IP>/32"]'
cd ..
```

Done when it ends `Destroy complete!`. If it stops on the VPC, something step 2 missed is
still in it (a load balancer, a network interface or a security group). List them, with the
VPC id from the error, then delete what you find and run the destroy again:

```bash
aws ec2 describe-network-interfaces --region us-west-2 --include-managed-resources \
  --filters Name=vpc-id,Values=<vpc id> --query 'NetworkInterfaces[].[NetworkInterfaceId,Description]'
aws ec2 describe-security-groups --region us-west-2 \
  --filters Name=vpc-id,Values=<vpc id> --query 'SecurityGroups[].[GroupId,GroupName]'
```

Auto Mode's network interfaces are hidden without `--include-managed-resources`. A VPC's
`default` security group goes with the VPC; it is not a leftover.

```text
TODO: output from the fresh run
```

**Step 5: check that everything is gone.** Set the two values, then run each read. Each
"gone" answer is an error or an empty list, as the second column says.

```bash
C=<CLUSTER_NAME>; R=us-west-2
```

| Read | Gone when it prints |
|---|---|
| `aws rds describe-db-instances --region $R --db-instance-identifier bfx-bifrost` | `DBInstanceNotFound` |
| `aws rds describe-db-subnet-groups --region $R --db-subnet-group-name bfx-bifrost` | `DBSubnetGroupNotFoundFault` |
| `aws iam get-role --role-name bfx-bifrost` (and again for `sra-agent`, `sra-gateway`, `sra-tool`, `sra-capability`) | `NoSuchEntity`, each time |
| `aws lambda get-function --region $R --function-name sra-clock` | `ResourceNotFoundException` |
| `aws ecr describe-repositories --region $R --repository-names sra` | `RepositoryNotFoundException` |
| `aws s3api head-bucket --bucket sra-runs-<ACCOUNT_ID>-$R` | `Not Found` (404) |
| `aws bedrock-agentcore-control list-gateways --region $R --query "items[?name=='sra-gw']"` | `[]` |
| `aws bedrock-agentcore-control list-policy-engines --region $R --query "policyEngines[?name=='sra_policy']"` | `[]` |
| `aws eks describe-cluster --region $R --name $C` | `ResourceNotFoundException` (`cluster/` path) |
| `aws ec2 describe-vpcs --region $R --filters Name=tag:Name,Values=$C --query 'Vpcs[].VpcId'` | `[]` (`cluster/` path) |
| `` aws ec2 describe-nat-gateways --region $R --filter "Name=tag:Name,Values=$C*" --query 'NatGateways[?State!=`deleted`].NatGatewayId' `` | `[]` (`cluster/` path) |
| `aws ec2 describe-addresses --region $R --filters "Name=tag:Name,Values=$C*" --query 'Addresses[].AllocationId'` | `[]` (`cluster/` path; the NAT gateways' addresses) |
| `aws ec2 describe-volumes --region $R --include-managed-resources --filters Name=tag-key,Values=eks:eks-cluster-name --query 'Volumes[].[VolumeId,Tags]'` | no volume tagged with your cluster's name |
| `aws logs describe-log-groups --region $R --log-group-name-prefix /aws/eks/$C/cluster --query 'logGroups[].logGroupName'` | `[]` (`cluster/` path) |
| `aws kms describe-key --region $R --key-id <the key ARN from step 1> --query KeyMetadata.KeyState` | `PendingDeletion` (`cluster/` path) |
| `aws resourcegroupstaggingapi get-resources --region $R --tag-filters Key=ManagedBy,Values=sra,bfx --query 'ResourceTagMappingList[].ResourceARN'` | `[]` |

The tagging read can still list a resource for hours after it was deleted, so check any ARN
it prints with that resource's own read before you treat it as left. An EBS volume EKS Auto
Mode made belongs to no VPC, so step 4 does not catch it, and it keeps billing until you
delete it (`aws ec2 delete-volume --region $R --volume-id <id>`).

**What stays.** The cluster's secrets KMS key stays pending deletion for 30 days. On your own
cluster, the runtime classes and network policy enforcement stay, which this sample only
reads, and the capabilities stay if you skipped step 3. On your machine: the agent image in
Docker's local store (`docker image rm <image>`), Terraform's state in `bootstrap/` (and
`cluster/`), and `tmp/self-running-agents/` at the clone's root with test.sh's logs (or
`LOG_DIR`). Auto Mode removes the run's node on its own.
