output "capability_role_arn" {
  value = aws_iam_role.capability.arn
}

output "ack_capability_arn" {
  value = aws_eks_capability.ack.arn
}

output "kro_capability_arn" {
  value = aws_eks_capability.kro.arn
}

output "kro_version" {
  value = aws_eks_capability.kro.version
}

output "ack_version" {
  value = aws_eks_capability.ack.version
}
