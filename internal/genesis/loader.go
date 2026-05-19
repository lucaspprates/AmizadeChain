package genesis

import (
	"encoding/json"
	"fmt"
	"github.com/lucaspprates/AmizadeChain/internal/blockchain"
	"os"
)

type File struct {
	SchemaVersion string `json:"schema_version"`
	Project       string `json:"project"`
	Subtitle      string `json:"subtitle"`
	Purpose       string `json:"purpose"`
	Network       struct {
		ChainID   string `json:"chain_id"`
		NetworkID string `json:"network_id"`
	} `json:"network"`
	GenesisPoem []string         `json:"genesis_poem"`
	Principles  []string         `json:"principles"`
	Block       blockchain.Block `json:"block"`
}

func Load(path string) (File, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return File{}, err
	}
	var f File
	if err := json.Unmarshal(b, &f); err != nil {
		return File{}, err
	}
	return f, nil
}
func LoadAndValidate(path string) (File, error) {
	f, err := Load(path)
	if err != nil {
		return f, err
	}
	if f.Block.Header.Height != 0 {
		return f, fmt.Errorf("genesis deve ter altura 0")
	}
	calcMerkle := blockchain.MerkleRoot(f.Block.Transactions)
	if calcMerkle != f.Block.Header.MerkleRoot {
		return f, fmt.Errorf("merkle do genesis inválida: esperado %s calculado %s", f.Block.Header.MerkleRoot, calcMerkle)
	}
	calcHash := blockchain.HashHeader(f.Block.Header)
	if calcHash != f.Block.Hash {
		return f, fmt.Errorf("hash do genesis inválido: esperado %s calculado %s", f.Block.Hash, calcHash)
	}
	if err := blockchain.ValidateBlock(f.Block, nil); err != nil {
		return f, err
	}
	return f, nil
}
