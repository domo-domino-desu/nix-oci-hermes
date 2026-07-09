#!/bin/sh
exec 2>&1
export HOME=/root
. /etc/profile.d/proxy.sh
unset NIX_REMOTE
exec nix-daemon --daemon
