#!/bin/bash
# Build ClaudeKey macOS menubar app
set -e
cd "$(dirname "$0")"
swiftc -O -framework AppKit -framework CoreGraphics -o ClaudeKey ClaudeKey.swift
echo "Built: ./app/ClaudeKey"
echo "Run:   ./app/ClaudeKey &"
