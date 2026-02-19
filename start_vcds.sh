#!/bin/bash

# =================================================================
# VCDS Docker Starter (v2.11 - Offline & Auto-update)
# =================================================================

CURRENT_VERSION="2.11"
REPO_URL="https://raw.githubusercontent.com/navratilpetr/vcds-docker/refs/heads/main/start_vcds.sh"
LOCAL_BIN="/usr/local/bin/vcds"

# Autorestart pod sudo a lokani instalace
if [ "$EUID" -ne 0 ]; then
    echo "Tento skript vyzaduje administratorska prava."
    # Pokud neni soubor fyzicky na disku (spusteno pres curl)
    if [[ "$0" == "bash" || "$0" == *"curl"* || ! -f "$0" ]]; then
        tmp_script="/tmp/start_vcds_root.sh"
        curl -fsSL "$REPO_URL" > "$tmp_script"
        chmod +x "$tmp_script"
        sudo env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" "$tmp_script" "$@"
        rm "$tmp_script"
        exit 0
    else
        # Spusteno lokalne z disku (napr. prikaz vcds)
        exec sudo env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" "$0" "$@"
    fi
fi

# Lokani instalace
if [ "$(realpath "$0")" != "$LOCAL_BIN" ]; then
    cp "$0" "$LOCAL_BIN"
    chmod +x "$LOCAL_BIN"
    echo "--- SKRIPT NAINSTALOVAN ---"
    echo "Pro pristi spusteni staci v terminalu napsat prikaz: vcds"
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

:: Smazani brany po startu
echo @echo off > %WINDIR%\kill_gw.bat
echo ping -n 15 127.0.0.1 ^> nul >> %WINDIR%\kill_gw.bat
echo route delete 0.0.0.0 >> %WINDIR%\kill_gw.bat
schtasks /create /tn "VCDS_Kill_Gateway" /tr "cmd.exe /c %WINDIR%\kill_gw.bat" /sc onstart /ru SYSTEM /rl HIGHEST /f

:: Vypnuti Defenderu
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiSpyware /t REG_DWORD /d 1 /f
route delete 0.0.0.0

:: Vytvoreni zavadece po startu Windows
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
$Action = "RUN"
if (Test-Path "\\host.lan\Data\action.txt") { $Action = (Get-Content "\\host.lan\Data\action.txt").Trim() }
if (-Not (Test-Path "C:\vcds_path.txt")) { $Action = "SETUP" }

if ($Action -eq "SETUP") {
  Start-Process "notepad.exe" "\\host.lan\Data\navod.txt" -Wait
  
  [void][System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Filter = "Spustitelne soubory (*.exe)|*.exe"
  $dlg.Title = "Vyber spousteci soubor VCDS"
  $dlg.InitialDirectory = "C:\"
  
  if ($dlg.ShowDialog() -eq 'OK') { 
      $dlg.FileName | Out-File 'C:\vcds_path.txt' -Encoding ascii 
  }
  try { "RUN" | Out-File "\\host.lan\Data\action.txt" -Encoding ascii } catch {}
} else {
  if (Test-Path "C:\vcds_path.txt") {
      $exe = Get-Content "C:\vcds_path.txt"
      Start-Process $exe
  }
}
EOF
    fix_permissions
}

wait_and_open_browser() {
    (
        until docker inspect vcds_win7 &> /dev/null; do sleep 1; done
        
        until docker logs vcds_win7 2>&1 | grep -q "Windows started successfully"; do
            sleep 2
        done
        
        sudo -u "$REAL_USER" env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" XDG_RUNTIME_DIR="/run/user/$(id -u "$REAL_USER")" xdg-open "http://127.0.0.1:8006/" &> /dev/null
    ) &
}

run_vcds() {
    local ACTION=$1
    echo "$ACTION" > "$TRANSFER_DIR/action.txt"
    create_shared_scripts
    
    if [ ! -f "$CONF_FILE" ]; then
        echo "Chybi konfigurace kabelu!"
        detect_cable
    fi
    source "$CONF_FILE"
    
    echo "Spoustim VCDS ve Windows (Rezim: $ACTION)..."
    wait_and_open_browser
    
    docker run -it --rm --name vcds_win7 \
      --device /dev/net/tun --cap-add NET_ADMIN \
      --device /dev/bus/usb --device /dev/kvm \
      -p 8006:8006 \
      -v "$DATA_DIR:/storage" \
      -v "$TRANSFER_DIR:/shared" \
      -v "$CONFIG_DIR:/oem" \
      -e VERSION="7u" \
      -e ARGUMENTS="-device usb-ehci,id=my-ehci -device piix3-usb-uhci,id=my-uhci -device usb-host,vendorid=$VENDOR_ID,productid=$PRODUCT_ID,bus=my-uhci.0" \
      dockurr/windows
}

uninstall() {
    echo "--- ODINSTALACE ---"
    read -p "Opravdu smazat vsechna data VCDS? [y/N]: " CONFIRM
    if [[ $CONFIRM == "y" ]]; then
        docker stop vcds_win7 &> /dev/null
        rm -rf "$DATA_DIR" "$TRANSFER_DIR" "$CONFIG_DIR"
        rm -f /etc/udev/rules.d/99-vcds.rules
        udevadm control --reload-rules
        rm -f "$LOCAL_BIN"
        echo "Soubory smazany."
        read -p "Chces smazat i Docker image (cca 5GB)? [y/N]: " IMG_CONFIRM
        [[ $IMG_CONFIRM == "y" ]] && docker rmi dockurr/windows
        echo "Hotovo."
    fi
    exit 0
}

# --- HLAVNI LOGIKA ---

clear
echo "=========================================="
echo "    VCDS Docker Instalator / Spoustec     "
echo "               (v$CURRENT_VERSION)        "
echo "=========================================="

if [ ! -f "$IMG_FILE" ]; then
    echo "STAV: Nova instalace"
    mkdir -p "$DATA_DIR" "$TRANSFER_DIR" "$CONFIG_DIR"
    fix_permissions
    
    check_system
    detect_cable
    create_install_bat
    
    echo ""
    echo "Nyni se spusti instalace Windows 7."
    echo "Pockej na plochu a otevreni navodu."
    echo ""
    read -p "Stiskni [ENTER] pro zahajeni..."
    run_vcds "SETUP"
else
    echo "STAV: System je jiz nainstalovan."
    echo "1) Spustit VCDS"
    echo "2) Aktualizovat (otevrit pruvodce)"
    echo "3) Reinstalace (smazat disk a zacit znovu)"
    echo "4) Odinstalovat (smazat vse)"
    read -p "Vyber moznost [1-4]: " CHOICE

    case $CHOICE in
        1) run_vcds "RUN" ;;
        2) run_vcds "SETUP" ;;
        3) rm -f "$IMG_FILE"; echo "Disk smazan. Restartuj prikaz vcds pro novou instalaci."; exit 0 ;;
        4) uninstall ;;
        *) echo "Neplatna volba."; exit 1 ;;
    esac
fi
