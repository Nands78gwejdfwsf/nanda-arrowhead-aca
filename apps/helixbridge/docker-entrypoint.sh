#!/bin/sh
set -eu

/usr/local/bin/db-check.sh

exec nginx -g 'daemon off;'
