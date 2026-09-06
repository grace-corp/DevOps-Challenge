resource "kubernetes_service_v1" "vault" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }
  spec {
    selector = {
      app = "vault"
    }
    port {
      port        = 8200
      target_port = 8200
    }
    type = "ClusterIP"
  }
}

resource "kubernetes_deployment_v1" "vault" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels = {
      app = "vault"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "vault"
      }
    }
    template {
      metadata {
        labels = {
          app = "vault"
        }
      }
      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 100
          fs_group        = 1000
        }
        container {
          name  = "vault"
          image = "hashicorp/vault:1.15"
          args  = ["server", "-dev", "-dev-root-token-id=root"]
          
          port {
            container_port = 8200
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "128Mi"
            }
          }
          security_context {
            allow_privilege_escalation = false
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }
}
