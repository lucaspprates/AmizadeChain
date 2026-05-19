package main

import (
	"flag"
	"fmt"
	"github.com/lucaspprates/AmizadeChain/internal/api"
	"github.com/lucaspprates/AmizadeChain/internal/service"
	"log"
)

func main() {
	addr := flag.String("http", "127.0.0.1:8080", "endereço HTTP")
	data := flag.String("data-dir", "./data", "diretório de dados")
	diff := flag.Int("difficulty", 3, "dificuldade PoW")
	flag.Parse()
	n, err := service.Open(*data, uint8(*diff), 100)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println("📖 amizadechaind ouvindo em", *addr)
	log.Fatal(api.New(n).Listen(*addr))
}
