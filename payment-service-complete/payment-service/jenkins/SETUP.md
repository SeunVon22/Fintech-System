# Jenkins Credentials Setup Guide
# Add these under: Jenkins → Manage Jenkins → Credentials → Global

## Required credentials (ID → Type → Description)

| Credential ID        | Type        | Value                                      |
|----------------------|-------------|--------------------------------------------|
| acr-name             | Secret text | Your ACR name e.g. moniepointprodacr       |
| acr-login-server     | Secret text | moniepointprodacr.azurecr.io               |
| aks-cluster-name     | Secret text | monie-prod-aks                             |
| aks-resource-group   | Secret text | monie-prod-rg                              |
| sonarqube-token      | Secret text | Token from SonarQube → My Account → Tokens |
| sonarqube-url        | Secret text | http://your-sonarqube-host:9000            |

## Required Jenkins plugins
- Kubernetes Plugin           (agent pod templates)
- Pipeline                    (declarative pipeline)
- Git                         (SCM checkout)
- JUnit                       (test result publishing)
- Coverage                    (code coverage reports)
- SonarQube Scanner           (SAST integration)
- Slack Notification          (deployment alerts)
- GitHub                      (webhook trigger)
- Credentials Binding         (secrets injection)
- Timestamper                 (log timestamps)

## Jenkins service account (AKS)
# The Jenkins agent pod needs a Kubernetes service account with
# permission to kubectl apply into staging and production namespaces.
# Apply this to your AKS cluster:

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-agent
  namespace: jenkins
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: jenkins-deploy
rules:
  - apiGroups: ["", "apps", "networking.k8s.io", "autoscaling", "policy"]
    resources: ["*"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: jenkins-deploy
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: jenkins-deploy
subjects:
  - kind: ServiceAccount
    name: jenkins-agent
    namespace: jenkins
