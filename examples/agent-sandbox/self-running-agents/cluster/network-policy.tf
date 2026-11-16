# Network policy enforcement, phase 2 of the apply (main.tf). EKS Auto Mode does not
# enforce NetworkPolicy or ApplicationNetworkPolicy objects until this ConfigMap
# exists. It is cluster-wide, so it lives here, in the root that
# makes the cluster, not in bootstrap/ or the example's scripts.
#
# The key is the one the Amazon EKS User Guide gives
# (https://docs.aws.amazon.com/eks/latest/userguide/auto-net-pol.html, Step 1). The
# EKS Best Practices Guide's example names `enable-network-policy` instead
# (latest/bpg/security/automode.adoc), which is not a ConfigMap key: it is the
# `--enable-network-policy` argument of the VPC CNI's aws-network-policy-agent
# container (User Guide, "Restrict Pod network traffic with Kubernetes network
# policies"). setup.sh checks this key and stops when it is not "true".
#
# A fresh Auto Mode cluster has no amazon-vpc-cni ConfigMap, so this creates it.
resource "kubernetes_config_map_v1" "network_policy" {
  metadata {
    name      = "amazon-vpc-cni"
    namespace = "kube-system"
  }
  data = {
    "enable-network-policy-controller" = "true"
  }
  depends_on = [module.eks]
}
