# DoodleNote @ Proxmox (LXC, Einzeiler)

Selbstgehosteter **DoodleNote Sync-Server** (`apps/web`, Next.js, Port `4040`)
als LXC-Container auf Proxmox — im Stil der Proxmox VE Community Scripts.
Upstream-App: <https://github.com/Onyx-Dev-Labs/doodle-note>

> **Scope:** Dieser LXC hostet nur den Web-Workspace/Sync-Server.
> Desktop-Capture und On-Device-Transkription (Electron + Swift-`engine/`,
> Mikrofon/Call-Capture) brauchen macOS Apple Silicon bzw. Windows mit GUI
> und laufen **nicht** headless im LXC. Laptops bleiben für Capture zuständig,
> der LXC optional für Sync/Share.

- Lokal: Next.js + **lokales Postgres 16 im gleichen Container**, keine Cloud nötig.
- Reboot-sicher: `systemd` (`Restart=always`, `After=network-online.target`)
  + `onboot: 1` für den Container.
- Idempotent: Erneut laufen lassen = Update (`git pull` + rebuild).

## Installation (Einzeiler, auf dem Proxmox-Host als root)

```bash
bash -c "$(curl -fsSL --connect-timeout 10 --max-time 60 https://raw.githubusercontent.com/HatchetMan111/DoodleNoteProxmox/main/install/doodle-note.sh)"
```

Alternative mit `wget`:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/DoodleNoteProxmox/main/install/doodle-note.sh)"
```

> **Kommt gar keine Ausgabe** (nicht mal `[doodle-note] Installer startet ...`),
> hängt der **Download**, nicht das Script — `bash -c "$(…)"` wartet erst den
> kompletten Download ab. Dann zweistufig vorgehen, um es zu sehen:
>
> ```bash
> curl -fsSL --connect-timeout 10 --max-time 60 -o /tmp/dn.sh \
>   https://raw.githubusercontent.com/HatchetMan111/DoodleNoteProxmox/main/install/doodle-note.sh \
>   && bash /tmp/dn.sh
> ```
>
> Steht `[doodle-note] Installer startet ...` da und es geht nicht weiter,
> bitte diese Zeile + die letzte Logzeile schicken — jede Phase loggt vorab,
> `pct`/`qm`/`pveam`-Aufrufe sind per `timeout` abgesichert.

Mit Optionen (CT-ID, Hostname, Storage, Bridge, Netz):

```bash
bash doodle-note.sh --ctid 101 --hostname doodleNote --storage local-lvm --bridge vmbr0 --net dhcp
# statisch z. B.: --net 10.0.0.50/24,gw=10.0.0.1
```

Ohne `--ctid` nimmt das Script die nächste freie ID ab 100 und weicht
automatisch aus, falls die ID doch belegt ist (der ID-Raum wird mit
QEMU-VMs geteilt — `qm status` wird mitgeprüft). Standard-Hostname:
`doodleNote`. Explizit per `--ctid` gewählte, belegte IDs werden nicht
still umgebogen — das Script schlägt dann eine freie ID vor.

Bei Fehlern mit vollem Trace (komplette Kette, nicht nur letzte Zeile):

```bash
DEBUG=1 bash -x doodle-note.sh
```

### Erwartete Ausgabe (Erfolg)

```
[OK] Template bereit: debian-12-standard_12.7-1_amd64.tar.zst
[OK] Container 101 erstellt (onboot=1).
[OK] CT 101 reagiert auf pct exec.
[CT-OK] Basis + Postgres installiert.
[CT-OK] Node/pnpm bereit.
[CT-OK] App-Code aktuell.
[CT-OK] Build fertig.
[CT-OK] systemd-Unit aktiv.
[CT-OK] Web UI antwortet auf localhost:4040.
[OK] onboot=1 gesetzt ...

========================================
 doodle-note Installation erfolgreich
========================================
 Container : CT 101 (doodleNote)
 Web UI    : http://192.168.1.101:4040
 Lokaltest : pct exec 101 -- curl -I http://localhost:4040/
 Service   : pct exec 101 -- systemctl status doodle-note
 ...
```

Danach im Browser öffnen: `http://<LXC-IP>:4040` (bind `0.0.0.0` via `next start --port 4040`).

Standard-Ressourcen: **2 vCPU / 4 GB RAM / 12 GB Disk**, Debian 12, unprivilegiert,
`nesting=1`. 1 GB RAM reicht für den Next.js-Build nicht (OOM) — daher 4 GB.

## Update

Einfach den Einzeiler erneut laufen lassen (mit `--ctid <ID>`):

```bash
bash doodle-note.sh --ctid 101
```

Das macht `git pull --ff-only`, `pnpm install`, `drizzle-kit migrate`,
`pnpm --filter web build` und `systemctl restart doodle-note`.
Bestehende Secrets in `/etc/doodle-note/doodle-note.env` bleiben erhalten.

## Reboot-Test (mit Log-Beleg)

```bash
CTID=101
pct reboot $CTID
sleep 20
pct exec $CTID -- systemctl is-active doodle-note     # erwartet: active
pct exec $CTID -- curl -fsSI http://localhost:4040/ | head -n 5  # erwartet: HTTP/1.1 200 OK
pct exec $CTID -- journalctl -u doodle-note -n 50 --no-pager
```

## Deinstallation

```bash
CTID=101
pct stop $CTID
pct destroy $CTID
```

(Optional Backups vorher: `vzdump $CTID --storage <backup-storage> --mode snapshot`.)

## Dateien in diesem Repo

```
install/doodle-note.sh      Host-Installer (pct create + pct exec Setup, set -euo pipefail, idempotent)
assets/doodle-note.service  systemd-Unit (im CT nach /etc/systemd/system/doodle-note.service installiert)
README.md                   diese Anleitung
```

App-Code selbst kommt per `git clone` aus dem Upstream
(`https://github.com/Onyx-Dev-Labs/doodle-note.git`, Branch `main`);
Env/Build/Doku: `SELF-HOSTING.md`, `apps/web/README.md`, Port `4040`,
`DOODLENOTE_SELF_HOSTED=true`, `DATABASE_URL` lokal.

## Debugging

- Das Script nutzt `set -euo pipefail` + `trap ERR` und druckt bei Fehlern
  Exit-Code, fehlgeschlagenes Kommando, `caller`-Stack und die
  `bash -x`-Anleitung — nie nur die letzte Zeile.
- Container-Logs: `pct exec <CTID> -- journalctl -u doodle-note -n 100 --no-pager`
- Service: `pct exec <CTID> -- systemctl status doodle-note`
- HTTP: `pct exec <CTID> -- curl -v http://localhost:4040/`
