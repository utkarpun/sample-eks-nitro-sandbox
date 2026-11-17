# Controller bootstrap: the EKS managed ACK and kro capabilities, one capability
# role, and the in-cluster RBAC kro needs to manage the ACK kinds the example's
# graphs compose.

locals {
  account = data.aws_caller_identity.this.account_id
  vpc_id  = data.aws_eks_cluster.this.vpc_config[0].vpc_id
  cluster = data.aws_eks_cluster.this.arn
  role    = "${var.prefix}-capability"
  # Roles, functions, log groups, buckets and repositories the graphs make.
  w   = "${var.prefix}-*"
  rds = "${var.rds_prefix}-*"
  # Security groups ACK may change: tagged ManagedBy=<prefix> or <rds_prefix>.
  managed_by = distinct([var.tags["ManagedBy"], var.rds_prefix])
  arn = {
    roles     = "arn:aws:iam::${local.account}:role/${var.prefix}-*"
    rds_roles = "arn:aws:iam::${local.account}:role/${var.rds_prefix}-*"
    self      = "arn:aws:iam::${local.account}:role/${local.role}"
    functions = "arn:aws:lambda:${var.region}:${local.account}:function:${local.w}"
    logs      = "arn:aws:logs:${var.region}:${local.account}:log-group:/aws/lambda/${local.w}"
  }
}

# One role for both capabilities (trust per
# https://docs.aws.amazon.com/eks/latest/userguide/kro-create-cli.html Step 1).
resource "aws_iam_role" "capability" {
  name = local.role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "capabilities.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# What ACK may do in AWS. The ACK capability uses this role directly
# (no IAMRoleSelector), https://docs.aws.amazon.com/eks/latest/userguide/ack-permissions.html.
resource "aws_iam_role_policy" "ack" {
  name = "${var.prefix}-ack"
  role = aws_iam_role.capability.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "WorkloadRoles", Effect = "Allow", Action = ["iam:*"], Resource = [local.arn.roles, local.arn.rds_roles] },
      # The pattern above also matches this role: never let ACK change itself.
      { Sid = "NotSelf", Effect = "Deny", Action = ["iam:*"], Resource = local.arn.self },
      {
        Sid       = "PassWorkloadRoles", Effect = "Allow", Action = "iam:PassRole", Resource = local.arn.roles
        Condition = { StringEquals = { "iam:PassedToService" = ["lambda.amazonaws.com", "bedrock-agentcore.amazonaws.com", "pods.eks.amazonaws.com"] } }
      },
      {
        Sid       = "PassBifrostRolesToPods", Effect = "Allow", Action = "iam:PassRole", Resource = local.arn.rds_roles
        Condition = { StringEquals = { "iam:PassedToService" = "pods.eks.amazonaws.com" } }
      },
      { Sid = "Functions", Effect = "Allow", Action = ["lambda:*"], Resource = [local.arn.functions, "${local.arn.functions}:*"] },
      { Sid = "LogGroups", Effect = "Allow", Action = ["logs:*"], Resource = [local.arn.logs, "${local.arn.logs}:*"] },
      { Sid = "DescribeLogGroupsIsStarOnly", Effect = "Allow", Action = ["logs:DescribeLogGroups"], Resource = "*" },
      # Gateway and policy-engine ids are generated, so no name scope here.
      { Sid = "AgentCoreHere", Effect = "Allow", Action = ["bedrock-agentcore:*"], Resource = "arn:aws:bedrock-agentcore:${var.region}:${local.account}:*" },
      {
        Sid      = "PodIdentityOnThisCluster", Effect = "Allow"
        Action   = ["eks:CreatePodIdentityAssociation", "eks:DescribePodIdentityAssociation", "eks:DeletePodIdentityAssociation", "eks:UpdatePodIdentityAssociation", "eks:ListPodIdentityAssociations", "eks:TagResource", "eks:UntagResource", "eks:ListTagsForResource", "eks:DescribeCluster"]
        Resource = [local.cluster, "arn:aws:eks:${var.region}:${local.account}:podidentityassociation/${var.cluster_name}/*"]
      },
      { Sid = "Buckets", Effect = "Allow", Action = ["s3:*"], Resource = ["arn:aws:s3:::${local.w}", "arn:aws:s3:::${local.w}/*"] },
      { Sid = "ListBucketsIsStarOnly", Effect = "Allow", Action = ["s3:ListAllMyBuckets"], Resource = "*" },
      { Sid = "Repositories", Effect = "Allow", Action = ["ecr:*"], Resource = "arn:aws:ecr:${var.region}:${local.account}:repository/${local.w}" },
      # RDS for the Bifrost unit: instances and subnet groups by name; creating
      # an instance also names the default option and parameter groups.
      {
        Sid = "RdsByName", Effect = "Allow", Action = ["rds:*"]
        Resource = [
          "arn:aws:rds:${var.region}:${local.account}:db:${local.rds}",
          "arn:aws:rds:${var.region}:${local.account}:subgrp:${local.rds}",
          "arn:aws:rds:${var.region}:${local.account}:og:default*",
          "arn:aws:rds:${var.region}:${local.account}:pg:default*",
        ]
      },
      { Sid = "RdsDescribe", Effect = "Allow", Action = ["rds:Describe*", "rds:ListTagsForResource"], Resource = "*" },
      {
        Sid       = "RdsServiceLinkedRole", Effect = "Allow", Action = "iam:CreateServiceLinkedRole", Resource = "*"
        Condition = { StringEquals = { "iam:AWSServiceName" = "rds.amazonaws.com" } }
      },
      # EC2 security groups for the DB: create only in the cluster VPC and only
      # tagged ManagedBy=<prefix> or <rds_prefix>; change or delete only those.
      { Sid = "SgCreateInClusterVpc", Effect = "Allow", Action = ["ec2:CreateSecurityGroup"], Resource = "arn:aws:ec2:${var.region}:${local.account}:vpc/${local.vpc_id}" },
      {
        Sid       = "SgCreateTagged", Effect = "Allow", Action = ["ec2:CreateSecurityGroup"], Resource = "arn:aws:ec2:${var.region}:${local.account}:security-group/*"
        Condition = { StringEquals = { "aws:RequestTag/ManagedBy" = local.managed_by } }
      },
      {
        Sid       = "SgTagOnCreate", Effect = "Allow", Action = ["ec2:CreateTags"], Resource = "arn:aws:ec2:${var.region}:${local.account}:security-group/*"
        Condition = { StringEquals = { "ec2:CreateAction" = "CreateSecurityGroup" } }
      },
      {
        Sid       = "SgChangeOurs", Effect = "Allow"
        Action    = ["ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress", "ec2:ModifySecurityGroupRules", "ec2:UpdateSecurityGroupRuleDescriptionsIngress", "ec2:UpdateSecurityGroupRuleDescriptionsEgress", "ec2:DeleteSecurityGroup", "ec2:CreateTags", "ec2:DeleteTags"]
        Resource  = ["arn:aws:ec2:${var.region}:${local.account}:security-group/*", "arn:aws:ec2:${var.region}:${local.account}:security-group-rule/*"]
        Condition = { StringEquals = { "aws:ResourceTag/ManagedBy" = local.managed_by } }
      },
      { Sid = "Ec2DescribeIsStarOnly", Effect = "Allow", Action = ["ec2:DescribeSecurityGroups", "ec2:DescribeSecurityGroupRules", "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeTags"], Resource = "*" },
    ]
  })
}

resource "aws_eks_capability" "ack" {
  cluster_name              = var.cluster_name
  capability_name           = "${var.prefix}-ack"
  type                      = "ACK"
  role_arn                  = aws_iam_role.capability.arn
  delete_propagation_policy = "RETAIN"
  depends_on                = [aws_iam_role_policy.ack]
}

resource "aws_eks_capability" "kro" {
  cluster_name              = var.cluster_name
  capability_name           = "${var.prefix}-kro"
  type                      = "KRO"
  role_arn                  = aws_iam_role.capability.arn
  delete_propagation_policy = "RETAIN"
  depends_on                = [aws_eks_capability.ack]
}

# The rds controller reads the DB master password Secret
# (https://docs.aws.amazon.com/eks/latest/userguide/capabilities-security.html,
# "ACK secret reader permissions"). The access entry is the one EKS made.
resource "aws_eks_access_policy_association" "secrets" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.capability.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSSecretReaderPolicy"
  access_scope {
    type       = "namespace"
    namespaces = var.secret_namespaces
  }
  depends_on = [aws_eks_capability.ack]
}

# kro gets only RGDs and instances by default (AmazonEKSKROPolicy); this lets it
# manage the ACK kinds and the plain objects the graphs compose. Its Kubernetes
# user is assumed-role/<role>/KRO (capabilities-security.html, "kro arbitrary
# resource permissions").
resource "kubernetes_cluster_role_v1" "kro" {
  metadata {
    name   = "${var.prefix}-kro-ack"
    labels = { ManagedBy = var.tags["ManagedBy"] }
  }
  rule {
    api_groups = [
      "iam.services.k8s.aws", "lambda.services.k8s.aws", "bedrockagentcorecontrol.services.k8s.aws",
      "eks.services.k8s.aws", "cloudwatchlogs.services.k8s.aws", "s3.services.k8s.aws",
      "ecr.services.k8s.aws", "rds.services.k8s.aws", "ec2.services.k8s.aws",
    ]
    resources = ["*"]
    verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces", "configmaps", "serviceaccounts", "secrets", "services"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  # The run's Job (kro/run-rgd.yaml SraRun).
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["admissionregistration.k8s.io"]
    resources  = ["validatingadmissionpolicies", "validatingadmissionpolicybindings"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["networking.k8s.aws"]
    resources  = ["applicationnetworkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["networkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
  # The example's instance kinds (kro/base-rgd.yaml SraBase, kro/gateway-rgd.yaml SraGateway,
  # kro/run-rgd.yaml SraRun).
  rule {
    api_groups = ["kro.run"]
    resources  = ["srabases", "srabases/status", "srabases/finalizers", "sragateways", "sragateways/status", "sragateways/finalizers", "sraruns", "sraruns/status", "sraruns/finalizers"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }
}

resource "kubernetes_cluster_role_binding_v1" "kro" {
  metadata {
    name   = "${var.prefix}-kro-ack"
    labels = { ManagedBy = var.tags["ManagedBy"] }
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.kro.metadata[0].name
  }
  subject {
    kind      = "User"
    api_group = "rbac.authorization.k8s.io"
    name      = "arn:aws:sts::${local.account}:assumed-role/${aws_iam_role.capability.name}/KRO"
  }
  depends_on = [aws_eks_capability.kro]
}
