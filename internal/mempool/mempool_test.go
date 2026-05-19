package mempool

import (
	"github.com/lucaspprates/AmizadeChain/internal/blockchain"
	"testing"
)

func TestRejectDuplicateTransaction(t *testing.T) {
	m := New(10)
	tx := blockchain.Transaction{ID: "x", Type: blockchain.TxTrueFriendship, From: "a", To: "b", Attitude: "a", Weight: 1, Visibility: "public_symbolic", CreatedAt: "2026-05-19T03:00:00Z"}
	if err := m.Add(tx); err != nil {
		t.Fatal(err)
	}
	if err := m.Add(tx); err == nil {
		t.Fatal("deveria rejeitar duplicada")
	}
}
