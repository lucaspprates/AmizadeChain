package blockchain

import (
	"fmt"
	"strings"
	"time"
)

type ValidationReport struct {
	Valid   bool     `json:"valid"`
	Height  uint64   `json:"height"`
	Message string   `json:"message"`
	Errors  []string `json:"errors,omitempty"`
}

func ValidateBlock(b Block, prev *Block) error {
	if b.Hash != HashHeader(b.Header) {
		return fmt.Errorf("hash inválido no bloco %d", b.Header.Height)
	}
	if b.Header.MerkleRoot != MerkleRoot(b.Transactions) {
		return fmt.Errorf("merkle root inválida no bloco %d", b.Header.Height)
	}
	if !b.MeetsDifficulty() {
		return fmt.Errorf("dificuldade PoW não atendida no bloco %d", b.Header.Height)
	}
	if prev != nil {
		if b.Header.Height != prev.Header.Height+1 {
			return fmt.Errorf("altura inválida")
		}
		if b.Header.PreviousHash != prev.Hash {
			return fmt.Errorf("previous_hash inválido")
		}
		if t1, e1 := time.Parse(time.RFC3339, prev.Header.Timestamp); e1 == nil {
			if t2, e2 := time.Parse(time.RFC3339, b.Header.Timestamp); e2 == nil && t2.Before(t1) {
				return fmt.Errorf("timestamp regressivo")
			}
		}
	}
	seen := map[string]bool{}
	for _, tx := range b.Transactions {
		if tx.ID == "" || seen[tx.ID] {
			return fmt.Errorf("tx duplicada/vazia")
		}
		if !strings.HasPrefix(tx.From, "genesis/") && tx.ID != tx.ComputeID() {
			return fmt.Errorf("tx %s adulterada: id não confere com conteúdo", tx.ID)
		}
		seen[tx.ID] = true
		if err := tx.Validate(); err != nil {
			return fmt.Errorf("tx %s inválida: %w", tx.ID, err)
		}
	}
	return nil
}
func ValidateChain(blocks []Block) ValidationReport {
	if len(blocks) == 0 {
		return ValidationReport{Valid: false, Message: "cadeia vazia"}
	}
	global := map[string]bool{}
	var errs []string
	for i := range blocks {
		var prev *Block
		if i > 0 {
			prev = &blocks[i-1]
		}
		if err := ValidateBlock(blocks[i], prev); err != nil {
			errs = append(errs, err.Error())
		}
		for _, tx := range blocks[i].Transactions {
			if global[tx.ID] {
				errs = append(errs, "transação duplicada na cadeia: "+tx.ID)
			}
			global[tx.ID] = true
		}
	}
	ok := len(errs) == 0
	msg := "A cadeia está íntegra. O livro-razão permanece coerente."
	if !ok {
		msg = "A cadeia tem inconsistências."
	}
	return ValidationReport{Valid: ok, Height: blocks[len(blocks)-1].Header.Height, Message: msg, Errors: errs}
}
