terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.13.0" # required for aws_eks_access_entry / aws_eks_access_policy_association
    }
  }
}

data "aws_subnets" "available-subnets" {
  filter {
    name   = "tag:Name"
    values = ["Our-Public-*"]
  }
}

resource "aws_eks_cluster" "project-cluster" {
  name     = "project-cluster"
  role_arn = aws_iam_role.example.arn
  vpc_config {
    subnet_ids = data.aws_subnets.available-subnets.ids
  }
  # Ensure that IAM Role permissions are created before and deleted after EKS Cluster handling.
  # Otherwise, EKS will not be able to properly delete EKS managed EC2 infrastructure such as Security Groups.
  depends_on = [
    aws_iam_role_policy_attachment.example-AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.example-AmazonEKSVPCResourceController,
  ]
}

output "endpoint" {
  value = aws_eks_cluster.project-cluster.endpoint
}

output "kubeconfig-certificate-authority-data" {
  value = aws_eks_cluster.project-cluster.certificate_authority[0].data
}

resource "aws_eks_node_group" "node-grp" {
  cluster_name    = aws_eks_cluster.project-cluster.name
  node_group_name = "pc-node-group"
  node_role_arn   = aws_iam_role.worker.arn
  subnet_ids      = data.aws_subnets.available-subnets.ids
  capacity_type   = "ON_DEMAND"
  disk_size       = "40"
  instance_types  = ["c7i-flex.large"]
  labels          = tomap({ env = "dev" })
  scaling_config {
    desired_size = 2
    max_size     = 3
    min_size     = 1
  }
  update_config {
    max_unavailable = 1
  }
  depends_on = [
    aws_iam_role_policy_attachment.AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.AmazonEC2ContainerRegistryReadOnly
  ]
}

# ---------------------------------------------------------------------------
# EKS Access Entries
# Grants IAM principals RBAC access to the cluster via the modern EKS
# Access Entry API. Without this, only the IAM principal that created the
# cluster (i.e. whichever identity ran `terraform apply`) can access it,
# and any other IAM user/role (e.g. your console user, or Jenkins if it
# uses a different identity) will see "Unauthorized" errors.
# ---------------------------------------------------------------------------

variable "account_id" {
  description = "AWS Account ID"
  type        = string
  default     = "215675829312"
}

variable "console_iam_user" {
  description = "IAM user that needs console/kubectl access to the cluster"
  type        = string
  default     = "Gayatri"
}

variable "jenkins_principal_arn" {
  description = "IAM role or user ARN that Jenkins assumes when running kubectl/terraform"
  type        = string
  # TODO: replace with the actual ARN Jenkins uses, e.g.
  # "arn:aws:iam::215675829312:role/JenkinsEksDeployRole"
  default = "arn:aws:iam::215675829312:role/CHANGE_ME_JENKINS_ROLE"
}

# --- Grant your IAM console user cluster-admin access ---
resource "aws_eks_access_entry" "gayatri" {
  cluster_name  = aws_eks_cluster.project-cluster.name
  principal_arn = "arn:aws:iam::${var.account_id}:user/${var.console_iam_user}"
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "gayatri-admin" {
  cluster_name  = aws_eks_cluster.project-cluster.name
  principal_arn = "arn:aws:iam::${var.account_id}:user/${var.console_iam_user}"
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.gayatri]
}

# --- Grant the Jenkins IAM role/user access, so kubectl/deploy pipeline
#     stages work even if Jenkins uses a different principal than the one
#     that ran `terraform apply` ---
resource "aws_eks_access_entry" "jenkins" {
  cluster_name  = aws_eks_cluster.project-cluster.name
  principal_arn = var.jenkins_principal_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins-admin" {
  cluster_name  = aws_eks_cluster.project-cluster.name
  principal_arn = var.jenkins_principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.jenkins]
}

