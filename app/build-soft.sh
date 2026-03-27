#!/bin/bash
# Build ClaudeKey Soft (pure software version)
set -e
cd "$(dirname "$0")"
swiftc -O -framework AppKit -framework CoreGraphics -framework AVFoundation -framework Speech -o ClaudeKeySoft ClaudeKeySoft.swift
echo "Built: ./app/ClaudeKeySoft"
echo "Run:   ./app/ClaudeKeySoft"
