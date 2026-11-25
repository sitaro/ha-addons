# iPhone Backup

Erstellt nachts ein vollständiges, **verschlüsseltes** iPhone-Backup (Format wie Finder/iTunes) über WLAN und lädt es als `.tar` nach **OneDrive**. Lokal bleibt nichts liegen; das Add-on ist von HA-Backups ausgenommen.

## Einrichtung

1. **OneDrive-Token** auf einem Rechner mit Browser erzeugen:
   ```
   rclone authorize "onedrive"
   ```
   Das ausgegebene JSON (`{"access_token": …}`) unter *OneDrive-Token* eintragen. Die Drive-ID wird automatisch ermittelt.
2. **Backup-Passwort** eintragen – es schaltet die iOS-Backup-Verschlüsselung einmalig ein. **Gut aufbewahren** (Passwortmanager): ohne es ist das Backup nicht wiederherstellbar. Ohne aktive Verschlüsselung lädt das Add-on nichts hoch.
3. **Koppeln (einmalig per USB):** iPhone entsperrt an den HA-Host bzw. die HA-VM anschließen (bei Proxmox: USB-Gerät durchreichen) und die Aktion ausführen:
   ```yaml
   action: hassio.addon_stdin
   data:
     addon: <slug>_iphone_backup
     input: koppeln
   ```
   Auf dem iPhone „Vertrauen“ tippen. Danach ist WLAN-Zugriff aktiviert, das Kabel kann ab.

## Bedienung

| `input` | Wirkung |
|---|---|
| `backup` | Backup sofort starten |
| `koppeln` | Mit per USB angeschlossenem iPhone koppeln |
| `status` | Status-Sensor neu senden |

Status-Sensor: `sensor.iphone_backup` (`bereit`, `laeuft`, `wartet`, `ok`, `fehler`) mit Attributen `meldung`, `letzter_erfolg`, `groesse`, `datei`, `dauer_min`.

## Optionen

| Option | Bedeutung |
|---|---|
| `zeitplan` | Tägliche Startzeit (HH:MM) |
| `versuche_bis` | Bis zu dieser Uhrzeit wird alle 15 min erneut versucht, wenn das iPhone nicht erreichbar ist (muss nach `zeitplan` liegen) |
| `backup_passwort` | iOS-Backup-Passwort |
| `onedrive_token` | Ausgabe von `rclone authorize "onedrive"` |
| `onedrive_drive_id` | leer = automatisch |
| `onedrive_drive_type` | `personal`, `business` oder `documentLibrary` |
| `ziel` | Zielordner im OneDrive |
| `behalten` | Anzahl der aufbewahrten Backups |

## Hinweise

- Das iPhone muss im selben Netz sein; das Add-on nutzt das Host-Netz für die mDNS-Suche.
- Während des Laufs wird das Backup in `/tmp` des Containers zwischengespeichert – auf dem HA-Datenträger muss so viel frei sein wie das Backup groß ist.
- Wiederherstellen: `.tar` entpacken und mit Finder/iTunes oder `pymobiledevice3 backup2 restore` einspielen.
