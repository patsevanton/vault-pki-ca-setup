# Инструкция по настройке Удостоверяющего Центра (CA) на базе HashiCorp Vault и OpenSSL в Kubernetes

## Цель: Автоматическое получение сертификатов от Certificate Autority c самоподписанный сертификатом используя vault и cert-manager в Kubernetes

## Обзор

Эта инструкция представляет собой полное руководство по развертыванию отказоустойчивого кластера HashiCorp Vault в Kubernetes и настройке двухуровневой Public Key Infrastructure (PKI). Корневой сертификат и промежуточный CA создаются через OpenSSL, но промежуточный импортируется и настраивается в Vault для повседневного выпуска сертификатов. Инфраструктура интегрируется с `cert-manager` для автоматического управления жизненным циклом TLS-сертификатов.

![](diagram.png)

**План:**

1.  **Установка Vault в Kubernetes:** Развертывание отказоустойчивого кластера Vault с использованием Helm-чарта и встроенного хранилища Raft, с активацией Ingress непосредственно в чарте.
2.  **Создание корневого и промежуточного сертификатов через OpenSSL:** Генерация корневого сертификата `apatsev.corp` и промежуточного CA `intermediate.apatsev.corp` с помощью OpenSSL.
3.  **Импорт промежуточного сертификата в Vault:** Настройка PKI-движка в Vault для промежуточного CA.
4.  **Интеграция с cert-manager:** Установка и настройка `cert-manager` для автоматизации выпуска и обновления сертификатов.
5.  **Настройка Ingress для Vault через Helm:** Активация и конфигурация Ingress непосредственно в Helm-чарте Vault для безопасного доступа с автоматическим созданием TLS-сертификата.
6.  **Создание ролей и выпуск сертификатов для приложений:** Демонстрация процесса создания ролей для различных сервисов и автоматического выпуска сертификатов для них.

## Комментарии для начинающих DevOps

Перед началом, несколько ключевых концепций, которые помогут понять происходящее:

*   **PKI (Public Key Infrastructure)** — это набор технологий, позволяющих выпускать и управлять цифровыми сертификатами. Вместо одного сертификата используется цепочка доверия: **Корневой CA -Промежуточный CA -Сертификат услуги**. Это повышает безопасность: корневой ключ хранится в сейфе и используется редко, а промежуточный — для повседневных задач.
*   **HashiCorp Vault** — это не просто хранилище секретов, а мощная система управления секретами и шифрования. Его движок **PKI** может выступать в роли полноценного Удостоверяющего Центра.
*   **cert-manager** — это оператор для Kubernetes, который автоматически запрашивает и продлевает TLS-сертификаты у различных провайдеров (в нашем случае — Vault), избавляя вас от рутины.
*   **Ingress** в Kubernetes — это объект, который управляет внешним доступом к услугам внутри кластера, обычно через HTTP/HTTPS. В этой статье весь TLS-трафик расшифровывается на уровне Ingress, а до Vault доходит уже чистый HTTP, что упрощает его конфигурацию.

## Предварительные требования

*   Рабочий кластер Kubernetes.
*   Установленные утилиты командной строки: `kubectl`, `helm`, `openssl`, `jq`, `vault`.
*   Настроенный доступ `kubectl` к целевому кластеру.
*   Установленный и настроенный Ingress-контроллер (например, nginx-ingress).

### **Шаг 1: Установка HashiCorp Vault в режиме HA в Kubernetes с активацией Ingress**

Используется официальный Helm-чарт от HashiCorp для развертывания Vault в отказоустойчивом режиме (HA) с использованием встроенного хранилища Raft и встроенного Ingress.

**1.1. Добавление Helm-репозитория HashiCorp:**
```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

**Проверка:**
```bash
helm repo list | grep hashicorp
```

**1.2. Создание файла конфигурации values.yaml с активированным Ingress:**
*Файл конфигурации определяет параметры развертывания Vault: режим HA, количество реплик, бэкенд-хранилище и настройки Ingress.*
```yaml
server:
  ha:
    enabled: true
    raft:
      enabled: true
ui:
  enabled: true
```

**1.3. Установка Vault с помощью Helm:**
*Команда создает пространство имен и устанавливает Vault с заданной конфигурацией, включая Ingress.*
```bash
kubectl create namespace vault
helm install vault hashicorp/vault --namespace vault --wait --values vault-values.yaml
```

**Проверка:** Дождитесь запуска всех подов и создания Ingress ресурса.
```bash
kubectl get pods -n vault
```

**1.4. Инициализация и распечатывание Vault:**
*Инициализация генерирует корневой токен и ключи для распечатывания. Ключи необходимо сохранить в безопасном месте.*

**ВАЖНО ДЛЯ НАЧИНАЮЩИХ:**
*   `-key-shares=1 -key-threshold=1` — это настройки для демо-среды. В продакшене используйте, например, `-key-shares=5 -key-threshold=3`. Это создаст 5 ключей, и для распечатывания потребуется любые 3 из них. Это реализует схему разделения секрета.
*   Файл `vault-init-keys.json` — САМЫЙ ГЛАВНЫЙ СЕКРЕТ ВО ВСЕЙ ИНФРАСТРУКТУРЕ. Сохраните его в надёжном месте (например, в зашифрованном хранилище). Без него вы не сможете восстановить Vault.
*   **Распечатывание (Unseal)** — это процесс расшифровки данных Vault. При перезагрузке подов Vault окажется в запечатанном состоянии, и его снова нужно будет распечатать этими же ключами. Для автоматизации этого в продакшене используют решения like `vault-agent` или HashiCorp Cloud Platform.

```bash
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > vault-init-keys.json
```

**Проверка созданных ключей:**
```bash
cat vault-init-keys.json | jq
```

**Получение ключа для разблокировки Vault и root-токен для входа:**
```bash
VAULT_UNSEAL_KEY=$(jq -r ".unseal_keys_b64[0]" vault-init-keys.json)
VAULT_ROOT_TOKEN=$(jq -r ".root_token" vault-init-keys.json)
```

**Распечатывание всех нод Vault:**
*Процесс распечатывания делает данные Vault доступными. Каждая нода должна быть распечатана.*
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

**Проверка статуса:**
```bash
kubectl get pods -n vault
```

### **Шаг 2: Создание корневого и промежуточного сертификатов через OpenSSL**

**Пояснение:** Мы создаём двухуровневую PKI. Корневой сертификат (Root CA) — это корень доверия. Его приватный ключ должен храниться максимально защищённо (оффлайн). Промежуточный сертификат (Intermediate CA) подписан корневым и используется для ежедневной выдачи сертификатов. Если он скомпрометирован, мы отзываем его, не трогая корневой.

**2.1. Создание корневого сертификата через OpenSSL:**
*Корневой сертификат является корнем доверия всей инфраструктуры. Его закрытый ключ должен храниться в безопасном месте, в идеале — оффлайн.*

**Создание конфигурационного файла для корневого CA:**
```bash
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

**Генерация приватного ключа для корневого CA:**
```bash
openssl genrsa -out rootCA.key 4096
```

**Создание самоподписанного корневого сертификата:**
```bash
openssl req -x509 -new -nodes -key rootCA.key -sha256 -days 3650 -out rootCA.crt -config rootCA.cnf -extensions v3_ca
```

**Проверка:**
```bash
openssl x509 -in rootCA.crt -text -noout | grep "Subject:"
```

**2.2. Создание промежуточного сертификата через OpenSSL:**
*Промежуточный сертификат будет использоваться Vault для ежедневного выпуска сертификатов, что ограничивает риск компрометации корневого ключа.*

**Генерация приватного ключа для промежуточного CA:**
```bash
openssl genrsa -out intermediateCA.key 4096
```

**Создание конфигурационного файла для промежуточного CA:**
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

**Примечание:** Расширения `authorityInfoAccess` и `crlDistributionPoints` критически важны. Они указывают клиентам (браузерам, ОС) где искать цепочку сертификатов (CA Issuers) и списки отозванных сертификатов (CRL). Мы указываем будущий внешний URL Vault.

**Создание CSR (Certificate Signing Request) для промежуточного CA:**
```bash
openssl req -new -key intermediateCA.key -out intermediateCA.csr -config intermediateCA.cnf
```

**Подписание промежуточного CA корневым сертификатом:**
```bash
openssl x509 -req -in intermediateCA.csr \
  -CA rootCA.crt -CAkey rootCA.key -CAcreateserial \
  -out intermediateCA.crt -days 1825 -sha256 \
  -extfile intermediateCA.cnf -extensions v3_intermediate_ca
```

**Проверка цепочки сертификатов:**
```bash
openssl verify -CAfile rootCA.crt intermediateCA.crt
```

### **Шаг 3: Импорт промежуточного сертификата в Vault**

**3.1. Настройка подключения к Vault:**
*Проброс порта позволяет взаимодействовать с Vault, работающим внутри кластера, с локальной машины.*

**Внимание:** Команда `kubectl port-forward` блокирует терминал. Запускайте её в отдельном окне или в фоновом режиме (`&`).

**Запустите в отдельном окне терминала проброс порта:**
```bash
kubectl port-forward -n vault service/vault 8200:8200
```

**Настройка переменных окружения для CLI Vault:**
```bash
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="${VAULT_ROOT_TOKEN}"
```

**Проверка подключения:**
```bash
vault status
```

**3.2. Импорт промежуточного CA в Vault:**
*Включение движка PKI и импорт связки сертификата и ключа промежуточного CA.*

**Включение PKI движка:**
```bash
vault secrets enable -path=pki -description="Apatsev Intermediate PKI" -max-lease-ttl="43800h" pki
```

**Импорт промежуточного сертификата и ключа:**
```bash
vault write pki/config/ca pem_bundle="$(cat intermediateCA.crt intermediateCA.key)"
```

**Совет:** Команда `vault write ... pem_bundle=...` — это ключевой момент, когда Vault принимает на себя роль промежуточного CA.

**Настройка URL-адресов для промежуточного CA:**
*Эти URL будут указываться в выпускаемых сертификатах для доступа к CA и CRL.*
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
*Роль определяет параметры (домены, TTL, ключи), с которыми могут быть выпущены сертификаты.*
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

**Разбор роли:**
*   `allowed_domains` и `allow_subdomains=true` — позволяют выпускать сертификаты для любого поддомена `apatsev.corp` (например, `app1.apatsev.corp`, `api.service.apatsev.corp`), а также для внутренних DNS-имён Kubernetes.
*   `max_ttl` — максимальное время жизни выпускаемого сертификата. Vault не выдаст сертификат на срок больше этого.
*   `enforce_hostnames=false` — упрощает жизнь, разрешая выпускать сертификаты для IP-адресов и "голых" доменов, но может быть менее безопасно. Настройте под свои нужды.

### **Шаг 4: Установка и настройка cert-manager**

**4.1. Установка cert-manager:**
*Установка cert-manager с помощью Helm для автоматического управления сертификатами в Kubernetes.*
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install --wait cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.18.2 \
  --set crds.enabled=true
```

**4.2. Настройка аутентификации для cert-manager в Vault:**
*Создание роли AppRole и политики доступа, чтобы cert-manager мог запрашивать сертификаты из Vault.*

**Пояснение по аутентификации:** Чтобы `cert-manager` мог общаться с Vault и запрашивать сертификаты, ему нужны права. Мы используем метод `AppRole`. Мы создаём в Vault "роль" для приложения (`cert-manager`), выдаём ему `RoleID` и `SecretID` (как логин и пароль). `SecretID` мы храним в Kubernetes Secret, чтобы `cert-manager` мог его безопасно использовать.

**Включение аутентификации AppRole:**
```bash
vault auth enable approle
```

**Создание политики для cert-manager:**
```bash
vault policy write cert-manager-policy - <<EOF
path "pki/sign/k8s-services" {
  capabilities = ["create", "update"]
}
path "pki/issue/k8s-services" {
  capabilities = ["create"]
}
EOF
```

**Создание AppRole:**
```bash
vault write auth/approle/role/cert-manager \
    secret_id_ttl=10m \
    token_num_uses=100 \
    token_ttl=20m \
    token_max_ttl=30m \
    secret_id_num_uses=40 \
    token_policies="cert-manager-policy"
```

**Получение RoleID и SecretID:**
```bash
ROLE_ID=$(vault read auth/approle/role/cert-manager/role-id -format=json | jq -r .data.role_id)
SECRET_ID=$(vault write -f auth/approle/role/cert-manager/secret-id -format=json | jq -r .data.secret_id)
```

**Создание Kubernetes Secret для хранения SecretID:**
```bash
kubectl create secret generic cert-manager-vault-approle \
    --namespace=cert-manager \
    --from-literal=secretId="${SECRET_ID}"
```

**4.3. Создание VaultIssuer:**
*ClusterIssuer представляет cert-manager'у точку входа в Vault для запроса сертификатов.*

**Создание файла с полной цепочкой сертификатов для caBundle:**
```bash
cat rootCA.crt intermediateCA.crt > full-chain.crt
```

**Важно:** `caBundle` в `ClusterIssuer` нужен для того, чтобы `cert-manager` мог проверить подлинность сервера Vault по TLS. Так как наш Vault пока работает по HTTP, это не так критично, но хорошая практика — указывать цепочку доверия.

**Создание ClusterIssuer:**
```bash
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

### **Шаг 5: Обновление конфигурации Vault для работы через Ingress**

**5.1. Обновление конфигурации Vault для работы через Ingress:**
*Обновляем values.yaml для корректной работы Vault через Ingress с отключенным TLS.*
```yaml
cat <<EOF > vault-values.yaml
server:
  ha:
    enabled: true
    raft:
      enabled: true
  ingress:
    enabled: true
    annotations:
      cert-manager.io/cluster-issuer: vault-cluster-issuer
      cert-manager.io/common-name: vault.apatsev.corp
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    ingressClassName: nginx
    pathType: Prefix
    hosts:
      - host: vault.apatsev.corp
        paths:
          - /
    tls:
      - secretName: vault-ingress-tls
        hosts:
          - vault.apatsev.corp
ui:
  enabled: true
EOF
```

** Пояснение архитектуры:** Обратите внимание на аннотацию `nginx.ingress.kubernetes.io/backend-protocol: "HTTP"`. Она говорит Ingress-контроллеру, что сам Vault принимает трафик по HTTP. TLS-терминация (расшифровка) происходит на уровне Ingress. Это называется "TLS Termination at the Edge".

**Применение обновлений:**
```bash
helm upgrade --install vault hashicorp/vault --namespace vault -f vault-values.yaml
```

**Проверка создания Ingress и сертификата:**
```bash
kubectl get ingress -n vault
kubectl get certificate -n vault
```

Добавляем vault.apatsev.corp в /etc/hosts
```
echo ip-load-balancer vault.apatsev.corp | sudo tee -a /etc/hosts
```

Открываем и проверяем https://vault.apatsev.corp
![](check_certificate_in_firefox.png)

### **Шаг 6: Пример выпуска сертификата для приложения**

**Создание ресурса Certificate для приложения:**
*Пример создания сертификата для тестового приложения с использованием Wildcard DNS имени.*
```yaml
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

** Автоматизация в действии:** После создания этого ресурса `cert-manager`:
1.  Увидит новый `Certificate`.
2.  Свяжется с `vault-cluster-issuer`.
3.  `Issuer` аутентифицируется в Vault через AppRole.
4.  Vault выпустит новый TLS-сертификат согласно правилам роли `k8s-services`.
5.  `cert-manager` сохранит сертификат и приватный ключ в Kubernetes Secret `my-app-tls`.
6.  За 360 часов до истечения срока действия (`renewBefore`) `cert-manager` автоматически обновит сертификат.

**Применение манифестов:**
```bash
kubectl create namespace apps
kubectl apply -f my-app-certificate.yaml
```

**Проверка:**
```bash
kubectl get certificate -n apps my-app-tls
kubectl describe secret -n apps my-app-tls
```

## Заключение

После выполнения всех шагов у вас будет полностью функционирующая PKI-инфраструктура в Kubernetes с HashiCorp Vault в качестве промежуточного Удостоверяющего Центра и автоматическим управлением сертификатами через cert-manager.
