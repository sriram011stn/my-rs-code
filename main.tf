# Create/ensure the Kind cluster and set kubectl context
resource "null_resource" "kind_cluster" {
  triggers = { cfg = filesha1("${path.module}/kind-config.yaml") }

  provisioner "local-exec" {
    command = <<EOT
set -e
if ! kind get clusters | grep -q tf-immu; then
  kind create cluster --name tf-immu --config kind-config.yaml
fi
kubectl config use-context kind-tf-immu
kubectl cluster-info --context kind-tf-immu
EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kind delete cluster --name tf-immu || true"
  }
}

# Demo namespace + workload
resource "kubernetes_namespace" "demo" {
  metadata { name = "demo" }
  depends_on = [null_resource.kind_cluster]
}

resource "kubernetes_deployment" "demo_app" {
  metadata {
    name      = "demo-app"
    namespace = kubernetes_namespace.demo.metadata[0].name
    labels    = { app = "demo-app" }
  }

  spec {
    replicas = 1
    selector { match_labels = { app = "demo-app" } }
    template {
      metadata { labels = { app = "demo-app" } }
      spec {
        container {
          name  = "nginx"
          image = "nginx:stable"
          port {
            container_port = 80
          }
        }
      }
    }
  }

  depends_on = [kubernetes_namespace.demo]
}

resource "kubernetes_service" "demo_svc" {
  metadata {
    name      = "demo-svc"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }
  spec {
    selector = { app = "demo-app" }
    port {
      port        = 80
      target_port = 80
    }
    type = "ClusterIP"
  }
  depends_on = [kubernetes_deployment.demo_app]
}

# Tetragon (eBPF) via Helm
resource "helm_release" "tetragon" {
  name       = "tetragon"
  repository = "https://helm.cilium.io/"
  chart      = "tetragon"
  version    = "1.1.0"
  namespace  = "kube-system"
  values     = [file("${path.module}/helm/tetragon-values.yaml")]
  depends_on = [null_resource.kind_cluster]
}

# Apply TracingPolicy after Tetragon + CRDs are ready
resource "null_resource" "policy_apply" {
  depends_on = [
    helm_release.tetragon,
    kubernetes_deployment.demo_app,
    kubernetes_service.demo_svc
  ]

  provisioner "local-exec" {
    command = <<EOT
set -e
kubectl config use-context kind-tf-immu
kubectl -n kube-system rollout status ds/tetragon --timeout=180s
kubectl wait --for=condition=Established crd/tracingpolicies.cilium.io --timeout=180s
kubectl apply -f ${path.module}/k8s/demo-deny-policy.yaml
EOT
  }
}
