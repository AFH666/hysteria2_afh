**deploy.sh**
```bash
curl -L https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/deploy.sh | bash
```

**deploy_v2.sh**
```bash
curl -L https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/deploy_v2.sh | bash
```

**Генерирует один ключ + ссылку**
```bash
bash https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/gen_keys.sh | bash
```

**Сгенерировать 5 ключей + ссылки**
```bash
bash https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/gen_keys.sh --count 5 | bash
```

**Сгенерировать + сразу применить к config.yaml и перезапустить сервис**
```bash
bash https://raw.githubusercontent.com/AFH666/hysteria2_afh/main/gen_keys.sh --apply | bash
```
