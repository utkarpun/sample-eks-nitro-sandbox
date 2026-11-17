# bootstrap: kro and ACK on the cluster

This Terraform root turns on the two controllers everything else is built with, as EKS
managed capabilities. It is Step 0 of the sample: run it once per cluster. After a pull, run it
and then the sample's `scripts/setup.sh` and `bifrost/apply.sh` again.

- **kro** (Kube Resource Orchestrator) runs the sample's graphs in [`kro/`](../kro/README.md)
  and [`bifrost/`](../bifrost/README.md).
- **ACK** (AWS Controllers for Kubernetes) makes the AWS resources those graphs name: the
  IAM roles, Lambda function, AgentCore Gateway and policy engine, S3 bucket, ECR
  repository and Bifrost's RDS database.

## What it makes

| Resource | What it is for |
|---|---|
| IAM role `sra-capability` | One role for both capabilities, trusted by `capabilities.eks.amazonaws.com` |
| Its inline policy `sra-ack` | What ACK may do in AWS, scoped by name (below) |
| EKS capabilities `sra-ack` and `sra-kro` | The two controllers, made with `delete_propagation_policy = "RETAIN"` |
| Access policy association | `AmazonEKSSecretReaderPolicy` in the namespaces `secret_namespaces` names (`sra`, `bfx`), so ACK's RDS controller can read the database password; it can read every Secret in those namespaces |
| ClusterRole and binding `sra-kro-ack` | Lets kro manage the ACK kinds and the Kubernetes objects the graphs use: namespaces, ConfigMaps, ServiceAccounts, Secrets, Services, Deployments, the run's Job, admission policies and network policies |

**What ACK may touch.** The policy names what the graphs make: IAM roles named `sra-*` and
`bfx-*` (never `sra-capability` itself), Lambda functions, log groups and S3 buckets named
`sra-*`, the ECR repository `sra`, any AgentCore resource in this account and
Region (their ids are generated), Pod Identity associations on this cluster, RDS instances
and subnet groups named `bfx-*`, and security groups tagged `ManagedBy=sra` or `bfx` (made
only in the cluster's VPC). ACK holds `iam:*` on `sra-*` and `bfx-*` roles with no
permissions boundary (`WorkloadRoles`, which includes `iam:PassRole` to any service), and
`bedrock-agentcore:*` in this Region. Whoever can create ACK kinds or
`resourcegraphdefinitions` can make an admin role and change the gateway's policy engine.
Keep those rights to cluster admins.

| Variable | Default | Note |
|---|---|---|
| `cluster_name` | none | The cluster to turn them on in |
| `region` | `us-west-2` | |
| `prefix` | `sra` | Must match the names in `kro/base.yaml` and `kro/gateway.yaml` |
| `rds_prefix` | `bfx` | For Bifrost; creates nothing on its own |
| `secret_namespaces` | `["sra", "bfx"]` | |

Its Terraform and provider versions are in the sample's [Versions](../README.md#versions)
table. It reads the cluster when it plans, so the cluster must exist first.

## Apply it

The commands are Step 0 of [How to run it](../README.md#how-to-run-it). If the cluster
already runs its own kro or ACK controllers, read the Amazon EKS User Guide's [*Comparing
EKS Capability for kro to self-managed
kro*](https://docs.aws.amazon.com/eks/latest/userguide/kro-comparison.html) and [*Comparing
EKS Capability for ACK to self-managed
ACK*](https://docs.aws.amazon.com/eks/latest/userguide/ack-comparison.html) first: the ACK
capability installs the CRD versions it ships.

## Destroy it

Only if nothing else on the cluster uses the capabilities, and only after
`bifrost/destroy.sh` and `scripts/cleanup.sh` both ended `clean up complete`. Because of
`RETAIN`, deleting a capability does not delete what its graphs made. The commands are
step 3 of the clean up in [How to run it](../README.md#how-to-run-it).
