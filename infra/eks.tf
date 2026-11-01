module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.nome
  cluster_version = var.versao_kubernetes

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
    # o eks nao traz metrics-server de fabrica, diferente de minikube.
    # sem ele o hpa le "cpu: <unknown>" e nunca escala.
    metrics-server = {}
  }

  # o control plane precisa alcancar o metrics-server dentro do no, na
  # 10251. o modulo abre 443, 10250 e 53, mas nao essa - e sem ela o
  # apiservice de metricas fica em FailedDiscoveryCheck e o hpa nunca le cpu.
  node_security_group_additional_rules = {
    metrics_server = {
      description                   = "control plane alcanca o metrics-server"
      protocol                      = "tcp"
      from_port                     = 10251
      to_port                       = 10251
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  eks_managed_node_groups = {
    padrao = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      capacity_type  = "ON_DEMAND"
    }
  }
}
