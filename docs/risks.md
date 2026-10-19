# Registro de riscos

Atualizado em 2026-10-18. Probabilidade e impacto: B (baixo), M (médio), A (alto).

| # | Risco | P | I | Mitigação | Situação |
| --- | --- | --- | --- | --- | --- |
| R1 | **Substituir o Dock do macOS** sem APIs públicas para removê-lo | A | M | Replacement Mode só com auto-hide via System Events e, opcionalmente, `autohide-delay` (uma reinicialização por ação do usuário); ponto de restauração; o Dock do macOS continua existindo na borda (ADR 0006) | Mitigado; falta validação manual |
| R2 | Mudança no esquema dos hooks do Claude Code | M | A | Normalizador tolerante (campos opcionais), conjunto de eventos por versão, nome do evento original guardado para diagnóstico, fixtures do esquema oficial, testes com sessão real | Monitorar a cada versão do Claude Code |
| R3 | Formato não documentado de `~/.claude/sessions/*.json` | M | B | Usado só para descoberta e liveness, nunca para decidir estado; desligável; parsing defensivo | Mitigado |
| R4 | Codex não testado com o binário real | A | M | Validação contra os schemas gerados e o protocolo oficial; critérios de aceitação separados por modo; roteiro manual | **Aberto** até instalar o Codex |
| R5 | Hook lento ou com falha atrasa o agente | B | A | Helper só com Foundation, entrega com timeout de 0,3 s, `alarm(2)`, `timeout: 5` na configuração, sempre `exit 0`, sem stdout, spool quando o app está fechado | Mitigado e medido |
| R6 | Vazamento de conteúdo sensível (prompts, código, segredos) | M | A | Sanitização **no helper** com lista branca de campos, redação de credenciais, detalhe de comando configurável, Privacy Mode, demo nunca gravado, testes "No content field survives…" e "Credentials are redacted…" | Mitigado; revisar a cada evento novo |
| R7 | Estados falsos ("Trabalhando" sem evidência) | M | A | Estados por evidência, confiança explícita, staleness, liveness por PID + horário de início, inferências documentadas e marcadas com "?" (ADR 0005) | Mitigado |
| R8 | Permissões negadas (Acessibilidade, Automação, Notificações) | A | B | Todas opcionais, pedidas no contexto, com degradação descrita em `docs/privacy.md` | Mitigado |
| R9 | Dock sobre jogos ou apps em tela cheia | M | M | Fora dos Spaces de tela cheia; supressão quando o app da frente cobre a tela; opção nos Ajustes | Mitigado; falta testar com jogos |
| R10 | Multi-monitor, mudança de resolução e suspensão | M | M | Reposicionamento em `didChangeScreenParameters`, ao acordar e com `screensDidWake`; telas identificadas por UUID | Implementado; falta roteiro manual com monitor externo |
| R11 | APIs do Liquid Glass mudarem entre versões do macOS | M | B | Isolado em `PulseGlassSurface`, com caminho legado sempre disponível | Mitigado |
| R12 | Distribuição: Gatekeeper bloqueia builds sem Developer ID | A (sem credenciais) | A | `scripts/package.sh` assina com Developer ID e notariza quando há credenciais; nunca sugere desligar o Gatekeeper | **Aberto**: requer conta Apple Developer |
| R13 | Consumo de energia de um app sempre aberto | B | M | Display link só com molas em movimento, monitores baratos, widgets pausados quando ocultos, sem polling agressivo; benchmark reproduzível (0,15 % de CPU ociosa) | Mitigado e medido |
| R14 | Licença do PrimoDock proíbe engenharia reversa do binário | — | A | Não realizada; só observação pública e metadados declarativos (`docs/research/competitive-analysis.md` §1.1) | Respeitado |
| R15 | Arquivo local com credencial versionado por engano (`.claude/settings.local.json` contém uma chave de API) | M | A | `.gitignore` exclui `.claude/settings.local.json` e `.env*`; recomenda-se rotacionar a chave | Mitigado no repositório; rotação depende do usuário |
