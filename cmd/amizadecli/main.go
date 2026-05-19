package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"github.com/lucaspprates/AmizadeChain/internal/blockchain"
	"github.com/lucaspprates/AmizadeChain/internal/genesis"
	"github.com/lucaspprates/AmizadeChain/internal/identity"
	"github.com/lucaspprates/AmizadeChain/internal/service"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		return
	}
	switch os.Args[1] {
	case "init":
		initCmd(os.Args[2:])
	case "identity":
		identityCmd(os.Args[2:])
	case "tx":
		txCmd(os.Args[2:])
	case "mempool":
		mempoolCmd(os.Args[2:])
	case "mine":
		mineCmd(os.Args[2:])
	case "chain":
		chainCmd(os.Args[2:])
	case "validate":
		validateCmd(os.Args[2:])
	case "export":
		exportCmd(os.Args[2:])
	default:
		usage()
	}
}
func usage() {
	fmt.Println("amizadecli init|identity new|tx add|mempool list|mine|chain print|validate|export")
}
func initCmd(args []string) {
	fs := flag.NewFlagSet("init", flag.ExitOnError)
	g := fs.String("genesis", "./genesis.json", "")
	d := fs.String("data-dir", "./data", "")
	fs.Parse(args)
	gf, err := genesis.LoadAndValidate(*g)
	must(err)
	_, err = service.Init(*d, *g)
	must(err)
	fmt.Printf("🌱 AmizadeChain inicializada\n📖 Chain ID: %s\n🧱 Genesis height: %d\n🔐 Genesis hash: %s\n✨ A vida é um livro-razão. Toda atitude vira lançamento.\n", gf.Network.ChainID, gf.Block.Header.Height, gf.Block.Hash)
}
func identityCmd(args []string) {
	if len(args) == 0 || args[0] != "new" {
		usage()
		return
	}
	fs := flag.NewFlagSet("identity new", flag.ExitOnError)
	name := fs.String("name", "lucao", "")
	d := fs.String("data-dir", "./data", "")
	fs.Parse(args[1:])
	id, err := identity.New(*name)
	must(err)
	must(identity.Save(*d, id))
	fmt.Println("🔑 Identidade criada:", id.Name)
	fmt.Println("🪪 PublicKey:", id.PublicKey)
}
func txCmd(args []string) {
	if len(args) == 0 || args[0] != "add" {
		usage()
		return
	}
	fs := flag.NewFlagSet("tx add", flag.ExitOnError)
	d := fs.String("data-dir", "./data", "")
	typ := fs.String("type", "TRUE_FRIENDSHIP", "")
	to := fs.String("to", "", "")
	att := fs.String("attitude", "presenca", "")
	weight := fs.Int("weight", 10, "")
	vis := fs.String("visibility", "public_symbolic", "")
	msg := fs.String("message", "", "")
	signer := fs.String("signer", "", "")
	var tags multi
	fs.Var(&tags, "tag", "")
	fs.Parse(args[1:])
	n, err := service.Open(*d, 3, 100)
	must(err)
	tx := blockchain.Transaction{Type: *typ, To: *to, Attitude: *att, Weight: *weight, Visibility: *vis, Message: *msg, Tags: tags, From: "local/unsigned"}
	tx.EnsureDefaults()
	if *signer != "" {
		id, err := identity.Load(*d, *signer)
		must(err)
		must(id.Sign(&tx))
	} else {
		tx.FinalizeID()
	}
	must(n.AddTransaction(tx))
	fmt.Println("✅ Transação no mempool:", tx.ID)
}
func mempoolCmd(args []string) {
	fs := flag.NewFlagSet("mempool", flag.ExitOnError)
	d := fs.String("data-dir", "./data", "")
	fs.Parse(skip(args, "list"))
	n, err := service.Open(*d, 3, 100)
	must(err)
	enc(n.MP.List())
}
func mineCmd(args []string) {
	fs := flag.NewFlagSet("mine", flag.ExitOnError)
	d := fs.String("data-dir", "./data", "")
	miner := fs.String("miner", "lucao", "")
	fs.Parse(args)
	n, err := service.Open(*d, 3, 100)
	must(err)
	fmt.Println("⛏️  Minerando bloco...")
	b, err := n.Mine(*miner)
	must(err)
	fmt.Printf("✅ Bloco #%d minerado\n🔗 Hash: %s\n📦 Transações: %d\n", b.Header.Height, b.Hash, len(b.Transactions))
}
func chainCmd(args []string) {
	fs := flag.NewFlagSet("chain", flag.ExitOnError)
	d := fs.String("data-dir", "./data", "")
	fs.Parse(skip(args, "print"))
	n, err := service.Open(*d, 3, 100)
	must(err)
	enc(n.Blocks())
}
func validateCmd(args []string) {
	fs := flag.NewFlagSet("validate", flag.ExitOnError)
	d := fs.String("data-dir", "./data", "")
	fs.Parse(args)
	n, err := service.Open(*d, 3, 100)
	must(err)
	r := n.Validate()
	enc(r)
	if !r.Valid {
		os.Exit(1)
	}
}
func exportCmd(args []string) {
	fs := flag.NewFlagSet("export", flag.ExitOnError)
	d := fs.String("data-dir", "./data", "")
	out := fs.String("out", "./chain-export.json", "")
	_ = fs.String("format", "json", "")
	fs.Parse(args)
	n, err := service.Open(*d, 3, 100)
	must(err)
	must(n.Export(*out))
	fmt.Println("📤 Exportado para", *out)
}

type multi []string

func (m *multi) String() string     { return fmt.Sprint([]string(*m)) }
func (m *multi) Set(v string) error { *m = append(*m, v); return nil }
func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, "erro:", err)
		os.Exit(1)
	}
}
func enc(v any) { b, _ := json.MarshalIndent(v, "", "  "); fmt.Println(string(b)) }
func skip(a []string, s string) []string {
	if len(a) > 0 && a[0] == s {
		return a[1:]
	}
	return a
}
