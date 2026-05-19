#!/usr/bin/env bash
set -euo pipefail
go run ./cmd/amizadecli init --genesis ./genesis.json --data-dir ./data
go run ./cmd/amizadecli identity new --name lucao --data-dir ./data
go run ./cmd/amizadecli tx add --data-dir ./data --signer lucao --type TRUE_FRIENDSHIP --to amigo --attitude presenca --weight 90 --message "Esteve presente."
go run ./cmd/amizadecli mine --data-dir ./data --miner lucao
go run ./cmd/amizadecli validate --data-dir ./data
