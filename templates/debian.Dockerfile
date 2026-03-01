FROM {{ .Image }} AS rootfs

USER root

{{- if eq .Release.VersionID "9" }}
RUN echo "deb http://archive.debian.org/debian stretch main" > /etc/apt/sources.list && \
    echo "deb-src http://archive.debian.org/debian stretch main" >> /etc/apt/sources.list && \
    echo "deb http://archive.debian.org/debian stretch-backports main" >> /etc/apt/sources.list && \
    echo "deb http://archive.debian.org/debian-security stretch/updates main" >> /etc/apt/sources.list && \
    echo "deb-src http://archive.debian.org/debian-security stretch/updates main" >> /etc/apt/sources.list
{{- end }}

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends \
      linux-image-amd64 && \
      find /boot -type l -exec rm {} \;

RUN ARCH="$([ "$(uname -m)" = "x86_64" ] && echo amd64 || echo arm64)"; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd-sysv \
      systemd \
      dbus \
      iproute2 \
      isc-dhcp-client \
      iputils-ping

{{- if .Grub }}
RUN DEBIAN_FRONTEND=noninteractive apt install -y grub-common grub2-common
{{- end }}
{{- if .GrubBIOS }}
RUN DEBIAN_FRONTEND=noninteractive apt install -y grub-pc-bin
{{- end }}
{{- if .GrubEFI }}
RUN ARCH="$([ "$(uname -m)" = "x86_64" ] && echo amd64 || echo arm64)"; \
    DEBIAN_FRONTEND=noninteractive apt install -y grub-efi-${ARCH}-bin
{{- end }}

RUN systemctl preset-all

{{ if .Password }}RUN echo "root:{{ .Password }}" | chpasswd {{ end }}

{{ if eq .NetworkManager "netplan" }}
RUN apt install -y netplan.io
RUN mkdir -p /etc/netplan && printf '\
network:\n\
  version: 2\n\
  renderer: networkd\n\
  ethernets:\n\
    eth0:\n\
      dhcp4: true\n\
      dhcp-identifier: mac\n\
      nameservers:\n\
        addresses:\n\
        - 8.8.8.8\n\
        - 8.8.4.4\n\
' > /etc/netplan/00-netcfg.yaml
{{ else if eq .NetworkManager "ifupdown"}}
RUN if [ -z "$(apt-cache madison ifupdown2 2> /dev/nul)" ]; then apt install -y ifupdown; else apt install -y ifupdown2; fi
RUN mkdir -p /etc/network && printf '\
auto eth0\n\
allow-hotplug eth0\n\
iface eth0 inet dhcp\n\
' > /etc/network/interfaces
{{ end }}


{{- if .Luks }}
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cryptsetup-initramfs && \
    echo "CRYPTSETUP=y" >> /etc/cryptsetup-initramfs/conf-hook && \
    update-initramfs -u -v
{{- end }}

{{- if .Bootstrap }}
RUN printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    '' \
    'MNT=/mnt/d2vm-bootstrap' \
    'DISK=/dev/vdb' \
    'DONE=/var/lib/d2vm-bootstrap/done' \
    'TRACE_LOG=/var/log/d2vm-bootstrap.trace.log' \
    '' \
    'mkdir -p /var/log' \
    'touch "$TRACE_LOG"' \
    'chmod 0644 "$TRACE_LOG"' \
    'SERIAL_DEV=""' \
    'for dev in /dev/ttyAMA0 /dev/ttyS0 /dev/console; do' \
    '  if [ -c "$dev" ]; then' \
    '    SERIAL_DEV="$dev"' \
    '    break' \
    '  fi' \
    'done' \
    'if [ -n "$SERIAL_DEV" ]; then' \
    '  exec > >(tee -a "$TRACE_LOG" "$SERIAL_DEV") 2>&1' \
    'else' \
    '  exec >>"$TRACE_LOG" 2>&1' \
    'fi' \
    'echo "d2vm-bootstrap: $(date -Iseconds) begin disk=$DISK mnt=$MNT"' \
    '' \
    'if [ -f "$DONE" ]; then' \
    '  echo "d2vm-bootstrap: already completed marker=$DONE"' \
    '  exit 0' \
    'fi' \
    '' \
    'if [ ! -b "$DISK" ]; then' \
    '  echo "d2vm-bootstrap: missing bootstrap disk $DISK" >&2' \
    '  exit 40' \
    'fi' \
    '' \
    'mkdir -p "$MNT"' \
    '' \
    'cleanup() {' \
    '  if mountpoint -q "$MNT"; then' \
    '    umount "$MNT" || true' \
    '  fi' \
    '}' \
    'trap cleanup EXIT' \
    '' \
    'if mountpoint -q "$MNT"; then' \
    '  umount "$MNT" || true' \
    'fi' \
    '' \
    'if ! mount -o ro "$DISK" "$MNT"; then' \
    '  echo "d2vm-bootstrap: failed to mount $DISK at $MNT" >&2' \
    '  ls -la "$MNT" >&2 || true' \
    '  exit 41' \
    'fi' \
    '' \
    'SCRIPT=""' \
    'if [ -f "$MNT/init.sh" ]; then' \
    '  SCRIPT="$MNT/init.sh"' \
    'elif [ -f "$MNT/INIT.SH" ]; then' \
    '  SCRIPT="$MNT/INIT.SH"' \
    'fi' \
    '' \
    'if [ -z "$SCRIPT" ]; then' \
    '  echo "d2vm-bootstrap: missing init script (expected $MNT/init.sh or $MNT/INIT.SH)" >&2' \
    '  ls -la "$MNT" >&2 || true' \
    '  exit 42' \
    'fi' \
    '' \
    'if /bin/bash "$SCRIPT"; then' \
    '  mkdir -p "$(dirname "$DONE")"' \
    '  touch "$DONE"' \
    '  echo "d2vm-bootstrap: init script completed marker written"' \
    'else' \
    '  rc=$?' \
    '  echo "d2vm-bootstrap: init script failed with exit code $rc ($SCRIPT)" >&2' \
    '  exit 43' \
    'fi' \
    > /usr/local/sbin/d2vm-bootstrap.sh
RUN chmod 0755 /usr/local/sbin/d2vm-bootstrap.sh
RUN printf '%s\n' \
    '[Unit]' \
    'Description=D2VM bootstrap loader' \
    'After=local-fs.target' \
    'ConditionPathExists=/dev/vdb' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    'ExecStart=/usr/local/sbin/d2vm-bootstrap.sh' \
    'StandardOutput=journal+console' \
    'StandardError=journal+console' \
    '' \
    '[Install]' \
    'WantedBy=multi-user.target' \
    > /etc/systemd/system/d2vm-bootstrap.service
RUN printf '%s\n' \
    '[Unit]' \
    'Description=Run D2VM bootstrap loader' \
    '' \
    '[Timer]' \
    'OnBootSec=30s' \
    'AccuracySec=30s' \
    'Persistent=true' \
    'Unit=d2vm-bootstrap.service' \
    '' \
    '[Install]' \
    'WantedBy=timers.target' \
    > /etc/systemd/system/d2vm-bootstrap.timer
RUN mkdir -p /etc/systemd/system/timers.target.wants /etc/systemd/system/multi-user.target.wants && \
    ln -sf /etc/systemd/system/d2vm-bootstrap.timer /etc/systemd/system/timers.target.wants/d2vm-bootstrap.timer && \
    ln -sf /etc/systemd/system/d2vm-bootstrap.service /etc/systemd/system/multi-user.target.wants/d2vm-bootstrap.service
{{- end }}

# needs to be after update-initramfs
{{- if not .Grub }}
RUN mv $(ls -t /boot/vmlinuz-* | head -n 1) /boot/vmlinuz && \
      mv $(ls -t /boot/initrd.img-* | head -n 1) /boot/initrd.img
{{- end }}

RUN apt-get clean && \
    rm -rf /var/lib/apt/lists/*

FROM scratch

COPY --from=rootfs / /
