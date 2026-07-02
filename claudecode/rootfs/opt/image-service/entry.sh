#!/bin/bash
# Claude Terminal Plus overlay entrypoint.
# Starts the image upload wrapper (ingress port 7682), then runs the upstream
# CMD unchanged so the base image's boot logic stays merge-friendly.
set -u

mkdir -p /data/images

node /opt/image-service/server.js &

exec "$@"
