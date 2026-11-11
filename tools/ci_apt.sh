#!/usr/bin/env bash
# apt-get install for GitHub-hosted runners, with a fallback to Ubuntu's main
# mirror when the runner's Azure mirror does not resolve. Seen 2026-11-11:
# every fetch failed with "Temporary failure resolving
# 'azure.archive.ubuntu.com'", failing CI and stalling runtime builds.
#
# Usage: tools/ci_apt.sh <package>...
set -euo pipefail

use_main_mirror() {
    local main=http://archive.ubuntu.com/ubuntu
    case "$(dpkg --print-architecture)" in
        arm64 | armhf) main=http://ports.ubuntu.com/ubuntu-ports ;;
    esac
    local f
    for f in /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list /etc/apt/sources.list; do
        [ -f "$f" ] || continue
        sudo sed -i -E \
            -e "s#mirror\+file:/etc/apt/apt-mirrors\.txt#${main}#g" \
            -e "s#https?://azure\.(archive|ports)\.ubuntu\.com/ubuntu(-ports)?#${main}#g" "$f"
    done
    echo "ci_apt: using ${main}" >&2
}

if ! getent hosts azure.archive.ubuntu.com >/dev/null 2>&1; then
    use_main_mirror
fi

for attempt in 1 2 3; do
    # apt-get update only warns when index files fail; the install fails.
    if sudo apt-get update -qq && sudo apt-get install -y -qq "$@"; then
        exit 0
    fi
    echo "ci_apt: attempt ${attempt} failed" >&2
    if [ "$attempt" = 1 ]; then
        use_main_mirror
    fi
    sleep 15
done
exit 1
