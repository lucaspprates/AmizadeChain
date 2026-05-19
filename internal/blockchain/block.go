package blockchain

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"time"
)

type BlockHeader struct {
	Version      uint32 `json:"version"`
	ChainID      string `json:"chain_id"`
	NetworkID    string `json:"network_id"`
	Height       uint64 `json:"height"`
	Timestamp    string `json:"timestamp"`
	PreviousHash string `json:"previous_hash"`
	MerkleRoot   string `json:"merkle_root"`
	Difficulty   uint8  `json:"difficulty"`
	Nonce        uint64 `json:"nonce"`
	Miner        string `json:"miner"`
}
type Block struct {
	Header       BlockHeader   `json:"header"`
	Transactions []Transaction `json:"transactions"`
	Hash         string        `json:"hash"`
}

func HashHeader(h BlockHeader) string {
	canonical := map[string]any{"chain_id": h.ChainID, "difficulty": h.Difficulty, "height": h.Height, "merkle_root": h.MerkleRoot, "miner": h.Miner, "network_id": h.NetworkID, "nonce": h.Nonce, "previous_hash": h.PreviousHash, "timestamp": h.Timestamp, "version": h.Version}
	b, _ := json.Marshal(canonical)
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}
func (b *Block) Recalculate() {
	b.Header.MerkleRoot = MerkleRoot(b.Transactions)
	b.Hash = HashHeader(b.Header)
}
func (b Block) MeetsDifficulty() bool {
	return strings.HasPrefix(b.Hash, strings.Repeat("0", int(b.Header.Difficulty)))
}
func NewBlock(prev Block, txs []Transaction, diff uint8, miner string) Block {
	for i := range txs {
		txs[i].Index = uint64(i)
	}
	return Block{Header: BlockHeader{Version: 1, ChainID: prev.Header.ChainID, NetworkID: prev.Header.NetworkID, Height: prev.Header.Height + 1, Timestamp: time.Now().UTC().Format(time.RFC3339), PreviousHash: prev.Hash, Difficulty: diff, Miner: miner}, Transactions: txs}
}
