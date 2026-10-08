# Orca auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App (kein Teil dieses Repos): `https://github.com/stablyai/orca`
> Dieses Repo enthält **nur den Proxmox-Installer**: Install-Script + systemd-Unit.
> Die App läuft als headless `orca serve` Remote-Server im LXC –
> vollständig lokal, keine Cloud-Dienste nötig.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OrcaAI-Proxmox/main/install/orca.sh)"
```

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
CT_ID=150 CORES=2 RAM=4096 DISK=20 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/OrcaAI-Proxmox/main/install/orca.sh)"
bash orca.sh --ctid 150 --cores 2 --memory 4096 --disk 20 --bridge vmbr0 --storage local-lvm
bash orca.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/orca-install-*.log
bash orca.sh --source-build  # Fallback: aus Source bauen statt Prebuilt (30-60 Min)
```

> Die systemd-Unit liegt unter `systemd/orca.service` desselben Repos und wird
> vom Installer von dort geladen (Fallback: Inline-Unit im Script).

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `orca` |
| Zweck | Orca ADE als always-on Remote-Server – parallele Coding-Agenten (Claude Code, Codex, OpenCode …), per Laptop-Orca / Browser / Mobile pairbar |
| Tech-Stack | Prebuilt `orca-linux.AppImage` (`--appimage-extract`, ohne FUSE) + systemd `orca serve :6768`, User `orca`, `/opt/orca`, `/var/lib/orca` |
| GitHub-Repo (Upstream) | `https://github.com/stablyai/orca` |
| Endpoint | `http://<LXC-IP>:6768` (Pairing-URL aus `journalctl -u orca`) |
| Standard-Ressourcen | 2 vCPU / 4096 MB RAM / 20 GB Disk (Electron-Prebuilt + Extract brauchen mehr als 1–2 GB / 4–8 GB) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-12-standard` (neuestes auf Storage `local`) |
| LXC-Features | **unprivilegiert** (`--unprivileged 1`), `nesting=1`, `onboot: 1` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-12-standard`-Template falls nötig,
2. erstellt den LXC `orca` (`onboot: 1`, unprivilegiert),
3. installiert im Container Deps + Electron-Libs, legt User `orca` an,
   lädt das neueste Orca-Release (GitHub-API, Fallback `/releases/latest`-Redirect),
   extrahiert per `--appimage-extract` nach `/opt/orca`, verlinkt `/usr/local/bin/orca`,
   schreibt `orca.service` (Pairing-Adresse = Container-IP), `systemctl enable --now orca`,
4. verifiziert `systemctl is-active orca` + HTTP auf `localhost:6768/`
   (**jeder Status außer 000 zählt**, da `/` nicht garantiert 200 liefert)
   und gibt Endpoint + Pairing-Link + Container-IP aus.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active orca = active).
[OK]    orca serve antwortet (HTTP 200 auf localhost:6768).

════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Orca – ADE Remote Server (orca serve, headless)
  Container    : CT 100 (Hostname: orca, unprivilegiert, onboot=1)
  Ressourcen   : 2 vCPU / 4096 MB RAM / 20 GB Disk
  Endpoint     : http://192.168.1.100:6768
  Pairing      : orca://pair?code=...
  ...
  Log          : /tmp/orca-install-2026-....log
══════════════════════════════════════════════════
```

Client-Setup danach: Laptop-Orca → Settings → Remote Orca Servers → Add Server → Pairing-Link einfügen.
Agent-CLIs (claude, codex, …) auf dem **Server** installieren/authentifizieren – ein Login auf dem Laptop überträgt sich nicht automatisch.

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active orca
curl -s -o /dev/null -w '%{http_code}\n' http://<LXC-IP>:6768
```

## Update / Deinstall

```bash
bash orca.sh --ctid 100            # Update: idempotent (Release-Refresh + Restart)
pct stop 100 && pct destroy 100  # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/orca-install-*.log`.
- `bash orca.sh --debug` für `bash -x`-Trace.
- Im Container: `systemctl status orca --no-pager`, `journalctl -u orca -n 100`, `ss -ltn`, `ls /opt/orca/squashfs-root` (AppImage-Layout prüfen).
- Hinweis DHCP: Die Unit enthält die Container-IP als `--pairing-address`. Bekommt der CT nach einem Reboot eine neue IP, Skript erneut laufen lassen (Update-Modus schreibt die Unit neu + Restart).

## Dateien

- `install/orca.sh` – Proxmox-Einzeiler (Host, root).
- `systemd/orca.service` – Unit (`:6768`, `After=network-online.target`, `Restart=always`; `__CT_IP__` wird beim Installieren ersetzt).
