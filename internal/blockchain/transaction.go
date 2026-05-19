package blockchain

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
)

const (
	TxGenesisDeclaration    = "GENESIS_DECLARATION"
	TxTrueFriendship        = "TRUE_FRIENDSHIP"
	TxGratitude             = "GRATITUDE"
	TxPresence              = "PRESENCE"
	TxLoyalty               = "LOYALTY"
	TxRepair                = "REPAIR"
	TxBoundaryAndLesson     = "BOUNDARY_AND_LESSON"
	TxFalseFriendshipSignal = "FALSE_FRIENDSHIP_SIGNAL"
	TxChainCommitment       = "CHAIN_COMMITMENT"
)

var types = map[string]bool{TxGenesisDeclaration: true, TxTrueFriendship: true, TxGratitude: true, TxPresence: true, TxLoyalty: true, TxRepair: true, TxBoundaryAndLesson: true, TxFalseFriendshipSignal: true, TxChainCommitment: true}
var vis = map[string]bool{"public_symbolic": true, "public_symbolic_no_shame": true, "private_hash": true, "private_local": true}

type Transaction struct {
	ID         string   `json:"id"`
	Index      uint64   `json:"index,omitempty"`
	Type       string   `json:"type"`
	From       string   `json:"from"`
	To         string   `json:"to"`
	Attitude   string   `json:"attitude"`
	Weight     int      `json:"weight"`
	Visibility string   `json:"visibility"`
	Message    string   `json:"message"`
	Tags       []string `json:"tags"`
	CreatedAt  string   `json:"created_at"`
	PublicKey  string   `json:"public_key,omitempty"`
	Signature  string   `json:"signature,omitempty"`
}

func (tx Transaction) signingCopy() Transaction {
	tx.ID = ""
	tx.Signature = ""
	tx.Index = 0
	return tx
}
func (tx Transaction) BytesForSigning() []byte { b, _ := json.Marshal(tx.signingCopy()); return b }
func (tx *Transaction) EnsureDefaults() {
	if tx.CreatedAt == "" {
		tx.CreatedAt = time.Now().UTC().Format(time.RFC3339)
	}
	if tx.Visibility == "" {
		tx.Visibility = "public_symbolic"
	}
	if tx.Tags == nil {
		tx.Tags = []string{}
	}
}
func (tx Transaction) ComputeID() string {
	c := tx
	c.ID = ""
	c.Signature = ""
	b, _ := json.Marshal(c)
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
func (tx *Transaction) FinalizeID() { tx.ID = tx.ComputeID() }
func (tx Transaction) ValidateBasic() error {
	if !types[tx.Type] {
		return errors.New("tipo de transação inválido")
	}
	if tx.Weight < -100 || tx.Weight > 100 {
		return errors.New("peso deve ficar entre -100 e 100")
	}
	if !vis[tx.Visibility] {
		return errors.New("visibilidade inválida")
	}
	if tx.Type == TxFalseFriendshipSignal && !(tx.Visibility == "private_hash" || tx.Visibility == "public_symbolic_no_shame") {
		return errors.New("FALSE_FRIENDSHIP_SIGNAL exige private_hash ou public_symbolic_no_shame")
	}
	if tx.To == "" || tx.Type == "" || tx.Attitude == "" {
		return errors.New("campos obrigatórios ausentes")
	}
	if len(tx.Message) > 2000 {
		return errors.New("mensagem muito longa")
	}
	return nil
}
func (tx Transaction) VerifySignature() error {
	if tx.Type == TxGenesisDeclaration || len(tx.PublicKey) == 0 {
		return nil
	}
	pk, err := hex.DecodeString(tx.PublicKey)
	if err != nil || len(pk) != ed25519.PublicKeySize {
		return errors.New("public_key inválida")
	}
	sig, err := hex.DecodeString(tx.Signature)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return errors.New("assinatura inválida")
	}
	if !ed25519.Verify(ed25519.PublicKey(pk), tx.BytesForSigning(), sig) {
		return errors.New("assinatura não confere")
	}
	return nil
}
func (tx Transaction) Validate() error {
	if err := tx.ValidateBasic(); err != nil {
		return err
	}
	return tx.VerifySignature()
}
