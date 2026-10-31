#!/usr/bin/env bash

set -euo pipefail

# Install Java

JAVA_HOME="$PWD/.java"
mkdir -p "$JAVA_HOME"

curl -fLsS \
  "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jre/hotspot/normal/eclipse" \
  -o /tmp/jre.tar.gz

tar -xzf /tmp/jre.tar.gz -C "$JAVA_HOME" --strip-components=1

export JAVA_HOME
export PATH="$PATH:$JAVA_HOME/bin"

java -version

# Build the Jekyll site

jekyll build
