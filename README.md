# Инструкция по настройке Удостоверяющего Центра (CA) на базе HashiCorp Vault и OpenSSL в Kubernetes

## Обзор

Эта инструкция представляет собой полное руководство по развертыванию отказоустойчивого (High-Availability) экземпляра HashiCorp Vault в кластере Kubernetes. Мы настроим двухуровневую PKI, где **корневой сертификат `apatsev.corp` и промежуточный CA `intermediate.apatsev.corp` создаются через OpenSSL**, а затем импортируются в Vault. Интегрируем систему с `cert-manager` для автоматического выпуска и обновления TLS-сертификатов, включая сертификат для самого Vault.

**Цели данной инструкции:**

1.  **Установка Vault в Kubernetes:** Развертывание отказоустойчивого кластера Vault с использованием Helm-чарта и встроенного хранилища Raft.
2.  **Создание корневого и промежуточного сертификатов через OpenSSL:** Генерация корневого сертификата `apatsev.corp` и промежуточного CA `intermediate.apatsev.corp` с помощью OpenSSL.
3.  **Импорт сертификатов в Vault:** Настройка PKI-движков в Vault с использованием предварительно созданных сертификатов.
4.  **Интеграция с cert-manager:** Установка и настройка `cert-manager` для автоматизации жизненного цикла сертификатов.
5.  **Выпуск и применение сертификата для Vault:** Использование `cert-manager` для получения TLS-сертификата для Vault от промежуточного CA.
6.  **Создание ролей и выпуск сертификатов для приложений:** Демонстрация процесса создания ролей для различных сервисов и автоматический выпуск сертификатов для них.

## Предварительные требования

*   Установлен кластер Kubernetes.
*   Установленные утилиты командной строки: `kubectl`, `helm`, `openssl`.
*   Настроенный `kubectl` для работы с вашим кластером.
*   Установленная утилита `jq` для удобной обработки JSON-вывода.
*   Установленная утилита `yq`
*   Установленная утилита `vault`.

### **Шаг 1: Установка HashiCorp Vault в режиме HA в Kubernetes**

Мы будем использовать официальный Helm-чарт от HashiCorp для развертывания Vault. Конфигурация будет рассчитана на отказоустойчивый режим (HA) с использованием встроенного хранилища Raft.

**1.1. Добавление Helm-репозитория HashiCorp:**

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

**Проверка:**
```bash
helm repo list | grep hashicorp
```

**1.2. Создание файла конфигурации values.yaml:**

Создайте файл `vault-values.yaml` со следующим содержимым:

```yaml
server:
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
ui:
  enabled: true
```

**1.3. Установка Vault с помощью Helm:**

```bash
kubectl create namespace vault
helm install vault hashicorp/vault --namespace vault --values vault-values.yaml
```

**Проверка:** Дождитесь запуска подов:
```bash
kubectl get pods -n vault -w
```

**1.4. Инициализация и распечатывание Vault:**

Инициализируем Vault и сохраняем ключи:

```bash
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > vault-init-keys.json
```

**Проверка созданных ключей:**
```bash
cat vault-init-keys.json | jq
```

Извлекаем ключи:
```bash
VAULT_UNSEAL_KEY=$(jq -r ".unseal_keys_b64[0]" vault-init-keys.json)
VAULT_ROOT_TOKEN=$(jq -r ".root_token" vault-init-keys.json)
```

Распечатываем все ноды Vault:

```bash
# Распечатываем vault-0
kubectl exec -n vault vault-0 -- vault operator unseal $VAULT_UNSEAL_KEY

# Присоединяем и распечатываем vault-1
kubectl exec -n vault vault-1 -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec -n vault vault-1 -- vault operator unseal $VAULT_UNSEAL_KEY

# Присоединяем и распечатываем vault-2
kubectl exec -n vault vault-2 -- vault operator raft join http://vault-0.vault-internal:8200
kubectl exec -n vault vault-2 -- vault operator unseal $VAULT_UNSEAL_KEY
```

Проверяем статус:

```bash
kubectl get pods -n vault
```

### **Шаг 2: Создание корневого и промежуточного сертификатов через OpenSSL**

**2.1. Создание корневого сертификата через OpenSSL:**

```bash
# Создаем приватный ключ для корневого CA
openssl genrsa -out rootCA.key 4096

# Создаем самоподписанный корневой сертификат
openssl req -x509 -new -nodes -key rootCA.key -sha256 -days 3650 \
  -out rootCA.crt \
  -subj "/C=RU/ST=Omsk Oblast/L=Omsk/O=MyCompany/OU=Apatsev/CN=apatsev.corp Root CA"
```

**Проверка:**
```bash
openssl x509 -in rootCA.crt -text -noout | grep "Subject:"
```

**2.2. Создание промежуточного сертификата через OpenSSL:**

```bash
# Создаем приватный ключ для промежуточного CA
openssl genrsa -out intermediateCA.key 4096

# Создаем CSR для промежуточного CA
openssl req -new -key intermediateCA.key -sha256 -days 1825 \
  -out intermediateCA.csr \
  -subj "/C=RU/ST=Omsk Oblast/L=Omsk/O=MyCompany/OU=Apatsev/CN=intermediate.apatsev.corp Intermediate CA"

# Создаем файл конфигурации расширений
cat <<EOF > intermediate_ext.cnf
[ v3_ca ]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

# Подписываем CSR промежуточного CA корневым CA
openssl x509 -req -in intermediateCA.csr \
  -CA rootCA.crt \
  -CAkey rootCA.key \
  -CAcreateserial \
  -out intermediateCA.crt \
  -days 1825 \
  -sha256 \
  -extfile intermediate_ext.cnf \
  -extensions v3_ca
```

Проверяем цепочку сертификатов:

```bash
openssl verify -CAfile rootCA.crt intermediateCA.crt
```

## Шаг 3: Импорт сертификатов в Vault

### **Шаг 3: Импорт сертификатов в Vault и настройка PKI**

**3.1. Настройка подключения к Vault:**

```bash
kubectl port-forward -n vault service/vault 8200:8200 &
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="${VAULT_ROOT_TOKEN}"
```

**Проверка подключения:**
```bash
vault status
```

**3.2. Импорт корневого CA в Vault:**

```bash
# Включаем PKI движок для корневого CA
vault secrets enable -path=pki-root -description="Apatsev Root PKI" -max-lease-ttl="87600h" pki

# Импортируем корневой сертификат и ключ
vault write pki-root/config/ca pem_bundle="$(cat rootCA.crt rootCA.key)"

# Настраиваем URL-адреса
vault write pki-root/config/urls \
    issuing_certificates="${VAULT_ADDR}/v1/pki-root/ca" \
    crl_distribution_points="${VAULT_ADDR}/v1/pki-root/crl"
```

**3.3. Импорт промежуточного CA в Vault:**

```bash
# Включаем PKI движок для промежуточного CA
vault secrets enable -path=pki-intermediate -description="Apatsev Intermediate PKI" -max-lease-ttl="43800h" pki

# Импортируем промежуточный сертификат и ключ
vault write pki-intermediate/config/ca pem_bundle="$(cat intermediateCA.crt intermediateCA.key)"

# Настраиваем URL-адреса
vault write pki-intermediate/config/urls \
    issuing_certificates="${VAULT_ADDR}/v1/pki-intermediate/ca" \
    crl_distribution_points="${VAULT_ADDR}/v1/pki-intermediate/crl"
```

**Проверка:**
```bash
vault secrets list | grep pki
```

**3.4. Создание роли для выпуска сертификатов:**

```bash
vault write pki-intermediate/roles/k8s-services \
    allowed_domains="apatsev.corp,svc.cluster.local" \
    allow_subdomains=true \
    max_ttl="8760h" \
    key_bits="2048" \
    key_type="rsa" \
    allow_bare_domains=true \
    allow_ip_sans=true \
    allow_localhost=true \
    server_flag=true \
    enforce_hostnames=true \
    key_usage="DigitalSignature,KeyEncipherment" \
    ext_key_usage="ServerAuth"
```

## Шаг 5: Настройка cert-manager

### **Шаг 4: Установка и настройка cert-manager**

**4.1. Установка cert-manager:**

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.18.2 \
  --set crds.enabled=true
```

**4.2. Настройка аутентификации для cert-manager в Vault:**

```bash
# Включаем аутентификацию AppRole
vault auth enable approle

# Создаем политику для cert-manager
vault policy write cert-manager-policy - <<EOF
path "pki-intermediate/sign/k8s-services" {
  capabilities = ["create", "update"]
}
path "pki-intermediate/issue/k8s-services" {
  capabilities = ["create"]
}
EOF

# Создаем AppRole
vault write auth/approle/role/cert-manager \
    secret_id_ttl=10m \
    token_num_uses=100 \
    token_ttl=20m \
    token_max_ttl=30m \
    secret_id_num_uses=40 \
    token_policies="cert-manager-policy"

# Получаем RoleID и SecretID
ROLE_ID=$(vault read auth/approle/role/cert-manager/role-id -format=json | jq -r .data.role_id)
SECRET_ID=$(vault write -f auth/approle/role/cert-manager/secret-id -format=json | jq -r .data.secret_id)

# Создаем Kubernetes Secret
kubectl create secret generic cert-manager-vault-approle \
    --namespace=cert-manager \
    --from-literal=secretId="${SECRET_ID}"
```

**4.3. Создание VaultIssuer:**


```bash
cat <<EOF > vault-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-cluster-issuer
spec:
  vault:
    server: http://vault.vault.svc.cluster.local:8200
    path: pki-intermediate/sign/k8s-services
    caBundle: $(cat rootCA.crt intermediateCA.crt | base64 | tr -d '\n')
    auth:
      appRole:
        path: approle
        roleId: "${ROLE_ID}"
        secretRef:
          name: cert-manager-vault-approle
          key: secretId
EOF

kubectl apply -f vault-issuer.yaml
```

**Проверка:**
```bash
kubectl get clusterissuer vault-cluster-issuer -o wide
```

### **Шаг 5: Выпуск TLS-сертификата для Vault**

**5.1. Создание ресурса Certificate для Vault:**

```bash
cat <<EOF > vault-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vault-server-tls
  namespace: vault
spec:
  secretName: vault-server-tls
  issuerRef:
    name: vault-cluster-issuer
    kind: ClusterIssuer
  duration: 720h
  renewBefore: 360h
  commonName: vault.apatsev.corp
  dnsNames:
  - vault.apatsev.corp
  - vault
  - vault.vault
  - vault.vault.svc
  - vault.vault.svc.cluster.local
  - localhost
EOF

kubectl apply -f vault-certificate.yaml
```

**Проверка выпуска сертификата:**
```bash
kubectl get certificate -n vault
kubectl describe certificate vault-server-tls -n vault
```

**5.2. Обновление конфигурации Vault для использования TLS:**

Обновите файл `vault-values.yaml`:

```yaml
server:
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      config: |
        ui = true
        
        storage "raft" {
          path = "/vault/data"
        }
        
        listener "tcp" {
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_cert_file = "/vault/userconfig/vault-server-tls/tls.crt"
          tls_key_file = "/vault/userconfig/vault-server-tls/tls.key"
        }
        
        api_addr = "https://_POD_IP_:8200"
        cluster_addr = "https://_POD_IP_:8201"

  extraVolumes:
    - type: 'secret'
      name: 'vault-server-tls'
  
ui:
  enabled: true
```

Примените обновления:

```bash
helm upgrade vault hashicorp/vault --namespace vault -f vault-values.yaml
```

### **Шаг 6: Пример выпуска сертификата для приложения**

```bash
cat <<EOF > my-app-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-app-tls
  namespace: apps
spec:
  secretName: my-app-tls
  issuerRef:
    name: vault-cluster-issuer
    kind: ClusterIssuer
  duration: 720h
  renewBefore: 360h
  commonName: my-app.apatsev.corp
  dnsNames:
  - my-app.apatsev.corp
EOF

kubectl create namespace apps
kubectl apply -f my-app-certificate.yaml
```

**Проверка:**
```bash
kubectl get certificate my-app-tls
kubectl describe secret my-app-tls
```

### **Проверка работы**

Убедитесь, что все компоненты работают корректно:

```bash
# Проверка подов
kubectl get pods -n vault
kubectl get pods -n cert-manager

# Проверка сертификатов
kubectl get certificates -A

# Проверка секретов с сертификатами
kubectl get secrets -n vault vault-server-tls
kubectl get secrets -n apps my-app-tls
```

Теперь у вас настроен полностью функциональный Удостоверяющий Центр в Kubernetes, где корневой и промежуточный сертификаты создаются через OpenSSL, а Vault используется для управления выпуском сертификатов через автоматизированный workflow с cert-manager.