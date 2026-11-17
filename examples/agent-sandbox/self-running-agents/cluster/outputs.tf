output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "update_kubeconfig" {
  description = "Writes a kubeconfig context for the cluster; bootstrap/ and the scripts read it."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
