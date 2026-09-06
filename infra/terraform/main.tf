resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace
  }
}

resource "kubernetes_config_map_v1" "app" {
  metadata {
    name      = "${var.app_name}-config"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  data = {
    ENVIRONMENT = var.environment
    HOST        = var.host
    PORT        = tostring(var.app_port)
    REDIS_HOST  = var.redis_name
    REDIS_PORT  = tostring(var.redis_port)
    REDIS_DB    = tostring(var.redis_db)
  }
}

resource "kubernetes_service_v1" "redis" {
  metadata {
    name      = var.redis_name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    selector = {
      app = var.redis_name
    }

    port {
      port        = var.redis_port
      target_port = var.redis_port
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_persistent_volume_claim_v1" "redis" {
  metadata {
    name      = "${var.redis_name}-data"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    access_modes = ["ReadWriteOnce"]

    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment_v1" "redis" {
  metadata {
    name      = var.redis_name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels = {
      app = var.redis_name
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = var.redis_name
      }
    }

    template {
      metadata {
        labels = {
          app = var.redis_name
        }
      }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 999
          fs_group        = 999
        }

        container {
          name  = "redis"
          image = "redis:7-alpine"

          command = ["redis-server", "--appendonly", "yes"]

          port {
            container_port = var.redis_port
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          readiness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }

          liveness_probe {
            exec {
              command = ["redis-cli", "ping"]
            }
            initial_delay_seconds = 15
            period_seconds        = 10
          }
        }

        volume {
          name = "data"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.redis.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment_v1" "app" {
  metadata {
    name      = var.app_name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels = {
      app = var.app_name
    }
  }

  spec {
    replicas = var.replicas

    strategy {
      type = "RollingUpdate"

      rolling_update {
        max_unavailable = "0"
        max_surge       = "1"
      }
    }

    selector {
      match_labels = {
        app = var.app_name
      }
    }

    template {
      metadata {
        labels = {
          app = var.app_name
        }
      }

      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"

          label_selector {
            match_labels = {
              app = var.app_name
            }
          }
        }

        container {
          name              = "app"
          image             = var.image
          image_pull_policy = "IfNotPresent"

          port {
            container_port = var.app_port
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.app.metadata[0].name
            }
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "256Mi"
            }
          }

          readiness_probe {
            http_get {
              path = "/"
              port = var.app_port
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 2
            failure_threshold     = 3
          }

          liveness_probe {
            http_get {
              path = "/"
              port = var.app_port
            }
            initial_delay_seconds = 15
            period_seconds        = 10
            timeout_seconds       = 2
            failure_threshold     = 3
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = false
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "app" {
  metadata {
    name      = var.app_name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    selector = {
      app = var.app_name
    }

    port {
      port        = 80
      target_port = var.app_port
    }

    type = "ClusterIP"
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "app" {
  metadata {
    name      = "${var.app_name}-hpa"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.app.metadata[0].name
    }

    metric {
      type = "Resource"

      resource {
        name = "cpu"

        target {
          type                = "Utilization"
          average_utilization = var.cpu_target_percent
        }
      }
    }

    behavior {
      scale_up {
        stabilization_window_seconds = 0

        select_policy = "Max"

        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 60
        }
      }

      scale_down {
        stabilization_window_seconds = 300

        select_policy = "Max"

        policy {
          type           = "Percent"
          value          = 50
          period_seconds = 60
        }
      }
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "app" {
  metadata {
    name      = "${var.app_name}-pdb"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    min_available = 2

    selector {
      match_labels = {
        app = var.app_name
      }
    }
  }
}

resource "kubernetes_ingress_v1" "app" {
  metadata {
    name      = var.app_name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      host = "tradebyte.local"

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.app.metadata[0].name

              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

output "namespace" {
  value = kubernetes_namespace_v1.this.metadata[0].name
}

output "app_service" {
  value = kubernetes_service_v1.app.metadata[0].name
}
