#!/usr/bin/env bash
set -euo pipefail
go run ./cmd/amizadecli init --genesis ./genesis.json --data-dir ./data
go run ./cmd/amizadechaind --http 127.0.0.1:8080 --data-dir ./data
