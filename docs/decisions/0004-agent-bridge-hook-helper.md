# ADR 0004 — Helper de hooks + Unix domain socket + spool

- Status: aceito
- Data: 2026-10-18

## Contexto

Hooks do Claude Code e do Codex executam um comando por evento e entregam o payload em JSON no stdin. O
comando roda no caminho crítico do agente. A especificação exige que o PulseDock nunca bloqueie o agente,
nunca escreva na saída padrão (para o Claude Code, o stdout de `SessionStart`/`UserPromptSubmit` vira
contexto da conversa), não exponha endpoint HTTP e não armazene conteúdo sensível.

## Decisão

Fluxo: `Agente → hook → pulsedock-hook → socket local → AgentBridge → AgentCore → UI`.

- **Helper (`pulsedock-hook`)**: executável Swift só com Foundation e `AgentBridge`.
  - Lê o stdin com limite de tamanho, valida, **sanitiza antes de enviar** (prompts, conteúdo de arquivos,
    saídas de comandos e mensagens do assistente nunca saem do helper) e monta um envelope versionado.
  - Captura o contexto de processo para o Smart Return: cadeia de ancestrais, TTY, app hospedeiro e
    horário de início do processo do agente (para detectar PID reutilizado).
  - Entrega com timeout total de 0,3 s, sempre sai com status 0, nunca escreve em stdout e se encerra
    sozinho com `alarm(2)` como última proteção.
- **Comando instalado**: `[ -x '<helper>' ] && exec '<helper>' claude-code <Evento> || exit 0`, com
  `timeout: 5`. Se o PulseDock foi removido sem desinstalar os hooks, o agente não vê erro.
- **Local estável**: o helper é copiado para `~/Library/Application Support/PulseDock/bin/` (atualizado
  quando a versão muda), para que mover o `.app` não quebre os hooks.
- **Socket**: `~/Library/Application Support/PulseDock/run/bridge.sock`, num diretório `0700` (corrigido
  se estiver mais aberto), arquivo `0600`, `getpeereid` exigindo o mesmo UID, mensagens NDJSON de no
  máximo 512 KiB e validação de esquema. Um segundo servidor não rouba o socket de um servidor vivo.
- **Spool**: se o app não está rodando, o envelope sanitizado vai para um spool privado (`0600`,
  `O_NOFOLLOW`, limite de 4 MiB), que é drenado de forma atômica na próxima abertura. Eventos ocorridos
  durante um reinício do PulseDock não se perdem; a reconciliação de liveness resolve sessões antigas.

## Alternativas consideradas

- **Servidor HTTP local**: proibido pela especificação, e com superfície de ataque maior.
- **XPC/Mach service**: exige um launchd agent ou um serviço embutido, além de assinatura coerente
  entre o helper e o app. O socket com checagem de UID atende ao modelo de ameaça (usuário único) com menos
  peças.
- **O app ler os transcripts diretamente**: seria ler o conteúdo da conversa, o que viola a política de
  privacidade.

## Consequências

- O custo por evento fica em milissegundos e independe de o app estar aberto.
- Testes: `AgentBridgeTests` (socket, validação, limite de tamanho, socket não roubado, spool, redação de
  credenciais, níveis de detalhe de comando) e `ClaudeCodePipelineTests` (nenhum campo de conteúdo
  sobrevive ao sanitizador).
