# Выпуск KeyKeep

Этот документ предназначен для сопровождающего проекта. Он не нужен пользователю приложения.

## Локальная разработка

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Отладочный APK подходит для личной проверки. Не публикуйте его как официальный релиз менеджера паролей.

## Конфигурация pipeline

В репозитории GitHub откройте `Settings → Secrets and variables → Actions → Variables` и создайте:

| Variable | Назначение |
| --- | --- |
| `YANDEX_OAUTH_CLIENT_ID` | Публичный ID OAuth-приложения, передаваемый в Android-сборку |

Это не секрет: он нужен только для того, чтобы пользователь мог подключить **свой** Яндекс Диск внутри KeyKeep. Выпуск APK больше не использует токен владельца Яндекс Диска.

## Версия и артефакт

Запустите:

```bash
./scripts/release.sh
```

Pipeline выполняет форматирование, анализ и тесты, отправляет `main`, запускает workflow `.github/workflows/release.yml`, создаёт `arm64-v8a` APK, присваивает версию `0.DDMMYY.NN`, создаёт Git-тег `build/v0.DDMMYY.NN`, публикует APK в GitHub Release и скачивает ровно этот файл в `Release/`. Локально и в GitHub остаются четыре последние успешные сборки. В Release нет checksum-файлов — только APK.

Для автоматического запуска после коммита:

```bash
git config core.hooksPath .githooks
```

## Подпись для публичного релиза

Текущая конфигурация намеренно подписывает release APK debug-ключом для личной разработки. Перед публикацией APK создайте отдельный production keystore и подключите его в GitHub Actions через Secrets; затем добавьте в workflow восстановление файла keystore и переменные Gradle. Никогда не храните ключ или пароль в репозитории.

Никогда не коммитьте `key.properties`, `.jks`, `.keystore`, `.p12`, `.pem`, `.env`, OAuth-токены или client secret. После настройки production-подписи проверьте сертификат и обновления APK на чистом Android-устройстве до первой публичной публикации.
