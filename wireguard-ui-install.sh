#!/bin/bash
#===============================================================================
# WireGuard UI - Production Installation Script
# Version: 2.0
# Description: Automated deployment with Docker, Nginx, SSL support
# Author: ChatLLM Teams
# Date: 2025-11-01
#===============================================================================

set -euo pipefail

#===============================================================================
# КОНСТАНТЫ И ПЕРЕМЕННЫЕ
#===============================================================================

readonly SCRIPT_VERSION="2.0"
readonly SERVICE_NAME="wireguard-ui"
readonly INSTALL_DIR="/opt/${SERVICE_NAME}"
readonly LOGFILE="/var/log/${SERVICE_NAME}-install.log"
readonly VARS_FILE="${INSTALL_DIR}/install_vars.txt"
readonly CONTAINER_PORT="5000"
readonly WG_INTERFACE="wg0"

# Цвета для вывода
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# Переменные для хранения данных
SERVER_IP=""
DOMAIN_NAME=""
USER_EMAIL=""
SSL_ENABLED=false
USERNAME="admin"
PASSWORD=""
TIMEZONE="Europe/Kyiv"

#===============================================================================
# ФУНКЦИИ ЛОГИРОВАНИЯ
#===============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[~]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_step() {
    echo -e "\n${CYAN}[Этап $1]${NC} $2"
    echo "----------------------------------------"
}

#===============================================================================
# ОБРАБОТКА ОШИБОК
#===============================================================================

error_handler() {
    local line_no=$1
    log_error "Ошибка на строке ${line_no}"
    log_error "Проверьте лог-файл: ${LOGFILE}"
    log_info "Для отладки выполните: tail -n 50 ${LOGFILE}"
    exit 1
}

trap 'error_handler ${LINENO}' ERR

#===============================================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
#===============================================================================

# Функция повторных попыток для сетевых операций
retry_command() {
    local max_attempts=3
    local timeout=5
    local attempt=1
    local cmd="$@"
    
    while [ $attempt -le $max_attempts ]; do
        if eval "$cmd"; then
            return 0
        else
            log_warning "Попытка $attempt из $max_attempts не удалась. Повтор через ${timeout}с..."
            sleep $timeout
            ((attempt++))
        fi
    done
    
    log_error "Команда не выполнена после $max_attempts попыток"
    return 1
}

# Проверка занятости порта
check_port() {
    local port=$1
    if netstat -tuln 2>/dev/null | grep -q ":${port} " || ss -tuln 2>/dev/null | grep -q ":${port} "; then
        return 0
    else
        return 1
    fi
}

# Определение IP-адреса сервера
get_server_ip() {
    local ip=""
    
    # Попытка получить публичный IP
    ip=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || \
         curl -s -4 --max-time 5 icanhazip.com 2>/dev/null || \
         curl -s -4 --max-time 5 ipinfo.io/ip 2>/dev/null || \
         hostname -I | awk '{print $1}')
    
    echo "$ip"
}

# Проверка DNS
check_dns() {
    local domain=$1
    local expected_ip=$2
    
    log_info "Проверка DNS для домена ${domain}..."
    
    local resolved_ip=$(dig +short "$domain" @8.8.8.8 | tail -n1)
    
    if [ -z "$resolved_ip" ]; then
        log_warning "Домен ${domain} не разрешается в IP-адрес"
        return 1
    fi
    
    if [ "$resolved_ip" != "$expected_ip" ]; then
        log_warning "Домен указывает на ${resolved_ip}, но сервер имеет IP ${expected_ip}"
        return 1
    fi
    
    log_success "DNS настроен корректно: ${domain} → ${expected_ip}"
    return 0
}

# Создание резервной копии файла
backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        local backup="${file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$backup"
        log_info "Создана резервная копия: ${backup}"
    fi
}

#===============================================================================
# ПРОВЕРКИ СИСТЕМЫ
#===============================================================================

check_root() {
    log_step "1/12" "Проверка прав доступа"
    
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен быть запущен от root"
        log_info "Используйте: sudo bash $0"
        exit 1
    fi
    
    log_success "Права root подтверждены"
}

check_system() {
    log_step "2/12" "Проверка системы"
    
    # Проверка ОС
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log_info "ОС: ${NAME} ${VERSION}"
        
        if [[ ! "$ID" =~ ^(ubuntu|debian)$ ]]; then
            log_warning "Скрипт оптимизирован для Ubuntu/Debian"
        fi
    fi
    
    # Определение IP
    SERVER_IP=$(get_server_ip)
    if [ -z "$SERVER_IP" ]; then
        log_error "Не удалось определить IP-адрес сервера"
        exit 1
    fi
    log_success "IP-адрес сервера: ${SERVER_IP}"
    
    # Проверка портов
    if check_port 80; then
        log_warning "Порт 80 уже используется"
        netstat -tuln | grep ":80 " || ss -tuln | grep ":80 "
    fi
    
    if check_port 443; then
        log_warning "Порт 443 уже используется"
        netstat -tuln | grep ":443 " || ss -tuln | grep ":443 "
    fi
    
    log_success "Проверка системы завершена"
}

#===============================================================================
# ИНТЕРАКТИВНЫЙ ВВОД
#===============================================================================

user_input() {
    log_step "3/12" "Сбор информации для установки"
    
    # Домен
    echo -n "Введите доменное имя (или нажмите Enter для использования только IP): "
    read -r DOMAIN_NAME
    
    if [ -n "$DOMAIN_NAME" ]; then
        log_info "Будет использован домен: ${DOMAIN_NAME}"
        
        # Email для Certbot
        echo -n "Введите email для SSL-сертификата (или нажмите Enter для пропуска): "
        read -r USER_EMAIL
    else
        log_info "Будет использован только IP-адрес: ${SERVER_IP}"
    fi
    
    # Часовой пояс
    echo -n "Введите часовой пояс [${TIMEZONE}]: "
    read -r tz_input
    if [ -n "$tz_input" ]; then
        TIMEZONE="$tz_input"
    fi
    
    # Генерация пароля
    PASSWORD=$(pwgen -s 16 1 2>/dev/null || openssl rand -base64 12)
    
    log_success "Данные собраны"
}

#===============================================================================
# ОБНОВЛЕНИЕ СИСТЕМЫ
#===============================================================================

update_system() {
    log_step "4/12" "Обновление системы"
    
    export DEBIAN_FRONTEND=noninteractive
    
    log_info "Обновление списка пакетов..."
    retry_command "apt-get update -y"
    
    log_info "Обновление установленных пакетов..."
    apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    
    log_info "Установка базовых зависимостей..."
    apt-get install -y \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        software-properties-common \
        pwgen \
        net-tools \
        dnsutils \
        ufw
    
    log_success "Система обновлена"
}

#===============================================================================
# УСТАНОВКА DOCKER
#===============================================================================

install_docker() {
    log_step "5/12" "Установка Docker"
    
    if command -v docker &> /dev/null; then
        local docker_version=$(docker --version)
        log_success "Docker уже установлен: ${docker_version}"
        
        # Проверка Docker Compose plugin
        if docker compose version &> /dev/null; then
            log_success "Docker Compose plugin установлен"
        else
            log_warning "Docker Compose plugin не найден, установка..."
            apt-get install -y docker-compose-plugin
        fi
        
        return 0
    fi
    
    log_info "Установка Docker..."
    
    # Удаление старых версий
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Добавление репозитория Docker
    retry_command "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg"
    
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    # Запуск и автозапуск Docker
    systemctl start docker
    systemctl enable docker
    
    log_success "Docker установлен: $(docker --version)"
}

#===============================================================================
# УСТАНОВКА NGINX
#===============================================================================

install_nginx() {
    log_step "6/12" "Установка Nginx"
    
    if command -v nginx &> /dev/null; then
        log_success "Nginx уже установлен: $(nginx -v 2>&1)"
        return 0
    fi
    
    log_info "Установка Nginx..."
    apt-get install -y nginx
    
    systemctl start nginx
    systemctl enable nginx
    
    log_success "Nginx установлен и запущен"
}

#===============================================================================
# УСТАНОВКА CERTBOT
#===============================================================================

install_certbot() {
    log_step "7/12" "Установка Certbot"
    
    if command -v certbot &> /dev/null; then
        log_success "Certbot уже установлен: $(certbot --version 2>&1 | head -n1)"
        return 0
    fi
    
    log_info "Установка Certbot..."
    apt-get install -y certbot python3-certbot-nginx
    
    log_success "Certbot установлен"
}

#===============================================================================
# УСТАНОВКА WIREGUARD
#===============================================================================

install_wireguard() {
    log_step "8/12" "Установка WireGuard"
    
    if command -v wg &> /dev/null; then
        log_success "WireGuard уже установлен: $(wg --version 2>&1)"
        return 0
    fi
    
    log_info "Установка WireGuard..."
    apt-get install -y wireguard wireguard-tools
    
    log_success "WireGuard установлен"
}

#===============================================================================
# НАСТРОЙКА UFW
#===============================================================================

configure_firewall() {
    log_step "9/12" "Настройка файрвола (UFW)"
    
    if ! command -v ufw &> /dev/null; then
        log_warning "UFW не установлен, пропуск настройки файрвола"
        return 0
    fi
    
    log_info "Настройка правил UFW..."
    
    # Разрешаем SSH (определяем текущий порт)
    local ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | grep -oP ':\K\d+$' | head -n1)
    ssh_port=${ssh_port:-22}
    
    ufw allow "$ssh_port"/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP'
    ufw allow 443/tcp comment 'HTTPS'
    ufw allow 51820/udp comment 'WireGuard'
    
    # Включаем UFW (если еще не включен)
    echo "y" | ufw enable 2>/dev/null || true
    
    log_success "Файрвол настроен"
}

#===============================================================================
# СОЗДАНИЕ СТРУКТУРЫ ПРОЕКТА
#===============================================================================

create_project_structure() {
    log_step "10/12" "Создание структуры проекта"
    
    mkdir -p "${INSTALL_DIR}"/{data,nginx}
    mkdir -p /etc/wireguard
    
    cd "${INSTALL_DIR}"
    
    log_success "Структура каталогов создана: ${INSTALL_DIR}"
}

#===============================================================================
# ГЕНЕРАЦИЯ КОНФИГУРАЦИЙ
#===============================================================================

generate_env_file() {
    log_info "Создание .env файла..."
    
    local protocol="http"
    local secure_cookie="false"
    
    if [ "$SSL_ENABLED" = true ]; then
        protocol="https"
        secure_cookie="true"
    fi
    
    cat > "${INSTALL_DIR}/.env" <<EOF
# WireGuard UI Configuration
# Generated: $(date)

# Authentication
WGUI_USERNAME=${USERNAME}
WGUI_PASSWORD=${PASSWORD}

# WireGuard Settings
WG_CONF_PATH=/etc/wireguard/${WG_INTERFACE}.conf
WG_INTERFACE_NAME=${WG_INTERFACE}

# Network
WGUI_PORT=${CONTAINER_PORT}
PROTOCOL=${protocol}
SECURE_COOKIE=${secure_cookie}

# Server Info
SERVER_IP=${SERVER_IP}
DOMAIN_NAME=${DOMAIN_NAME}

# Timezone
TZ=${TIMEZONE}
EOF
    
    chmod 600 "${INSTALL_DIR}/.env"
    log_success ".env файл создан"
}

generate_docker_compose() {
    log_info "Создание docker-compose.yml..."
    
    cat > "${INSTALL_DIR}/docker-compose.yml" <<'EOF'
services:
  wireguard-ui:
    image: ngoduykhanh/wireguard-ui:latest
    container_name: wireguard-ui
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    networks:
      - wireguard-net
    ports:
      - "127.0.0.1:5000:5000"
    volumes:
      - ./data:/app/db
      - /etc/wireguard:/etc/wireguard
    env_file:
      - .env
    healthcheck:
      test: ["CMD", "wget", "--quiet", "--tries=1", "--spider", "http://localhost:5000"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

networks:
  wireguard-net:
    driver: bridge
EOF
    
    log_success "docker-compose.yml создан"
}

generate_nginx_config() {
    log_info "Создание конфигурации Nginx..."
    
    local config_file="/etc/nginx/sites-available/${SERVICE_NAME}"
    
    backup_file "$config_file"
    
    # Базовая конфигурация для IP
    cat > "$config_file" <<EOF
# WireGuard UI - HTTP (IP)
server {
    listen 80;
    server_name ${SERVER_IP};
    
    access_log /var/log/nginx/${SERVICE_NAME}-access.log;
    error_log /var/log/nginx/${SERVICE_NAME}-error.log;
    
    location / {
        proxy_pass http://127.0.0.1:${CONTAINER_PORT};
        proxy_http_version 1.1;
        
        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Proxy headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF
    
    # Добавляем конфигурацию для домена, если указан
    if [ -n "$DOMAIN_NAME" ]; then
        cat >> "$config_file" <<EOF

# WireGuard UI - HTTP (Domain)
server {
    listen 80;
    server_name ${DOMAIN_NAME};
    
    access_log /var/log/nginx/${SERVICE_NAME}-access.log;
    error_log /var/log/nginx/${SERVICE_NAME}-error.log;
    
    location / {
        proxy_pass http://127.0.0.1:${CONTAINER_PORT};
        proxy_http_version 1.1;
        
        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        # Proxy headers
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF
    fi
    
    # Активация конфигурации
    ln -sf "$config_file" "/etc/nginx/sites-enabled/${SERVICE_NAME}"
    
    # Удаление дефолтной конфигурации
    rm -f /etc/nginx/sites-enabled/default
    
    # Проверка конфигурации
    if nginx -t 2>&1 | grep -q "successful"; then
        systemctl reload nginx
        log_success "Конфигурация Nginx применена"
    else
        log_error "Ошибка в конфигурации Nginx"
        nginx -t
        exit 1
    fi
}

#===============================================================================
# SSL СЕРТИФИКАТ
#===============================================================================

obtain_ssl_certificate() {
    if [ -z "$DOMAIN_NAME" ]; then
        log_info "Домен не указан, SSL сертификат не будет получен"
        return 0
    fi
    
    log_info "Попытка получения SSL сертификата для ${DOMAIN_NAME}..."
    
    # Проверка DNS
    if ! check_dns "$DOMAIN_NAME" "$SERVER_IP"; then
        log_warning "DNS не настроен корректно. Пропуск получения SSL."
        log_info "Настройте A-запись для ${DOMAIN_NAME} → ${SERVER_IP} и запустите:"
        log_info "certbot --nginx -d ${DOMAIN_NAME} --non-interactive --agree-tos --email ${USER_EMAIL:-admin@${DOMAIN_NAME}} --no-redirect"
        return 1
    fi
    
    # Получение сертификата
    local certbot_email="${USER_EMAIL:-admin@${DOMAIN_NAME}}"
    
    if certbot --nginx -d "$DOMAIN_NAME" \
        --non-interactive \
        --agree-tos \
        --email "$certbot_email" \
        --no-redirect \
        2>&1 | tee -a "$LOGFILE"; then
        
        SSL_ENABLED=true
        log_success "SSL сертификат успешно получен для ${DOMAIN_NAME}"
        
        # Обновляем .env файл
        sed -i "s/PROTOCOL=http/PROTOCOL=https/" "${INSTALL_DIR}/.env"
        sed -i "s/SECURE_COOKIE=false/SECURE_COOKIE=true/" "${INSTALL_DIR}/.env"
        
        return 0
    else
        log_warning "Не удалось получить SSL сертификат"
        log_info "Возможные причины:"
        log_info "  - Rate limit от Let's Encrypt (5 сертификатов в неделю на домен)"
        log_info "  - DNS еще не обновился"
        log_info "  - Порт 80 недоступен извне"
        log_info "Сервис будет работать на HTTP"
        return 1
    fi
}

#===============================================================================
# ЗАПУСК СЕРВИСА
#===============================================================================

start_service() {
    log_step "11/12" "Запуск сервиса"
    
    cd "${INSTALL_DIR}"
    
    log_info "Запуск Docker контейнеров..."
    docker compose up -d
    
    log_info "Ожидание готовности сервиса..."
    sleep 10
    
    # Проверка статуса контейнера
    if docker ps | grep -q "${SERVICE_NAME}"; then
        log_success "Контейнер ${SERVICE_NAME} запущен"
    else
        log_error "Контейнер не запустился"
        docker compose logs
        exit 1
    fi
    
    # Проверка healthcheck
    local max_wait=60
    local waited=0
    while [ $waited -lt $max_wait ]; do
        if docker inspect --format='{{.State.Health.Status}}' "${SERVICE_NAME}" 2>/dev/null | grep -q "healthy"; then
            log_success "Healthcheck пройден"
            break
        fi
        sleep 5
        waited=$((waited + 5))
    done
}

#===============================================================================
# СОЗДАНИЕ SYSTEMD UNIT
#===============================================================================

create_systemd_service() {
    log_info "Создание systemd unit для автозапуска..."
    
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=WireGuard UI Service
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service"
    
    log_success "Systemd unit создан и активирован"
}

#===============================================================================
# СОХРАНЕНИЕ ПЕРЕМЕННЫХ
#===============================================================================

save_install_vars() {
    log_info "Сохранение переменных установки..."
    
    cat > "$VARS_FILE" <<EOF
# WireGuard UI Installation Variables
# Generated: $(date)

INSTALL_DATE=$(date +"%Y-%m-%d %H:%M:%S")
SCRIPT_VERSION=${SCRIPT_VERSION}
SERVER_IP=${SERVER_IP}
DOMAIN_NAME=${DOMAIN_NAME}
SSL_ENABLED=${SSL_ENABLED}
INSTALL_DIR=${INSTALL_DIR}
CONTAINER_PORT=${CONTAINER_PORT}
USERNAME=${USERNAME}
PASSWORD=${PASSWORD}
TIMEZONE=${TIMEZONE}
LOGFILE=${LOGFILE}
EOF
    
    chmod 600 "$VARS_FILE"
    log_success "Переменные сохранены в ${VARS_FILE}"
}

#===============================================================================
# ФИНАЛЬНАЯ ПРОВЕРКА
#===============================================================================

final_check() {
    log_step "12/12" "Финальная проверка и отчет"
    
    local all_ok=true
    
    # Проверка Docker контейнера
    echo -n "Проверка Docker контейнера... "
    if docker ps | grep -q "${SERVICE_NAME}"; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        all_ok=false
    fi
    
    # Проверка Nginx
    echo -n "Проверка Nginx... "
    if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        all_ok=false
    fi
    
    # Проверка HTTP доступности
    echo -n "Проверка HTTP доступности... "
    if curl -s -o /dev/null -w "%{http_code}" "http://${SERVER_IP}" | grep -q "200\|302"; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${YELLOW}~${NC}"
    fi
    
    # Проверка HTTPS доступности (если SSL включен)
    if [ "$SSL_ENABLED" = true ] && [ -n "$DOMAIN_NAME" ]; then
        echo -n "Проверка HTTPS доступности... "
        if curl -s -o /dev/null -w "%{http_code}" "https://${DOMAIN_NAME}" | grep -q "200\|302"; then
            echo -e "${GREEN}✓${NC}"
        else
            echo -e "${YELLOW}~${NC}"
        fi
    fi
    
    echo ""
    
    if [ "$all_ok" = true ]; then
        log_success "Все проверки пройдены успешно!"
    else
        log_warning "Некоторые проверки не прошли. Проверьте логи."
    fi
}

#===============================================================================
# ИТОГОВЫЙ ОТЧЕТ
#===============================================================================

print_final_report() {
    echo ""
    echo "================================================================================"
    echo -e "${GREEN}✅ УСТАНОВКА WIREGUARD UI ЗАВЕРШЕНА УСПЕШНО!${NC}"
    echo "================================================================================"
    echo ""
    echo -e "${CYAN}📍 ДОСТУП К ПАНЕЛИ УПРАВЛЕНИЯ:${NC}"
    echo "   HTTP:  http://${SERVER_IP}"
    
    if [ -n "$DOMAIN_NAME" ]; then
        echo "   HTTP:  http://${DOMAIN_NAME}"
        
        if [ "$SSL_ENABLED" = true ]; then
            echo -e "   ${GREEN}HTTPS: https://${DOMAIN_NAME}${NC}"
        else
            echo -e "   ${YELLOW}HTTPS: не настроен (см. инструкции ниже)${NC}"
        fi
    fi
    
    echo ""
    echo -e "${CYAN}🔐 УЧЕТНЫЕ ДАННЫЕ:${NC}"
    echo "   Логин:  ${USERNAME}"
    echo "   Пароль: ${PASSWORD}"
    echo ""
    echo -e "${CYAN}📁 ВАЖНЫЕ ПУТИ:${NC}"
    echo "   Установка:     ${INSTALL_DIR}"
    echo "   Конфигурация:  ${INSTALL_DIR}/.env"
    echo "   Docker Compose: ${INSTALL_DIR}/docker-compose.yml"
    echo "   WireGuard:     /etc/wireguard"
    echo "   Nginx:         /etc/nginx/sites-available/${SERVICE_NAME}"
    echo "   Логи:          ${LOGFILE}"
    echo "   Переменные:    ${VARS_FILE}"
    echo ""
    echo -e "${CYAN}🛠️  ПОЛЕЗНЫЕ КОМАНДЫ:${NC}"
    echo "   Логи контейнера:    docker logs ${SERVICE_NAME} -f"
    echo "   Перезапуск:         cd ${INSTALL_DIR} && docker compose restart"
    echo "   Остановка:          cd ${INSTALL_DIR} && docker compose down"
    echo "   Запуск:             cd ${INSTALL_DIR} && docker compose up -d"
    echo "   Статус:             docker ps | grep ${SERVICE_NAME}"
    echo "   Логи Nginx:         tail -f /var/log/nginx/${SERVICE_NAME}-*.log"
    echo "   Перезапуск Nginx:   systemctl restart nginx"
    echo ""
    
    if [ "$SSL_ENABLED" = false ] && [ -n "$DOMAIN_NAME" ]; then
        echo -e "${YELLOW}⚠️  SSL СЕРТИФИКАТ НЕ ПОЛУЧЕН${NC}"
        echo "   Для получения SSL сертификата:"
        echo "   1. Убедитесь, что DNS настроен: ${DOMAIN_NAME} → ${SERVER_IP}"
        echo "   2. Выполните команду:"
        echo "      certbot --nginx -d ${DOMAIN_NAME} --non-interactive --agree-tos --email ${USER_EMAIL:-admin@${DOMAIN_NAME}} --no-redirect"
        echo "   3. После получения сертификата обновите .env:"
        echo "      sed -i 's/PROTOCOL=http/PROTOCOL=https/' ${INSTALL_DIR}/.env"
        echo "      sed -i 's/SECURE_COOKIE=false/SECURE_COOKIE=true/' ${INSTALL_DIR}/.env"
        echo "      cd ${INSTALL_DIR} && docker compose restart"
        echo ""
    fi
    
    echo -e "${CYAN}📚 ДОПОЛНИТЕЛЬНАЯ ИНФОРМАЦИЯ:${NC}"
    echo "   Документация: https://github.com/ngoduykhanh/wireguard-ui"
    echo "   Часовой пояс: ${TIMEZONE}"
    echo "   Версия скрипта: ${SCRIPT_VERSION}"
    echo ""
    echo "================================================================================"
    echo -e "${GREEN}Спасибо за использование скрипта установки WireGuard UI!${NC}"
    echo "================================================================================"
    echo ""
}

#===============================================================================
# ГЛАВНАЯ ФУНКЦИЯ
#===============================================================================

main() {
    # Инициализация логирования
    mkdir -p "$(dirname "$LOGFILE")"
    exec > >(tee -i "$LOGFILE")
    exec 2>&1
    
    echo "================================================================================"
    echo "  WireGuard UI - Production Installation Script v${SCRIPT_VERSION}"
    echo "  Начало установки: $(date)"
    echo "================================================================================"
    echo ""
    
    # Выполнение этапов установки
    check_root
    check_system
    user_input
    update_system
    install_docker
    install_nginx
    install_certbot
    install_wireguard
    configure_firewall
    create_project_structure
    
    # Генерация конфигураций
    generate_env_file
    generate_docker_compose
    generate_nginx_config
    
    # Попытка получить SSL
    obtain_ssl_certificate
    
    # Если SSL получен, обновляем конфигурацию и перезапускаем
    if [ "$SSL_ENABLED" = true ]; then
        generate_env_file  # Пересоздаем .env с HTTPS настройками
    fi
    
    # Запуск сервиса
    start_service
    create_systemd_service
    save_install_vars
    
    # Финальная проверка и отчет
    final_check
    print_final_report
    
    log_success "Установка завершена: $(date)"
}

#===============================================================================
# ЗАПУСК
#===============================================================================

main "$@"
