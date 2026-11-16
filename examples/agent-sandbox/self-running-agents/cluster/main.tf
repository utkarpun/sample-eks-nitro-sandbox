# The EKS Auto Mode cluster the example runs on, and its VPC. This replaces the
# eksctl line in the Hello sandbox sample; the runtime classes come with Auto
# Mode, as they do there.
#
# Apply in two phases, because the kubernetes provider (versions.tf) is configured
# from this cluster and cannot reach it before it exists:
#
#   terraform init
#   terraform apply -target=module.vpc -target=module.eks   # 1. VPC and cluster
#   terraform apply                                          # 2. network-policy.tf
#   aws eks update-kubeconfig --name <cluster_name> --region <region>
#
# Then bootstrap/ (Step 0), then the example. Destroy in reverse: the example's
# clean up, bootstrap/'s destroy, then here one `terraform destroy`, which deletes
# the ConfigMap before the cluster (network-policy.tf depends_on).

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
  cidr            = var.vpc_cidr
  azs             = local.azs
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, 48 + i)]

  # One NAT gateway for the whole VPC, as eksctl's default makes.
  enable_nat_gateway = true
  single_nat_gateway = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  # Auto Mode: compute, block storage and load balancing are turned on together
  # from this one block (the module's main.tf), and the module makes the
  # cluster and node IAM roles Auto Mode needs.
  compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Reach the API from the machine that runs kubectl, and give the identity that
  # runs Terraform cluster admin through an access entry. eksctl does both by
  # default; the module does neither.
  endpoint_public_access                   = true
  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true

  # The example's pods get AWS credentials through EKS Pod Identity, so no IRSA
  # OIDC provider.
  enable_irsa = false
}
