package blockchain

import (
	"crypto/sha256"
	"encoding/hex"
)

func MerkleRoot(txs []Transaction) string {
	if len(txs) == 0 {
		h := sha256.Sum256([]byte{})
		return hex.EncodeToString(h[:])
	}
	level := make([]string, len(txs))
	for i, t := range txs {
		level[i] = t.ID
		if level[i] == "" {
			level[i] = t.ComputeID()
		}
	}
	for len(level) > 1 {
		var next []string
		for i := 0; i < len(level); i += 2 {
			a := level[i]
			b := a
			if i+1 < len(level) {
				b = level[i+1]
			}
			h := sha256.Sum256([]byte(a + b))
			next = append(next, hex.EncodeToString(h[:]))
		}
		level = next
	}
	return level[0]
}
