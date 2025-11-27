# Создание внешнего IP-адреса в Yandex Cloud
resource "yandex_vpc_address" "addr" {
  name = "vault-pip"  # Имя ресурса внешнего IP-адреса

  external_ipv4_address {
    zone_id = yandex_vpc_subnet.vault-a.zone  # Зона доступности, где будет выделен IP-адрес
  }
}
