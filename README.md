### **Инструкция по настройке Удостоверяющего Центра (CA) на базе HashiCorp Vault и OpenSSL**

Эта инструкция описывает процесс создания гибридной двухуровневой инфраструктуры открытых ключей (PKI). Мы настроим:
1.  **Корневой Удостоверяющий Центр (Root CA)**: Самоподписанный центр `apatsev.corp`, созданный через OpenSSL, который является корнем доверия для всей инфраструктуры.
2.  **Промежуточный Удостоверяющий Центр (Intermediate CA)**: Центр `intermediate.apatsev.corp`, подписанный корневым CA, который будет использоваться для выпуска сертификатов для конечных пользователей и сервисов через Vault.

**Предварительные требования:**
*   Установленный и инициализированный (unsealed) экземпляр HashiCorp Vault.
*   Установленный `vault` CLI и настроенное подключение к вашему серверу Vault (через переменные окружения `VAULT_ADDR` и `VAULT_TOKEN`).
*   Установленная утилита `jq` для удобной обработки JSON-вывода.
*   Установленная утилита `openssl` для создания корневого сертификата.


Шаг 0. Установить Kubernetes

### **Шаг 1: Создание корневого сертификата apatsev.corp через OpenSSL**

На этом шаге мы создадим корневой сертификат `apatsev.corp` с помощью OpenSSL. Это будет корень доверия для всей инфраструктуры.

```bash
# 1. Создаем приватный ключ для корневого CA.
# Используем длину ключа 4096 бит для повышенной безопасности.
openssl genrsa -out rootCA.key 4096

# 2. Создаем самоподписанный корневой сертификат.
# Срок жизни устанавливаем 10 лет (3650 дней).
# `-subj` задает параметры субъекта сертификата.
openssl req -x509 -new -nodes -key rootCA.key -sha256 -days 3650 \
  -out rootCA.crt \
  -subj "/C=RU/ST=Moscow/L=Moscow/O=MyCompany/OU=Apatsev/CN=apatsev.corp Root CA"

# 3. Проверяем созданные файлы.
# Убедитесь, что файлы `rootCA.key` и `rootCA.crt` созданы успешно.
ls -la rootCA.key rootCA.crt

# 4. Проверяем содержимое корневого сертификата.
# Убедитесь, что сертификат содержит правильное общее имя.
openssl x509 -in rootCA.crt -text -noout | grep "Subject:"
```


### **Шаг 2: Настройка Промежуточного Удостоверяющего Центра intermediate.apatsev.corp в Vault**

Теперь, когда у нас есть корневой сертификат `apatsev.corp`, созданный через OpenSSL, мы настроим промежуточный CA `intermediate.apatsev.corp` в Vault.

```bash
# 1. Включаем секретный движок PKI для промежуточного CA.
# Используем путь `pki_int_ca`.
# Срок жизни сертификатов устанавливаем 5 лет (43800 часов).
vault secrets enable \
    -path=pki_int_ca \
    -description="Apatsev PKI Intermediate CA" \
    -max-lease-ttl="43800h" \
    pki

# 2. Генерируем ключ и запрос на подпись сертификата (CSR) для промежуточного CA.
# На этом этапе создается приватный ключ внутри Vault и CSR, который мы передадим корневому CA для подписи.
# Сохраняем CSR в файл `pki_intermediate_ca.csr`.
vault write -format=json pki_int_ca/intermediate/generate/internal \
   common_name="intermediate.apatsev.corp" \
   issuer_name="pki_intermediate_2024" \
   country="Russian Federation" \
   locality="Moscow" \
   organization="MyCompany" \
   ou="Apatsev" \
   ttl="43800h" | jq -r '.data.csr' > pki_intermediate_ca.csr

# 3. Подписываем CSR промежуточного CA с помощью корневого сертификата OpenSSL.
# Используем OpenSSL для подписи CSR корневым сертификатом.
# Сохраняем подписанный сертификат в файл `intermediateCA.cert.crt`.
openssl x509 -req -in pki_intermediate_ca.csr \
  -CA rootCA.crt \
  -CAkey rootCA.key \
  -CAcreateserial \
  -out intermediateCA.cert.crt \
  -days 1825 \
  -sha256

# 4. Загружаем подписанный сертификат обратно в движок промежуточного CA.
# Эта команда связывает ранее сгенерированный приватный ключ с публичным сертификатом,
# подписанным корневым CA. После этого промежуточный CA готов к работе.
vault write pki_int_ca/intermediate/set-signed \
    certificate=@intermediateCA.cert.crt

# 5. Настраиваем URL-адреса для CRL и AIA промежуточного CA.
# Замените `https://vault.apatsev.corp` на ваш реальный адрес Vault.
vault write pki_int_ca/config/urls \
    issuing_certificates="https://vault.apatsev.corp/v1/pki_int_ca/ca" \
    crl_distribution_points="https://vault.apatsev.corp/v1/pki_int_ca/crl"
```

---

### **Шаг 3: Создание Роли для Выпуска Сертификатов**

Роль в Vault PKI определяет параметры и ограничения для сертификатов, которые могут быть выпущены. Мы создадим роль для домена `apatsev.corp` через промежуточный CA `intermediate.apatsev.corp`.

```bash
# Создаем роль с именем `apatsev-dot-corp`.
# Эта роль позволит генерировать сертификаты для домена `apatsev.corp` и его поддоменов через промежуточный CA.
vault write pki_int_ca/roles/apatsev-dot-corp \
    # Разрешенные домены для выпуска сертификатов.
    allowed_domains="apatsev.corp" \
    # Разрешает выпуск сертификатов для поддоменов (например, sub.apatsev.corp).
    allow_subdomains=true \
    # Максимальный срок жизни сертификата, выпущенного по этой роли (1 год).
    max_ttl="8760h" \
    # Длина ключа RSA.
    key_bits="2048" \
    # Тип ключа.
    key_type="rsa" \
    # Запрещаем выпуск сертификата с любым CN, он должен соответствовать allowed_domains.
    allow_any_name=false \
    # Разрешает выпуск сертификатов для "голых" доменов (например, apatsev.corp).
    allow_bare_domains=true \
    # Запрещает использование символа '*' в середине доменного имени.
    allow_glob_domains=false \
    # Разрешает включать IP-адреса в поле Subject Alternative Name (SAN).
    allow_ip_sans=true \
    # Разрешает `localhost` в качестве имени.
    allow_localhost=true \
    # Указывает, что сертификат не предназначен для аутентификации клиента.
    client_flag=false \
    # Указывает, что сертификат предназначен для аутентификации сервера (например, для TLS).
    server_flag=true \
    # Требует, чтобы имена хостов в CSR соответствовали разрешенным доменам.
    enforce_hostnames=true \
    # Разрешает использовать Common Name из CSR.
    use_csr_common_name=true \
    # Определяет назначение ключа (Digital Signature, Key Encipherment).
    key_usage="DigitalSignature,KeyEncipherment" \
    # Определяет расширенное назначение ключа (аутентификация сервера).
    ext_key_usage="ServerAuth" \
    # Не требовать обязательное наличие CN, если есть SAN.
    require_cn=false
```

---

### **Шаг 4: Пример Выпуска Сертификата**

Теперь, когда вся иерархия настроена (корневой CA через OpenSSL и промежуточный CA в Vault), мы можем выпустить наш первый сертификат через промежуточный CA `intermediate.apatsev.corp`.

```bash
# 1. Выпускаем сертификат для сервера `test.apatsev.corp`.
# Мы используем эндпоинт `pki_int_ca/issue/apatsev-dot-corp`, где `apatsev-dot-corp` - имя нашей роли.
# `common_name` - основное имя сервера.
# `alt_names` - альтернативные имена, включая localhost для локального тестирования.
# `ttl` - срок жизни сертификата (например, 90 дней).
vault write -format=json pki_int_ca/issue/apatsev-dot-corp \
    common_name="test.apatsev.corp" \
    alt_names="test.apatsev.corp,localhost" \
    ttl="2160h" > test.apatsev.corp.json

# 2. Извлекаем данные из полученного JSON.
# Сохраняем сертификат, приватный ключ и цепочку сертификатов в отдельные файлы.

# Сохраняем сертификат сервера.
cat test.apatsev.corp.json | jq -r .data.certificate > test.apatsev.corp.crt.crt

# Сохраняем приватный ключ сервера.
cat test.apatsev.corp.json | jq -r .data.private_key > test.apatsev.corp.crt.key

# Сохраняем сертификат промежуточного CA (цепочка доверия).
cat test.apatsev.corp.json | jq -r .data.issuing_ca >> test.apatsev.corp.crt.crt

# Теперь у вас есть 3 файла:
# - test.apatsev.corp.crt.crt: Полная цепочка сертификатов (сертификат сервера + промежуточный CA).
# - test.apatsev.corp.crt.key: Приватный ключ для вашего сервера.
# - rootCA.crt: Корневой сертификат, созданный через OpenSSL, который должен быть установлен на клиентах.
```

На этом настройка удостоверяющего центра завершена. Вы можете создавать дополнительные роли с другими ограничениями и выпускать сертификаты для всех ваших сервисов.
