package api

import (
	"encoding/json"
	"github.com/lucaspprates/AmizadeChain/internal/blockchain"
	"github.com/lucaspprates/AmizadeChain/internal/service"
	"net/http"
	"strconv"
	"strings"
)

type Server struct {
	Node *service.Node
	mux  *http.ServeMux
}

func New(n *service.Node) *Server {
	s := &Server{Node: n, mux: http.NewServeMux()}
	s.routes()
	return s
}
func (s *Server) Handler() http.Handler    { return s.mux }
func (s *Server) Listen(addr string) error { return http.ListenAndServe(addr, s.Handler()) }
func write(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
func errw(w http.ResponseWriter, code int, msg string) { write(w, code, map[string]any{"error": msg}) }
func (s *Server) routes() {
	s.mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		write(w, 200, map[string]any{"status": "ok", "message": "AmizadeChain respirando: o livro-razão permanece aberto."})
	})
	s.mux.HandleFunc("/v1/genesis", s.genesis)
	s.mux.HandleFunc("/v1/chain", s.chain)
	s.mux.HandleFunc("/v1/blocks", s.blocks)
	s.mux.HandleFunc("/v1/blocks/height/", s.blockHeight)
	s.mux.HandleFunc("/v1/blocks/hash/", s.blockHash)
	s.mux.HandleFunc("/v1/mempool", func(w http.ResponseWriter, r *http.Request) { write(w, 200, s.Node.MP.List()) })
	s.mux.HandleFunc("/v1/transactions", s.transactions)
	s.mux.HandleFunc("/v1/mine", s.mine)
	s.mux.HandleFunc("/v1/validate", func(w http.ResponseWriter, r *http.Request) { write(w, 200, s.Node.Validate()) })
	s.mux.HandleFunc("/v1/friendships/", s.ledger)
}
func (s *Server) genesis(w http.ResponseWriter, r *http.Request) {
	bs := s.Node.Blocks()
	if len(bs) == 0 {
		errw(w, 404, "genesis não inicializado")
		return
	}
	write(w, 200, bs[0])
}
func (s *Server) chain(w http.ResponseWriter, r *http.Request) {
	type sum struct {
		Height       uint64 `json:"height"`
		Hash         string `json:"hash"`
		PreviousHash string `json:"previous_hash"`
		TxCount      int    `json:"tx_count"`
		Timestamp    string `json:"timestamp"`
	}
	var out []sum
	for _, b := range s.Node.Blocks() {
		out = append(out, sum{b.Header.Height, b.Hash, b.Header.PreviousHash, len(b.Transactions), b.Header.Timestamp})
	}
	write(w, 200, out)
}
func (s *Server) blocks(w http.ResponseWriter, r *http.Request) { write(w, 200, s.Node.Blocks()) }
func (s *Server) blockHeight(w http.ResponseWriter, r *http.Request) {
	h, er := strconv.ParseUint(strings.TrimPrefix(r.URL.Path, "/v1/blocks/height/"), 10, 64)
	if er != nil {
		errw(w, 400, "altura inválida")
		return
	}
	b, er := s.Node.Store.GetBlockByHeight(h)
	if er != nil {
		errw(w, 404, er.Error())
		return
	}
	write(w, 200, b)
}
func (s *Server) blockHash(w http.ResponseWriter, r *http.Request) {
	hash := strings.TrimPrefix(r.URL.Path, "/v1/blocks/hash/")
	b, er := s.Node.Store.GetBlockByHash(hash)
	if er != nil {
		errw(w, 404, er.Error())
		return
	}
	write(w, 200, b)
}
func (s *Server) transactions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		errw(w, 405, "método não permitido")
		return
	}
	var tx blockchain.Transaction
	if err := json.NewDecoder(r.Body).Decode(&tx); err != nil {
		errw(w, 400, err.Error())
		return
	}
	if tx.From == "" {
		tx.From = "api/local"
	}
	if err := s.Node.AddTransaction(tx); err != nil {
		errw(w, 400, err.Error())
		return
	}
	write(w, 201, tx)
}
func (s *Server) mine(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		errw(w, 405, "método não permitido")
		return
	}
	var in struct {
		Miner string `json:"miner"`
	}
	_ = json.NewDecoder(r.Body).Decode(&in)
	if in.Miner == "" {
		in.Miner = "api/miner"
	}
	b, err := s.Node.Mine(in.Miner)
	if err != nil {
		errw(w, 500, err.Error())
		return
	}
	write(w, 201, b)
}
func (s *Server) ledger(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/v1/friendships/"), "/ledger")
	var out []blockchain.Transaction
	for _, b := range s.Node.Blocks() {
		for _, tx := range b.Transactions {
			if tx.To == id || tx.From == id {
				out = append(out, tx)
			}
		}
	}
	write(w, 200, out)
}
