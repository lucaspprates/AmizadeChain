# ONÇA-8X1 V2.1

Pacote operacional para conectar a Zoe de produção ao worker temporário
`win-codex-wak-01`, executar Codex sem aprovação interativa e preservar
evidências fail-closed.

## Topologia

```text
Zoe de produção / control plane
ubuntu@zoe-infranetwork-com-br
  - Hermes
  - Zoe Coder Router
  - runtime.db
  - configuração e política
  - commits, push, gates e evidências
            |
            | SSH por chave + git bundle
            v
Worker temporário
ubuntu@201.23.86.157
hostname: win-codex-wak-01
  - onca-runner sem sudo
  - Codex CLI 0.145.0
  - ChatGPT auth
  - jobs e worktrees descartáveis
  - exclusão até 2026-07-31 23:59 -03:00
```

## Decisão de permissão

O Codex trabalha em **YOLO / permissão total**, sem operador no terminal:

```text
approval_policy = "never"
sandbox_mode = "danger-full-access"
--dangerously-bypass-approvals-and-sandbox
```

A contenção não depende do sandbox interno do Codex. Ela é feita por:

- VM temporária e descartável;
- usuário `onca-runner` sem sudo;
- repositório por `git bundle`;
- ausência de credencial GitHub no worker;
- bridge com validação de SHA, ancestralidade e limpeza;
- política injetada em todo prompt;
- control plane congelado durante manutenção;
- resultado terminal independente de exit code.

## Por que este pacote substitui os scripts anteriores

O canário anterior só criava `result.json` no caminho feliz. Quando qualquer
comando remoto falhava, o coletor via apenas “arquivo ausente”.

O runner V2.1:

- cria `result.json` em sucesso ou falha;
- grava `failure_code` e `failure_detail`;
- preserva stdout, stderr, metadados, prompt e traceback;
- gera `SHA256SUMS`;
- permite coleta integral da evidência;
- valida o contrato Git externamente;
- mantém o objeto terminal como última linha útil;
- não confunde código de saída zero com sucesso semântico.

## Arquivos

```text
onca-8x1-v2.sh
control-plane/onca_remote_bridge.sh
worker/remote_job_runner.py
worker/ONCA_WORKER_POLICY.md
worker/AGENTS.md
README.md
MANIFEST.json
```

## Instalação

O instalador publicado no `AmizadeChain` baixa este pacote preso a um commit
imutável, verifica sete partes, payload, arquivo, manifesto, modos e sintaxe e
instala atomicamente em:

```text
/tmp/ONCA_8X1_V2
```

Âncoras imutáveis:

```text
package commit:   c32c62afffccfc8bc9058fa99229c6757b8e9d09
installer commit: c60b4db434f0a066a0453403e15de3729e0ccc70
installer blob:   fa08ffaf4c6b334f81894eed529d26d27056400c
archive SHA256:   f314322067e44ac8329da535d6fdbdf6a3ae505f5934cd856ec38b2014f462fc
```

Execução na Zoe de produção:

```bash
curl -fsSL \
'https://raw.githubusercontent.com/lucaspprates/AmizadeChain/c60b4db434f0a066a0453403e15de3729e0ccc70/tmp/onca-8x1-v2/install_onca_8x1_v2_1.sh' \
-o /tmp/install_onca_8x1_v2_1.sh

test "$(git hash-object /tmp/install_onca_8x1_v2_1.sh)" = \
'fa08ffaf4c6b334f81894eed529d26d27056400c'

bash -n /tmp/install_onca_8x1_v2_1.sh &&
chmod 700 /tmp/install_onca_8x1_v2_1.sh &&
/tmp/install_onca_8x1_v2_1.sh
```

## Comandos

Execute sempre na Zoe de produção:

```bash
cd /tmp/ONCA_8X1_V2

./onca-8x1-v2.sh status
./onca-8x1-v2.sh bootstrap-worker
./onca-8x1-v2.sh canary
./onca-8x1-v2.sh install-bridge
./onca-8x1-v2.sh collect-worker-evidence
```

Ou execute a preparação encadeada:

```bash
./onca-8x1-v2.sh prepare
```

`prepare` para no primeiro erro e deixa evidências.

## O que cada fase altera

### `bootstrap-worker`

No worker:

- cria `zoe-worker`;
- cria `onca-runner` sem sudo;
- instala Codex como root-owned;
- copia a autenticação ChatGPT para `onca-runner`;
- instala o runner remoto;
- instala política e `AGENTS.md`;
- grava `approval_policy=never`;
- grava `sandbox_mode=danger-full-access`;
- valida o flag YOLO.

Não altera o Router.

### `canary`

- cria um repositório descartável;
- executa Codex real em YOLO;
- exige um único arquivo com bytes exatos;
- proíbe commit;
- valida o objeto terminal;
- recolhe toda a evidência mesmo em falha;
- relê runtime, config, banco, timer e units.

### `install-bridge`

No control plane:

- instala `/usr/local/bin/onca-codex-remote`;
- instala `/etc/zoe-coder-router/onca-worker.conf`;
- cria o diretório de evidências remotas;
- configura Terra High;
- configura auto-push no control plane.

Essa fase **não altera `config.toml` do Router**. A admissão das rotas é a próxima
mudança controlada, depois de o canário passar.

## Recomendações permanentes no worker

As recomendações operacionais são instaladas em:

```text
/etc/zoe-worker/ONCA_WORKER_POLICY.md
/home/onca-runner/.codex/AGENTS.md
```

O bridge também injeta a política em todos os prompts. Assim, as instruções não
dependem apenas da descoberta de `AGENTS.md`.

## Contrato terminal do bridge

O bridge não aceita mais terminal implícito:

- ZCR19 exige `terminal_status` e os campos fixos do contrato;
- gates `read_only` exigem `gate_status`;
- writers genéricos exigem `terminal_status`;
- o objeto normalizado permanece como última linha de stdout;
- falha do processo ou do contrato nunca é convertida em sucesso.

## Coleta de evidências

A qualquer momento, com a fábrica congelada:

```bash
./onca-8x1-v2.sh collect-worker-evidence
```

O teardown recolhe todos os jobs antes de remover autenticação e workspaces.

## Segurança

- Não modificar UFW ou a porta 22 neste pacote.
- Não copiar credencial GitHub para o worker.
- Não executar Codex como `ubuntu` ou root.
- Não usar YOLO na Zoe de produção.
- Não religar o reconciliador antes do scheduler aprovado.
- Não excluir a VM sem recolher evidências e remover `auth.json`.

## Teardown

Antes de terminar a VM:

```bash
./onca-8x1-v2.sh teardown-worker
```

Depois:

- confirmar `WORKER_READY_FOR_TERMINATION=true`;
- terminar `win-codex-wak-01`;
- excluir permanentemente o boot volume.

## Estado terminal desta etapa

```text
OPERACAO_ONCA_8X1_V2_PREPARE: PASS
NEXT_PHASE=ROUTER_ROUTE_ADMISSION
```
