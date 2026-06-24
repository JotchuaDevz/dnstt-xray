#!/bin/bash
# HexSlowDNSV1 - DNSTT (DNS Tunnel) Manager
# Para Hex Tunnel VPN - Android App
# https://play.google.com/store/apps/details?id=com.hex.tunnel.jotchuast

set -euo pipefail

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_RED=$'\033[38;5;196m'
C_GREEN=$'\033[38;5;46m'
C_YELLOW=$'\033[38;5;226m'
C_BLUE=$'\033[38;5;39m'
C_CYAN=$'\033[38;5;51m'
C_WHITE=$'\033[38;5;255m'

DNSTT_SERVICE_FILE="/etc/systemd/system/dnstt.service"
DNSTT_BINARY="/usr/local/bin/dnstt-server"
DNSTT_KEYS_DIR="/etc/dnstt"
DNSTT_CONFIG_FILE="/etc/dnstt/dnstt_config.conf"
DNS_INFO_FILE="/etc/dnstt/dns_info.conf"

if [[ $EUID -ne 0 ]]; then
   echo -e "${C_RED}❌ Este script requiere permisos root.${C_RESET}"
   exit 1
fi

show_spinner() {
    local pid=$1
    local message=$2
    local frames=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    local frame=0
    
    while kill -0 $pid 2>/dev/null; do
        printf "\r${C_BLUE}${frames[$((frame % 10))]}${C_RESET} ${message}"
        ((frame++))
        sleep 0.1
    done
    printf "\r${C_GREEN}✅${C_RESET} ${message} - Completado\n"
}

show_progress_bar() {
    local current=$1
    local total=$2
    local message=$3
    local width=40
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    
    printf "\r${C_CYAN}${message}${C_RESET} ${C_WHITE}["
    for ((i=0; i<filled; i++)); do printf "█"; done
    for ((i=filled; i<width; i++)); do printf "░"; done
    printf "]${C_RESET} ${C_YELLOW}${percentage}%%${C_RESET}"
}

animate_text() {
    local text=$1
    local color=$2
    for ((i=0; i<${#text}; i++)); do
        printf "${color}${text:$i:1}${C_RESET}"
        sleep 0.05
    done
    echo
}

show_step() {
    local step_num=$1
    local step_text=$2
    echo
    echo -e "${C_BOLD}${C_BLUE}╭─ Paso $step_num:${C_RESET}${C_RESET}"
    echo -e "${C_BLUE}│${C_RESET} $step_text"
    echo -e "${C_BLUE}╰─${C_RESET}"
}

show_section() {
    local section=$1
    echo
    echo -e "${C_BOLD}${C_CYAN}▶ $section${C_RESET}"
}

_is_valid_ipv4() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

check_and_free_ports() {
    local port="$1"
    echo -e "\n${C_BLUE}🔎 Verificando si el puerto $port está disponible...${C_RESET}"
    
    if ss -H -lunp "( sport = :$port )" 2>/dev/null | grep -q .; then
        local conflicting_pid
        conflicting_pid=$(ss -H -lunp "( sport = :$port )" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -n 1)
        echo -e "${C_YELLOW}⚠️ Puerto $port en uso (PID: ${conflicting_pid:-N/A}).${C_RESET}"
        read -p "👉 ¿Liberar este puerto? (y/n): " kill_confirm
        if [[ "$kill_confirm" == "y" || "$kill_confirm" == "Y" ]]; then
            if [[ -z "$conflicting_pid" ]]; then
                echo -e "${C_RED}❌ No se puede determinar el PID.${C_RESET}"
                return 1
            fi
            kill -9 "$conflicting_pid" 2>/dev/null || true
            sleep 2
            if ss -H -lunp "( sport = :$port )" 2>/dev/null | grep -q .; then
                echo -e "${C_RED}❌ No se pudo liberar el puerto $port.${C_RESET}"
                return 1
            else
                echo -e "${C_GREEN}✅ Puerto $port liberado.${C_RESET}"
            fi
        else
            echo -e "${C_RED}❌ No se puede continuar sin liberar puerto $port.${C_RESET}"
            return 1
        fi
    else
        echo -e "${C_GREEN}✅ Puerto $port disponible.${C_RESET}"
    fi
check_and_open_firewall_port() {
    local port="$1"
    local protocol="${2:-udp}"
    local firewall_detected=false

    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        firewall_detected=true
        if ! ufw status | grep -qw "$port/$protocol"; then
            echo -e "${C_YELLOW}🔥 UFW está activo. Puerto ${port}/${protocol} cerrado.${C_RESET}"
            read -p "👉 ¿Abrir este puerto? (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                ufw allow "$port/$protocol"
                echo -e "${C_GREEN}✅ Puerto ${port}/${protocol} abierto en UFW.${C_RESET}"
            else
                echo -e "${C_RED}❌ Puerto no abierto. DNSTT podría no funcionar.${C_RESET}"
                return 1
            fi
        else
             echo -e "${C_GREEN}✅ Puerto ${port}/${protocol} ya está abierto en UFW.${C_RESET}"
        fi
    fi

    if command -v firewall-cmd &> /dev/null && systemctl is-active --quiet firewalld; then
        firewall_detected=true
        if ! firewall-cmd --list-ports --permanent | grep -qw "$port/$protocol"; then
            echo -e "${C_YELLOW}🔥 firewalld está activo. Puerto ${port}/${protocol} no abierto.${C_RESET}"
            read -p "👉 ¿Abrir este puerto? (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                firewall-cmd --add-port="$port/$protocol" --permanent
                firewall-cmd --reload
                echo -e "${C_GREEN}✅ Puerto ${port}/${protocol} abierto en firewalld.${C_RESET}"
            else
                echo -e "${C_RED}❌ Puerto no abierto. DNSTT podría no funcionar.${C_RESET}"
                return 1
            fi
        else
            echo -e "${C_GREEN}✅ Puerto ${port}/${protocol} ya está abierto en firewalld.${C_RESET}"
        fi
    fi

    if ! $firewall_detected; then
        echo -e "${C_BLUE}ℹ️ No se detectó cortafuegos activo (UFW/firewalld).${C_RESET}"
    fi
    return 0
}

show_dnstt_details() {
    if [ -f "$DNSTT_CONFIG_FILE" ]; then
        source "$DNSTT_CONFIG_FILE"
        echo -e "\n${C_GREEN}=====================================================${C_RESET}"
        echo -e "${C_GREEN}            📡 DETALLES DE CONEXIÓN DNSTT             ${C_RESET}"
        echo -e "${C_GREEN}=====================================================${C_RESET}"
        echo -e "\n${C_WHITE}Información de conexión:${C_RESET}"
        echo -e "  - ${C_CYAN}Dominio Túnel:${C_RESET} ${C_YELLOW}$TUNNEL_DOMAIN${C_RESET}"
        echo -e "  - ${C_CYAN}Clave Pública:${C_RESET} ${C_YELLOW}$PUBLIC_KEY${C_RESET}"
        if [[ -n "$FORWARD_DESC" ]]; then
            echo -e "  - ${C_CYAN}Reenviando a:${C_RESET} ${C_YELLOW}$FORWARD_DESC${C_RESET}"
        else
            echo -e "  - ${C_CYAN}Reenviando a:${C_RESET} ${C_YELLOW}Desconocido${C_RESET}"
        fi
        if [[ -n "$MTU_VALUE" ]]; then
            echo -e "  - ${C_CYAN}Valor MTU:${C_RESET} ${C_YELLOW}$MTU_VALUE${C_RESET}"
        fi
        if [[ "$DNSTT_RECORDS_MANAGED" == "false" && -n "$NS_DOMAIN" ]]; then
             echo -e "  - ${C_CYAN}Registro NS:${C_RESET} ${C_YELLOW}$NS_DOMAIN${C_RESET}"
        fi
        echo -e "\n${C_DIM}Usa estos detalles en tu configuración del cliente.${C_RESET}"
    else
        echo -e "\n${C_YELLOW}ℹ️ Archivo de configuración no encontrado.${C_RESET}"
    fi
}

install_dnstt() {
    clear
    echo -e "${C_BOLD}${C_BLUE}╔════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}║   📡 HexSlowDNSV1 - Instalación de DNSTT          ║${C_RESET}"
    echo -e "${C_BOLD}${C_BLUE}╚════════════════════════════════════════════════════╝${C_RESET}\n"
    
    if [ -f "$DNSTT_SERVICE_FILE" ]; then
        echo -e "${C_YELLOW}ℹ️ DNSTT ya está instalado.${C_RESET}"
        show_dnstt_details
        return
    fi
    
    # Detener systemd-resolved
    echo -e "${C_GREEN}⚙️ Liberando puerto 53 (deteniendo systemd-resolved)...${C_RESET}"
    {
        systemctl stop systemd-resolved >/dev/null 2>&1 || true
        systemctl disable systemd-resolved >/dev/null 2>&1 || true
        rm -f /etc/resolv.conf
        echo "nameserver 8.8.8.8" | tee /etc/resolv.conf > /dev/null
    } &
    local resolve_pid=$!
    show_spinner $resolve_pid "Deteniendo systemd-resolved..."
    
    # Verificar puerto 53
    echo -e "\n${C_BLUE}🔎 Verificando puerto 53 (UDP)...${C_RESET}"
    if ss -lunp | grep -q ':53\s'; then
        echo -e "${C_YELLOW}⚠️ El puerto 53 está en uso.${C_RESET}"
        read -p "👉 ¿Permitir que el script lo libere? (y/n): " resolve_confirm
        if [[ "$resolve_confirm" == "y" || "$resolve_confirm" == "Y" ]]; then
            systemctl stop systemd-resolved 2>/dev/null || true
            systemctl disable systemd-resolved 2>/dev/null || true
            chattr -i /etc/resolv.conf &>/dev/null || true
            rm -f /etc/resolv.conf
            echo "nameserver 8.8.8.8" > /etc/resolv.conf
            chattr +i /etc/resolv.conf 2>/dev/null || true
            echo -e "${C_GREEN}✅ Puerto 53 liberado. DNS configurado a 8.8.8.8.${C_RESET}"
        else
            echo -e "${C_RED}❌ No se puede continuar sin liberar puerto 53.${C_RESET}"
            return
        fi
    else
        echo -e "${C_GREEN}✅ Puerto 53 (UDP) disponible.${C_RESET}"
    fi

    check_and_open_firewall_port 53 udp || return

    # Elegir destino del reenvío
    local forward_port=""
    local forward_desc=""
    echo -e "\n${C_BLUE}¿A dónde debería reenviar DNSTT el tráfico?${C_RESET}"
    echo -e "  ${C_GREEN}[ 1]${C_RESET} ➡️ Servicio SSH local (puerto 22)"
    echo -e "  ${C_GREEN}[ 2]${C_RESET} ➡️ Backend V2Ray local (puerto 8787)"
    read -p "👉 Selecciona (1/2) [2]: " fwd_choice
    fwd_choice=${fwd_choice:-2}
    if [[ "$fwd_choice" == "1" ]]; then
        forward_port="22"
        forward_desc="SSH (puerto 22)"
        echo -e "${C_GREEN}ℹ️ DNSTT reenviará a SSH en 127.0.0.1:22.${C_RESET}"
    elif [[ "$fwd_choice" == "2" ]]; then
        forward_port="8787"
        forward_desc="V2Ray (puerto 8787)"
        echo -e "${C_GREEN}ℹ️ DNSTT reenviará a V2Ray en 127.0.0.1:8787.${C_RESET}"
    else
        echo -e "${C_RED}❌ Opción inválida. Abortando.${C_RESET}"
        return
    fi
    local FORWARD_TARGET="127.0.0.1:$forward_port"
    
    local NS_DOMAIN=""
    local TUNNEL_DOMAIN=""
    local DNSTT_RECORDS_MANAGED="false"
    local NS_SUBDOMAIN=""
    local TUNNEL_SUBDOMAIN=""
    local HAS_IPV6="false"

    echo -e "\n${C_BLUE}⚙️ Configuración de dominios DNS para DNSTT...${C_RESET}"
    echo -e "${C_DIM}(Se requiere un dominio propio configurado en tu proveedor DNS)${C_RESET}\n"
    
    # Pedir NS_DOMAIN con validación
    while [[ -z "$NS_DOMAIN" ]]; do
        read -p "👉 Dominio del Nameserver (ej: ns1.tudominio.com): " NS_DOMAIN
        if [[ -z "$NS_DOMAIN" ]]; then
            echo -e "${C_RED}❌ El dominio NS no puede estar vacío. Intenta de nuevo.${C_RESET}"
        fi
    done
    
    # Pedir TUNNEL_DOMAIN con validación
    while [[ -z "$TUNNEL_DOMAIN" ]]; do
        read -p "👉 Dominio del Túnel (ej: tun.tudominio.com): " TUNNEL_DOMAIN
        if [[ -z "$TUNNEL_DOMAIN" ]]; then
            echo -e "${C_RED}❌ El dominio del túnel no puede estar vacío. Intenta de nuevo.${C_RESET}"
        fi
    done
    
    echo -e "\n${C_GREEN}✅ Dominios configurados:${C_RESET}"
    echo -e "   • NS: ${C_YELLOW}${NS_DOMAIN}${C_RESET}"
    echo -e "   • Túnel: ${C_YELLOW}${TUNNEL_DOMAIN}${C_RESET}"
    echo -e "${C_CYAN}Asegúrate de que estén configurados en tu proveedor DNS.${C_RESET}\n"
    
    read -p "👉 Valor MTU (ej: 512, 1200) o presiona Enter para default: " mtu_value
    local mtu_string=""
    if [[ "$mtu_value" =~ ^[0-9]+$ ]]; then
        mtu_string=" -mtu $mtu_value"
        echo -e "${C_GREEN}ℹ️ Usando MTU: $mtu_value${C_RESET}"
    else
        mtu_value=""
        echo -e "${C_YELLOW}ℹ️ Usando MTU por defecto.${C_RESET}"
    fi

    echo -e "\n${C_BLUE}📥 Descargando binario DNSTT precompilado...${C_RESET}"
    local arch
    arch=$(uname -m)
    local binary_url=""
    if [[ "$arch" == "x86_64" ]]; then
        binary_url="https://dnstt.network/dnstt-server-linux-amd64"
        echo -e "${C_BLUE}ℹ️ Detectado: x86_64 (amd64).${C_RESET}"
    elif [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        binary_url="https://dnstt.network/dnstt-server-linux-arm64"
        echo -e "${C_BLUE}ℹ️ Detectado: ARM64.${C_RESET}"
    else
        echo -e "\n${C_RED}❌ Arquitectura no soportada: $arch${C_RESET}"
        return
    fi
    
    # Descarga con animación
    {
        curl -sL "$binary_url" -o "$DNSTT_BINARY"
    } &
    local download_pid=$!
    show_spinner $download_pid "Descargando $arch..."
    
    if [ $? -ne 0 ] || [ ! -f "$DNSTT_BINARY" ]; then
        echo -e "${C_RED}❌ Error al descargar el binario DNSTT.${C_RESET}"
        return
    fi
    chmod +x "$DNSTT_BINARY"
    echo -e "${C_GREEN}✅ Binario descargado: ${C_YELLOW}$(du -h "$DNSTT_BINARY" | cut -f1)${C_RESET}"

    echo -e "${C_BLUE}🔐 Generando claves criptográficas...${C_RESET}"
    mkdir -p "$DNSTT_KEYS_DIR"
    {
        "$DNSTT_BINARY" -gen-key -privkey-file "$DNSTT_KEYS_DIR/server.key" -pubkey-file "$DNSTT_KEYS_DIR/server.pub" 2>/dev/null
    } &
    local keygen_pid=$!
    show_spinner $keygen_pid "Generando claves RSA..."
    
    if [[ ! -f "$DNSTT_KEYS_DIR/server.key" ]]; then 
        echo -e "${C_RED}❌ Error al generar claves.${C_RESET}"
        return
    fi
    echo -e "${C_GREEN}✅ Claves generadas correctamente${C_RESET}"
    
    local PUBLIC_KEY
    PUBLIC_KEY=$(cat "$DNSTT_KEYS_DIR/server.pub")
    
    echo -e "\n${C_BLUE}📝 Creando configuración del servicio...${C_RESET}"
    sleep 0.5
    cat > "$DNSTT_SERVICE_FILE" <<-EOF
[Unit]
Description=DNSTT (DNS Tunnel) Server for $forward_desc
After=network.target
[Service]
Type=simple
User=root
ExecStart=$DNSTT_BINARY -udp :53$mtu_string -privkey-file $DNSTT_KEYS_DIR/server.key $TUNNEL_DOMAIN $FORWARD_TARGET
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    echo -e "${C_GREEN}✅ Servicio systemd configurado${C_RESET}"
    
    echo -e "\n${C_BLUE}💾 Guardando configuración...${C_RESET}"
    sleep 0.3
    cat > "$DNSTT_CONFIG_FILE" <<-EOF
NS_DOMAIN="$NS_DOMAIN"
TUNNEL_DOMAIN="$TUNNEL_DOMAIN"
PUBLIC_KEY="$PUBLIC_KEY"
FORWARD_DESC="$forward_desc"
DNSTT_RECORDS_MANAGED="false"
MTU_VALUE="$mtu_value"
EOF
    echo -e "${C_GREEN}✅ Configuración guardada${C_RESET}"
    
    echo -e "\n${C_BLUE}🚀 Iniciando servicios...${C_RESET}"
    {
        systemctl daemon-reload 2>/dev/null
        systemctl enable dnstt.service 2>/dev/null
        systemctl start dnstt.service 2>/dev/null
    } &
    local start_pid=$!
    show_spinner $start_pid "Iniciando DNSTT..."
    sleep 2
    if systemctl is-active --quiet dnstt.service; then
        clear
        echo
        echo -e "${C_GREEN}╔════════════════════════════════════════════════════╗${C_RESET}"
        echo -e "${C_GREEN}║                                                    ║${C_RESET}"
        echo -e "${C_GREEN}║          🎉 ¡INSTALACIÓN COMPLETADA! 🎉            ║${C_RESET}"
        echo -e "${C_GREEN}║                                                    ║${C_RESET}"
        echo -e "${C_GREEN}╚════════════════════════════════════════════════════╝${C_RESET}"
        echo
        echo -e "   ${C_BOLD}${C_GREEN}✅ DNSTT está activo y funcionando${C_RESET}\n"
        show_dnstt_details
        
        # Mostrar config de ejemplo V2Ray
        echo
        echo -e "${C_BOLD}${C_CYAN}════════════════════════════════════════════════════${C_RESET}"
        echo -e "${C_BOLD}${C_CYAN}     📋 CONFIG DE EJEMPLO PARA CLIENTE (V2Ray)${C_RESET}"
        echo -e "${C_BOLD}${C_CYAN}════════════════════════════════════════════════════${C_RESET}"
        echo
        echo -e "${C_YELLOW}🔧 JSON VLESS:${C_RESET}"
        echo -e "${C_WHITE}{${C_RESET}"
        echo -e "${C_WHITE}  \"v\": \"2\",${C_RESET}"
        echo -e "${C_WHITE}  \"ps\": \"SlowDNS-V2Ray\",${C_RESET}"
        echo -e "${C_WHITE}  \"add\": \"${TUNNEL_DOMAIN}\",${C_RESET}"
        echo -e "${C_WHITE}  \"port\": \"53\",${C_RESET}"
        echo -e "${C_WHITE}  \"id\": \"tu-uuid-aqui\",${C_RESET}"
        echo -e "${C_WHITE}  \"aid\": \"0\",${C_RESET}"
        echo -e "${C_WHITE}  \"net\": \"tcp\",${C_RESET}"
        echo -e "${C_WHITE}  \"type\": \"none\",${C_RESET}"
        echo -e "${C_WHITE}  \"host\": \"\",${C_RESET}"
        echo -e "${C_WHITE}  \"path\": \"\",${C_RESET}"
        echo -e "${C_WHITE}  \"tls\": \"\"${C_RESET}"
        echo -e "${C_WHITE}}${C_RESET}"
        echo
        echo -e "${C_CYAN}📝 Parámetros:${C_RESET}"
        echo -e "   • Protocolo: VLESS"
        echo -e "   • Dominio: ${C_YELLOW}${TUNNEL_DOMAIN}${C_RESET}"
        echo -e "   • Puerto: ${C_YELLOW}53${C_RESET}"
        echo -e "   • Network: TCP"
        echo -e "   • TLS: Desactivado"
        echo
        echo -e "${C_DIM}Genera un UUID con: cat /proc/sys/kernel/random/uuid${C_RESET}"
        echo
        echo -e "${C_BOLD}${C_CYAN}════════════════════════════════════════════════════${C_RESET}"
    else
        echo -e "\n${C_RED}❌ Error: El servicio DNSTT falló al iniciar.${C_RESET}"
        journalctl -u dnstt.service -n 15 --no-pager
    fi
}

uninstall_dnstt() {
    echo -e "\n${C_BOLD}${C_RED}═══════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_RED}       🗑️ DESINTALACIÓN DE DNSTT 🗑️${C_RESET}"
    echo -e "${C_BOLD}${C_RED}═══════════════════════════════════════════════════${C_RESET}\n"
    
    if [ ! -f "$DNSTT_SERVICE_FILE" ]; then
        echo -e "${C_YELLOW}ℹ️ DNSTT no parece estar instalado.${C_RESET}"
        return
    fi
    
    read -p "👉 ¿Desinstalar DNSTT completamente? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then
        echo -e "\n${C_YELLOW}❌ Desinstalación cancelada.${C_RESET}"
        return
    fi
    
    echo -e "${C_BLUE}🛑 Deteniendo servicio DNSTT...${C_RESET}"
    systemctl stop dnstt.service > /dev/null 2>&1 || true
    systemctl disable dnstt.service > /dev/null 2>&1 || true
    
    if [ -f "$DNSTT_CONFIG_FILE" ]; then
        source "$DNSTT_CONFIG_FILE"
        echo -e "${C_YELLOW}⚠️ Recuerda eliminar manualmente los registros DNS de tu proveedor:${C_RESET}"
        echo -e "   • NS: ${C_YELLOW}${NS_DOMAIN}${C_RESET}"
        echo -e "   • Túnel: ${C_YELLOW}${TUNNEL_DOMAIN}${C_RESET}"
    fi
    
    echo -e "${C_BLUE}🗑️ Removiendo archivos de servicio...${C_RESET}"
    rm -f "$DNSTT_SERVICE_FILE"
    rm -f "$DNSTT_BINARY"
    rm -rf "$DNSTT_KEYS_DIR"
    rm -f "$DNSTT_CONFIG_FILE"
    rm -f "$DNS_INFO_FILE"
    systemctl daemon-reload
    
    echo -e "${C_YELLOW}ℹ️ Haciendo /etc/resolv.conf escribible...${C_RESET}"
    chattr -i /etc/resolv.conf &>/dev/null || true

    echo -e "\n${C_GREEN}✅ DNSTT ha sido desinstalado correctamente.${C_RESET}"
}

install_command_alias() {
    clear
    echo -e "\n${C_BOLD}${C_CYAN}╔════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}║       📦 Instalar Comando 'dnstt-hex' 📦          ║${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}╚════════════════════════════════════════════════════╝${C_RESET}\n"
    
    if [ -f "/usr/local/bin/dnstt-hex" ]; then
        echo -e "${C_YELLOW}ℹ️ El comando 'dnstt-hex' ya está instalado.${C_RESET}"
        echo -e "${C_DIM}Ubicación: /usr/local/bin/dnstt-hex${C_RESET}\n"
        return
    fi
    
    echo -e "${C_BLUE}📥 Instalando comando 'dnstt-hex'...${C_RESET}\n"
    
    # Obtener la ruta del script actual
    local script_path="$0"
    
    # Si es una ruta relativa, convertir a absoluta
    if [[ ! "$script_path" =~ ^/ ]]; then
        script_path="$(cd "$(dirname "$script_path")" && pwd)/$(basename "$script_path")"
    fi
    
    # Copiar el script a /usr/local/bin/ con el nombre dnstt-hex
    cp "$script_path" "/usr/local/bin/dnstt-hex"
    chmod +x "/usr/local/bin/dnstt-hex"
    
    echo -e "${C_GREEN}✅ Comando instalado correctamente.${C_RESET}\n"
    echo -e "${C_CYAN}Ahora puedes ejecutar:${C_RESET}"
    echo -e "   ${C_YELLOW}dnstt-hex${C_RESET}\n"
    echo -e "${C_DIM}Desde cualquier directorio para abrir el menú.${C_RESET}\n"
    read -p "Presiona Enter para volver al menú..." 
}

show_status() {
    echo -e "\n${C_BOLD}${C_CYAN}╔════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}║      📡 ESTADO DE DNSTT - HexSlowDNSV1 📡         ║${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}╚════════════════════════════════════════════════════╝${C_RESET}\n"
    
    if systemctl is-active --quiet dnstt.service; then
        echo -e "${C_GREEN}✅ DNSTT está ${C_BOLD}ACTIVO${C_RESET}${C_GREEN} y funcionando.${C_RESET}\n"
        show_dnstt_details
    else
        echo -e "${C_RED}❌ DNSTT no está activo.${C_RESET}\n"
    fi
}

show_menu() {
    clear
    echo -e "\n${C_BOLD}${C_CYAN}╔════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}║     🔧 HexSlowDNSV1 - DNS Tunnel Manager 🔧       ║${C_RESET}"
    echo -e "${C_BOLD}${C_CYAN}╚════════════════════════════════════════════════════╝${C_RESET}\n"
    
    printf "  ${C_GREEN}[1]${C_RESET} 🚀 Instalar DNSTT\n"
    printf "  ${C_GREEN}[2]${C_RESET} 🗑️  Desinstalar DNSTT\n"
    printf "  ${C_GREEN}[3]${C_RESET} 📊 Ver estado/detalles\n"
    printf "  ${C_GREEN}[4]${C_RESET} 🔄 Reiniciar servicio\n"
    printf "  ${C_CYAN}[5]${C_RESET} 📱 Descargar Hex Tunnel (Android)\n"
    printf "  ${C_CYAN}[6]${C_RESET} 📦 Instalar comando 'dnstt-hex'\n"
    printf "  ${C_RED}  [0]${C_RESET} ❌ Salir\n\n"
    
    read -p "👉 Selecciona opción: " choice
    
    case $choice in
        1) install_dnstt ;;
        2) uninstall_dnstt ;;
        3) show_status ;;
        4) 
            if [ -f "$DNSTT_SERVICE_FILE" ]; then
                systemctl restart dnstt.service
                echo -e "\n${C_GREEN}✅ DNSTT reiniciado.${C_RESET}\n"
                sleep 2
            else
                echo -e "\n${C_RED}❌ DNSTT no está instalado.${C_RESET}\n"
                sleep 2
            fi
            ;;
        5)
            clear
            echo -e "${C_BOLD}${C_CYAN}╔════════════════════════════════════════════════════╗${C_RESET}"
            echo -e "${C_BOLD}${C_CYAN}║           📱 DESCARGAR HEX TUNNEL 📱              ║${C_RESET}"
            echo -e "${C_BOLD}${C_CYAN}╚════════════════════════════════════════════════════╝${C_RESET}\n"
            echo -e "${C_YELLOW}🔗 Google Play Store:${C_RESET}"
            echo -e "   ${C_WHITE}https://play.google.com/store/apps/details?id=com.hex.tunnel.jotchuast${C_RESET}\n"
            echo -e "${C_CYAN}Características:${C_RESET}"
            echo -e "   • Multi-protocolo VPN (SSH, V2Ray, SlowDNS, Hysteria)"
            echo -e "   • Interfaz nativa Android\n"
            read -p "Presiona Enter para volver al menú..." 
            ;;
        6) install_command_alias ;;
        0) echo -e "\n${C_GREEN}¡Hasta luego!${C_RESET}\n"; exit 0 ;;
        *) echo -e "\n${C_RED}❌ Opción inválida.${C_RESET}\n"; sleep 1 ;;
    esac
    
    show_menu
}

show_menu
