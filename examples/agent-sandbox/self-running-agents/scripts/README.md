# scripts: set up, run, test and clean up

The scripts make no AWS resource themselves: they apply the graphs in
[`kro/`](../kro/README.md), and ACK makes every AWS object.

| Script | What it does |
|---|---|
| `setup.sh` | Checks the cluster, applies the three graphs and the two instances, uploads the tool and pushes the image |
| `run.sh` | Starts one run and streams its output |
| `test.sh` | One agent run end to end, then one refusal for each thing meant to refuse |
| `cleanup.sh` | Deletes what `setup.sh` and `run.sh` made, then reads everything back |
| `common.sh` | Shared settings, readings and guards; sourced, never run |

They read `.env` (copied from `.env.example`); a value already set in your environment
wins. When `KUBE_CONTEXT` is set, every kubectl and helm call pins it.

## setup.sh

Checks the runtime class, network policy enforcement and the kro and ACK kinds, and changes
none of them. Applies the `SraBase` instance, uploads the tool's zip to the run bucket,
pushes the agent image, then applies the `SraGateway` instance and waits until it is
`ACTIVE`.

It stops if a namespace `sra` exists that its `SraBase` instance did not make. It is safe to
re-run. If it never reaches `ACTIVE`, it prints each ACK object's state
([`kro/`](../kro/README.md#good-to-know)).

## run.sh

```bash
./scripts/run.sh                 # the agent: headless Claude Code with the prompt
./scripts/run.sh tools <tool...> # list the gateway's tools and call each named one
```

It makes one `SraRun` ([`deploy/`](../deploy/README.md)) and follows the pod's logs from the
start, because EKS Auto Mode can remove the node, and the logs with it, once the pod has
finished. Then it prints the Job's verdict and deletes the `SraRun` and the pod.

- **A failed run.** Read the streamed output. A run that exited on its own, before its
  15-minute deadline, also stored its output:
  `aws s3 cp s3://<run bucket>/runs/<run id>/stream.jsonl -`. A pod exit of 3 means the
  egress gate failed and stored nothing.
- **Limits.** See [`agent/`](../agent/README.md#changing-it).
- **Overwrites.** A run may overwrite earlier runs' objects. If you turn on bucket
  versioning, empty the bucket in the S3 console before clean up, since `cleanup.sh` removes
  only current objects.

## What test.sh checks

```bash
./scripts/test.sh
```

| Check | What it shows |
|---|---|
| T | The agent's `get_time` call was answered with the time the tool returned. The agent has no Bedrock permission and no `bedrock-runtime` egress, so its model calls went through Bifrost. |
| T2 | With no model, the gateway lists only `get_time` of the `clock` tools for the agent's role, and answers it |
| NC1 | In T's run, the egress gate could not reach a host the rule does not name |
| NC2 | The gateway refuses `get_host_info`, which the Cedar policy does not permit |
| NC4 | The egress gate stops a run whose canary answers (pointed at the run bucket's host) |
| NC-B1 | The agent cannot call Bedrock itself: its role is denied the model (Bifrost's is allowed, the control), and `bedrock-runtime` is unreachable from its pod |
| NC3 | Admission refuses a pod that automounts the token, and accepts one that does not |

T2 and NC2 call the gateway directly (`agent/mcp_call.py`), so a refusal is the gateway's,
not the model's. NC1 reads T's own run, so the seven checks are six independent outcomes.
NC-B1's network leg can fail on a node that also runs Bifrost (see *Name rules match
addresses* in the [Design](../README.md#design)). Not covered: other callers, hosts other
than `example.com`, and pods without the agent label or the sandbox runtime class.

The raw output is kept in `tmp/self-running-agents/` at the clone's root (or `LOG_DIR`).

## cleanup.sh

Run it after `bifrost/destroy.sh`. It deletes the `SraRun` instances and their pods, the
`SraGateway` instance, empties the run bucket, deletes the `SraBase` instance and the three
graphs, then reads back each AWS resource it names; a read it could not make counts as not
gone. It never touches a shared install, a cluster-wide setting or `bootstrap/`.

It is done when its last line is `clean up complete`. If it ends
`clean up INCOMPLETE: <n> item(s) above`, the lines above name what is left: run it again.

### If kro or ACK is already gone

Nothing then removes their finalizers, so `cleanup.sh` and `bifrost/destroy.sh` time out.
A stuck object shows a `deletionTimestamp` and its finalizer:

```bash
kubectl get <kind> -A -o custom-columns=NAME:.metadata.name,DELETING:.metadata.deletionTimestamp,FINALIZERS:.metadata.finalizers
```

These steps have not been run live.

- **kro gone, ACK running:** do not delete in AWS by hand, because ACK makes an AWS object
  again when it reads it as deleted. Empty the run bucket
  (`aws s3 rm s3://sra-runs-<ACCOUNT_ID>-<Region> --recursive`), then delete the ACK objects:

  ```bash
  kubectl -n bfx delete --all dbinstances.rds.services.k8s.aws,dbsubnetgroups.rds.services.k8s.aws,securitygroups.ec2.services.k8s.aws,roles.iam.services.k8s.aws,podidentityassociations.eks.services.k8s.aws
  kubectl -n sra delete --all buckets.s3.services.k8s.aws,repositories.ecr.services.k8s.aws,gateways.bedrockagentcorecontrol.services.k8s.aws,gatewaytargets.bedrockagentcorecontrol.services.k8s.aws,policies.bedrockagentcorecontrol.services.k8s.aws,policyengines.bedrockagentcorecontrol.services.k8s.aws,loggroups.cloudwatchlogs.services.k8s.aws,functions.lambda.services.k8s.aws,roles.iam.services.k8s.aws,podidentityassociations.eks.services.k8s.aws
  ```

  Once a `get` of those kinds lists none, remove `kro.run/finalizer` from each instance:
  `kubectl patch <kind> <name> --type=merge -p '{"metadata":{"finalizers":null}}'` (add
  `-n sra` for an `SraRun`; the other three kinds are cluster scoped).
- **ACK gone:** delete in AWS, by name, what the scripts' `read back` lines name as present,
  then remove the ACK finalizer from each stuck object with the same `kubectl patch` and
  `-n <namespace>`. Removing it before the AWS delete leaves that object with nothing to
  remove it.

## Check that everything is gone

After the whole clean up (the README's Clean up, steps 1 to 4), set the two values and run
each read. Each "gone" answer is an error or an empty list.

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
| `aws eks list-pod-identity-associations --region $R --cluster-name $C --namespace sra --service-account agent --query associations` (and again with `--namespace bfx --service-account bifrost`) | `[]`, each time (your own cluster) |
| `aws eks describe-cluster --region $R --name $C` | `ResourceNotFoundException` (`cluster/` path) |
| `aws ec2 describe-vpcs --region $R --filters Name=tag:Name,Values=$C --query 'Vpcs[].VpcId'` | `[]` (`cluster/` path) |
| `` aws ec2 describe-nat-gateways --region $R --filter "Name=tag:Name,Values=$C*" --query 'NatGateways[?State!=`deleted`].NatGatewayId' `` | `[]` (`cluster/` path) |
| `aws ec2 describe-addresses --region $R --filters "Name=tag:Name,Values=$C*" --query 'Addresses[].AllocationId'` | `[]` (`cluster/` path; the NAT gateways' addresses) |
| `aws ec2 describe-volumes --region $R --include-managed-resources --filters Name=tag-key,Values=eks:eks-cluster-name --query 'Volumes[].[VolumeId,Tags]'` | no volume tagged with your cluster's name |
| `aws logs describe-log-groups --region $R --log-group-name-prefix /aws/eks/$C/cluster --query 'logGroups[].logGroupName'` | `[]` (`cluster/` path) |
| `aws kms describe-key --region $R --key-id <the key ARN from step 1> --query KeyMetadata.KeyState` | `PendingDeletion` (`cluster/` path) |
| `aws resourcegroupstaggingapi get-resources --region $R --tag-filters Key=ManagedBy,Values=sra,bfx --query 'ResourceTagMappingList[].ResourceARN'` | `[]` |

The tagging read can list a resource for hours after it was deleted, so check any ARN it
prints with that resource's own read. To remove what is left, first check no ACK object
still names it, then run that service's delete command on the name the read used; for the
EBS volume, see [`cluster/`](../cluster/README.md#what-outlives-it).

**What stays.** The cluster's KMS key, pending deletion
([`cluster/`](../cluster/README.md#what-outlives-it)). On your own cluster, the runtime
classes and network policy enforcement, which this sample only reads, and the capabilities
if you skipped `bootstrap/`'s destroy. On your machine: the agent image in Docker
(`docker image rm <image>`), Terraform's state in `bootstrap/` (and `cluster/`), and
`tmp/self-running-agents/`.
