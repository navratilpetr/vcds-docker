# Projekt: VCDS Docker
**Kontextový soubor pro Gemini Code Assist**

## 1. Architektura a cíl
* **Cil:** Spousteni autodiagnostiky VCDS (Windows 7) v Docker kontejneru na Linuxu (Arch Linux, Proxmox, Debian kontejnery).
* **Distribuce:** Jeden hlavni bash skript (`start_vcds.sh`) spousteny pres `curl`. Skript se sam instaluje lokalne a resi aktualizace.
* **Klicove technologie:** Docker (dockurr/windows), QEMU/KVM, bash, PowerShell, xfreerdp3, udev.

## 2. Kodovaci standard a komunikace
* **Jazyk:** Cestina. Odpovedi musi byt maximalne strucne a k veci.
* **Komentare:** Ve scriptovacich jazycich (bash, ps1, bat) psat komentare vyhradne bez ceske diakritiky a bez emoji.
* **Editor:** Pro veskere CLI operace a navrhy uprav vzdy predpokladat pouziti `vim` (nikdy nenavrhovat nano).
* **Presnost:** Pokud chybi technicke detaily, asistent se musi doptat. Nehadat reseni. Vzdy dohledavat aktualni reseni (napriklad zname bugy xfreerdp3 na Waylandu).

## 3. Systemova pravidla a Sudo
* **Eskalace:** Hlavni skript musi bezet pod rootem pro spravu Dockeru a zapis do `/etc/udev/rules.d/`. Pokud neni spusten jako root, musi se sam restartovat pres `sudo`.
* **De-eskalace (Kriticke):** GUI aplikace (napr. `xfreerdp3`, `xdg-open`) se NIKDY nesmi spoustet pod rootem. Skript musi pouzit `sudo -u $REAL_USER` a spravne predat promenne prostredi (`DISPLAY`, `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`), aby okna fungovala pod X11/Wayland.

## 4. Zname problemy a zakazane postupy
* **Sitiovani (Zakazano):** Je striktne zakazano pouzivat prikaz `route delete 0.0.0.0` ve Windows. Odrizne to RDP odpovedi zpet do site Dockeru a zpusobi zamrznuti xfreerdp3. Odstrizeni od internetu (Ross-Tech) se resi vyhradne pres `%WINDIR%\System32\drivers\etc\hosts`.
* **RDP a RemoteApp:** Mod RemoteApp (`/app`) ve Windows 7 pod Dockerem spatne mapuje z-order a focus na vice monitorech na Arch Linuxu (pruhledna okna kradou kliknuti). 
    * Preferovane reseni: Spustit Full Desktop a VCDS maximalizovat.
    * Pripadne parametry pro testy RemoteApp: `/app:no-shell`, `/gdi:hw`, vynechat `/dynamic-resolution`.
* **Logoff vs Disconnect:** Pro ukonceni/pripravu RDP relace v ps1 skriptu pouzivat `logoff.exe`. Prikaz `tsdiscon` zpusobuje kolize pri okamzitem pokusu o pripojeni.

## 5. Verzovani (Sematika)
* `MAJOR`: Zmeny vyzadujici cistou instalaci Windows (smazani `data.img`).
* `MINOR`: Upravy skriptu, ktere nevyzaduji zasah do uzivatelskych dat a zaktualizuji se "on-the-fly".