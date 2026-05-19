package consensus

import (
	"github.com/lucaspprates/AmizadeChain/internal/blockchain"
	"strings"
	"testing"
)

func TestMineBlockDifficulty(t *testing.T) {
	tx := blockchain.Transaction{ID: "x", Type: blockchain.TxGenesisDeclaration, From: "g", To: "t", Attitude: "a", Weight: 1, Visibility: "public_symbolic", CreatedAt: "2026-05-19T03:00:00Z"}
	b := blockchain.Block{Header: blockchain.BlockHeader{Version: 1, ChainID: "c", NetworkID: "n", Height: 1, Timestamp: "2026-05-19T03:00:00Z", PreviousHash: strings.Repeat("0", 64), Difficulty: 2, Miner: "m"}, Transactions: []blockchain.Transaction{tx}}
	out, err := NewProofOfWork(2).Mine(b)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(out.Hash, "00") {
		t.Fatal(out.Hash)
	}
}
