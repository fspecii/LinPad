#!/bin/sh
# Copy guest binaries into /usr/local/bin of the gpu fakefs.
tar -cf - "$@" | timeout 60 /tmp/vgpu.sh /bin/sh -c 'tar -xf - -C /usr/local/bin && ls -la /usr/local/bin | tail -n +4'
