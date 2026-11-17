# scripts: set up, run, test and clean up

The scripts make no AWS resource themselves. They check what the sample needs, apply the kro
graphs, wait, upload the tool's code, push the agent image, run, check and delete. Every
AWS object is made by ACK from the graphs in [`kro/`](../kro/README.md).

| Script | What it does |
|---|---|
| `setup.sh` | Checks the cluster, applies the three graphs and the two instances, uploads the tool and pushes the image |
| `run.sh` | Starts one run and streams its output |
| `test.sh` | One agent run end to end, then one refusal for each thing meant to refuse |
| `cleanup.sh` | Deletes what `setup.sh` and `run.sh` made, then reads everything back |
| `common.sh` | Shared settings, readings and guards; sourced, never run |

They read `.env` (copied from `.env.example`): `CLUSTER_NAME`, `AWS_REGION`, `AWS_PROFILE`,
`KUBE_CONTEXT`, `BEDROCK_MODEL_ID`, `PROJECT_TAG` and `KUBECTL`. A value already set in your
environment wins. Every kubectl call pins `--context`, so a run never depends on your
current context.

## setup.sh

Checks the runtime class, network policy enforcement and the kro and ACK kinds, and changes
none of them. Applies the three graphs and the `SraBase` instance and waits for it, uploads
the tool's zip to the run bucket (`tool/clock-<hash>.zip`), pushes the agent image to the
repository, then applies the `SraGateway` instance and waits until it is `ACTIVE`.

It stops if a namespace `sra` exists that its `SraBase` instance did not make. It never
changes a shared install or a cluster-wide setting. It is safe to re-run: applying the same
instances changes nothing, and a new tool zip or image is picked up. If it never reaches
`ACTIVE`, it prints each ACK object's state ([`kro/`](../kro/README.md#good-to-know)).

## run.sh

```bash
./scripts/run.sh                 # the agent: headless Claude Code with the prompt
./scripts/run.sh tools <tool...> # list the gateway's tools and call each named one
```

It reads the namespace, bucket, repository, Region and model from the two instances, makes
one `SraRun` ([`deploy/`](../deploy/README.md)), and follows the pod's logs from the moment
it starts, because EKS Auto Mode can remove the node once the pod has finished, and the logs
with it. Then it prints the Job's verdict and deletes the `SraRun` and the pod.

- **A failed run.** Read the streamed output or, if the pod got past the egress gate,
  `runs/<run id>/` in the bucket: `aws s3 cp s3://<run bucket>/runs/<run id>/stream.jsonl -`.
  A pod exit of 3 means the egress gate failed and stored nothing.
- **Limits.** A run is stopped at 15 minutes while its Job exists, is not retried, and the model gets at most 8
  turns.
- **Overwrites.** A run may overwrite earlier runs' objects. Turn on bucket versioning if
  the record matters, and then empty the bucket in the S3 console before clean up (Empty
  deletes every version), since `cleanup.sh` removes only current objects.

## What test.sh checks

```bash
./scripts/test.sh
```

| Check | What it shows |
|---|---|
| T | The agent's `get_time` call was answered, and its answer has the `time-in-utc:` form with the time the tool returned. The agent has no Bedrock permission and no `bedrock-runtime` egress, so a pass also shows its model calls went through Bifrost (T-B1). |
| T2 | Outside the model, the gateway lists only `get_time` for the agent's role and answers it |
| NC1 | In T's run, the egress gate's connections to a host the rule does not name failed |
| NC2 | A call to `get_host_info`, which the Cedar policy does not permit, is refused by the gateway |
| NC4 | The egress gate stops a run when its canary answers: pointed at a host the rule does allow (the run bucket's), the run stops before its tool call |
| NC-B1 | The agent cannot call Bedrock itself: a simulation of its role on the model's profile reads `implicitDeny` (Bifrost's role, the control, reads `allowed`), and a run whose canary is `bedrock-runtime.<Region>.amazonaws.com` finds it unreachable |
| NC3 | Admission refuses a pod that automounts the token, and accepts one that does not |

- T2 and NC2 call the gateway directly as the pod's role (`agent/mcp_call.py`), so the refusal
  is the gateway's, not the model's choice and not the bridge's. The gateway refuses
  `get_host_info` with a JSON-RPC error.
- NC1 reads the gate line of T's own run, so it passes whenever T's run stopped at the gate;
  the seven checks are six independent outcomes.
- On EKS Auto Mode an allow learned for one pod is shared with every pod on its node, so on a
  node that also runs Bifrost NC-B1's network leg can fail while its IAM leg holds.
- Not covered: callers other than the agent role, hosts other than `example.com`, a pod
  without the agent label, a pod without `runtimeClassName: isolated-sandbox`, and the Pod
  Identity token, which the pod does hold.

The raw output is kept in `tmp/self-running-agents/` at the clone's root (or `LOG_DIR`).

## cleanup.sh

Run it after `bifrost/destroy.sh`. It deletes the `SraRun` instances and their pods, the
`SraGateway` instance, empties the run bucket (data, which ACK does not delete), deletes the
`SraBase` instance (the bucket, the image repository and the namespace `sra`, last), and the
three graphs `SraRun`, `SraGateway` and `SraBase` and their CRDs; `bifrost/destroy.sh` removes
the fourth, `BifrostBackend`. Then it reads every AWS resource back; a read it could not make
counts as not gone. It never touches a shared install, a cluster-wide setting or the
controllers from `bootstrap/`.

It is done when its last line is `clean up complete`. If it ends
`clean up INCOMPLETE: <n> item(s) above`, the lines above name what is left: run it again.

### If kro or ACK is already gone

kro puts the finalizer `kro.run/finalizer` on every instance, and ACK puts
`finalizers.<service>.services.k8s.aws/<Kind>` on each object it manages. With the controller
gone nothing removes them, so `cleanup.sh` and `bifrost/destroy.sh` time out and end
incomplete. To see it, an object stays with a `deletionTimestamp` and its finalizer:

```bash
kubectl get <kind> -A -o custom-columns=NAME:.metadata.name,DELETING:.metadata.deletionTimestamp,FINALIZERS:.metadata.finalizers
```

The recovery depends on which is gone. These steps have not been run live.

- **kro gone, ACK running:** do not delete in AWS by hand. kro no longer deletes its ACK
  objects, and ACK makes an AWS object again when it reads it as deleted. Delete the ACK
  objects with kubectl, Bifrost's in `bfx` and the sample's in `sra`:

  ```bash
  kubectl -n bfx delete --all dbinstances.rds.services.k8s.aws,dbsubnetgroups.rds.services.k8s.aws,securitygroups.ec2.services.k8s.aws,roles.iam.services.k8s.aws,podidentityassociations.eks.services.k8s.aws
  kubectl -n sra delete --all buckets.s3.services.k8s.aws,repositories.ecr.services.k8s.aws,gateways.bedrockagentcorecontrol.services.k8s.aws,gatewaytargets.bedrockagentcorecontrol.services.k8s.aws,policies.bedrockagentcorecontrol.services.k8s.aws,policyengines.bedrockagentcorecontrol.services.k8s.aws,loggroups.cloudwatchlogs.services.k8s.aws,functions.lambda.services.k8s.aws,roles.iam.services.k8s.aws,podidentityassociations.eks.services.k8s.aws
  ```

  Wait until a `get` of the same kinds in each namespace lists none, then remove
  `kro.run/finalizer` from each instance:
  `kubectl patch <kind> <name> --type=merge -p '{"metadata":{"finalizers":null}}'` (add
  `-n sra` for an `SraRun`; `SraBase`, `SraGateway` and `BifrostBackend` are cluster scoped).
- **ACK gone:** delete in AWS, by name, each object the scripts' `read back` lines name as
  present, then remove the ACK finalizer from each stuck object:
  `kubectl -n <namespace> patch <kind> <name> --type=merge -p '{"metadata":{"finalizers":null}}'`.
  Removing an ACK finalizer before the AWS delete leaves that AWS object with nothing to
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
| `aws eks describe-cluster --region $R --name $C` | `ResourceNotFoundException` (`cluster/` path) |
| `aws ec2 describe-vpcs --region $R --filters Name=tag:Name,Values=$C --query 'Vpcs[].VpcId'` | `[]` (`cluster/` path) |
| `` aws ec2 describe-nat-gateways --region $R --filter "Name=tag:Name,Values=$C*" --query 'NatGateways[?State!=`deleted`].NatGatewayId' `` | `[]` (`cluster/` path) |
| `aws ec2 describe-addresses --region $R --filters "Name=tag:Name,Values=$C*" --query 'Addresses[].AllocationId'` | `[]` (`cluster/` path; the NAT gateways' addresses) |
| `aws ec2 describe-volumes --region $R --include-managed-resources --filters Name=tag-key,Values=eks:eks-cluster-name --query 'Volumes[].[VolumeId,Tags]'` | no volume tagged with your cluster's name |
| `aws logs describe-log-groups --region $R --log-group-name-prefix /aws/eks/$C/cluster --query 'logGroups[].logGroupName'` | `[]` (`cluster/` path) |
| `aws kms describe-key --region $R --key-id <the key ARN from step 1> --query KeyMetadata.KeyState` | `PendingDeletion` (`cluster/` path) |
| `aws resourcegroupstaggingapi get-resources --region $R --tag-filters Key=ManagedBy,Values=sra,bfx --query 'ResourceTagMappingList[].ResourceARN'` | `[]` |

The tagging read can list a resource for hours after it was deleted, so check any ARN it
prints with that resource's own read before you treat it as left. An EBS volume EKS Auto Mode
made belongs to no VPC, so the cluster destroy does not catch it, and it keeps billing until
you delete it (`aws ec2 delete-volume --region $R --volume-id <id>`).

**What stays.** The cluster's secrets KMS key stays pending deletion for 30 days. On your own
cluster, the runtime classes and network policy enforcement stay, which this sample only
reads, and the capabilities stay if you skipped `bootstrap/`'s destroy. On your machine: the
agent image in Docker's local store (`docker image rm <image>`), Terraform's state in
`bootstrap/` (and `cluster/`), and `tmp/self-running-agents/` with `test.sh`'s logs. Auto
Mode removes the run's node on its own, once no run's pod is left.
