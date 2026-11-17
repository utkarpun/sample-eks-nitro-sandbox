variable "cluster_name" {
  description = "EKS cluster that gets the ACK and kro capabilities."
  type        = string
}

variable "region" {
  description = "Region of the cluster."
  type        = string
  default     = "us-west-2"
}

variable "prefix" {
  description = "Name prefix of every AWS resource the example's kro graphs create (roles, functions, log groups, buckets, repositories)."
  type        = string
  default     = "sra"
}

variable "rds_prefix" {
  description = "Name prefix of the RDS DB instances and subnet groups ACK may manage (the Bifrost unit)."
  type        = string
  default     = "bfx"
}

variable "secret_namespaces" {
  description = "Namespaces where the ACK capability may read Secrets (the rds controller reads the DB master password Secret)."
  type        = list(string)
  default     = ["sra", "bfx"]
}

variable "tags" {
  description = "Tags on every AWS resource this stack creates."
  type        = map(string)
  default = {
    Project   = "self-running-agents"
    ManagedBy = "sra"
  }
}
