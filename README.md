**Установка**
```bash
curl -L https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/deploy.sh | bash
```

**Установка v2 (обход сертификата)**
```bash
curl -L https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/deploy_v2.sh | bash
```

**Генерирует один ключ + ссылку конфига**
```bash
curl -L https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/gen_keys.sh | bash
```

**Сгенерировать 5 ключей + ссылки конфигов**
```bash
--count 5
```

**Сгенерировать + сразу применить к config.yaml и перезапустить сервис**
```bash
--apply
```

**Пример:
Генерация 5 ключей с ссылками конфигов, и записью в config.yaml + перезагрузка**
```bash
bash <(curl -sL https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/gen_keys.sh) --count 5 --apply
