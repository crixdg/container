#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat $SCRIPT_DIR/version.conf)"
helm show values ingress-nginx/ingress-nginx --version $VERSION > __default_values.yml
