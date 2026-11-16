# Network policy enforcement, phase 2 of the apply (main.tf). EKS Auto Mode accepts
# NetworkPolicy and ApplicationNetworkPolicy objects without enforcing them until
# this ConfigMap exists. It is cluster-wide, so it lives here, in the root that
# makes the cluster, not in bootstrap/ or the example's scripts.
#
# The key is the one the Amazon EKS User Guide gives
# (https://docs.aws.amazon.com/eks/latest/userguide/auto-net-pol.html, Step 1). The
# EKS Best Practices Guide's example names `enable-network-policy` instead
# (latest/bpg/security/automode.adoc); setup.sh checks this key and stops when it is
# not "true".
#
# A fresh Auto Mode cluster has no amazon-vpc-cni ConfigMap, so this creates it.
resource "kubernetes_config_map_v1" "network_policy" {
  metadata {
    name      = "amazon-vpc-cni"
    namespace = "kube-system"
    labels    = { ManagedBy = var.tags["ManagedBy"] }
  }
  data = {
    "enable-network-policy-controller" = "true"
  }
  depends_on = [module.eks]
}
