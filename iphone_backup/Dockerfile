ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base-debian:trixie-2026.02.0
FROM ${BUILD_FROM}

ENV LANG=C.UTF-8 HOME=/data/home PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      usbmuxd python3 python3-venv python3-dev build-essential \
      ca-certificates curl jq tar unzip \
 && curl -fsSLo /tmp/rclone.deb https://downloads.rclone.org/v1.68.2/rclone-v1.68.2-linux-amd64.deb \
 && apt-get install -y /tmp/rclone.deb && rm /tmp/rclone.deb \
 && python3 -m venv /opt/pmd3 \
 && /opt/pmd3/bin/pip install --no-cache-dir pymobiledevice3==11.63.1 \
 && apt-get purge -y build-essential python3-dev && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

COPY run.sh /run.sh
RUN chmod +x /run.sh
CMD ["/run.sh"]
