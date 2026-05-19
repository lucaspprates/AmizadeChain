package consensus

import "github.com/lucaspprates/AmizadeChain/internal/blockchain"

type Consensus interface {
	Mine(block blockchain.Block) (blockchain.Block, error)
	Validate(block blockchain.Block) error
}
