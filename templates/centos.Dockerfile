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

{{- if not .Grub }}
RUN cd /boot && \
        mv $(find / -name 'vmlinuz*') /boot/vmlinuz && \
        mv $(find . -name 'initramfs-*.img' -o -name initrd) /boot/initrd.img
{{- end }}

RUN yum clean all && \
    rm -rf /var/cache/yum

FROM scratch

COPY --from=rootfs / /
