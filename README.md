### **Инструкция по настройке Удостоверяющего Центра (CA) на базе HashiCorp Vault и OpenSSL в Kubernetes**

Эта инструкция представляет собой полное руководство по развертыванию отказоустойчивого (High-Availability) экземпляра HashiCorp Vault в кластере Kubernetes. Мы настроим двухуровневую PKI, где корневой сертификат `apatsev.corp` создается через OpenSSL, а промежуточный CA `intermediate.apatsev.corp` настраивается в Vault. Интегрируем систему с `cert-manager` для автоматического выпуска и обновления TLS-сертификатов, включая сертификат для самого Vault.

**Цели данной инструкции:**

1.  **Установка Vault в Kubernetes:** Развертывание отказоустойчивого кластера Vault с использованием Helm-чарта и встроенного хранилища Raft.
2.  **Создание корневого сертификата через OpenSSL:** Генерация корневого сертификата `apatsev.corp` с помощью OpenSSL.
3.  **Настройка промежуточного CA в Vault:** Конфигурация промежуточного удостоверяющего центра `intermediate.apatsev.corp` в Vault.
4.  **Интеграция с cert-manager:** Установка и настройка `cert-manager` для автоматизации жизненного цикла сертификатов.
5.  **Выпуск и применение сертификата для Vault:** Использование `cert-manager` для получения TLS-сертификата для Vault от промежуточного CA.
6.  **Создание ролей и выпуск сертификатов для приложений:** Демонстрация процесса создания ролей для различных сервисов и автоматический выпуск сертификатов для них.

**Предварительные требования:**

*   Установлен кластер Kubernetes.
*   Установленные утилиты командной строки: `kubectl`, `helm`, `openssl`.
*   Настроенный `kubectl` для работы с вашим кластером.
*   Установленная утилита `jq` для удобной обработки JSON-вывода.
*   Установленная утилита `yq`
*   Установленная утилита `vault`.

### **Шаг 1: Установка HashiCorp Vault в режиме HA в Kubernetes**

Мы будем использовать официальный Helm-чарт от HashiCorp для развертывания Vault. Конфигурация будет рассчитана на отказоустойчивый режим (HA) с использованием встроенного хранилища Raft, что избавляет от необходимости разворачивать отдельное хранилище, такое как Consul.

**1.1. Добавление Helm-репозитория HashiCorp:**

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```
**Проверка:** Убедитесь, что репозиторий успешно добавлен.
```bash
helm repo list | grep hashicorp
```
Вы должны увидеть строку с `hashicorp https://helm.releases.hashicorp.com`.

Экспортируйте значения по умолчанию чарта Vault в файл default-values.yaml:
```shell
helm show values hashicorp/vault | sed -e '/^\s*#/d' -e 's/\s*#.*$//' -e '/^\s*$/d' > default-values.yaml
```

Удаляем ключи с пустыми значениями
```shell
yq -i 'del(.. | select( length == 0))'  default-values.yaml
sed -i '/{}/d' default-values.yaml
```

**1.2. Установка Vault с помощью Helm:**

Выполните команду ниже в вашем терминале. Vault будет установлен в неймспейс `vault`.

```bash
kubectl create namespace vault
```

Установка `vault`.

```bash
helm install vault hashicorp/vault --namespace vault --values values.yaml
```
**Проверка:** Проверьте статус установки и подов Vault. Дождитесь, пока поды перейдут в состояние `Running`.
```bash
kubectl get pods -n vault -w
```
Вы увидите поды `vault-0`, `vault-1`, `vault-2` в статусе `0/1 Running`. Они еще не готовы (not Ready), так как Vault запечатан.

**1.3. Инициализация и распечатывание (Unseal) Vault:**

После установки поды Vault будут в состоянии готовности, но сам сервис будет запечатан. Нам нужно его инициализировать и распечатать.

Инициализируем Vault. Сохраните ключи и root-токен в надежном месте!

```bash
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json > vault-init-keys.json
```
**Проверка:** Убедитесь, что файл `vault-init-keys.json` создан и содержит ключи.
```bash
cat vault-init-keys.json | jq
```

Извлекаем ключ для распечатывания и root-токен:

```bash
VAULT_UNSEAL_KEY=$(cat vault-init-keys.json | jq -r ".unseal_keys_b64[0]")
VAULT_ROOT_TOKEN=$(cat vault-init-keys.json | jq -r ".root_token")
echo "Root Token: ${VAULT_ROOT_TOKEN}"
echo "UNSEAL KEY: ${VAULT_UNSEAL_KEY}"
```

Распечатываем первый pod:

```bash
kubectl exec -n vault vault-0 -- vault operator unseal ${VAULT_UNSEAL_KEY}
```
**Проверка:** Проверьте статус Vault внутри пода.
```bash
kubectl exec -n vault vault-0 -- vault status
```
Вывод должен показать `Sealed: false` и `HA Mode: active`.


Присоединение остальных нод К ПЕРВОЙ ноде
```bash
# vault-1 присоединяется к vault-0
```bash
kubectl exec -n vault vault-1 -- vault operator raft join http://vault-0.vault-internal:8200
```

# vault-2 присоединяется к vault-0
```bash
kubectl exec -n vault vault-2 -- vault operator raft join http://vault-0.vault-internal:8200
```

Распечатать все ноды

Распечатать vault-1
```bash
kubectl exec -n vault vault-1 -- vault operator unseal ${VAULT_UNSEAL_KEY}
```

Распечатать vault-2
```bash
kubectl exec -n vault vault-2 -- vault operator unseal ${VAULT_UNSEAL_KEY}
```

**Проверка:** Проверьте статус Vault внутри пода.
```bash
kubectl exec -n vault vault-1 -- vault status
kubectl exec -n vault vault-2 -- vault status
```
Вывод должен показать `Sealed: false` и `HA Mode: active`.

Проверим, что все поды готовы.
```bash
kubectl get pods -n vault
```
Все поды `vault-0`, `vault-1`, `vault-2` должны быть в статусе `1/1 Running`.

```bash
echo "Vault успешно развернут и распечатан."
```

**Важно:** Сохраните `VAULT_ROOT_TOKEN` и `VAULT_UNSEAL_KEY`. Они необходимы для доступа и управления Vault.

### **Шаг 2: Создание корневого сертификата через OpenSSL и настройка промежуточного CA в Vault**

В этой конфигурации мы создадим корневой сертификат `apatsev.corp` через OpenSSL, а в Vault настроим промежуточный удостоверяющий центр `intermediate.apatsev.corp`.

**2.1. Создание корневого сертификата apatsev.corp через OpenSSL:**

Сначала создадим корневой сертификат с помощью OpenSSL:

```bash
# Создаем приватный ключ для корневого CA
openssl genrsa -out rootCA.key 4096

# Создаем самоподписанный корневой сертификат
openssl req -x509 -new -nodes -key rootCA.key -sha256 -days 3650 \
  -out rootCA.crt \
  -subj "/C=RU/ST=Omsk Oblast/L=Omsk/O=MyCompany/OU=Apatsev/CN=apatsev.corp Root CA"
```
**Проверка:** Убедитесь, что файлы `rootCA.key` и `rootCA.crt` созданы.
```bash
ls rootCA.key rootCA.crt
```

**2.2. Настройка подключения к Vault:**

Для удобства настроим переменные окружения и выполним вход.

Используем port-forward для доступа к Vault с локальной машины:

```bash
kubectl port-forward -n vault service/vault 8200:8200 &
```
**Проверка:** Команда должна работать в фоновом режиме. Следующая команда `vault status` подтвердит, что соединение установлено.

Экспортируем переменные окружения:

```bash
export VAULT_ADDR='http://127.0.0.1:8200'
export VAULT_TOKEN="${VAULT_ROOT_TOKEN}"
```

Проверяем статус:

```bash
vault status
```
**Проверка:** Успешный вывод команды `vault status` означает, что вы подключились к Vault. Вы должны увидеть информацию о кластере, версию и статус `Sealed: false`.

Входим по root токену:

```bash
vault login $VAULT_ROOT_TOKEN
```
**Проверка:** Команда должна вернуть `Success! You are now authenticated.`

**2.3. Настройка промежуточного CA в Vault:**

1. Включаем секретный движок PKI для промежуточного CA. Мы используем путь `pki`. Срок жизни сертификатов ставим 5 лет (43800 часов):

```bash
vault secrets enable \
    -path=pki \
    -description="Apatsev Kubernetes Intermediate PKI" \
    -max-lease-ttl="43800h" \
    pki
```
**Проверка:** Убедитесь, что движок PKI включен по указанному пути.
```bash
vault secrets list | grep pki
```
Вы должны увидеть `pki/`.

2. Генерируем CSR для промежуточного CA:

```bash
vault write -format=json pki/intermediate/generate/internal \
    common_name="intermediate.apatsev.corp" \
    issuer_name="pki-intermediate-2025" \
    country="Russian Federation" \
    locality="Omsk" \
    organization="MyCompany" \
    ou="Apatsev" \
    ttl="43800h" | jq -r '.data.csr' > intermediate.csr
```
**Проверка:** Просмотр содержимого CSR.
```bash
openssl req -in intermediate.csr -text -noout
```

3. Создаем файл конфигурации расширений intermediate_ext.cnf:

```bash
cat <<EOF > intermediate_ext.cnf
[ v3_ca ]
# Пометить сертификат как CA
# pathlen:0 - запрещает промежуточному CA выпускать дополнительные подчиненные CA, повышая безопасность.
basicConstraints = critical, CA:TRUE, pathlen:0

# Указать назначение ключа (знак — подпись сертификатов и CRL)
keyUsage = critical, digitalSignature, cRLSign, keyCertSign

# Идентификаторы ключей
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
```

4. Подписываем CSR промежуточного CA с помощью корневого сертификата OpenSSL, включая расширения:

```bash
openssl x509 -req -in intermediate.csr \
  -CA rootCA.crt \
  -CAkey rootCA.key \
  -CAcreateserial \
  -out intermediate.crt \
  -days 1825 \
  -sha256 \
  -extfile intermediate_ext.cnf \
  -extensions v3_ca
```
**Проверка:** Просмотр краткой информации, расширений и проверка цепочки сертификатов.
```bash
openssl x509 -in intermediate.crt -text -noout
openssl x509 -in intermediate.crt -subject -issuer -dates -noout
openssl verify -CAfile rootCA.crt intermediate.crt
```

4. Загружаем подписанный сертификат обратно в Vault:

```bash
vault write pki/intermediate/set-signed certificate=@intermediate.crt
```
**Проверка:** Команда должна завершиться успешно.

5. Настраиваем URL-адреса для CRL и AIA промежуточного CA:

```bash
vault write pki/config/urls \
    issuing_certificates="${VAULT_ADDR}/v1/pki/ca" \
    crl_distribution_points="${VAULT_ADDR}/v1/pki/crl"
```
**Проверка:** Прочитайте конфигурацию, чтобы убедиться, что URL-адреса установились.
```bash
vault read pki/config/urls
```

### **Шаг 3: Создание Роли для Выпуска Сертификатов**

Роль определяет, какие сертификаты можно выпускать: для каких доменов, с каким сроком жизни и другими параметрами.

Создаем роль с именем `k8s-services`. Эта роль позволит генерировать сертификаты для сервисов внутри кластера (например, в домене .svc.cluster.local) и для внешнего домена apatsev.corp через промежуточный CA:

```bash
vault write pki/roles/k8s-services \
    allowed_domains="apatsev.corp,svc.cluster.local" \
    allow_subdomains=true \
    max_ttl="8760h" \
    key_bits="2048" \
    key_type="rsa" \
    allow_any_name=false \
    allow_bare_domains=true \
    allow_ip_sans=true \
    allow_localhost=true \
    client_flag=false \
    server_flag=true \
    enforce_hostnames=true \
    use_csr_common_name=true \
    key_usage="DigitalSignature,KeyEncipherment" \
    ext_key_usage="ServerAuth" \
    require_cn=false
```

### **Шаг 4: Установка и настройка cert-manager**

`cert-manager` — это стандарт де-факто для управления TLS-сертификатами в Kubernetes. Он будет автоматически запрашивать сертификаты у нашего Vault.

**4.1. Установка cert-manager:**

Мы установим `cert-manager` с помощью его официального Helm-чарта.

```bash
helm repo add jetstack https://charts.jetstack.io
```

```bash
helm repo update
```

```bash
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.18.2 \
  --set crds.enabled=true
```

**4.2. Настройка аутентификации для cert-manager в Vault:**

`cert-manager` должен как-то аутентифицироваться в Vault. Мы используем метод `AppRole`.

1. Включаем аутентификацию по AppRole:

```bash
vault auth enable approle
```

2. Создаем политику, которая разрешает cert-manager'у выпускать сертификаты:

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

3. Создаем AppRole для cert-manager:

```bash
vault write auth/approle/role/cert-manager \
    secret_id_ttl=10m \
    token_num_uses=100 \
    token_ttl=20m \
    token_max_ttl=30m \
    secret_id_num_uses=40 \
    token_policies="cert-manager-policy"
```

4. Получаем RoleID:

```bash
ROLE_ID=$(vault read auth/approle/role/cert-manager/role-id -format=json | jq -r .data.role_id)
```

5. Генерируем SecretID:

```bash
SECRET_ID=$(vault write -f auth/approle/role/cert-manager/secret-id -format=json | jq -r .data.secret_id)
```

6. Создаем Kubernetes Secret с SecretID, который будет использовать cert-manager:

```bash
kubectl create secret generic cert-manager-vault-approle \
    --namespace=cert-manager \
    --from-literal=secretId="${SECRET_ID}"
```

**4.3. Создание VaultIssuer:**

`VaultIssuer` — это ресурс `cert-manager`, который указывает, как подключаться к Vault.

Создайте файл vault-issuer.yaml:

```bash
cat <<EOF > vault-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-cluster-issuer
spec:
  vault:
    # Адрес сервиса Vault в Kubernetes
    server: http://vault.vault.svc.cluster.local:8200
    # Путь к PKI-движку
    path: pki/sign/k8s-services
    # Корневой сертификат нашего CA для проверки соединения
    caBundle: $(cat rootCA.pem | base64 | tr -d '\n')
    auth:
      appRole:
        path: approle
        roleId: "${ROLE_ID}" # Подставляем полученный RoleID
        secretRef:
          name: cert-manager-vault-approle
          key: secretId
EOF
```

Применяем манифест:

```bash
kubectl apply -f vault-issuer.yaml
```

### **Шаг 5: Выпуск и применение TLS-сертификата для Vault**

Теперь самое интересное: мы заставим `cert-manager` выпустить сертификат для самого Vault, чтобы он работал по HTTPS.

**5.1. Создание ресурса `Certificate` для Vault:**

Этот ресурс говорит `cert-manager`: "Выпусти, пожалуйста, сертификат для этих DNS-имен и сохрани его в этот Secret".

Создайте файл vault-certificate.yaml:

```bash
cat <<EOF > vault-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vault-server-tls
  namespace: vault # Важно: в том же неймспейсе, что и Vault
spec:
  secretName: vault-server-tls # Имя секрета, где будет храниться сертификат
  issuerRef:
    name: vault-cluster-issuer # Наш ClusterIssuer
    kind: ClusterIssuer
  duration: 720h # 30 дней
  renewBefore: 360h # Обновить за 15 дней до истечения
  commonName: vault.apatsev.corp
  dnsNames:
  - vault.apatsev.corp
  # Внутренние DNS-имена для доступа внутри кластера
  - vault
  - vault.vault
  - vault.vault.svc
  - vault.vault.svc.cluster.local
EOF
```

Применяем манифест:

```bash
kubectl apply -f vault-certificate.yaml
```

Через несколько мгновений `cert-manager` создаст секрет `vault-server-tls` в неймспейсе `vault`.

**5.2. Обновление конфигурации Vault для использования TLS:**

Теперь нам нужно обновить Helm-релиз Vault, чтобы он использовал этот сертификат. Добавим в наш `vault-values.yaml` секцию `server.extraVolumes` и изменим конфигурацию `listener`.

Обновите `vault-values.yaml`:

```yaml
# vault-values.yaml (обновленная версия)

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
        
        # Листенер теперь настроен на HTTPS
        listener "tcp" {
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          # Указываем пути к сертификату и ключу
          tls_cert_file = "/vault/userconfig/vault-server-tls/tls.crt"
          tls_key_file = "/vault/userconfig/vault-server-tls/tls.key"
        }
        
        # Адреса теперь используют https
        api_addr = "https://_POD_IP_:8200"
        cluster_addr = "https://_POD_IP_:8201"

  # Добавляем монтирование секрета с TLS-сертификатом в поды Vault
  extraVolumes:
    - type: 'secret'
      name: 'vault-server-tls' # Имя секрета, созданного cert-manager'ом
  
  dev:
    enabled: false
```

**5.3. Применение новой конфигурации:**

Применяем обновленные значения:

```bash
helm upgrade vault hashicorp/vault --namespace vault -f vault-values.yaml
```

После рестарта подов, Vault будет доступен по HTTPS. Обновим переменные окружения для работы с ним. Сначала остановим старый port-forward (Ctrl+C):

```bash
killall kubectl # Завершит процесс port-forward
```

Настроим новый port-forward для HTTPS:

```bash
kubectl port-forward -n vault service/vault 8200:8200 &
```

Обновим переменные окружения:

```bash
export VAULT_ADDR='https://127.0.0.1:8200'
```

Указываем путь к нашему корневому сертификату:

```bash
export VAULT_CACERT=$(pwd)/rootCA.pem
```

Проверяем статус - теперь соединение должно быть защищено TLS:

```bash
vault status
```

### **Шаг 6: Пример выпуска сертификата для приложения**

Теперь, когда вся система настроена, выпустить сертификат для любого другого приложения в кластере — тривиальная задача.

Предположим, у вас есть приложение `my-app` в неймспейсе `apps`, и ему нужен сертификат для `my-app.apatsev.corp`.

Создайте файл my-app-certificate.yaml:

```bash
cat <<EOF > my-app-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-app-tls
  namespace: apps # Неймспейс вашего приложения
spec:
  secretName: my-app-tls # Секрет будет создан в этом же неймспейсе
  issuerRef:
    name: vault-cluster-issuer
    kind: ClusterIssuer
  duration: 720h
  renewBefore: 360h
  commonName: my-app.apatsev.corp
  dnsNames:
  - my-app.apatsev.corp
EOF
```

Создайте неймспейс, если его нет:

```bash
kubectl create namespace apps
```

Примените манифест:

```bash
kubectl apply -f my-app-certificate.yaml
```

`cert-manager` автоматически создаст секрет `my-app-tls` в неймспейсе `apps`, который вы можете использовать в своем Ingress, Deployment или любом другом ресурсе Kubernetes. `cert-manager` также будет следить за сроком действия этого сертификата и автоматически обновлять его, запрашивая новый у Vault.

На этом настройка полностью завершена. Вы получили отказоустойчивый Удостоверяющий Центр в Kubernetes, который полностью автоматизирован для выдачи и продления сертификатов.
