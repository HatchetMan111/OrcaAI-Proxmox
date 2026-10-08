# Orca auf Proxmox (LXC, `orca serve`) – Design-Spec

Datum: 2026-10-08 · Pfad-Kandidat: `orca-proxmox/` · Status: Entwurf zur Review

## 1. Verstandnis (agreed intent)

- **Outcome:** Orca (stablyai/orca, ADE für parallele Coding-Agenten) läuft als
  always-on **Remote Orca Server** auf Proxmox, installierbar per **Einzeiler**
  im Stil der Proxmox VE Community Scripts.
- **Gewählter Modus (freigegeben):** `orca serve` headless
  (`orca serve --port 6768 --pairing-address <LXC-IP>`), kein Desktop-Fenster.
  Clients (Laptop-Orca, Browser, Mobile) pairen per Pairing-URL.
- **Neues Installer-Repo (freigegeben):** eigener Ordner/Repo `USER/proxmox-orca`
  (Platzhalter `USER` noch zu setzen), App-Name `orca`, Port `6768`,
  Debian-12-LXC, **2 vCPU / 4 GB RAM / 20 GB Disk**, **nächste freie ID** via
  `pvesh get /cluster/nextid`, Hostname `orca`.
- **Annahmen (bitte korrigieren falls falsch):**
  - Proxmox-Host mit `pct`/`pvesh`/`pveam`/`pvesm`, Storage `local-lvm`
    bevorzugt, Template-Store `local`, Bridge `vmbr0`, DHCP.
  - LXC unprivilegiert mit `nesting=1`, `onboot: 1`.
  - „Web UI“ = `orca serve`-Endpoint auf `:6768` (kein klassisches Dashboard;
    Pairing-URL aus `journalctl -u orca` wird ausgegeben). HTTP-Check akzeptiert
    **jeden HTTP-Status ≠ 000** als „antwortet“ (auch 404), weil `/` keinen
    garantierten 200er liefert.
  - Vollständig lokal: keine Cloud-Dienste nötig (Tailscale optional, nicht
    required). Agent-CLIs (claude/codex/…) installiert der Betreiber nachträglich
    auf dem Server – nicht Teil des Installers.

## 2. Ansätze (betrachtet, mit Trade-offs)

- **(A) LXC + Prebuilt-Release — GEWÄHLT.** Lädt neuestes `orca-linux.AppImage`
  aus GitHub-Releases, `--appimage-extract` nach `/opt/orca` (kein FUSE nötig),
  Symlink `/usr/local/bin/orca`. Schnell (~5–10 Min), idempotent, kein
  Toolchain-Build. Risiko: AppImage-Layout kann sich ändern; Electron-Deps
  (libnss3, libatk, libdrm, libxkbcommon …) müssen im LXC nachinstalliert werden.
- **(B) LXC + Source-Build (Fallback-Flag `--source-build`).** `git clone` +
  Node 24 + pnpm 12 + `build:cli`/serve-Targets. Immer aktuell, kein
  AppImage-Risiko, aber 30–60 Min, build-anfällig, braucht die vollen
  4 GB/20 GB. Nur als opt-in Flag, nicht Default.
- **(C) VM statt LXC — VERWORFEN.** Ubuntu-24.04-VM via `qm` wäre die sicherste
  Electron-Umgebung und GUI-fähig, bricht aber das geforderte
  Community-Scripts-LXC-Muster und kostet deutlich mehr Ressourcen.

## 3. Design (Sektionen)

### 3.1 Architektur

```text
Proxmox-Host (root)
  └─ install/orca.sh  (set -euo pipefail, trap ERR, Log /tmp/orca-install-*.log)
       ├─ pvesh nextid → CT-ID (oder --ctid)
       ├─ pveam: neuestes debian-12-standard Template (tar.gz/xz/zst)
       ├─ pct create orca (unprivilegiert, nesting=1, onboot=1, DHCP)
       ├─ pct start + IP-Wait (hostname -I, 24×5s)
       └─ pct exec: Container-Setup (idempotent)
            ├─ apt: curl ca-certificates git squashfs-tools + Electron-Libs
            ├─ User orca, /opt/orca, /var/lib/orca (chown orca)
            ├─ Prebuilt: latest-Release-Tag via GitHub-API (+ Fallback
            │   /releases/latest), AppImage-Download, --appimage-extract,
            │   Symlink /usr/local/bin/orca → squashfs-root/<bin>
            ├─ /etc/systemd/system/orca.service (aus Repo-URL, Fallback inline)
            ├─ systemctl daemon-reload + enable --now orca
            └─ Verifikation: is-active + Port-Check :6768 + Pairing-URL ausgeben
```

### 3.2 Komponenten / Dateien

| Datei | Zweck |
|---|---|
| `install/orca.sh` | Host-Installer (Variablen oben, Env-Overrides `CT_ID/CORES/RAM/DISK`, Flags `--ctid/--cores/--memory/--disk/--storage/--bridge/--source-build/--debug`) |
| `systemd/orca.service` | Unit: `User=orca`, `ExecStart=/usr/local/bin/orca serve --port 6768 --pairing-address <IP>`, `Restart=always`, `After=network-online.target` (IP wird beim Installieren eingesetzt; Fallback: Start ohne pairing-address + Hinweis) |
| `README.md` | Einzeiler + Optionen + Reboot-Test + Update/Deinstall + Debugging |
| `docs/superpowers/specs/2026-10-08-orca-design.md` | diese Spec |

Kein App-Code-Fork: Orca-Upstream bleibt unberührt; Repo enthält nur Installer.

### 3.3 Datenfluss (Install → Betrieb)

1. Host prüft root + `pct`/`pvesh`, löst CT-ID/Storage/Template auf.
2. CT wird erstellt/gestartet; IP via `pct exec hostname -I`.
3. Im CT: Deps → Download → Extract → Symlink → Unit schreiben (Pairing-IP
   eingesetzt) → `enable --now`.
4. Verifikation: `systemctl is-active orca` = active; TCP/HTTP auf
   `localhost:6768` (jede Antwort ≠ 000 zählt); Pairing-URL aus
   `journalctl -u orca` in Schlussausgabe + `http://<LXC-IP>:6768`.
5. Reboot-Test separat: `pct reboot → sleep → is-active + curl`.

### 3.4 Fehlerbehandlung / Debugging

- `set -euo pipefail`, `trap ERR` mit Befehl + Zeile + Exit-Code + Log-Pfad.
- `exec > >(tee -i "$LOG_FILE") 2>&1`; `--debug` = `set -x`.
- Bei Verifikationsfehlern: `systemctl status`, `journalctl -u orca -n 100`,
  `ss -ltn`, AppImage-Layout-Listing – **komplette Kette**, nie nur letzte Zeile.
- Idempotenz: existierende CT-ID → Update-Modus (kein `pct create`);
  Download/Extract nur bei fehlendem/upgedatetem Release; `enable --now` erneut.

### 3.5 Tests / Verifikation

- Statisch: `bash -n install/orca.sh`, `shellcheck -S warning` (falls vorhanden).
- Dry-Run ohne Proxmox: Arg-Parsing/`--help` prüfbar; Host-Guard schlägt
  erwartbar an (`pct nicht gefunden`).
- Echter Lauf (Proxmox nötig, nicht hier ausführbar): Install →
  `systemctl is-active` → HTTP-Check → `pct reboot` → erneut erreichbar,
  mit Logauszügen als Beleg im README/PR.

## 4. Offene Punkte (vor Plan-Phase zu klären)

1. `USER`/Repo-Name für die raw-URLs im Einzeiler (Platzhalter ersetzen).
2. Ob Pairing-IP beim Unit-Schreiben fix eingesetzt oder via
   `ExecStartPre`-IP-Resolve dynamisch sein soll (DHCP-Wechsel).
3. Ob Electron-Dep-Liste im CT noch um `libgbm1`/`libasound2` ergänzt werden muss
   (hängt vom tatsächlichen AppImage-Layout ab – beim ersten echten Test prüfen).

## 5. Self-Review (Spec-Check)

- [x] Keine TBD/TODO-Platzhalter außer explizit als offene Punkte (1)–(3) markiert.
- [x] Konsistent: Port 6768 überall; `orca serve`-Syntax aus CLI-Referenz;
      Ressourcen 2/4096/20 überall (begründet: Electron-Prebuilt + Extract).
- [x] Scope: ein Installer + eine Unit + README; kein Upstream-Fork, keine VM.
- [x] Eindeutig: HTTP-Check-Semantik (≠ 000) definiert; ID-Vergabe (nextid)
      definiert; Update = Re-Run.
