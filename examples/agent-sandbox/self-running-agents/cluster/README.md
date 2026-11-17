# cluster: the EKS Auto Mode cluster and its VPC

This Terraform root makes the cluster the sample runs on. Skip it if you bring your own
EKS Auto Mode cluster with Nitro sandboxes and network policy enforcement on.

## What it makes

- **A VPC** (`terraform-aws-modules/vpc/aws`) named after the cluster, with three
  private and three public subnets in the first three Availability Zones, and one NAT
  gateway per zone, as the EKS Best Practices Guide advises for a zone-independent design.
  That bills three NAT gateways and three Elastic IPs.
- **An EKS Auto Mode cluster** (`terraform-aws-modules/eks/aws`) with the
  `general-purpose` and `system` node pools. The module keeps its defaults: a KMS key for
  secrets (30-day deletion window), and the audit, api and authenticator logs in CloudWatch
  for 90 days. Pods get AWS credentials through EKS Pod Identity, so there is no IRSA OIDC
  provider.
- **Network policy enforcement** (`network-policy.tf`): the `amazon-vpc-cni` ConfigMap in
  `kube-system` with `enable-network-policy-controller: "true"`. EKS Auto Mode enforces no
  network policy until it exists. It is cluster-wide, so it lives here and not in the
  sample's scripts. `setup.sh` checks this key and stops when it is not `"true"`.

The API endpoint is public, but open only to `endpoint_public_access_cidrs`, which has no
default: give your own address. The identity that runs Terraform gets cluster admin through
an access entry.

| Variable | Default |
|---|---|
| `cluster_name` | `sandbox-demo` (also the VPC's name) |
| `region` | `us-west-2` |
| `kubernetes_version` | `1.36` |
| `endpoint_public_access_cidrs` | none, required |

## Apply it

Two applies, because the Kubernetes provider is configured from this cluster and cannot
reach it before it exists. The commands are in [How to run it](../README.md#how-to-run-it).
If you set `cluster_name` or `region`, pass the same `-var` values on both applies and on
the destroy, and use them in `update-kubeconfig`. Then go on to
[`bootstrap/`](../bootstrap/README.md).

## Destroy it

Last, after the sample's clean up and `bootstrap/`'s destroy. One `terraform destroy`
removes the ConfigMap, then the cluster, its IAM roles and log group, and the VPC with its
NAT gateways (step 4 of the clean up in [How to run it](../README.md#how-to-run-it)). Done
when it ends `Destroy complete!`.

### If the destroy stops on the VPC

Something the sample's clean up missed is still in it: a load balancer, a network interface
or a security group. List them with the VPC id from the error, delete what you find, and run
the destroy again:

```bash
aws ec2 describe-network-interfaces --region us-west-2 --include-managed-resources \
  --filters Name=vpc-id,Values=<vpc id> --query 'NetworkInterfaces[].[NetworkInterfaceId,Description]'
aws ec2 describe-security-groups --region us-west-2 \
  --filters Name=vpc-id,Values=<vpc id> --query 'SecurityGroups[].[GroupId,GroupName]'
```

Auto Mode's network interfaces are hidden without `--include-managed-resources`. A VPC's
`default` security group goes with the VPC; it is not a leftover.

### What outlives it

- The secrets KMS key stays pending deletion for 30 days. The destroy removes its alias, so
  note the key's ARN before you destroy (the sample's clean up, step 1), or find it by its
  description `<cluster_name> cluster encryption key`.
- An EBS volume Auto Mode made belongs to no VPC, so it outlives the destroy and keeps
  billing. Find it by the tag key `eks:eks-cluster-name` and delete it
  (`aws ec2 delete-volume --region us-west-2 --volume-id <id>`).
- The Terraform state is only in this folder of the clone that applied it.
