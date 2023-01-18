#!/usr/bin/env bash
# on debian/ubuntu: apt-get install time

timing() {
  command time -f "[$*] took %E" "$@"
}
