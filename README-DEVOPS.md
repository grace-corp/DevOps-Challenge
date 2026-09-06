# TradeByte DevOps Implementation

## Architecture

The challenge asks for a robust, production-ready, and scalable Kubernetes deployment featuring at least three replicas, CPU-based autoscaling, secure runtime configurations, and performance/scalability isolation patterns.

This implementation leverages:
* **Docker:** For reliable application multi-stage packaging.
* **Minikube:** Providing a local single-node development cluster infrastructure.
* **Kubernetes:** Orchestrating core application container runtimes.
* **Terraform:** Managing declarative Kubernetes state lifecycles.
* **Terragrunt:** Facilitating DRY, modular configurations for the Terraform provider engine.
* **Redis:** Deployed internally to isolate the datastore for evaluation portability.
* **GitHub Actions:** Driving end-to-end linting, image scanning, and real Kubernetes integration verification.

### Runtime Topology

```text
Host Machine Browser / Curl
            |
            v
   Kubernetes Service (Port-Forwarded / Localhost Tunnel)
            |
            v
    ClusterIP Service
            |
      +-----+-----+

      |     |     |
     app   app   app       <- 3 replicas minimum (Unprivileged UID 1000)

      |     |     |
      +-----+-----+
            |
            v
      Redis Service
            |
            v
      Redis Pod + PVC      <- Single Replica (Secure UID 999)

Horizontal Pod Autoscaler (HPA) monitors CPU utilization and dynamically 
scales app replicas up to 10 instances.
```

## Why Redis is Containerized Locally

For this engineering evaluation, Redis is deployed within the same Kubernetes cluster namespace to guarantee that the entire infrastructure stack remains self-contained, reproducible, and portable for the evaluator. 

The Redis deployment tracks a single replica backed by a `PersistentVolumeClaim` (PVC) for data persistence. In a live cloud production architecture, this single pod layout would represent an availability bottleneck; I would recommend migrating this layer to a cloud-managed service (such as AWS ElastiCache) or a clustered High-Availability Redis/Valkey topology.

## Local Deployment & Fully Automated Setup

On WSL2 with Docker Desktop and WSL integration active, the complete, automated local environment can be brought online using a single script wrapper. 

The build pipeline is designed to be completely idempotent:

```bash
# 1. Grant execution rights to the script matrix
chmod +x scripts/*.sh

# 2. Run the main bootstrap orchestration script
./scripts/bootstrap.sh
```

### What the Bootstrap Script Automates:
1. Detects and validates system packages, ensuring `kubectl`, Minikube, Terraform, and Terragrunt are installed.
2. Synchronizes local credentials with the active Docker daemon.
3. Initializes Minikube using a standard, cluster-agnostic default profile configuration with an optimized 2GB memory profile.
4. Activates mandatory cluster extensions: `metrics-server`, `ingress`, and localized storage provisioners.
5. Packages your local environment utilizing a backwards-compatible `python:3.9-slim` base context to resolve legacy framework compilation criteria.
6. Synchronizes image metadata directly into Minikube's internal container directory.
7. Executes a Terragrunt lifecycle orchestration block to dynamically spin up your live cluster workloads.
8. Monitors deployment rollout thresholds until pods report as fully healthy.

### Exposing the Infrastructure & Viewing the App

Because Minikube's virtual bridge network layer is inherently isolated from the host Windows operating system inside WSL2, the application is exposed to the local machine interfaces using high-performance service port-forwarding:

```bash
# In your active terminal, open a secure background port forward bridge:
kubectl port-forward service/tradebyte-app 8080:80 -n tradebyte
```

Once active, open any standard browser on your Windows host machine and navigate to:
```text
http://localhost:8080
```
*Note: You will see the application load successfully, showing the dynamic `PROD` configuration flag and an active rolling value stream tracking against the underlying Redis datastore container.*

### Running Validation Checks

```bash
# Run the automated smoke test script to verify endpoint reliability
./scripts/smoke-test.sh

# Track active workload statuses inside your namespace
kubectl get pods -n tradebyte
kubectl get hpa -n tradebyte
kubectl describe hpa tradebyte-app-hpa -n tradebyte
```

## Security & Hardening Choices

* **Least-Privilege User Contexts:** Both containers have been completely stripped of root execution capabilities to secure the runtime matrix against cluster escape vulnerabilities. The Redis deployment container explicitly initializes under non-root UID `999`. The primary Python application builds and executes under user UID `1000`.
* **Container Defenses:** App specifications explicitly introduce standard `RuntimeDefault` seccomp security profiles, block execution elevation (`allowPrivilegeEscalation: false`), and drop all granular host Linux capabilities (`drop: ["ALL"]`).
* **Environment Configuration Isolation:** Non-sensitive settings are dynamically injected at runtime via Kubernetes ConfigMaps, removing the need for environment data leaks within image file layers.
* **Probes & Thresholds:** Both layers implement strict readiness and liveness checks (via custom HTTP lookups for the app and `redis-cli ping` executors for the database) to ensure traffic routing drops failing pods instantly.

## Availability & Auto-Scaling

* **Replication Thresholds:** Configured to maintain a tight `maxUnavailable: 0` and `maxSurge: 1` rolling update strategy to guarantee completely zero-downtime cluster upgrades.
* **Autoscaling Mechanics:** An active Horizontal Pod Autoscaler (HPA) checks container tracking targets, configuring the replica array to expand up to **10 instances** if target CPU demands cross a 70% utilization barrier.
* **Disruption Protections:** A Pod Disruption Budget (`tradebyte-app-pdb`) enforces a mandatory minimum of **2 concurrent ready application pods** during all planned node operations.

## CI Pipeline (GitHub Actions)

Since GitHub-hosted build runners execute inside isolated temporary environments that cannot route back to a physical developer workspace, the GitHub Actions configuration uses an ephemeral **Kind (Kubernetes in Docker)** cluster to run end-to-end integration tracking.

The CI workflow automatically performs:
1. Natively triggers isolated python testing metrics under a verified `3.9` environment layer.
2. Compiles a localized release container package.
3. Automatically runs an **Aqua Security Trivy Vulnerability Scan** to inspect code layers for HIGH or CRITICAL security threats.
4. Executes static validation rules across your Terragrunt architecture.
5. Instantiates a clean, ephemeral Kind environment inside the GitHub virtual runner.
6. Deploys live `metrics-server` extensions and links context configurations.
7. Executes a trial Terragrunt deploy to verify manifest stability.
8. Asserts that the cluster scales to at least 3 active running pods and that the HPA initializes successfully before completing the pull request review gate.
