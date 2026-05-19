package genesis

import "testing"

func TestGenesisLoad(t *testing.T) {
	f, err := Load("../../genesis.json")
	if err != nil {
		t.Fatal(err)
	}
	if f.Block.Header.Height != 0 {
		t.Fatal("altura genesis inválida")
	}
}
func TestGenesisHashValidation(t *testing.T) {
	if _, err := LoadAndValidate("../../genesis.json"); err != nil {
		t.Fatal(err)
	}
}
