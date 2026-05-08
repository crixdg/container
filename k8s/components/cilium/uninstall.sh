#!/bin/bash
set -e

helm uninstall cilium -n cni-system
