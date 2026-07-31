# ONÇA-8X1 V3

Pacote operacional imutável para preparar o worker temporário da fábrica Zoe.

## Escopo

- executor dedicado sem sudo;
- execução não interativa;
- canário real com evidência em sucesso ou falha;
- transporte por git bundle;
- bridge instalado sem alterar as rotas do Router;
- política operacional e AGENTS.md instalados no worker;
- coleta e teardown antes da exclusão da VM.

## Uso

Execute o instalador publicado nesta pasta somente na Zoe de produção. Após a instalação:

```bash
cd /tmp/ONCA_8X1_V3
./onca-8x1-v3.sh prepare
```

O `prepare` é fail-closed e não religa o reconciliador.
