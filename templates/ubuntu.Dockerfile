FROM {{ .Image }} AS rootfs

USER root

RUN ARCH="$([ "$(uname -m)" = "x86_64" ] && echo amd64 || echo arm64)"; \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends \
  linux-image-virtual \
  initramfs-tools \
  systemd-sysv \
  systemd \
{{- if .Grub }}
  grub-common \
  grub2-common \
{{- end }}
{{- if .GrubBIOS }}
  grub-pc-bin \
{{- end }}
{{- if .GrubEFI }}
  grub-efi-${ARCH}-bin \
{{- end }}
  dbus \
  isc-dhcp-client \
  iproute2 \
  iputils-ping && \
  find /boot -type l -exec rm {} \;

{{ if gt .Release.VersionID "16.04" }}
RUN systemctl preset-all
{{ end }}

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
RUN if [ -z "$(apt-cache madison ifupdown-ng 2> /dev/nul)" ]; then apt install -y ifupdown; else apt install -y ifupdown-ng; fi
RUN mkdir -p /etc/network && printf '\
auto eth0\n\
allow-hotplug eth0\n\
iface eth0 inet dhcp\n\
' > /etc/network/interfaces
{{ end }}

{{- if .Luks }}
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends cryptsetup-initramfs && \
    update-initramfs -u -v
{{- end }}

{{- if .Bootstrap }}
RUN cat <<'EOF' >/usr/local/sbin/d2vm-bootstrap.sh
#!/bin/bash
set -euo pipefail

MNT=/mnt/d2vm-bootstrap
DISK=/dev/vdb
DONE=/var/lib/d2vm-bootstrap/done

if [ -f "$DONE" ]; then
  exit 0
fi

if [ ! -b "$DISK" ]; then
  exit 0
fi

mkdir -p "$MNT"

cleanup() {
  if mountpoint -q "$MNT"; then
    umount "$MNT" || true
  fi
}
trap cleanup EXIT

if mountpoint -q "$MNT"; then
  umount "$MNT" || true
fi

if ! mount -o ro "$DISK" "$MNT"; then
  exit 0
fi

SCRIPT="$MNT/init.sh"
if [ ! -f "$SCRIPT" ]; then
  exit 0
fi

if /bin/bash "$SCRIPT"; then
  mkdir -p "$(dirname "$DONE")"
  touch "$DONE"
fi
EOF
RUN chmod 0755 /usr/local/sbin/d2vm-bootstrap.sh && \
    cat <<'EOF' >/etc/systemd/system/d2vm-bootstrap.service
[Unit]
Description=D2VM bootstrap loader
After=local-fs.target
ConditionPathExists=/dev/vdb

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/d2vm-bootstrap.sh

[Install]
WantedBy=multi-user.target
EOF
RUN cat <<'EOF' >/etc/systemd/system/d2vm-bootstrap.timer
[Unit]
Description=Run D2VM bootstrap loader

[Timer]
OnBootSec=30s
AccuracySec=30s
Persistent=true
Unit=d2vm-bootstrap.service

[Install]
WantedBy=timers.target
EOF
RUN mkdir -p /etc/systemd/system/timers.target.wants && \
    ln -sf /etc/systemd/system/d2vm-bootstrap.timer /etc/systemd/system/timers.target.wants/d2vm-bootstrap.timer
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
