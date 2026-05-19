package service

import (
	"encoding/json"
	"github.com/lucaspprates/AmizadeChain/internal/blockchain"
	"github.com/lucaspprates/AmizadeChain/internal/consensus"
	"github.com/lucaspprates/AmizadeChain/internal/genesis"
	"github.com/lucaspprates/AmizadeChain/internal/mempool"
	"github.com/lucaspprates/AmizadeChain/internal/storage"
	"os"
	"path/filepath"
)

type Node struct {
	Store      storage.BlockStore
	MP         *mempool.Mempool
	MPStore    storage.MempoolStore
	Difficulty uint8
	MaxTx      int
	Genesis    *genesis.File
}

func New(store storage.BlockStore, mpstore storage.MempoolStore, difficulty uint8, maxTx int) *Node {
	txs, _ := mpstore.LoadMempool()
	return &Node{Store: store, MP: mempool.From(txs, 1000), MPStore: mpstore, Difficulty: difficulty, MaxTx: maxTx}
}
func Init(dataDir, genesisPath string) (*Node, error) {
	fs, err := storage.NewFileStore(dataDir)
	if err != nil {
		return nil, err
	}
	g, err := genesis.LoadAndValidate(genesisPath)
	if err != nil {
		return nil, err
	}
	if _, err := fs.GetLatestBlock(); err == nil {
		return New(fs, fs, g.Block.Header.Difficulty, 100), nil
	}
	if err := fs.SaveBlock(g.Block); err != nil {
		return nil, err
	}
	os.WriteFile(filepath.Join(dataDir, "genesis.path"), []byte(genesisPath), 0600)
	n := New(fs, fs, g.Block.Header.Difficulty, 100)
	n.Genesis = &g
	return n, nil
}
func Open(dataDir string, difficulty uint8, maxTx int) (*Node, error) {
	fs, err := storage.NewFileStore(dataDir)
	if err != nil {
		return nil, err
	}
	return New(fs, fs, difficulty, maxTx), nil
}
func (n *Node) AddTransaction(tx blockchain.Transaction) error {
	tx.EnsureDefaults()
	if tx.ID == "" {
		tx.FinalizeID()
	}
	if err := n.MP.Add(tx); err != nil {
		return err
	}
	return n.MPStore.SaveMempool(n.MP.List())
}
func (n *Node) Mine(miner string) (blockchain.Block, error) {
	prev, err := n.Store.GetLatestBlock()
	if err != nil {
		return blockchain.Block{}, err
	}
	txs := n.MP.Drain(n.MaxTx)
	b := blockchain.NewBlock(prev, txs, n.Difficulty, miner)
	b, err = consensus.NewProofOfWork(n.Difficulty).Mine(b)
	if err != nil {
		return b, err
	}
	if err := n.Store.SaveBlock(b); err != nil {
		return b, err
	}
	_ = n.MPStore.SaveMempool(n.MP.List())
	return b, nil
}
func (n *Node) Blocks() []blockchain.Block            { bs, _ := n.Store.ListBlocks(0, 0); return bs }
func (n *Node) Validate() blockchain.ValidationReport { return blockchain.ValidateChain(n.Blocks()) }
func (n *Node) Export(path string) error {
	b, _ := json.MarshalIndent(map[string]any{"blocks": n.Blocks(), "validation": n.Validate()}, "", "  ")
	return os.WriteFile(path, b, 0644)
}
