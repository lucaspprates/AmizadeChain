package storage

import "github.com/lucaspprates/AmizadeChain/internal/blockchain"

type BlockStore interface {
	SaveBlock(block blockchain.Block) error
	GetBlockByHeight(height uint64) (blockchain.Block, error)
	GetBlockByHash(hash string) (blockchain.Block, error)
	GetLatestBlock() (blockchain.Block, error)
	ListBlocks(offset, limit int) ([]blockchain.Block, error)
}
type MempoolStore interface {
	SaveMempool([]blockchain.Transaction) error
	LoadMempool() ([]blockchain.Transaction, error)
}
