#!/bin/bash
# Build ClaudeKey Pro (TFT display + encoder + extra keys)
set -e
cd "$(dirname "$0")"
swiftc -O -framework AppKit -framework CoreGraphics -framework AVFoundation -framework Speech -o ClaudeKeyPro ClaudeKeyPro.swift
echo "Built: ./app/pro/ClaudeKeyPro"
echo "Run:   ./app/pro/ClaudeKeyPro"
