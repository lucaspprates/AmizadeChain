package storage

import (
	"github.com/lucaspprates/AmizadeChain/internal/blockchain"
	"testing"
)

func TestFileStoreReload(t *testing.T) {
	dir := t.TempDir()
	st, err := NewFileStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	b := blockchain.Block{Header: blockchain.BlockHeader{Version: 1, ChainID: "c", NetworkID: "n", Height: 0, Timestamp: "2026-05-19T03:00:00Z", Difficulty: 0}, Transactions: nil}
	b.Recalculate()
	if err := st.SaveBlock(b); err != nil {
		t.Fatal(err)
	}
	st2, err := NewFileStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	got, err := st2.GetLatestBlock()
	if err != nil {
		t.Fatal(err)
	}
	if got.Hash != b.Hash {
		t.Fatal("reload falhou")
	}
}
