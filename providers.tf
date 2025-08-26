terraform {
  required_version = ">= 1.5.0"
  required_providers {
    kubernetes = { 
      source = "hashicorp/kubernetes"
      version = "~> 2.31" 
    }
    helm = { 
      source = "hashicorp/helm"
      version = "~> 2.13" 
    }
    null = { 
      source = "hashicorp/null"
      version = "~> 3.2" 
    }
  }
}

provider "kubernetes" {
  config_path    = pathexpand("~/.kube/config")
  config_context = "kind-tf-immu"
}

provider "helm" {
  kubernetes {
    config_path    = pathexpand("~/.kube/config")
    config_context = "kind-tf-immu"
  }
}
