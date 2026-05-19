package blockchain

import (
	"strings"
	"testing"
)

func sampleTx() Transaction {
	tx := Transaction{Type: TxTrueFriendship, From: "a", To: "b", Attitude: "presenca", Weight: 10, Visibility: "public_symbolic", Message: "ok", CreatedAt: "2026-05-19T03:00:00Z", Tags: []string{"t"}}
	tx.FinalizeID()
	return tx
}

func TestHashBlockHeader(t *testing.T) {
	h := BlockHeader{Version: 1, ChainID: "amizadechain-local-v1", NetworkID: "amizade-local", Height: 0, Timestamp: "2026-05-19T03:00:00Z", PreviousHash: "0000000000000000000000000000000000000000000000000000000000000000", MerkleRoot: "ecffd77e454d7cba8b729ef61f5151a297ae69ff9bba346ca35eb708384234e6", Difficulty: 3, Nonce: 7795, Miner: "genesis/amizadechain"}
	got := HashHeader(h)
	want := "000c65374b8ff01ec664f5a0a1e6bfdd889a49903eb02dd43786a6f604e6a582"
	if got != want {
		t.Fatalf("hash got %s want %s", got, want)
	}
}
func TestTransactionIDDeterministic(t *testing.T) {
	a := sampleTx()
	b := sampleTx()
	if a.ID != b.ID {
		t.Fatal("id deve ser determinístico")
	}
}
func TestMerkleRoot(t *testing.T) {
	tx := sampleTx()
	if MerkleRoot([]Transaction{tx}) != tx.ID {
		t.Fatal("merkle de uma tx deve ser o id")
	}
	if MerkleRoot([]Transaction{tx, tx}) == "" {
		t.Fatal("merkle vazia")
	}
}
func TestRejectInvalidTransactionWeight(t *testing.T) {
	tx := sampleTx()
	tx.Weight = 101
	if err := tx.ValidateBasic(); err == nil {
		t.Fatal("deveria rejeitar peso inválido")
	}
}
func TestValidateChainSuccess(t *testing.T) {
	tx := sampleTx()
	b := Block{Header: BlockHeader{Version: 1, ChainID: "c", NetworkID: "n", Height: 0, Timestamp: "2026-05-19T03:00:00Z", PreviousHash: strings.Repeat("0", 64), Difficulty: 0, Miner: "m"}, Transactions: []Transaction{tx}}
	b.Recalculate()
	r := ValidateChain([]Block{b})
	if !r.Valid {
		t.Fatalf("cadeia inválida: %+v", r.Errors)
	}
}
func TestValidateChainTamperedBlock(t *testing.T) {
	tx := sampleTx()
	b := Block{Header: BlockHeader{Version: 1, ChainID: "c", NetworkID: "n", Height: 0, Timestamp: "2026-05-19T03:00:00Z", PreviousHash: strings.Repeat("0", 64), Difficulty: 0, Miner: "m"}, Transactions: []Transaction{tx}}
	b.Recalculate()
	b.Transactions[0].Message = "tamper"
	r := ValidateChain([]Block{b})
	if r.Valid {
		t.Fatal("deveria detectar adulteração")
	}
}
