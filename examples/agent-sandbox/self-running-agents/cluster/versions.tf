terraform {
  # terraform-aws-modules/eks v21.29.0 needs 1.5.7 or later (its versions.tf).
  required_version = ">= 1.5.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.73.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

# Configured from the cluster this root creates, so it can only reach the cluster
# once the cluster exists: hence the two-phase apply in main.tf, which the provider's
# own docs call the most reliable way ("the cluster itself and the Kubernetes
# provider resources can be managed with separate `apply` operations"). The token comes
# from the AWS CLI at each call rather than from a data source read at plan time.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}
