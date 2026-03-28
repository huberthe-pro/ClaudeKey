#!/bin/bash
# Build ClaudeKey Lite (6-button + LED version)
set -e
cd "$(dirname "$0")"
swiftc -O -framework AppKit -framework CoreGraphics -framework AVFoundation -framework Speech -o ClaudeKeyLite ../shared/Shared.swift ClaudeKeyLite.swift
echo "Built: ./app/lite/ClaudeKeyLite"
echo "Run:   ./app/lite/ClaudeKeyLite"
