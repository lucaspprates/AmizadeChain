package identity

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"github.com/lucaspprates/AmizadeChain/internal/blockchain"
	"os"
	"path/filepath"
)

type Identity struct {
	Name       string `json:"name"`
	PublicKey  string `json:"public_key"`
	PrivateKey string `json:"private_key"`
}

func New(name string) (Identity, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return Identity{}, err
	}
	return Identity{Name: name, PublicKey: hex.EncodeToString(pub), PrivateKey: hex.EncodeToString(priv)}, nil
}
func Save(dir string, id Identity) error {
	p := filepath.Join(dir, "identities")
	if err := os.MkdirAll(p, 0700); err != nil {
		return err
	}
	b, _ := json.MarshalIndent(id, "", "  ")
	return os.WriteFile(filepath.Join(p, id.Name+".json"), b, 0600)
}
func Load(dir, name string) (Identity, error) {
	b, err := os.ReadFile(filepath.Join(dir, "identities", name+".json"))
	if err != nil {
		return Identity{}, err
	}
	var id Identity
	err = json.Unmarshal(b, &id)
	return id, err
}
func (id Identity) Sign(tx *blockchain.Transaction) error {
	priv, err := hex.DecodeString(id.PrivateKey)
	if err != nil {
		return err
	}
	tx.From = id.Name
	tx.PublicKey = id.PublicKey
	tx.Signature = hex.EncodeToString(ed25519.Sign(ed25519.PrivateKey(priv), tx.BytesForSigning()))
	tx.FinalizeID()
	return nil
}
