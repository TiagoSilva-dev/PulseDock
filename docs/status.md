# Registro de status

Atualizado em 2026-10-18, versão 0.1.0 (build de desenvolvimento).

## Funcionalidades concluídas (verificadas)

- **Dock**: apps reais via NSWorkspace (fixados, em execução, ativo, oculto), abrir e alternar via
  LaunchServices, reordenar arrastando, remover arrastando para fora, soltar `.app` para fixar, soltar
  arquivos num app ou no Lixo, menu contextual nativo (Mostrar no Finder, Manter no Dock, Ocultar, Encerrar,
  Forçar Encerramento com ⌥, Nova Instância quando permitido, janelas), magnificação orgânica com alvo de
  clique estável, rótulo flutuante, auto-hide com atrasos, supressão em tela cheia, multi-monitor por UUID,
  reposicionamento em mudanças de tela e ao acordar.
- **Aparência**: Pulse Glass (Liquid Glass no macOS 26+, `NSVisualEffectView` no 15), temas Native Glass,
  Midnight e Aurora, tamanho, espaçamento, transparência, borda, Reduzir Movimento, Reduzir Transparência,
  Aumentar Contraste, modo claro e escuro (revisados com capturas).
- **Ambientes**: Desenvolvimento, Criativo, Pessoal e Foco, com fixados, tema, widgets e filtro de IA
  próprios; nomes dos presets traduzidos até o usuário renomear; atalho ⌃⌥⌘W.
- **Widgets**: Relógio, Saúde do Sistema, Tocando Agora (Música/Spotify), Quick Launch (coleções) e Agent Pulse.
- **Agentes**: modelo universal de eventos, máquina de estados por evidência, staleness, liveness, prioridade,
  ilha (5 modos), Quick Peek, Agent Card, AI Mission Control, notificações agrupadas com horário de
  silêncio, Smart Return (aba exata do Terminal/iTerm2), Privacy Mode (⌃⌥⌘P), modo Demo.
- **Claude Code**: instalador com prévia, backup e remoção; 18 eventos; helper silencioso e limitado no
  tempo; spool; descoberta de sessões já abertas; **validado com sessões reais** (ferramentas, falha,
  subagente, fim de turno, compactação, reinício do app).
- **Codex**: hooks, notify encadeado e Managed Mode (app-server com aprovações pela API), validados contra
  schemas e protocolo oficiais.
- **Ajustes**: Geral, Aparência, Comportamento do Dock, Agentes de IA, Notificações, Privacidade e Avançado.
  Todos os controles têm efeito.
- **Localização**: pt-BR e inglês completos (551 chaves + 12 plurais + textos de permissão), números e
  datas no locale.
- **Distribuição**: build universal (arm64 + x86_64), ZIP e DMG, script de assinatura/notarização,
  desinstalação.
- **Diagnóstico**: painel Avançado, exportação sanitizada, log unificado (`app.pulsedock.PulseDock`).

## Pendente

| Item | Bloqueio |
| --- | --- |
| Teste ao vivo de permissão, duas sessões simultâneas e `StopFailure` no Claude Code | execução manual (roteiro pronto) |
| Teste ponta a ponta do Codex (3 modos) | Codex não instalado |
| Developer ID, notarização e instalação em outro Mac | credenciais Apple Developer |
| Multi-monitor físico, Mac Intel real, jogos em tela cheia, ciclo real de suspensão | hardware e execução manual |
| Revisão VoiceOver e teclado completo no dock | execução manual |
| Testes de snapshot das views | a implementar |
| Relatório de falhas local e opcional | a implementar |
| Revisão do material do macOS 15 | máquina com macOS 15 (ou o alternador de compatibilidade) |

## Testes executados

- `swift test`: **66/66** aprovados (10 suítes). Detalhes em `docs/testing.md`.
- Integração real com o Claude Code 2.1.302 (hooks globais): ver `docs/integrations/claude-code.md` §6.
- Benchmark de release: abertura em 85 ms, 0,15 % de CPU ociosa, 44 MB de memória e 23 µs por evento.
- Revisão visual com capturas reais (escuro/claro, pt-BR/inglês), com os problemas encontrados corrigidos (lista em `docs/testing.md` §3).
- Empacotamento: ZIP + DMG verificados com `codesign --verify --strict --deep`; Intel testado sob Rosetta.

## Problemas conhecidos

- O macOS mostra periodicamente ao Terminal o aviso "ignorar o seletor de janelas privadas". Ele vem da
  permissão de Gravação de Tela usada **só** para as capturas de desenvolvimento; o PulseDock não captura a
  tela.
- Builds sem Developer ID são bloqueados pelo Gatekeeper em outros Macs (comportamento esperado).
- Sessões só com `notify` do Codex não têm início de turno observável: o estado entre turnos é
  desconhecido, por design.
- Sob tmux, o Smart Return ativa o terminal identificado, mas não seleciona o painel.

## Restrições técnicas

- Não existe API pública para remover o Dock do macOS: o Replacement Mode usa auto-hide (ADR 0006).
- Hooks não dão heartbeat: estados longos sem eventos dependem de liveness e staleness (ADR 0005).
- Pré-visualização do conteúdo de janelas exigiria Gravação de Tela (ScreenCaptureKit): não implementada.
- `~/.claude/sessions/*.json` não é documentado: só descoberta e liveness.

## Segurança

- `.claude/settings.local.json` (local, fora do PulseDock) contém uma chave de API em texto puro. O
  `.gitignore` já exclui esse arquivo; recomenda-se **rotacionar a chave**.
- Hooks do PulseDock estão instalados em `~/.claude/settings.json` (com backup em
  `~/Library/Application Support/PulseDock/backups/`). Remoção: Ajustes › Agentes de IA › Desconectar, ou
  `pulsedockctl uninstall-hooks`.

## Próxima tarefa recomendada

Rodar o roteiro manual do Claude Code (`docs/testing.md` §4.1), com duas sessões em projetos diferentes e um
pedido de permissão, e depois instalar o Codex para fechar a Fase 4.
