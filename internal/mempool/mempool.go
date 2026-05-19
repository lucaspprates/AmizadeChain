package mempool

import (
	"errors"
	"github.com/lucaspprates/AmizadeChain/internal/blockchain"
	"sync"
)

type Mempool struct {
	mu  sync.Mutex
	max int
	txs []blockchain.Transaction
	ids map[string]bool
}

func New(max int) *Mempool {
	if max <= 0 {
		max = 1000
	}
	return &Mempool{max: max, ids: map[string]bool{}}
}
func From(txs []blockchain.Transaction, max int) *Mempool {
	m := New(max)
	for _, tx := range txs {
		_ = m.Add(tx)
	}
	return m
}
func (m *Mempool) Add(tx blockchain.Transaction) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	tx.EnsureDefaults()
	if tx.ID == "" {
		tx.FinalizeID()
	}
	if err := tx.Validate(); err != nil {
		return err
	}
	if m.ids[tx.ID] {
		return errors.New("transação duplicada")
	}
	if len(m.txs) >= m.max {
		return errors.New("mempool cheia")
	}
	m.txs = append(m.txs, tx)
	m.ids[tx.ID] = true
	return nil
}
func (m *Mempool) List() []blockchain.Transaction {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]blockchain.Transaction(nil), m.txs...)
}
func (m *Mempool) Drain(limit int) []blockchain.Transaction {
	m.mu.Lock()
	defer m.mu.Unlock()
	if limit <= 0 || limit > len(m.txs) {
		limit = len(m.txs)
	}
	out := append([]blockchain.Transaction(nil), m.txs[:limit]...)
	m.txs = m.txs[limit:]
	m.ids = map[string]bool{}
	for _, tx := range m.txs {
		m.ids[tx.ID] = true
	}
	return out
}
