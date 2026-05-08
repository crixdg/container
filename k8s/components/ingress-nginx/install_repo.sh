#!/bin/bash

if helm repo list | grep -q '^ingress-nginx'; then
	echo "ingress-nginx Helm repo already added, skipping."
else
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm repo update
fi
