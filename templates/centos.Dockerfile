FROM {{ .Image }} AS rootfs

USER root

{{ if and (eq .Release.ID "centos") (le (atoi .Release.VersionID) 8) }}
RUN sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-* && \
    sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
{{ end }}

# See https://bugzilla.redhat.com/show_bug.cgi?id=1917213
RUN yum install -y \
    kernel \
    systemd \
    NetworkManager \
    e2fsprogs \
    sudo && \
    systemctl enable NetworkManager && \
    systemctl unmask systemd-remount-fs.service && \
    systemctl unmask getty.target && \
    mkdir -p /boot && \
    find /boot -type l -exec rm {} \;

{{- if .GrubBIOS }}
RUN yum install -y grub2
{{- end }}
{{- if .GrubEFI }}
RUN yum install -y grub2 grub2-efi-x64 grub2-efi-x64-modules
{{- end }}

{{ if .Luks }}
RUN yum install -y cryptsetup && \
    dracut --no-hostonly --regenerate-all --force --install="/usr/sbin/cryptsetup"
{{ else }}
RUN dracut --no-hostonly --regenerate-all --force
{{ end }}

{{ if .Password }}RUN echo "root:{{ .Password }}" | chpasswd {{ end }}

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

{{- if not .Grub }}
RUN cd /boot && \
        mv $(find / -name 'vmlinuz*') /boot/vmlinuz && \
        mv $(find . -name 'initramfs-*.img' -o -name initrd) /boot/initrd.img
{{- end }}

RUN yum clean all && \
    rm -rf /var/cache/yum

FROM scratch

COPY --from=rootfs / /
