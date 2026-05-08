#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat $SCRIPT_DIR/version.conf)"
helm show values cilium/cilium --version $VERSION > __default_values.yaml
