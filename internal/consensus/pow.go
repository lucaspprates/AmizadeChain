package consensus

import (
	"context"
	"errors"
	"github.com/lucaspprates/AmizadeChain/internal/blockchain"
)

type ProofOfWorkConsensus struct {
	Difficulty uint8
	MaxNonce   uint64
}

func NewProofOfWork(d uint8) *ProofOfWorkConsensus {
	return &ProofOfWorkConsensus{Difficulty: d, MaxNonce: 0}
}
func (p *ProofOfWorkConsensus) Mine(block blockchain.Block) (blockchain.Block, error) {
	return p.MineContext(context.Background(), block)
}
func (p *ProofOfWorkConsensus) MineContext(ctx context.Context, block blockchain.Block) (blockchain.Block, error) {
	block.Header.Difficulty = p.Difficulty
	block.Header.MerkleRoot = blockchain.MerkleRoot(block.Transactions)
	for {
		select {
		case <-ctx.Done():
			return block, ctx.Err()
		default:
			block.Hash = blockchain.HashHeader(block.Header)
			if block.MeetsDifficulty() {
				return block, nil
			}
			block.Header.Nonce++
			if p.MaxNonce > 0 && block.Header.Nonce > p.MaxNonce {
				return block, errors.New("nonce máximo atingido")
			}
		}
	}
}
func (p *ProofOfWorkConsensus) Validate(block blockchain.Block) error {
	if !block.MeetsDifficulty() {
		return errors.New("hash não atende dificuldade")
	}
	return nil
}
