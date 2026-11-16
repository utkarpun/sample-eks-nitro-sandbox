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

variable "endpoint_public_access_cidrs" {
  description = "CIDR blocks that may reach the cluster's public API endpoint, such as your own address as a /32. No default: the module's own opens the endpoint to every address."
  type        = list(string)
  validation {
    condition     = length(var.endpoint_public_access_cidrs) > 0
    error_message = "Give at least one CIDR block, such as [\"<your IP>/32\"]."
  }
}

variable "tags" {
  description = "Tags on every AWS resource this stack creates."
  type        = map(string)
  default = {
    Project   = "self-running-agents"
    ManagedBy = "sra"
  }
}
