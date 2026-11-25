#!/bin/bash
# Lädt eine Datei über die OneDrive-Integration von Home Assistant hoch.
# Aufruf: upload_teil.sh <datei>  – existiert <datei> nicht, wird stdin dorthin geschrieben (split --filter).
set -o pipefail
datei=$1
case "$datei" in /*) ;; *) datei="$UPLOAD_DIR/$datei"; cat > "$datei" || exit 1 ;; esac
body=$(jq -nc --arg e "$OD_ENTRY" --arg f "$datei" --arg d "$ORDNER" '{config_entry_id:$e, filename:[$f], destination_folder:$d}')
for versuch in 1 2 3 4 5; do
  code=$(curl -s -o /tmp/upload_teil.out -w '%{http_code}' --max-time 1800 -X POST \
    -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" -H "Content-Type: application/json" \
    -d "$body" "http://supervisor/core/api/services/onedrive/upload")
  [ "$code" = 200 ] && break
  echo "Upload $(basename "$datei") Versuch $versuch: HTTP $code $(head -c 300 /tmp/upload_teil.out)" >&2
  sleep $((versuch * 30))
done
rm -f "$datei"
[ "$code" = 200 ] && echo "hochgeladen: $(basename "$datei")" >&2
[ "$code" = 200 ]
