#!/bin/bash

if helm repo list | grep -q '^cilium'; then
	echo "Cilium Helm repo already added, skipping."
else
	helm repo add cilium https://helm.cilium.io/
	helm repo update
fi
