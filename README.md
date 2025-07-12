### **Инструкция по настройке Удостоверяющего Центра (CA) на базе HashiCorp Vault**

Эта инструкция описывает процесс создания двухуровневой инфраструктуры открытых ключей (PKI) с помощью Vault. Мы настроим:
1.  **Корневой Удостоверяющий Центр (Root CA)**: Самоподписанный центр, который является корнем доверия для всей вашей инфраструктуры.
2.  **Промежуточный Удостоверяющий Центр (Intermediate CA)**: Центр, подписанный Root CA, который будет использоваться для выпуска сертификатов для конечных пользователей и сервисов.

**Предварительные требования:**
*   Установленный и инициализированный (unsealed) экземпляр HashiCorp Vault.
*   Установленный `vault` CLI и настроенное подключение к вашему серверу Vault (через переменные окружения `VAULT_ADDR` и `VAULT_TOKEN`).
*   Установленная утилита `jq` для удобной обработки JSON-вывода.

---

### **Шаг 1: Настройка Корневого Удостоверяющего Центра (Root CA)**

На этом шаге мы создадим корневой центр сертификации. Его ключ будет использоваться только для подписания промежуточных центров, что повышает общую безопасность системы.

```bash
# 1. Включаем секретный движок PKI для корневого CA.
# Мы указываем путь `pki_root_ca`, чтобы отличать его от других PKI-движков.
# `max-lease-ttl` определяет максимальный срок жизни для сертификатов, выпускаемых этим CA.
# Для корневого CA устанавливается очень большой срок, например, 15 лет (131400 часов).
vault secrets enable \
    -path=pki_root_ca \
    -description="Apatsev PKI Root CA" \
    -max-lease-ttl="131400h" \
    pki

# 2. Генерируем корневой сертификат.
# Это будет самоподписанный сертификат, который станет корнем доверия.
# `common_name` - это общее имя, которое будет отображаться в информации о сертификате.
# `ttl` соответствует максимальному сроку жизни, установленному ранее.
# Результат выполнения команды сохраняется в файл pki-root-ca.json.
vault write -format=json pki_root_ca/root/generate/internal \
    common_name="Apatsev Root Certificate Authority" \
    issuer_name="pki_root_ca_2024" \
    country="Russian Federation" \
    locality="Moscow" \
    organization="MyCompany" \
    ou="Apatsev" \
    ttl="131400h" > pki-root-ca.json

# 3. Настраиваем URL-адреса для точек распространения списка отзыва (CRL) и для доступа к сертификату CA.
# Эти URL будут встроены в сертификаты, выпускаемые этим CA.
# Замените `https://vault.apatsev.corp` на реальный адрес вашего Vault сервера.
vault write pki_root_ca/config/urls \
    issuing_certificates="https://vault.apatsev.corp/v1/pki_root_ca/ca" \
    crl_distribution_points="https://vault.apatsev.corp/v1/pki_root_ca/crl"

# 4. Извлекаем публичную часть корневого сертификата в формате PEM.
# Этот файл `rootCA.pem` нужно будет распространить на все машины,
# которые должны доверять сертификатам, выпущенным в вашей инфраструктуре.
cat pki-root-ca.json | jq -r .data.certificate > rootCA.pem
```

---

### **Шаг 2: Настройка Промежуточного Удостоверяющего Центра (Intermediate CA)**

Теперь, когда у нас есть корневой CA, мы создадим промежуточный CA. Именно он будет использоваться для повседневных задач по выпуску сертификатов.

```bash
# 1. Включаем еще один секретный движок PKI для промежуточного CA.
# Используем отдельный путь `pki_int_ca`.
# Срок жизни сертификатов здесь меньше, чем у корневого, например, 5 лет (43800 часов).
vault secrets enable \
    -path=pki_int_ca \
    -description="Apatsev PKI Intermediate CA" \
    -max-lease-ttl="43800h" \
    pki

# 2. Генерируем ключ и запрос на подпись сертификата (CSR) для промежуточного CA.
# На этом этапе создается приватный ключ внутри Vault и CSR, который мы передадим корневому CA для подписи.
# Сохраняем CSR в файл `pki_intermediate_ca.csr`.
vault write -format=json pki_int_ca/intermediate/generate/internal \
   common_name="Apatsev Intermediate CA" \
   issuer_name="pki_intermediate_2024" \
   country="Russian Federation" \
   locality="Moscow" \
   organization="MyCompany" \
   ou="Apatsev" \
   ttl="43800h" | jq -r '.data.csr' > pki_intermediate_ca.csr

# 3. Подписываем CSR промежуточного CA с помощью корневого CA.
# Мы используем эндпоинт `pki_root_ca/root/sign-intermediate` и передаем ему CSR.
# `format=pem_bundle` гарантирует, что мы получим сертификат в нужном формате.
# `ttl` определяет срок действия промежуточного сертификата.
# Сохраняем подписанный сертификат в файл `intermediateCA.cert.pem`.
vault write -format=json pki_root_ca/root/sign-intermediate csr=@pki_intermediate_ca.csr \
   issuer_ref="pki_root_ca_2024" \
   country="Russian Federation" \
   locality="Moscow" \
   organization="MyCompany" \
   ou="Apatsev" \
   format=pem_bundle \
   ttl="43800h" | jq -r '.data.certificate' > intermediateCA.cert.pem

# 4. Загружаем подписанный сертификат обратно в движок промежуточного CA.
# Эта команда связывает ранее сгенерированный приватный ключ с публичным сертификатом,
# подписанным корневым CA. После этого промежуточный CA готов к работе.
vault write pki_int_ca/intermediate/set-signed \
    certificate=@intermediateCA.cert.pem

# 5. Настраиваем URL-адреса для CRL и AIA промежуточного CA.
# Аналогично корневому CA, замените `https://vault.apatsev.corp` на ваш реальный адрес Vault.
vault write pki_int_ca/config/urls \
    issuing_certificates="https://vault.apatsev.corp/v1/pki_int_ca/ca" \
    crl_distribution_points="https://vault.apatsev.corp/v1/pki_int_ca/crl"
```

---

### **Шаг 3: Создание Роли для Выпуска Сертификатов**

Роль в Vault PKI определяет параметры и ограничения для сертификатов, которые могут быть выпущены. Мы создадим роль для домена `apatsev.corp`.

```bash
# Создаем роль с именем `apatsev-dot-corp`.
# Эта роль позволит генерировать сертификаты для домена `apatsev.corp` и его поддоменов.
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

Теперь, когда вся иерархия и роль настроены, мы можем выпустить наш первый сертификат.

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
cat test.apatsev.corp.json | jq -r .data.certificate > test.apatsev.corp.crt.pem

# Сохраняем приватный ключ сервера.
cat test.apatsev.corp.json | jq -r .data.private_key > test.apatsev.corp.crt.key

# Сохраняем сертификат промежуточного CA (цепочка доверия).
cat test.apatsev.corp.json | jq -r .data.issuing_ca >> test.apatsev.corp.crt.pem

# Теперь у вас есть 3 файла:
# - test.apatsev.corp.crt.pem: Полная цепочка сертификатов (сертификат сервера + промежуточный CA).
# - test.apatsev.corp.crt.key: Приватный ключ для вашего сервера.
# - rootCA.pem: Корневой сертификат, который должен быть установлен на клиентах.
```

На этом настройка удостоверяющего центра завершена. Вы можете создавать дополнительные роли с другими ограничениями и выпускать сертификаты для всех ваших сервисов.
