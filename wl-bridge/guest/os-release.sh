#!/bin/sh
# Rebrands /etc/os-release as Linux for iPad, keeping Alpine's version fields.
# /etc/alpine-release stays as it is, for apk and scripts that check it.
# usage: os-release.sh /etc/os-release (Alpine's is a symlink into /usr/lib)
file=$(readlink -f "$1")
[ -r "$file" ] || exit 0
grep -q '^ID=linuxforipad' "$file" && exit 0
version=$(sed -n 's/^VERSION_ID=//p' "$file" | tr -d '"')
series=$(echo "$version" | cut -d. -f1,2)
{
    echo 'NAME="Linux for iPad"'
    echo "VERSION_ID=$version"
    echo "PRETTY_NAME=\"Linux for iPad (Alpine ${series:-$version} base)\""
    echo 'ID=linuxforipad'
    echo 'ID_LIKE=alpine'
    echo 'HOME_URL="https://ish.app/"'
    echo 'BUG_REPORT_URL="https://github.com/ish-app/ish/issues"'
} > "$file.new" && mv "$file.new" "$file"
