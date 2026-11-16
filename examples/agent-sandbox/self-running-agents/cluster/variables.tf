variable "cluster_name" {
  description = "Name of the EKS Auto Mode cluster this root creates, and of its VPC."
  type        = string
  default     = "sandbox-demo"
}

variable "region" {
  description = "Region of the cluster."
  type        = string
  default     = "us-west-2"
}

variable "kubernetes_version" {
  description = "Kubernetes version of the cluster."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR of the new VPC. Three private subnets (nodes) and three public subnets (the NAT gateway) are cut from it."
  type        = string
  default     = "10.0.0.0/16"
}

variable "tags" {
  description = "Tags on every AWS resource this stack creates."
  type        = map(string)
  default = {
    Project   = "self-running-agents"
    ManagedBy = "sra"
  }
}
