# The EKS Auto Mode cluster the example runs on, and its VPC. This replaces the
# eksctl line in the Hello sandbox sample; the runtime classes come with Auto
# Mode, as they do there.
#
# Apply in two phases, because the kubernetes provider (versions.tf) is configured
# from this cluster and cannot reach it before it exists:
#
#   terraform init
#   terraform apply -target=module.vpc -target=module.eks \
#     -var 'endpoint_public_access_cidrs=["<your IP>/32"]'   # 1. VPC and cluster
#   terraform apply -var 'endpoint_public_access_cidrs=["<your IP>/32"]'   # 2. network-policy.tf
#   aws eks update-kubeconfig --name <cluster_name> --region <region>
#
# Then bootstrap/ (Step 0), then the example. Destroy in reverse: the example's
# clean up, bootstrap/'s destroy, then here one `terraform destroy`, which deletes
# the ConfigMap before the cluster (network-policy.tf depends_on). Some things can
# outlive it. The secrets KMS key stays pending deletion for 30 days; destroy deletes
# its alias, so find it by its description "<cluster_name> cluster encryption key".
# An EBS volume Auto Mode made belongs to no VPC, so it outlives the destroy and keeps
# billing; find it by the tag key eks:eks-cluster-name. A load balancer, a network
# interface or a security group that the example's clean up missed blocks the VPC
# delete. List those with `aws ec2 describe-network-interfaces
# --include-managed-resources` and `aws ec2 describe-security-groups`, each filtered
# on the VPC's vpc-id; Auto Mode network interfaces are hidden without that flag.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name            = var.cluster_name
  cidr            = "10.0.0.0/16"
  azs             = local.azs
  private_subnets = [for i in range(3) : cidrsubnet("10.0.0.0/16", 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet("10.0.0.0/16", 8, 48 + i)]

  # One NAT gateway per Availability Zone, as the EKS Best Practices Guide
  # advises for a zone-independent design and lower cross-AZ cost
  # (networking/subnets.adoc). This bills three NAT gateways and three
  # Elastic IPs instead of one.
  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version
  # Module defaults kept: a KMS key for secrets (30-day deletion window), and the
  # audit, api and authenticator logs to CloudWatch, kept 90 days.

  # Auto Mode: compute, block storage and load balancing are turned on together
  # from this one block (the module's main.tf), and the module makes the
  # cluster and node IAM roles Auto Mode needs.
  compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # The API endpoint is public but open only to endpoint_public_access_cidrs, which
  # the reader sets to their own address (EKS Best Practices Guide, security/iam.adoc:
  # "Leave the cluster endpoint public and specify which CIDR blocks can communicate
  # with the cluster endpoint"). The identity that runs Terraform gets cluster admin
  # through an access entry. eksctl makes a public endpoint and that entry by
  # default; the module does neither.
  endpoint_public_access                   = true
  endpoint_public_access_cidrs             = var.endpoint_public_access_cidrs
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # The example's pods get AWS credentials through EKS Pod Identity, so no IRSA
  # OIDC provider.
  enable_irsa = false
}
