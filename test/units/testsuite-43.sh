#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -eux
set -o pipefail

systemd-analyze log-level debug

runas() {
    declare userid=$1
    shift
    # shellcheck disable=SC2016
    su "$userid" -s /bin/sh -c 'XDG_RUNTIME_DIR=/run/user/$UID exec "$@"' -- sh "$@"
}

runas testuser systemd-run --wait --user --unit=test-private-users \
    -p PrivateUsers=yes -P echo hello

runas testuser systemctl --user log-level debug

runas testuser systemd-run --wait --user --unit=test-private-tmp-innerfile \
    -p PrivateUsers=yes -p PrivateTmp=yes \
    -P touch /tmp/innerfile.txt
# File should not exist outside the job's tmp directory.
test ! -e /tmp/innerfile.txt

touch /tmp/outerfile.txt
# File should not appear in unit's private tmp.
runas testuser systemd-run --wait --user --unit=test-private-tmp-outerfile \
    -p PrivateUsers=yes -p PrivateTmp=yes \
    -P test ! -e /tmp/outerfile.txt

# Confirm that creating a file in home works
runas testuser systemd-run --wait --user --unit=test-unprotected-home \
    -P touch /home/testuser/works.txt
test -e /home/testuser/works.txt

# Confirm that creating a file in home is blocked under read-only
runas testuser systemd-run --wait --user --unit=test-protect-home-read-only \
    -p PrivateUsers=yes -p ProtectHome=read-only \
    -P bash -c '
        test -e /home/testuser/works.txt || exit 10
        touch /home/testuser/blocked.txt && exit 11
    ' \
        && { echo 'unexpected success'; exit 1; }
test ! -e /home/testuser/blocked.txt

# Check that tmpfs hides the whole directory
runas testuser systemd-run --wait --user --unit=test-protect-home-tmpfs \
    -p PrivateUsers=yes -p ProtectHome=tmpfs \
    -P test ! -e /home/testuser

# Confirm that home, /root, and /run/user are inaccessible under "yes"
# shellcheck disable=SC2016
runas testuser systemd-run --wait --user --unit=test-protect-home-yes \
    -p PrivateUsers=yes -p ProtectHome=yes \
    -P bash -c '
        test "$(stat -c %a /home)" = "0"
        test "$(stat -c %a /root)" = "0"
        test "$(stat -c %a /run/user)" = "0"
    '

# Confirm we cannot change groups because we only have one mapping in the user
# namespace (no CAP_SETGID in the parent namespace to write the additional
# mapping of the user supplied group and thus cannot change groups to an
# unmapped group ID)
runas testuser systemd-run --wait --user --unit=test-group-fail \
    -p PrivateUsers=yes -p Group=daemon \
    -P true \
    && { echo 'unexpected success'; exit 1; }

# Check that with a new user namespace we can bind mount
# files and use a different root directory
runas testuser systemd-run --wait --user --unit=test-bind-mount \
    -p PrivateUsers=yes -p BindPaths=/dev/null:/etc/os-release \
    test ! -s /etc/os-release

runas testuser systemd-run --wait --user --unit=test-read-write \
    -p PrivateUsers=yes -p ReadOnlyPaths=/ \
    -p ReadWritePaths="/var /run /tmp" \
    -p NoExecPaths=/ -p ExecPaths=/usr \
    test ! -w /etc/os-release

runas testuser systemd-run --wait --user --unit=test-caps \
    -p PrivateUsers=yes -p AmbientCapabilities=CAP_SYS_ADMIN \
    -p CapabilityBoundingSet=CAP_SYS_ADMIN \
    test -s /etc/os-release

runas testuser systemd-run --wait --user --unit=test-devices \
    -p PrivateUsers=yes -p PrivateDevices=yes -p PrivateIPC=yes \
    sh -c "ls -1 /dev/ | wc -l | grep -q -F 18"

# Same check as test/test-execute/exec-privatenetwork-yes.service
runas testuser systemd-run --wait --user --unit=test-network \
    -p PrivateUsers=yes -p PrivateNetwork=yes \
    /bin/sh -x -c '! ip link | grep -E "^[0-9]+: " | grep -Ev ": (lo|(erspan|gre|gretap|ip_vti|ip6_vti|ip6gre|ip6tnl|sit|tunl)0@.*):"'

runas testuser systemd-run --wait --user --unit=test-hostname \
    -p PrivateUsers=yes -p ProtectHostname=yes \
    hostnamectl hostname foo \
    && { echo 'unexpected success'; exit 1; }

runas testuser systemd-run --wait --user --unit=test-clock \
    -p PrivateUsers=yes -p ProtectClock=yes \
    timedatectl set-time "2012-10-30 18:17:16" \
    && { echo 'unexpected success'; exit 1; }

runas testuser systemd-run --wait --user --unit=test-kernel-tunable \
    -p PrivateUsers=yes -p ProtectKernelTunables=yes \
    sh -c "echo 0 >/proc/sys/user/max_user_namespaces" \
    && { echo 'unexpected success'; exit 1; }

runas testuser systemd-run --wait --user --unit=test-kernel-mod \
    -p PrivateUsers=yes -p ProtectKernelModules=yes \
    sh -c "modprobe -r overlay && modprobe overlay" \
    && { echo 'unexpected success'; exit 1; }

if sysctl kernel.dmesg_restrict=0; then
    runas testuser systemd-run --wait --user --unit=test-kernel-log \
        -p PrivateUsers=yes -p ProtectKernelLogs=yes -p LogNamespace=yes \
        dmesg \
        && { echo 'unexpected success'; exit 1; }
fi

unsquashfs -no-xattrs -d /tmp/img /usr/share/minimal_0.raw
runas testuser systemd-run --wait --user --unit=test-root-dir \
    -p PrivateUsers=yes -p RootDirectory=/tmp/img \
    grep MARKER=1 /etc/os-release

mkdir /tmp/img_bind
mount --bind /tmp/img /tmp/img_bind
runas testuser systemd-run --wait --user --unit=test-root-dir-bind \
    -p PrivateUsers=yes -p RootDirectory=/tmp/img_bind -p MountFlags=private \
    grep MARKER=1 /etc/os-release
umount /tmp/img_bind

# Unprivileged overlayfs was added to Linux 5.11, so try to detect it first
mkdir -p /tmp/a /tmp/b /tmp/c
if unshare --mount --user --map-root-user mount -t overlay overlay /tmp/c -o lowerdir=/tmp/a:/tmp/b; then
    unsquashfs -no-xattrs -d /tmp/app2 /usr/share/app1.raw
    runas testuser systemd-run --wait --user --unit=test-extension-dir \
        -p PrivateUsers=yes -p ExtensionDirectories=/tmp/app2 \
        -p TemporaryFileSystem=/run -p RootDirectory=/tmp/img \
        -p MountAPIVFS=yes \
        grep PORTABLE_PREFIXES=app1 /usr/lib/extension-release.d/extension-release.app2
fi

systemd-analyze log-level info

echo OK >/testok

exit 0
