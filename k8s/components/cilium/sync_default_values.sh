#!/bin/bash

VERSION="1.19.3"
helm show values cilium/cilium --version $VERSION > __default_values.yaml
