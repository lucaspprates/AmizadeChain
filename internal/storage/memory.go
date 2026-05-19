package storage

import (
	"errors"
	"github.com/lucaspprates/AmizadeChain/internal/blockchain"
	"sort"
	"sync"
)

type MemoryStore struct {
	mu      sync.RWMutex
	blocks  map[uint64]blockchain.Block
	byHash  map[string]uint64
	mempool []blockchain.Transaction
}

func NewMemoryStore() *MemoryStore {
	return &MemoryStore{blocks: map[uint64]blockchain.Block{}, byHash: map[string]uint64{}}
}
func (s *MemoryStore) SaveBlock(b blockchain.Block) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.blocks[b.Header.Height] = b
	s.byHash[b.Hash] = b.Header.Height
	return nil
}
func (s *MemoryStore) GetBlockByHeight(h uint64) (blockchain.Block, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	b, ok := s.blocks[h]
	if !ok {
		return blockchain.Block{}, errors.New("bloco não encontrado")
	}
	return b, nil
}
func (s *MemoryStore) GetBlockByHash(hash string) (blockchain.Block, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	h, ok := s.byHash[hash]
	if !ok {
		return blockchain.Block{}, errors.New("bloco não encontrado")
	}
	return s.blocks[h], nil
}
func (s *MemoryStore) GetLatestBlock() (blockchain.Block, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if len(s.blocks) == 0 {
		return blockchain.Block{}, errors.New("cadeia não inicializada")
	}
	var hs []int
	for h := range s.blocks {
		hs = append(hs, int(h))
	}
	sort.Ints(hs)
	return s.blocks[uint64(hs[len(hs)-1])], nil
}
func (s *MemoryStore) ListBlocks(offset, limit int) ([]blockchain.Block, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var hs []int
	for h := range s.blocks {
		hs = append(hs, int(h))
	}
	sort.Ints(hs)
	if limit <= 0 {
		limit = len(hs)
	}
	var out []blockchain.Block
	for i := offset; i < len(hs) && len(out) < limit; i++ {
		out = append(out, s.blocks[uint64(hs[i])])
	}
	return out, nil
}
func (s *MemoryStore) SaveMempool(txs []blockchain.Transaction) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.mempool = append([]blockchain.Transaction(nil), txs...)
	return nil
}
func (s *MemoryStore) LoadMempool() ([]blockchain.Transaction, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return append([]blockchain.Transaction(nil), s.mempool...), nil
}
