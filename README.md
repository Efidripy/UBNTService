# 🚀 UBNTService

Набор удобных CLI-скриптов для администрирования **Ubuntu / Debian серверов**.

Позволяет быстро:

* 🔄 обновлять систему
* 🧹 очищать систему от мусора
* ⚙️ управлять systemd сервисами

---

# ⚡ Быстрый запуск

### 🔄 Полное обновление системы

Обновляет пакеты Ubuntu и выполняет обслуживание системы.

```bash
sudo curl -fsSL https://raw.githubusercontent.com/Efidripy/UBNTService/main/full_update.sh | bash
```

---

### 🧹 Полная очистка системы

Удаляет кэш, старые пакеты и системный мусор.

Просмотр:
```bash
sudo curl -fsSL https://raw.githubusercontent.com/Efidripy/UBNTService/main/full_clean.sh | bash
```
Очистка:
```bash
sudo curl -fsSL https://raw.githubusercontent.com/Efidripy/UBNTService/main/full_clean.sh | sudo bash -s -- --apply
```
Очистка с firmware:
```bash
sudo curl -fsSL https://raw.githubusercontent.com/Efidripy/UBNTService/main/full_clean.sh | sudo bash -s -- --purge-firmware --apply
```
---

### ⚙️ Менеджер сервисов Ubuntu

Интерактивный менеджер для управления `systemd` сервисами.

```bash
sudo curl -fsSL https://raw.githubusercontent.com/Efidripy/UBNTService/main/srv_manager.sh | bash
```

---

# 📦 Установка через Git

Если хотите скачать весь репозиторий:

```bash
git clone https://github.com/Efidripy/UBNTService.git
cd UBNTService
chmod +x *.sh
```

Запуск:

```bash
sudo ./srv_manager.sh
```

---

# 🖥 Поддерживаемые системы

* Ubuntu 20.04+
* Ubuntu 22.04+
* Debian based systems

---

# ⚠️ Внимание

Скрипты выполняются с правами **root**.

Перед запуском рекомендуется ознакомиться с их содержимым.

---

# ⭐ Поддержка проекта

Если проект оказался полезным:

⭐ Поставьте **Star** на GitHub
🐛 Сообщайте о багах в **Issues**

---

# 👨‍💻 Автор

GitHub:
https://github.com/Efidripy

![Ubuntu](https://img.shields.io/badge/Ubuntu-20.04%2B-E95420?logo=ubuntu)
![Bash](https://img.shields.io/badge/Bash-Shell-4EAA25?logo=gnubash)
![License](https://img.shields.io/github/license/Efidripy/UBNTService)
![Stars](https://img.shields.io/github/stars/Efidripy/UBNTService?style=social)
