#!/bin/bash

# =================================================================
# VCDS Docker Starter (v2.36 - UNC path pushd fix)
# =================================================================

CURRENT_VERSION="2.36"
REPO_URL="https://raw.githubusercontent.com/navratilpetr/vcds-docker/refs/heads/main/start_vcds.sh"
LOCAL_BIN="/usr/local/bin/vcds"

if [ "$EUID" -ne 0 ]; then
    if [[ "$0" == "bash" || "$0" == *"curl"* || ! -f "$0" ]]; then
        tmp_script="/tmp/start_vcds_root.sh"
        curl -fsSL "$REPO_URL" > "$tmp_script"
        chmod +x "$tmp_script"
        exec sudo env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" "$tmp_script" "$@"
    else
        exec sudo env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" "$0" "$@"
    fi
fi

if [ "$(realpath "$0")" != "$LOCAL_BIN" ]; then
    cp "$0" "$LOCAL_BIN"
    chmod +x "$LOCAL_BIN"
    echo "--- SKRIPT NAINSTALOVAN ---"
    echo "Pro pristi spusteni napis: vcds"
    echo "---------------------------"
    sleep 2
fi

echo "Kontrola aktualizaci..."
REMOTE_SCRIPT=$(curl -s -m 2 "$REPO_URL")
if [ -n "$REMOTE_SCRIPT" ]; then
    REMOTE_VERSION=$(echo "$REMOTE_SCRIPT" | grep -m 1 '^CURRENT_VERSION=' | cut -d'"' -f2)
    if [[ "$REMOTE_VERSION" > "$CURRENT_VERSION" ]]; then
        echo "Nalezena nova verze: $REMOTE_VERSION (soucasna: $CURRENT_VERSION)"
        read -p "Chces aktualizovat? [y/N]: " UPDATE_CONFIRM
        if [[ "$UPDATE_CONFIRM" == "y" ]]; then
            echo "$REMOTE_SCRIPT" > "$LOCAL_BIN"
            chmod +x "$LOCAL_BIN"
            echo "Aktualizace dokoncena. Restartuji..."
            exec "$LOCAL_BIN" "$@"
        fi
    fi
else
    echo "Offline rezim - preskakuji kontrolu aktualizaci."
fi

REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

DATA_DIR="${REAL_HOME}/vcds_data"
TRANSFER_DIR="${REAL_HOME}/vcds_transfer"
CONFIG_DIR="${REAL_HOME}/vcds_config"
CONF_FILE="$CONFIG_DIR/settings.conf"
IMG_FILE="$DATA_DIR/data.img"

fix_permissions() {
    chown -R "$REAL_USER:$REAL_USER" "$DATA_DIR" "$TRANSFER_DIR" "$CONFIG_DIR"
}

check_system() {
    echo "--- Kontrola systemu ---"
    if ! command -v docker &> /dev/null; then
        echo "CHYBA: Docker neni nainstalovan!"
        exit 1
    fi
    if [ ! -e /dev/kvm ]; then
        echo "CHYBA: Virtualizace (KVM) neni povolena!"
        exit 1
    fi
    if [ ! -e /dev/net/tun ]; then
        modprobe tun || { echo "CHYBA: Nelze zavest modul tun!"; exit 1; }
    fi
    echo "System: OK"
}

detect_cable() {
    echo ""
    echo "--- Detekce VCDS kabelu ---"
    echo "1. Odpoj kabel."
    echo "2. Pockej 2 sekundy."
    echo "3. Znovu pripoj kabel."
    read -p "Potom stiskni [ENTER]..."
    
    echo ""
    lsusb
    echo ""
    read -p "Zadej ID tveho zarizeni (napr. 0403:fa24): " USER_ID
    
    if [[ $USER_ID =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
        V_ID=$(echo "$USER_ID" | cut -d: -f1)
        P_ID=$(echo "$USER_ID" | cut -d: -f2)
        
        echo "VENDOR_ID=0x$V_ID" > "$CONF_FILE"
        echo "PRODUCT_ID=0x$P_ID" >> "$CONF_FILE"
        
        echo "SUBSYSTEM==\"usb\", ATTR{idVendor}==\"$V_ID\", ATTR{idProduct}==\"$P_ID\", MODE=\"0666\"" > /etc/udev/rules.d/99-vcds.rules
        udevadm control --reload-rules && udevadm trigger
        echo "Kabel ulozen: $USER_ID"
        fix_permissions
    else
        echo "Neplatny format ID!"
        exit 1
    fi
}

create_install_bat() {
    cat << 'EOF' > "$CONFIG_DIR/install.bat"
@echo off
echo 127.0.0.1 update.ross-tech.com >> %WINDIR%\System32\drivers\etc\hosts
echo 127.0.0.1 www.ross-tech.com >> %WINDIR%\System32\drivers\etc\hosts

echo @echo off > %WINDIR%\kill_gw.bat
echo ping -n 15 127.0.0.1 ^> nul >> %WINDIR%\kill_gw.bat
echo route delete 0.0.0.0 >> %WINDIR%\kill_gw.bat
schtasks /create /tn "VCDS_Kill_Gateway" /tr "cmd.exe /c %WINDIR%\kill_gw.bat" /sc onstart /ru SYSTEM /rl HIGHEST /f

set STARTUP_DIR="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Startup"
echo @echo off > %STARTUP_DIR%\vcds_launcher.bat
echo timeout /t 5 /nobreak ^> nul >> %STARTUP_DIR%\vcds_launcher.bat
echo powershell -sta -ExecutionPolicy Bypass -WindowStyle Hidden -File \\host.lan\Data\startup.ps1 >> %STARTUP_DIR%\vcds_launcher.bat
EOF
    fix_permissions
}

create_shared_scripts() {
    printf "=== NAVOD K INSTALACI VCDS ===\r\n1. V Linuxu uloz instalacku VCDS do slozky 'vcds_transfer'.\r\n2. Ve Windows otevri slozku 'Shared'.\r\n3. Nainstaluj VCDS vcetne vsech ovladacu.\r\n4. Po dokonceni instalace ZAVRI tento soubor.\r\n5. Nasledne vyber spousteci soubor VCDS.\r\n" > "$TRANSFER_DIR/navod.txt"

    cat << 'EOF' > "$TRANSFER_DIR/startup.ps1"
net user docker vcds
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d "1" /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultUserName /t REG_SZ /d "Docker" /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /t REG_SZ /d "vcds" /f

bcdedit /set "{default}" recoveryenabled No
bcdedit /set "{default}" bootstatuspolicy ignoreallfailures
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiSpyware /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Lsa" /v LimitBlankPasswordUse /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList" /v fDisabledAllowList /t REG_DWORD /d 1 /f
route delete 0.0.0.0

$Action = "RUN"
if (Test-Path "\\host.lan\Data\action.txt") { $Action = (Get-Content "\\host.lan\Data\action.txt").Trim() }
if (-Not (Test-Path "\\host.lan\Data\vcds_path.txt")) { $Action = "SETUP" }

if ($Action -eq "SETUP") {
  Start-Process "notepad.exe" "\\host.lan\Data\navod.txt" -Wait
  [void][System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = "Spustitelne soubory (*.exe)|*.exe"
  $dlg.Title = "Vyber spousteci soubor VCDS"
  $dlg.InitialDirectory = "C:\"
  if ($dlg.ShowDialog() -eq 'OK') { 
      $dlg.FileName | Out-File '\\host.lan\Data\vcds_path.txt' -Encoding ascii 
  }
  try { "RUN" | Out-File "\\host.lan\Data\action.txt" -Encoding ascii } catch {}
} else {
  if (Test-Path "\\host.lan\Data\vcds_path.txt") {
      $exe = (Get-Content "\\host.lan\Data\vcds_path.txt").Trim().Replace('"', '')
      $dir = Split-Path -Parent $exe
      $file = Split-Path -Leaf $exe
      
      # Oprava pro UNC cesty pres pushd
      $batContent = "pushd `"$dir`"`r`nstart `"`" `"$file`"`r`nexit"
      $batContent | Out-File "C:\run_vcds.bat" -Encoding ascii

      if ($Action -eq "RDP") {
          "READY" | Out-File "\\host.lan\Data\status.txt" -Encoding ascii
          Start-Process "tsdiscon.exe"
      } else {
          Start-Process "C:\run_vcds.bat"
      }
  }
}
EOF
    fix_permissions
}

create_shortcut() {
    local app_dir="${REAL_HOME}/.local/share/applications"
    local desk_dir_cs="${REAL_HOME}/Plocha"
    local desk_dir_en="${REAL_HOME}/Desktop"
    
    mkdir -p "$app_dir"
    cat << 'EOF' > "$app_dir/vcds.desktop"
[Desktop Entry]
Name=VCDS
Comment=VCDS diagnostika v Dockeru
Exec=/usr/local/bin/vcds
Icon=utilities-terminal
Terminal=true
Type=Application
Categories=Utility;
EOF
    chown "$REAL_USER:$REAL_USER" "$app_dir/vcds.desktop"

    if [ -d "$desk_dir_cs" ]; then
        cp "$app_dir/vcds.desktop" "$desk_dir_cs/"
        chown "$REAL_USER:$REAL_USER" "$desk_dir_cs/vcds.desktop"
        chmod +x "$desk_dir_cs/vcds.desktop"
    elif [ -d "$desk_dir_en" ]; then
        cp "$app_dir/vcds.desktop" "$desk_dir_en/"
        chown "$REAL_USER:$REAL_USER" "$desk_dir_en/vcds.desktop"
        chmod +x "$desk_dir_en/vcds.desktop"
    fi
    echo "Zastupce vytvoren."
}

run_vcds() {
    local MODE=$1
    local ACTION="RUN"
    local RDP_CMD=""
    
    if [ "$MODE" == "SETUP" ]; then
        ACTION="SETUP"
    elif [ "$MODE" == "RDP" ]; then
        ACTION="RDP"
    fi

    if [ "$MODE" == "RDP" ]; then
        if command -v xfreerdp3 &> /dev/null; then
            RDP_CMD="xfreerdp3"
        elif command -v xfreerdp &> /dev/null; then
            RDP_CMD="xfreerdp"
        else
            echo "CHYBA: xfreerdp neni nainstalovan!"
            exit 1
        fi
    fi
    
    rm -f "$TRANSFER_DIR/status.txt"
    echo "$ACTION" > "$TRANSFER_DIR/action.txt"
    create_shared_scripts
    
    if [ ! -f "$CONF_FILE" ]; then
        detect_cable
    fi
    source "$CONF_FILE"
    
    echo "Startuji kontejner..."
    docker run -d --rm --name vcds_win7 --stop-timeout 120 \
      --device /dev/net/tun --cap-add NET_ADMIN \
      --device /dev/bus/usb --device /dev/kvm \
      -p 8006:8006 -p 33890:3389 \
      -v "$DATA_DIR:/storage" \
      -v "$TRANSFER_DIR:/shared" \
      -v "$CONFIG_DIR:/oem" \
      -e VERSION="7u" \
      -e ARGUMENTS="-device usb-ehci,id=my-ehci -device piix3-usb-uhci,id=my-uhci -device usb-host,vendorid=$VENDOR_ID,productid=$PRODUCT_ID,bus=my-uhci.0" \
      dockurr/windows > /dev/null

    if [ "$MODE" == "RDP" ]; then
        VCDS_PATH=$(cat "$TRANSFER_DIR/vcds_path.txt" 2>/dev/null | tr -d '\r\n')
        if [ -z "$VCDS_PATH" ]; then
            echo "Cesta k VCDS chybi! Spust volbu 3."
            docker stop vcds_win7 &> /dev/null
            exit 1
        fi
        
        echo "Cekam na start systemu..."
        until docker logs vcds_win7 2>&1 | grep -q "Windows started successfully"; do sleep 2; done
        
        echo "Cekam na uvolneni relace ve Windows..."
        until grep -q "READY" "$TRANSFER_DIR/status.txt" 2>/dev/null; do sleep 1; done
        sleep 2
        
        local RDP_ARGS=(
            "/v:127.0.0.1:33890"
            "/u:docker"
            "/p:vcds"
            "/cert:ignore"
            "+clipboard"
            "/dynamic-resolution"
        )

        if [ "$RDP_CMD" == "xfreerdp3" ]; then
            RDP_ARGS+=("/app:program:||C:\run_vcds.bat")
            RDP_ARGS+=("/tls:seclevel:0")
            RDP_ARGS+=("/auth-pkg-list:!kerberos")
        else
            RDP_ARGS+=("/app:||C:\run_vcds.bat")
            RDP_ARGS+=("/tls-seclevel:0")
        fi

        echo "Spoustim VCDS..."
        sudo -u "$REAL_USER" env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" $RDP_CMD "${RDP_ARGS[@]}" &> /dev/null
        
        echo "Ukoncuji kontejner..."
        docker stop vcds_win7 &> /dev/null
    else
        echo "Cekam na Windows..."
        until docker logs vcds_win7 2>&1 | grep -q "Windows started successfully"; do sleep 2; done
        sudo -u "$REAL_USER" env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" xdg-open "http://127.0.0.1:8006/" &> /dev/null
        
        echo ""
        read -p "Po dokonceni prace stiskni [ENTER] pro vypnuti VCDS..."
        echo "Ukoncuji kontejner..."
        docker stop vcds_win7 &> /dev/null
    fi
}

uninstall() {
    read -p "Smazat vsechna data? [y/N]: " CONFIRM
    if [[ "$CONFIRM" == "y" ]]; then
        docker stop vcds_win7 &> /dev/null
        rm -rf "$DATA_DIR" "$TRANSFER_DIR" "$CONFIG_DIR"
        rm -f /etc/udev/rules.d/99-vcds.rules
        udevadm control --reload-rules
        rm -f "$LOCAL_BIN" "${REAL_HOME}/.local/share/applications/vcds.desktop" "${REAL_HOME}/Plocha/vcds.desktop" "${REAL_HOME}/Desktop/vcds.desktop"
        read -p "Smazat i Docker image? [y/N]: " IMG_CONFIRM
        [[ "$IMG_CONFIRM" == "y" ]] && docker rmi dockurr/windows
        echo "Hotovo."
    fi
    exit 0
}

clear
echo "=========================================="
echo "    VCDS Docker Instalator (v$CURRENT_VERSION)    "
echo "=========================================="

check_system

if [ ! -f "$IMG_FILE" ]; then
    echo "STAV: Nova instalace"
    mkdir -p "$DATA_DIR" "$TRANSFER_DIR" "$CONFIG_DIR"
    fix_permissions
    detect_cable
    create_install_bat
    create_shortcut
    run_vcds "SETUP"
else
    echo "STAV: System nainstalovan."
    echo "1) Spustit VCDS (RDP)"
    echo "2) Spustit VCDS (Prohlizec)"
    echo "3) Nastavit/Aktualizovat"
    echo "4) Reinstalace Windows"
    echo "5) Odinstalovat"
    echo "6) Zmenit kabel"
    echo "7) Vytvorit zastupce"
    read -p "Vyber [1-7]: " CHOICE

    case "$CHOICE" in
        1) run_vcds "RDP" ;;
        2) run_vcds "WEB" ;;
        3) run_vcds "SETUP" ;;
        4) rm -f "$IMG_FILE"; exit 0 ;;
        5) uninstall ;;
        6) detect_cable ;;
        7) create_shortcut ;;
        *) exit 1 ;;
    esac
fi
