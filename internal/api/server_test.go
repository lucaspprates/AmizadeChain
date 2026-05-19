package api

import (
	"bytes"
	"github.com/lucaspprates/AmizadeChain/internal/blockchain"
	"github.com/lucaspprates/AmizadeChain/internal/service"
	"github.com/lucaspprates/AmizadeChain/internal/storage"
	"net/http"
	"net/http/httptest"
	"testing"
)

func testServer() *Server {
	st := storage.NewMemoryStore()
	tx := blockchain.Transaction{ID: "g", Type: blockchain.TxGenesisDeclaration, From: "g", To: "t", Attitude: "a", Weight: 1, Visibility: "public_symbolic", CreatedAt: "2026-05-19T03:00:00Z"}
	b := blockchain.Block{Header: blockchain.BlockHeader{Version: 1, ChainID: "c", NetworkID: "n", Height: 0, Timestamp: "2026-05-19T03:00:00Z", PreviousHash: "0", Difficulty: 0, Miner: "g"}, Transactions: []blockchain.Transaction{tx}}
	b.Recalculate()
	_ = st.SaveBlock(b)
	n := service.New(st, st, 0, 100)
	return New(n)
}
func TestHealth(t *testing.T) {
	s := testServer()
	rr := httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, httptest.NewRequest("GET", "/health", nil))
	if rr.Code != 200 {
		t.Fatal(rr.Code)
	}
}
func TestPostTransactionMineValidate(t *testing.T) {
	s := testServer()
	body := []byte(`{"type":"TRUE_FRIENDSHIP","to":"amigo","attitude":"presenca","weight":10,"visibility":"public_symbolic","message":"ok"}`)
	rr := httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, httptest.NewRequest("POST", "/v1/transactions", bytes.NewReader(body)))
	if rr.Code != 201 {
		t.Fatalf("tx code %d body %s", rr.Code, rr.Body.String())
	}
	rr = httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, httptest.NewRequest("POST", "/v1/mine", bytes.NewReader([]byte(`{"miner":"m"}`))))
	if rr.Code != 201 {
		t.Fatalf("mine %d %s", rr.Code, rr.Body.String())
	}
	rr = httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, httptest.NewRequest("GET", "/v1/validate", nil))
	if rr.Code != 200 {
		t.Fatal(rr.Code)
	}
}
func TestMethods(t *testing.T) { _ = http.MethodGet }
