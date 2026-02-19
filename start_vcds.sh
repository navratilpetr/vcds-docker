#!/bin/bash

# =================================================================
# VCDS Docker Starter (v2.17 - Sudo a bezny uzivatel)
# =================================================================

CURRENT_VERSION="2.17"
REPO_URL="https://raw.githubusercontent.com/navratilpetr/vcds-docker/refs/heads/main/start_vcds.sh"
LOCAL_BIN="/usr/local/bin/vcds"

# Autorestart pod sudo
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

# Lokani instalace
if [ "$(realpath "$0")" != "$LOCAL_BIN" ]; then
    cp "$0" "$LOCAL_BIN"
    chmod +x "$LOCAL_BIN"
    echo "--- SKRIPT NAINSTALOVAN ---"
    echo "Pro pristi spusteni staci napsat: vcds"
    echo "---------------------------"
    sleep 2
fi

# Kontrola aktualizaci
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

# Zjisteni puvodniho uzivatele
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

    if ! command -v xfreerdp &> /dev/null; then
        echo "VAROVANI: xfreerdp neni nainstalovan. RDP rezim nebude fungovat."
        echo "Lze doinstalovat: pacman -S freerdp"
    fi

    if [ ! -e /dev/kvm ]; then
        echo "CHYBA: Virtualizace (KVM) neni povolena nebo chybi modul!"
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
    echo "Najdi v seznamu svuj kabel (napr. Ross-Tech nebo FTDI)."
    read -p "Zadej ID tveho zarizeni (napr. 0403:fa24): " USER_ID
    
    if [[ $USER_ID =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
        V_ID=$(echo $USER_ID | cut -d: -f1)
        P_ID=$(echo $USER_ID | cut -d: -f2)
        
        echo "VENDOR_ID=0x$V_ID" > "$CONF_FILE"
        echo "PRODUCT_ID=0x$P_ID" >> "$CONF_FILE"
        
        echo "Nastavuji udev pravidla..."
        echo "SUBSYSTEM==\"usb\", ATTR{idVendor}==\"$V_ID\", ATTR{idProduct}==\"$P_ID\", MODE=\"0666\"" > /etc/udev/rules.d/99-vcds.rules
        udevadm control --reload-rules && udevadm trigger
        echo "Kabel ulozen: $USER_ID"
        fix_permissions
    else
        echo "Neplatny format ID! Zkus to znovu."
        exit 1
    fi
}

create_install_bat() {
    cat << 'EOF' > "$CONFIG_DIR/install.bat"
@echo off
:: Blokace Ross-Tech
echo 127.0.0.1 update.ross-tech.com >> %WINDIR%\System32\drivers\etc\hosts
echo 127.0.0.1 www.ross-tech.com >> %WINDIR%\System32\drivers\etc\hosts

:: Smazani brany
echo @echo off > %WINDIR%\kill_gw.bat
echo ping -n 15 127.0.0.1 ^> nul >> %WINDIR%\kill_gw.bat
echo route delete 0.0.0.0 >> %WINDIR%\kill_gw.bat
schtasks /create /tn "VCDS_Kill_Gateway" /tr "cmd.exe /c %WINDIR%\kill_gw.bat" /sc onstart /ru SYSTEM /rl HIGHEST /f

:: Bezpecnost a RDP povoleni
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiSpyware /t REG_DWORD /d 1 /f
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Lsa" /v LimitBlankPasswordUse /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList" /v fDisabledAllowList /t REG_DWORD /d 1 /f
route delete 0.0.0.0

set STARTUP_DIR="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Startup"
echo @echo off > %STARTUP_DIR%\vcds_launcher.bat
echo timeout /t 5 /nobreak ^> nul >> %STARTUP_DIR%\vcds_launcher.bat
echo powershell -sta -ExecutionPolicy Bypass -WindowStyle Hidden -File \\host.lan\Data\startup.ps1 >> %STARTUP_DIR%\vcds_launcher.bat
EOF
    fix_permissions
}

create_shared_scripts() {
    printf "=== NAVOD K INSTALACI VCDS ===\r\n1. V Linuxu uloz instalacku VCDS do slozky 'vcds_transfer' ve tvem domovskem adresari (Home).\r\n2. Tady ve Windows otevri slozku 'Shared' (Tento pocitac -> Z: nebo Sit -> host.lan).\r\n3. Nainstaluj VCDS vcetne vsech ovladacu.\r\n4. Po dokonceni instalace ZAVRI tento textovy soubor (krizkem).\r\n5. Nasledne vyskoci okno, kde vyberes spousteci soubor VCDS.\r\n" > "$TRANSFER_DIR/navod.txt"

    cat << 'EOF' > "$TRANSFER_DIR/startup.ps1"
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Lsa" /v LimitBlankPasswordUse /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Terminal Server\TSAppAllowList" /v fDisabledAllowList /t REG_DWORD /d 1 /f

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
      $exe = Get-Content "\\host.lan\Data\vcds_path.txt"
      $dir = Split-Path -Parent $exe
      Start-Process -FilePath $exe -WorkingDirectory $dir
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
    echo "Zastupce byl vytvoren."
}

run_vcds() {
    local MODE=$1
    local ACTION="RUN"
    
    if [ "$MODE" == "SETUP" ]; then
        ACTION="SETUP"
    fi
    
    echo "$ACTION" > "$TRANSFER_DIR/action.txt"
    create_shared_scripts
    
    if [ ! -f "$CONF_FILE" ]; then
        echo "Chybi konfigurace kabelu!"
        detect_cable
    fi
    source "$CONF_FILE"
    
    echo "Startuji kontejner..."
    docker run -d --rm --name vcds_win7 \
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
            echo "Cesta k VCDS chybi! Spust nejprve volbu 'Aktualizovat/Nastavit'."
            docker stop vcds_win7 &> /dev/null
            exit 1
        fi
        
        echo "Cekam na RDP server ve Windows (muze to chvili trvat)..."
        until bash -c 'echo > /dev/tcp/127.0.0.1/33890' 2>/dev/null; do sleep 2; done
        sleep 5
        
        echo "Spoustim VCDS jako okno..."
        sudo -u "$REAL_USER" env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" xfreerdp /v:127.0.0.1:33890 /u:docker /p:"" /cert:ignore /app:"||$VCDS_PATH" +clipboard /dynamic-resolution &> /dev/null
        
        echo "VCDS ukonceno. Zastavuji kontejner..."
        docker stop vcds_win7 &> /dev/null
    else
        echo "Cekam na Windows (otevre se v prohlizeci)..."
        until docker logs vcds_win7 2>&1 | grep -q "Windows started successfully"; do sleep 2; done
        sudo -u "$REAL_USER" env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" xdg-open "http://127.0.0.1:8006/" &> /dev/null
    fi
}

uninstall() {
    echo "--- ODINSTALACE ---"
    read -p "Opravdu smazat vsechna data VCDS? [y/N]: " CONFIRM
    if [[ $CONFIRM == "y" ]]; then
        docker stop vcds_win7 &> /dev/null
        rm -rf "$DATA_DIR" "$TRANSFER_DIR" "$CONFIG_DIR"
        rm -f /etc/udev/rules.d/99-vcds.rules
        udevadm control --reload-rules
        rm -f "$LOCAL_BIN" "${REAL_HOME}/.local/share/applications/vcds.desktop" "${REAL_HOME}/Plocha/vcds.desktop" "${REAL_HOME}/Desktop/vcds.desktop"
        echo "Soubory smazany."
        read -p "Chces smazat i Docker image (cca 5GB)? [y/N]: " IMG_CONFIRM
        [[ $IMG_CONFIRM == "y" ]] && docker rmi dockurr/windows
        echo "Hotovo."
    fi
    exit 0
}

clear
echo "=========================================="
echo "    VCDS Docker Instalator / Spoustec     "
echo "               (v$CURRENT_VERSION)        "
echo "=========================================="

check_system

if [ ! -f "$IMG_FILE" ]; then
    echo "STAV: Nova instalace"
    mkdir -p "$DATA_DIR" "$TRANSFER_DIR" "$CONFIG_DIR"
    fix_permissions
    detect_cable
    create_install_bat
    create_shortcut
    
    echo ""
    echo "Nyni se spusti instalace Windows 7."
    read -p "Stiskni [ENTER] pro zahajeni..."
    run_vcds "SETUP"
else
    echo "STAV: System je jiz nainstalovan."
    echo "1) Spustit VCDS (v okne - RDP)"
    echo "2) Spustit VCDS (v prohlizeci - Plna plocha)"
    echo "3) Aktualizovat/Nastavit (otevrit v prohlizeci)"
    echo "4) Reinstalace Windows (smazat disk a zacit znovu)"
    echo "5) Odinstalovat vse"
    echo "6) Zmenit/Detekovat jiny kabel"
    echo "7) Vytvorit zastupce na plochu"
    read -p "Vyber moznost [1-7]: " CHOICE

    case $CHOICE in
        1) run_vcds "RDP" ;;
        2) run_vcds "WEB" ;;
        3) run_vcds "SETUP" ;;
        4) rm -f "$IMG_FILE"; echo "Disk smazan. Restartuj prikaz vcds."; exit 0 ;;
        5) uninstall ;;
        6) detect_cable; echo "Novy kabel nastaven."; exit 0 ;;
        7) create_shortcut; exit 0 ;;
        *) echo "Neplatna volba."; exit 1 ;;
    esac
fi
