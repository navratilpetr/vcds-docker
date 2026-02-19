#!/bin/bash

# =================================================================
# VCDS Docker Starter - Interaktivni pruvodce (v2.4 - auto browser)
# =================================================================

# Autorestart pod sudo, pokud nespousti root
if [ "$EUID" -ne 0 ]; then
    echo "Tento skript vyzaduje administratorska prava (sudo)."
    # Stazeni skriptu do docasneho souboru pro spusteni pod sudo
    tmp_script="/tmp/start_vcds_root.sh"
    curl -fsSL https://raw.githubusercontent.com/navratilpetr/vcds-docker/refs/heads/main/start_vcds.sh > "$tmp_script"
    chmod +x "$tmp_script"
    # Zachovani promennych prostredi pro grafiku
    sudo env DISPLAY="$DISPLAY" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" "$tmp_script" "$@"
    rm "$tmp_script"
    exit 0
fi

# Zjisteni puvodniho uzivatele pro spravne nastaveni cest
REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# Konfigurace cest
DATA_DIR="${REAL_HOME}/vcds_data"
TRANSFER_DIR="${REAL_HOME}/vcds_transfer"
CONFIG_DIR="${REAL_HOME}/vcds_config"
CONF_FILE="$CONFIG_DIR/settings.conf"
IMG_FILE="$DATA_DIR/data.img"

# Funkce pro nastaveni spravnych prav souboru
fix_permissions() {
    chown -R "$REAL_USER:$REAL_USER" "$DATA_DIR" "$TRANSFER_DIR" "$CONFIG_DIR"
}

# Funkce pro kontrolu prerekvizit
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

# Funkce pro detekci kabelu
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

# Funkce pro vytvoreni install.bat
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

:: Registrace do planovace
schtasks /create /tn "VCDS_Kill_Gateway" /tr "cmd.exe /c %WINDIR%\kill_gw.bat" /sc onstart /ru SYSTEM /rl HIGHEST /f

:: Vypnuti Defenderu
reg add "HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender" /v DisableAntiSpyware /t REG_DWORD /d 1 /f
route delete 0.0.0.0
EOF
    fix_permissions
}

# Funkce pro automaticke otevreni prohlizece
wait_and_open_browser() {
    (
        # Cekani na vytvoreni kontejneru
        until docker inspect vcds_win7 &> /dev/null; do sleep 1; done
        # Sledovani logu do nalezeni fraze
        docker logs -f vcds_win7 2>&1 | grep -q -m 1 "Windows started successfully"
        # Spusteni prohlizece pod puvodnim uzivatelem
        sudo -u "$REAL_USER" env DISPLAY="${DISPLAY:-:0}" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" xdg-open "http://127.0.0.1:8006/" &> /dev/null
    ) &
}

# Funkce pro spusteni Dockeru
run_vcds() {
    if [ ! -f "$CONF_FILE" ]; then
        echo "Chybi konfigurace kabelu!"
        detect_cable
    fi
    source "$CONF_FILE"
    
    echo "Spoustim VCDS ve Windows..."
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

# Funkce pro odinstalaci
uninstall() {
    echo "--- ODINSTALACE ---"
    read -p "Opravdu smazat vsechna data VCDS? [y/N]: " CONFIRM
    if [[ $CONFIRM == "y" ]]; then
        docker stop vcds_win7 &> /dev/null
        rm -rf "$DATA_DIR" "$TRANSFER_DIR" "$CONFIG_DIR"
        rm -f /etc/udev/rules.d/99-vcds.rules
        udevadm control --reload-rules
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
    echo "1. Pockej na plochu (cca 5-10 min)."
    echo "2. Stahni VCDS a dej ho do slozky vcds_transfer u tebe v Home."
    echo "3. Ve Windows otevri 'Shared', nainstaluj VCDS a pouzivej."
    echo ""
    read -p "Stiskni [ENTER] pro zahajeni..."
    run_vcds
else
    echo "STAV: System je jiz nainstalovan."
    echo "1) Spustit VCDS"
    echo "2) Aktualizovat (otevrit Windows)"
    echo "3) Reinstalace (smazat disk a zacit znovu)"
    echo "4) Odinstalovat (smazat vse)"
    read -p "Vyber moznost [1-4]: " CHOICE

    case $CHOICE in
        1|2) run_vcds ;;
        3) rm -f "$IMG_FILE"; echo "Disk smazan. Restartuj skript pro novou instalaci."; exit 0 ;;
        4) uninstall ;;
        *) echo "Neplatna volba."; exit 1 ;;
    esac
fi
