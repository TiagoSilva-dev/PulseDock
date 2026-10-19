# ADR 0007 — Codex: Observe Mode (hooks ou notify) e Managed Mode (app-server)

- Status: aceito
- Data: 2026-10-18

## Contexto

O Codex oferece três mecanismos oficiais com níveis diferentes de observabilidade:

1. **Hooks** (`~/.codex/hooks.json`): eventos de sessão, prompt, ferramentas, aprovação, subagentes e fim de
   turno. Hooks novos só executam depois que o usuário os revisa e confia neles com `/hooks`.
2. **`notify`** (`config.toml`): um único programa, chamado **apenas** no fim de cada turno.
3. **App-server** (`codex app-server`, JSON-RPC por stdio): controle completo das threads que o próprio
   cliente inicia, com itens, planos e pedidos de aprovação que o cliente responde.

Iniciar uma conexão ao app-server **não** permite observar sessões que o usuário abriu num terminal.

## Decisão

- **Observe Mode** (sessões iniciadas pelo usuário):
  - Preferência: hooks. O PulseDock mostra o estado "confie nos hooks no Codex" até o primeiro evento chegar.
  - Alternativa: `notify`, marcado na UI como "só fim de turno". Entre um turno e outro, o PulseDock não
    afirma atividade. Se já existir um `notify`, ele é preservado e encadeado: o helper repassa cada
    notificação ao comando anterior, guardado em `codex-notify-chain.json`. Só um `notify = [...]` de
    uma linha é editado automaticamente; outros formatos são reportados para edição manual.
- **Managed Mode** (tarefas iniciadas pelo PulseDock): o `CodexManagedService` inicia `codex app-server`,
  envia `initialize`, `thread/start`, `turn/start` (e `turn/interrupt` quando o usuário pede) e mapeia
  `thread/started`, `turn/started`, `item/started`, `item/completed`, `turn/plan/updated`,
  `turn/completed` e `thread/closed`. Os pedidos `item/commandExecution/requestApproval`,
  `item/fileChange/requestApproval` e `item/permissions/requestApproval` aparecem no Agent Card com o
  comando, o motivo e o diretório. As decisões oferecidas são **só** as que a API aceita, e nada é aprovado
  sem clique explícito.
- Em Observe Mode, o PulseDock **nunca** oferece botões de aprovação: navega até a origem (Smart Return).

## Consequências

- O Codex CLI não está instalado no Mac de desenvolvimento. A integração foi validada contra os **schemas
  oficiais gerados** do Codex (`codex-rs/hooks/schema/generated`) e contra fixtures do protocolo do app-server
  (`CodexAdapterTests`). Falta o teste ponta a ponta com o Codex real (ver `docs/testing.md`).
- Critérios de aceitação independentes: Observe/hooks, Observe/notify e Managed (ver `docs/integrations/codex.md`).
