# vcds-docker
VCDS v dockeru
# VCDS v Dockeru

Tento projekt umožňuje spouštět autodiagnostiku VCDS (VAG-COM) v izolovaném prostředí Windows 7 uvnitř Docker kontejneru na Linuxu.

## Klíčové vlastnosti
* **Bezpečnost:** Windows 7 běží v izolaci, bez přístupu k internetu (blokováno na úrovni hosts).
* **Jednoduchost:** Automatická instalace a konfigurace pomocí jednoho skriptu.
* **USB Passthrough:** Automatická detekce a nastavení práv pro kabel (HEX-V2, HEX-CAN atd.) pomocí udev pravidel.
* **Integrace:** Spouštění přes RDP (xfreerdp) nebo ve webovém prohlížeči.
* **Aktualizace:** Skript sám kontroluje a instaluje aktualizace (včetně migrace dat při menších updatech).

## Požadavky
* Linux (testováno na Arch Linux, Debian, Proxmox)
* Docker
* Povolena virtualizace KVM (`/dev/kvm`)
* `xfreerdp` nebo `xfreerdp3` (doporučeno pro nativní okno aplikace)

## Instalace

Spusťte následující příkaz v terminálu:

```bash
curl -fsSL https://raw.githubusercontent.com/navratilpetr/vcds-docker/refs/heads/main/start_vcds.sh | bash
