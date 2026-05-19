package storage

import (
	"encoding/json"
	"errors"
	"github.com/lucaspprates/AmizadeChain/internal/blockchain"
	"os"
	"path/filepath"
	"sort"
	"sync"
)

type FileStore struct {
	mu      sync.Mutex
	dir     string
	blocks  map[uint64]blockchain.Block
	byHash  map[string]uint64
	mempool []blockchain.Transaction
}
type dump struct {
	Blocks  []blockchain.Block       `json:"blocks"`
	Mempool []blockchain.Transaction `json:"mempool"`
}

func NewFileStore(dir string) (*FileStore, error) {
	s := &FileStore{dir: dir, blocks: map[uint64]blockchain.Block{}, byHash: map[string]uint64{}}
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, err
	}
	_ = s.load()
	return s, nil
}
func (s *FileStore) path() string { return filepath.Join(s.dir, "chain.json") }
func (s *FileStore) load() error {
	b, err := os.ReadFile(s.path())
	if err != nil {
		return nil
	}
	var d dump
	if err := json.Unmarshal(b, &d); err != nil {
		return err
	}
	for _, bl := range d.Blocks {
		s.blocks[bl.Header.Height] = bl
		s.byHash[bl.Hash] = bl.Header.Height
	}
	s.mempool = d.Mempool
	return nil
}
func (s *FileStore) persist() error {
	var hs []int
	for h := range s.blocks {
		hs = append(hs, int(h))
	}
	sort.Ints(hs)
	d := dump{Mempool: s.mempool}
	for _, h := range hs {
		d.Blocks = append(d.Blocks, s.blocks[uint64(h)])
	}
	b, _ := json.MarshalIndent(d, "", "  ")
	return os.WriteFile(s.path(), b, 0600)
}
func (s *FileStore) SaveBlock(b blockchain.Block) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.blocks[b.Header.Height] = b
	s.byHash[b.Hash] = b.Header.Height
	return s.persist()
}
func (s *FileStore) GetBlockByHeight(h uint64) (blockchain.Block, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, ok := s.blocks[h]
	if !ok {
		return blockchain.Block{}, errors.New("bloco não encontrado")
	}
	return b, nil
}
func (s *FileStore) GetBlockByHash(hash string) (blockchain.Block, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	h, ok := s.byHash[hash]
	if !ok {
		return blockchain.Block{}, errors.New("bloco não encontrado")
	}
	return s.blocks[h], nil
}
func (s *FileStore) GetLatestBlock() (blockchain.Block, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
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
func (s *FileStore) ListBlocks(offset, limit int) ([]blockchain.Block, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
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
func (s *FileStore) SaveMempool(txs []blockchain.Transaction) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.mempool = append([]blockchain.Transaction(nil), txs...)
	return s.persist()
}
func (s *FileStore) LoadMempool() ([]blockchain.Transaction, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]blockchain.Transaction(nil), s.mempool...), nil
}
