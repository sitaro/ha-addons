#!/usr/bin/with-contenv bashio
# iPhone Backup – Add-on für Home Assistant
# Befehle per hassio.addon_stdin: koppeln | backup | status
set +e -o pipefail   # bashio setzt -e; Fehler werden selbst behandelt

PMD=/opt/pmd3/bin/pymobiledevice3
STAGING=/tmp/staging
STATUS=/data/status.json
RCLONE_CONF=/data/rclone.conf
ENTITY=sensor.iphone_backup
LOCK=/tmp/backup.lock

export HOME=/data/home
mkdir -p "$HOME" /data/lockdown
# Kopplungsdaten von usbmuxd dauerhaft in /data
rm -rf /var/lib/lockdown && ln -s /data/lockdown /var/lib/lockdown

ZEITPLAN=$(bashio::config zeitplan)
VERSUCHE_BIS=$(bashio::config versuche_bis)
ZIEL=$(bashio::config ziel)
BEHALTEN=$(bashio::config behalten)

# ---------- Status nach HA ----------
status_set() { # $1 zustand, $2 meldung, weitere Felder per jq-Argumente
  local zustand=$1 meldung=$2; shift 2
  local alt='{}'; [ -s "$STATUS" ] && alt=$(cat "$STATUS")
  jq -n --argjson alt "$alt" --arg z "$zustand" --arg m "$meldung" --arg t "$(date -Iseconds)" "$@" \
    '($alt|del(.alt,.z,.m,.t)) + {zustand:$z, meldung:$m, aktualisiert:$t} + ($ARGS.named|del(.alt,.z,.m,.t))' > "$STATUS.neu" && mv "$STATUS.neu" "$STATUS"
  status_push
}
status_push() {
  [ -s "$STATUS" ] || return 0
  jq '{state: .zustand, attributes: (. + {friendly_name:"iPhone-Backup", icon:"mdi:cellphone-arrow-down"})}' "$STATUS" |
    curl -s -o /dev/null -X POST -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
      -H "Content-Type: application/json" -d @- "http://supervisor/core/api/states/${ENTITY}" || true
}

# ---------- rclone ----------
rclone_setup() {
  local token hash
  token=$(bashio::config onedrive_token)
  if [ -z "$token" ]; then bashio::log.warning "Kein OneDrive-Token gesetzt."; return 1; fi
  hash=$(printf '%s' "$token" | sha256sum | cut -c1-16)
  # Konfig nur neu schreiben, wenn sich das Token in den Optionen geändert hat –
  # sonst würde das von rclone erneuerte Token überschrieben.
  if [ ! -s "$RCLONE_CONF" ] || [ "$(cat /data/token.hash 2>/dev/null)" != "$hash" ]; then
    local drive_id drive_type
    drive_id=$(bashio::config onedrive_drive_id)
    drive_type=$(bashio::config onedrive_drive_type)
    if [ -z "$drive_id" ] || [ "$drive_id" = "null" ]; then
      local at; at=$(printf '%s' "$token" | jq -r .access_token)
      drive_id=$(curl -s -H "Authorization: Bearer $at" https://graph.microsoft.com/v1.0/me/drive | jq -r '.id // empty')
      [ -n "$drive_id" ] || { bashio::log.error "Drive-ID nicht ermittelbar (Token abgelaufen? Dann Drive-ID eintragen oder neues Token)."; return 1; }
    fi
    umask 077
    printf '[onedrive]\ntype = onedrive\ntoken = %s\ndrive_id = %s\ndrive_type = %s\n' \
      "$(printf '%s' "$token" | jq -c .)" "$drive_id" "$drive_type" > "$RCLONE_CONF"
    echo "$hash" > /data/token.hash
    bashio::log.info "rclone-Konfiguration erstellt (Drive ${drive_type})."
  fi
}
rc() { rclone --config "$RCLONE_CONF" "$@"; }

# ---------- Gerät finden ----------
DEV=()
geraet_finden() {
  if $PMD usbmux list 2>/dev/null | jq -e 'map(select(.ConnectionType=="USB")) | length > 0' >/dev/null 2>&1; then
    DEV=(); bashio::log.info "iPhone per USB gefunden."; return 0
  fi
  if $PMD lockdown info --mobdev2 >/dev/null 2>&1; then
    DEV=(--mobdev2); bashio::log.info "iPhone per WLAN gefunden."; return 0
  fi
  return 1
}

# ---------- Koppeln (einmalig per USB) ----------
koppeln() {
  bashio::log.info "Koppeln: iPhone muss per USB verbunden und entsperrt sein – auf dem iPhone „Vertrauen“ tippen."
  status_set koppeln "Warte auf „Vertrauen“ am iPhone"
  local i
  for i in $(seq 1 24); do
    if $PMD lockdown pair >/tmp/pair.log 2>&1; then break; fi
    sleep 5
  done
  if ! $PMD lockdown info >/dev/null 2>&1; then
    bashio::log.error "Koppeln fehlgeschlagen: $(tail -3 /tmp/pair.log)"
    status_set fehler "Koppeln fehlgeschlagen"; return 1
  fi
  $PMD lockdown wifi-connections on && bashio::log.info "WLAN-Verbindungen erlaubt."
  local name; name=$($PMD lockdown info 2>/dev/null | jq -r '.DeviceName // "iPhone"')
  bashio::log.info "Gekoppelt mit ${name}."
  status_set bereit "Gekoppelt mit ${name}" --arg geraet "$name"
  verschluesselung_pruefen || true
}

# ---------- Verschlüsselung ----------
verschluesselung_pruefen() {
  local aus
  aus=$($PMD backup2 encryption "${DEV[@]}" 2>&1 | tail -1)
  if echo "$aus" | grep -qiE '\bon\b|true|enabled|aktiv'; then return 0; fi
  local pw; pw=$(bashio::config backup_passwort)
  if [ -z "$pw" ] || [ "$pw" = "null" ]; then
    bashio::log.error "Backup-Verschlüsselung ist aus und kein Backup-Passwort gesetzt – kein Upload."
    return 1
  fi
  bashio::log.info "Schalte Backup-Verschlüsselung ein (iPhone fragt evtl. nach dem Gerätecode)."
  mkdir -p "$STAGING"
  $PMD backup2 encryption "${DEV[@]}" -b "$STAGING" on "$pw" >/tmp/enc.log 2>&1
  aus=$($PMD backup2 encryption "${DEV[@]}" 2>&1 | tail -1)
  echo "$aus" | grep -qiE '\bon\b|true|enabled|aktiv' || { bashio::log.error "Verschlüsselung nicht aktiv: $aus"; return 1; }
}

# ---------- Ziel / Upload ----------
METHODE=ha
OD_ENTRY=""
UPLOAD_DIR=/share/iphone_backup_upload
TEIL_GROESSE=240M   # Integration erlaubt max. 250 MB pro Datei

ha_api() { # methode pfad [json] [timeout]
  curl -s --max-time "${4:-60}" -X "$1" -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" \
    -H "Content-Type: application/json" ${3:+-d "$3"} "http://supervisor/core/api$2"
}
ziel_pruefen() {
  local token; token=$(bashio::config onedrive_token)
  if [ -n "$token" ] && [ "$token" != "null" ]; then METHODE=rclone; rclone_setup; return; fi
  METHODE=ha
  OD_ENTRY=$(ha_api GET "/config/config_entries/entry?domain=onedrive" | jq -r '[.[]|select(.state=="loaded")][0].entry_id // empty')
  [ -n "$OD_ENTRY" ] || { bashio::log.error "Keine geladene OneDrive-Integration in Home Assistant gefunden (oder OneDrive-Token eintragen)."; return 1; }
  mkdir -p "$UPLOAD_DIR"
}
upload_rclone() { # $1 = Basisname
  local datei="$1.tar"
  tar --remove-files -C "$STAGING" -cf "/tmp/$datei" . || return 1
  rc copyto "/tmp/$datei" "onedrive:${ZIEL}/${datei}" --onedrive-chunk-size 50M --retries 5 --low-level-retries 20 > /tmp/upload.log 2>&1 \
    || { bashio::log.error "Upload fehlgeschlagen: $(tail -5 /tmp/upload.log)"; rm -f "/tmp/$datei"; return 1; }
  rm -f "/tmp/$datei"
  rc lsf "onedrive:${ZIEL}" --include "iphone-*.tar" | sort | head -n -"$BEHALTEN" | while read -r alt; do
    rc deletefile "onedrive:${ZIEL}/${alt}" && bashio::log.info "Altes Backup gelöscht: $alt"
  done
}
upload_ha() { # $1 = Basisname → Ordner <ziel>/<basis>/ im App-Ordner der Integration, Teile à 240 MB
  local basis="$1"
  export OD_ENTRY UPLOAD_DIR ORDNER="${ZIEL}/${basis}"
  printf 'iPhone-Backup %s (verschlüsselt, Format Finder/iTunes)\n\nWiederherstellen:\n  cat %s.tar.part* > %s.tar\n  tar -xf %s.tar\n  danach mit Finder/iTunes oder pymobiledevice3 backup2 restore einspielen.\n' \
    "$basis" "$basis" "$basis" "$basis" > "$UPLOAD_DIR/LIESMICH.txt"
  /upload_teil.sh < /dev/null "$UPLOAD_DIR/LIESMICH.txt" || return 1
  tar --remove-files -C "$STAGING" -cf - . \
    | split -b "$TEIL_GROESSE" -d -a 4 --filter='/upload_teil.sh "$FILE"' - "${basis}.tar.part" \
    || { bashio::log.error "Upload abgebrochen."; return 1; }
  echo "$basis" >> /data/uploads.txt
  # Alte Stände löschen
  local anzahl; anzahl=$(wc -l < /data/uploads.txt)
  while [ "$anzahl" -gt "$BEHALTEN" ]; do
    local alt; alt=$(head -1 /data/uploads.txt)
    if ha_api POST /services/onedrive/delete "$(jq -nc --arg e "$OD_ENTRY" --arg p "${ZIEL}/${alt}" '{config_entry_id:$e, destination_path:[$p]}')" 300 >/dev/null; then
      bashio::log.info "Altes Backup gelöscht: $alt"
    else
      bashio::log.warning "Löschen von $alt fehlgeschlagen."
    fi
    sed -i 1d /data/uploads.txt; anzahl=$((anzahl-1))
  done
}

# ---------- Backup ----------
backup() {
  exec 9>"$LOCK"; flock -n 9 || { bashio::log.warning "Backup läuft bereits."; return 2; }
  local start; start=$(date +%s)
  ziel_pruefen || { status_set fehler "OneDrive nicht eingerichtet"; return 1; }
  geraet_finden || { status_set wartet "iPhone nicht erreichbar"; return 3; }
  verschluesselung_pruefen || { status_set fehler "Backup nicht verschlüsselt – nichts hochgeladen"; return 1; }

  rm -rf "$STAGING" /tmp/*.tar; mkdir -p "$STAGING"
  status_set laeuft "Backup vom iPhone läuft"
  bashio::log.info "Backup startet …"
  if ! $PMD backup2 backup "${DEV[@]}" --full "$STAGING" > /tmp/backup.log 2>&1; then
    bashio::log.error "Backup fehlgeschlagen: $(tail -5 /tmp/backup.log)"
    rm -rf "$STAGING"; status_set fehler "Backup vom iPhone fehlgeschlagen"; return 1
  fi
  local udid groesse datei
  udid=$(ls "$STAGING" | head -1)
  groesse=$(du -sb "$STAGING" | cut -f1)
  datei="iphone-${udid:0:8}-$(date +%Y-%m-%d_%H%M)"
  bashio::log.info "Backup fertig ($(numfmt --to=iec "$groesse")), lade nach OneDrive (${METHODE}) …"
  status_set laeuft "Upload nach OneDrive"
  if [ "$METHODE" = rclone ]; then
    upload_rclone "$datei" || { rm -rf "$STAGING" /tmp/*.tar; status_set fehler "Upload nach OneDrive fehlgeschlagen"; return 1; }
  else
    upload_ha "$datei" || { rm -rf "$STAGING" "$UPLOAD_DIR"/*; status_set fehler "Upload nach OneDrive fehlgeschlagen"; return 1; }
  fi
  rm -rf "$STAGING"
  local dauer=$(( ($(date +%s) - start) / 60 ))
  bashio::log.info "Fertig: ${datei} in ${dauer} min."
  status_set ok "Backup hochgeladen" --arg letzter_erfolg "$(date -Iseconds)" --arg datei "$datei" \
    --argjson groesse_bytes "$groesse" --arg groesse "$(numfmt --to=iec "$groesse")" --argjson dauer_min "$dauer"
}

# ---------- Zeitplan ----------
zeitplan_schleife() {
  local erledigt=""
  while true; do
    local jetzt heute; jetzt=$(date +%H:%M); heute=$(date +%F)
    if [ "$erledigt" != "$heute" ] && [[ "$jetzt" > "$ZEITPLAN" || "$jetzt" == "$ZEITPLAN" ]] && [[ "$jetzt" < "$VERSUCHE_BIS" ]]; then
      backup; rc_=$?
      if [ $rc_ -eq 0 ] || [ $rc_ -eq 1 ]; then erledigt=$heute; fi   # 3 = nicht erreichbar → später erneut
      if [ $rc_ -eq 3 ]; then sleep 900; continue; fi
    fi
    if [ "$erledigt" != "$heute" ] && ! [[ "$jetzt" < "$VERSUCHE_BIS" ]] && [ "$(jq -r .zustand "$STATUS" 2>/dev/null)" = "wartet" ]; then
      status_set fehler "iPhone war bis ${VERSUCHE_BIS} nicht erreichbar"; erledigt=$heute
    fi
    sleep 60
  done
}

# ---------- Start ----------
bashio::log.info "iPhone Backup startet (Zeitplan ${ZEITPLAN}, Ziel OneDrive:${ZIEL}, behalten ${BEHALTEN})."
/usr/sbin/usbmuxd -f -U usbmux >/tmp/usbmuxd.log 2>&1 &
sleep 2
ziel_pruefen >/dev/null 2>&1 || true
[ -s "$STATUS" ] && status_push || status_set bereit "Noch kein Backup"

zeitplan_schleife &

while read -r befehl; do
  befehl=$(echo "$befehl" | tr -d '"' | tr '[:upper:]' '[:lower:]' | xargs)
  bashio::log.info "Befehl: ${befehl}"
  case "$befehl" in
    koppeln) koppeln ;;
    backup)  backup ;;
    status)  status_push ;;
    testupload)
      if ziel_pruefen; then
        if [ "$METHODE" = ha ]; then
          export OD_ENTRY UPLOAD_DIR ORDNER="${ZIEL}/test"
          echo "Testdatei $(date -Iseconds)" > "$UPLOAD_DIR/test.txt"
          /upload_teil.sh "$UPLOAD_DIR/test.txt" && bashio::log.info "Testupload ok: ${ZIEL}/test/test.txt im App-Ordner der OneDrive-Integration." \
            || bashio::log.error "Testupload fehlgeschlagen."
        else
          echo "Testdatei" | rc rcat "onedrive:${ZIEL}/test.txt" && bashio::log.info "Testupload (rclone) ok."
        fi
      fi ;;
    *) bashio::log.warning "Unbekannter Befehl: ${befehl} (koppeln|backup|status|testupload)" ;;
  esac
done
wait
