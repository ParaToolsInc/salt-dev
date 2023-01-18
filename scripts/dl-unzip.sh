#!/usr/bin/env bash

set -euo pipefail
# shellcheck source=timing.sh
. "${BASH_SOURCE%/*}/timing.sh"

main() {
    if (( $# <= 0 || $# > 2 )); then
        >&2 echo "Incorrect number of arguments passed to $0"
        >&2 echo "Usage: $0 <url> <optional-sha256-checksum>"
        exit 1
    fi
    local fetch_url="$1"
    local filename="${fetch_url##*/}"
    shift
    if (( $# >= 1 )); then
        local checksum="$1"
        local havechecksum=true
    fi

    echo "Fetch URL: $fetch_url"
    echo "File: $filename"
    [[ "${havechecksum:-}" ]] && echo "Checksum: $checksum"

    echo "verbose=off" > ~/.wgetrc
    timing wget --no-verbose "${fetch_url}"
    if [[ ${havechecksum:-} ]]; then
        echo "${checksum} ${filename}" | sha256sum -c
    fi
    echo "File extension is: ${filename#*.}"
    case "${filename#*.}" in
        zip)
            timing unzip "${filename}" && rm "${filename}"
            ;;
        tar|tgz|tar.gz)
            timing tar xzvf "${filename}" && rm "${filename}"
            ;;
        *)
            echo "$filename does not appear to need unzipping/extracting."
    esac
}

main "$@"
