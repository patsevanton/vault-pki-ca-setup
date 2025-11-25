# Инструкция по настройке Удостоверяющего Центра (CA) на базе HashiCorp Vault и OpenSSL в Kubernetes

## Обзор

Эта инструкция представляет собой полное руководство по развертыванию отказоустойчивого (High-Availability) экземпляра HashiCorp Vault в кластере Kubernetes. Мы настроим двухуровневую PKI, где **корневой сертификат `apatsev.corp` создается через OpenSSL**, а **промежуточный CA `intermediate.apatsev.corp` импортируется и настраивается в Vault**. Интегрируем систему с `cert-manager` для автоматического выпуска и обновления TLS-сертификатов, включая сертификат для самого Vault.

**План:**

1.  **Установка Vault в Kubernetes:** Развертывание отказоустойчивого кластера Vault с использованием Helm-чарта и встроенного хранилища Raft.
2.  **Создание корневого и промежуточного сертификатов через OpenSSL:** Генерация корневого сертификата `apatsev.corp` и промежуточного CA `intermediate.apatsev.corp` с помощью OpenSSL.
3.  **Импорт промежуточного сертификата в Vault:** Настройка PKI-движка в Vault для промежуточного CA с полной конфигурацией URL-адресов.
4.  **Интеграция с cert-manager:** Установка и настройка `cert-manager` для автоматизации жизненного цикла сертификатов.
5.  **Выпуск и применение сертификата для Vault:** Использование `cert-manager` для получения TLS-сертификата для Vault от промежуточного CA.
6.  **Создание ролей и выпуск сертификатов для приложений:** Демонстрация процесса создания ролей для различных сервисов и автоматический выпуск сертификатов для них.

## Предварительные требования

*   Установлен кластер Kubernetes.
*   Установленные утилиты командной строки: `kubectl`, `helm`, `openssl`.
*   Настроенный `kubectl` для работы с вашим кластером.
*   Установленная утилита `jq` для удобной обработки JSON-вывода.
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
helm install vault hashicorp/vault --namespace vault --wait --values vault-values.yaml
```

**Проверка:** Дождитесь запуска подов:
```bash
kubectl get pods -n vault
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
# Создаем конфиг для корневого CA
cat <<EOF > rootCA.cnf
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = v3_ca
prompt = no

[ req_distinguished_name ]
C = RU
ST = Omsk Oblast
L = Omsk
O = MyCompany
OU = Apatsev
CN = apatsev.corp Root CA

[ v3_ca ]
basicConstraints = critical, CA:TRUE, pathlen:1
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF
```

# Создаем приватный ключ для корневого CA
```bash
openssl genrsa -out rootCA.key 4096
```

# Создаем самоподписанный корневой сертификат
```bash
openssl req -x509 -new -nodes -key rootCA.key -sha256 -days 3650 -out rootCA.crt -config rootCA.cnf -extensions v3_ca
```

**Проверка:**
```bash
openssl x509 -in rootCA.crt -text -noout | grep "Subject:"
```

**2.2. Создание промежуточного сертификата через OpenSSL:**

```bash
# Создаем приватный ключ для промежуточного CA
openssl genrsa -out intermediateCA.key 4096
```

# Создаем конфиг для промежуточного CA
```bash
cat <<EOF > intermediateCA.cnf
[ req ]
distinguished_name = req_distinguished_name
prompt = no

[ req_distinguished_name ]
C = RU
ST = Omsk Oblast
L = Omsk
O = MyCompany
OU = Apatsev
CN = intermediate.apatsev.corp Intermediate CA

[ v3_intermediate_ca ]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, digitalSignature, cRLSign, keyCertSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
authorityInfoAccess = @issuer_info
crlDistributionPoints = @crl_info

[ issuer_info ]
caIssuers;URI.0 = http://vault.apatsev.corp/v1/pki/ca

[ crl_info ]
URI.0 = http://vault.apatsev.corp/v1/pki/crl
EOF
```

# Создаем CSR для промежуточного CA
```bash
openssl req -new -key intermediateCA.key -out intermediateCA.csr -config intermediateCA.cnf
```

# Подписываем промежуточный CA корневым
```bash
openssl x509 -req -in intermediateCA.csr \
  -CA rootCA.crt -CAkey rootCA.key -CAcreateserial \
  -out intermediateCA.crt -days 1825 -sha256 \
  -extfile intermediateCA.cnf -extensions v3_intermediate_ca
```

Проверяем цепочку сертификатов:
```bash
openssl verify -CAfile rootCA.crt intermediateCA.crt
```

### **Шаг 3: Импорт промежуточного сертификата в Vault с полной конфигурацией**

**3.1. Настройка подключения к Vault:**

Запустите в отдельном окне проброс порта
```bash
kubectl port-forward -n vault service/vault 8200:8200
```

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="${VAULT_ROOT_TOKEN}"
```

**Проверка подключения:**
```bash
vault status
```

**3.2. Импорт промежуточного CA в Vault:**

```bash
# Включаем PKI движок для промежуточного CA
vault secrets enable -path=pki -description="Apatsev Intermediate PKI" -max-lease-ttl="43800h" pki
```

# Импортируем промежуточный сертификат и ключ
```bash
vault write pki/config/ca pem_bundle="$(cat intermediateCA.crt intermediateCA.key)"
```

# Настраиваем URL-адреса для промежуточного CA
```bash
vault write pki/config/urls \
    issuing_certificates="http://vault.apatsev.corp/v1/pki/ca" \
    crl_distribution_points="http://vault.apatsev.corp/v1/pki/crl"
```

**Проверка:**
```bash
vault secrets list | grep pki
```

**3.3. Создание роли для выпуска сертификатов:**

```bash
vault write pki/roles/k8s-services \
    allowed_domains="apatsev.corp,svc.cluster.local,vault,vault.vault" \
    allow_subdomains=true \
    max_ttl="8760h" \
    key_bits="2048" \
    key_type="rsa" \
    allow_bare_domains=true \
    allow_ip_sans=true \
    allow_localhost=true \
    server_flag=true \
    enforce_hostnames=false \
    key_usage="DigitalSignature,KeyEncipherment" \
    ext_key_usage="ServerAuth"
```

### **Шаг 4: Установка и настройка cert-manager**

**4.1. Установка cert-manager:**

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.18.2 \
  --set crds.enabled=true
```

**4.2. Настройка аутентификации для cert-manager в Vault:**

```bash
# Включаем аутентификацию AppRole
vault auth enable approle
```

# Создаем политику для cert-manager
```
vault policy write cert-manager-policy - <<EOF
path "pki/sign/k8s-services" {
  capabilities = ["create", "update"]
}
path "pki/issue/k8s-services" {
  capabilities = ["create"]
}
EOF
```

# Создаем AppRole
```
vault write auth/approle/role/cert-manager \
    secret_id_ttl=10m \
    token_num_uses=100 \
    token_ttl=20m \
    token_max_ttl=30m \
    secret_id_num_uses=40 \
    token_policies="cert-manager-policy"
```

# Получаем RoleID и SecretID
```
ROLE_ID=$(vault read auth/approle/role/cert-manager/role-id -format=json | jq -r .data.role_id)
SECRET_ID=$(vault write -f auth/approle/role/cert-manager/secret-id -format=json | jq -r .data.secret_id)
```

# Создаем Kubernetes Secret
```
kubectl create secret generic cert-manager-vault-approle \
    --namespace=cert-manager \
    --from-literal=secretId="${SECRET_ID}"
```

**4.3. Создание VaultIssuer:**

# Создаем файл с полной цепочкой сертификатов для caBundle
```bash
cat rootCA.crt intermediateCA.crt > full-chain.crt
```

Создаем ClusterIssuer
```
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-cluster-issuer
spec:
  vault:
    server: http://vault.vault.svc.cluster.local:8200
    path: pki/sign/k8s-services
    caBundle: $(cat full-chain.crt | base64 | tr -d '\n')
    auth:
      appRole:
        path: approle
        roleId: "${ROLE_ID}"
        secretRef:
          name: cert-manager-vault-approle
          key: secretId
EOF
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
  - vault.vault.svc.cluster.local
  - localhost
  ipAddresses:
  - 127.0.0.1
EOF
```

Применяем
```
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
        tls_disable = 0
        address = "[::]:8200"
        cluster_address = "[::]:8201"
        tls_cert_file = "/vault/userconfig/vault-server-tls/tls.crt"
        tls_key_file = "/vault/userconfig/vault-server-tls/tls.key"
      }
      
      api_addr = "https://vault.vault.svc.cluster.local:8200"
      cluster_addr = "https://\${POD_IP}:8201"

  extraVolumes:
    - type: secret
      name: vault-server-tls
      path: /vault/userconfig/vault-server-tls
  
ui:
  enabled: true
  service:
    type: ClusterIP
```

Примените обновления:

```bash
helm upgrade vault hashicorp/vault --namespace vault -f vault-values.yaml
```

### **Шаг 6: Пример выпуска сертификата для приложения**

Создаем Certificate
```
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
  - "*.apps.apatsev.corp"
EOF
```

Применяем
```
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

# Проверка статуса issuer
kubectl get clusterissuer vault-cluster-issuer -o yaml
```

## Решение проблем

**Если cert-manager не может выпустить сертификаты:**

1. Проверьте логи cert-manager: `kubectl logs -n cert-manager deployment/cert-manager`
2. Убедитесь, что Secret с secretId существует: `kubectl get secrets -n cert-manager cert-manager-vault-approle`
3. Проверьте политики Vault: `vault policy read cert-manager-policy`
4. Проверьте, что все URL-адреса правильно сконфигурированы в PKI-движке
5. Убедитесь, что промежуточный сертификат имеет правильные расширения `keyUsage = critical, digitalSignature, cRLSign, keyCertSign`

## Заключение

После выполнения всех шагов у вас будет полностью функционирующая PKI-инфраструктура в Kubernetes с HashiCorp Vault в качестве промежуточного Удостоверяющего Центра и автоматическим управлением сертификатами через cert-manager. Корневой сертификат хранится отдельно в файловой системе, что обеспечивает дополнительную безопасность, в то время как промежуточный CA в Vault используется для повседневного выпуска сертификатов.