# AGENTS.md — guia para agentes de código neste repositório

PulseDock: dock nativo para macOS (Swift 6, SwiftUI + AppKit, macOS 15+) que mostra o estado real de
agentes de IA (Claude Code, Codex) a partir dos hooks oficiais deles. Leia `docs/architecture/overview.md`
antes de mudanças estruturais.

## Comandos

```bash
swift build                                  # todos os targets
swift test                                   # 66 testes (Swift Testing); devem passar antes de concluir
scripts/build-app.sh debug                   # .app de desenvolvimento em build/debug
scripts/build-app.sh release                 # universal; falha se faltar tradução
python3 scripts/localize.py --strict         # valida chaves, placeholders e plurais
scripts/benchmark.sh release 30              # recursos (fecha e reabre o PulseDock)
open build/debug/PulseDock.app --args --developer --demo --no-onboarding
```

Revisão visual (app em `--developer`): `build/debug/PulseDock.app/Contents/Helpers/pulsedockctl control …`
com `open what=card|missionControl|settings pane=<pane>|onboarding`, `hover x=0.3`, `unhover`,
`demo enabled=true|false`, `appearance mode=light|dark|system`, `sleep`, `wake` e `snapshot dir=<pasta>`.
Capture janelas com `screencapture -x -o -l <windowID>`.

## Regras do projeto

1. **Fronteiras de módulo**: `AgentCore`, `AgentBridge`, `AdapterSupport`, os adaptadores, `Persistence` e
   `Diagnostics` não importam AppKit nem SwiftUI. O helper (`PulseDockHook`) depende só de `AgentBridge`. Os
   módulos de UI usam isolamento padrão no `MainActor`.
2. **Estados honestos** (ADR 0005): nada de sucesso inferido; um fim de turno não é uma tarefa concluída.
   Toda inferência nova usa `confidence: .inferred`, é documentada no ADR 0005 e ganha teste em
   `SessionReducerTests`/`EngineRobustnessTests`. Atividades vêm só de campos concretos (`ToolClassifier`).
3. **Privacidade** (`docs/privacy.md`): a sanitização acontece **no helper**. Campo novo de hook =
   entrada na lista branca do `HookSanitizer`, com limite de tamanho, mais um teste em
   `ClaudeCodePipelineTests` ou `AgentBridgeTests`. Nunca registre prompts, conteúdo de arquivos, saídas,
   diffs, variáveis de ambiente ou credenciais, nem em logs.
4. **Helper dos hooks**: roda em **toda** chamada de ferramenta do Claude Code deste Mac (os hooks estão
   instalados). Ele precisa continuar silencioso (nada em stdout), rápido (entrega ≤ 0,3 s) e sempre com
   `exit 0`. Teste mudanças com `pulsedockctl send-hook claude-code <fixture.json>` antes de reconstruir o app.
   A versão copiada para `~/Library/Application Support/PulseDock/bin/` é atualizada quando o app abre.
5. **Configurações de terceiros**: só pelos instaladores (`ClaudeCodeHookInstaller`, `CodexHookInstaller`,
   `CodexNotifyInstaller`), que fazem prévia, backup, preservam entradas de terceiros e recusam sobrescrever
   mudanças concorrentes. Nunca edite `~/.claude/settings.json` ou `~/.codex/*` à mão nem por `sed`.
6. **Localização** (ADR 0008): todo texto visível passa por `tr("chave", "English")` ou
   `trp("chave", one:, other:, n)`. Adicione a tradução em `Resources/Localization/pt-BR.json` e rode
   `scripts/localize.py --strict`. Frases com mais de um contador: rótulo + valor, sem plural combinado.
   Números e datas via `Locale.current`.
7. **Design** (`docs/design-system.md`): use os tokens (`DockMetrics`, `PanelMetrics`, `PulseTypography`,
   `Theme.tone`, `Motion`/`MotionSprings`). Superfícies com texto usam
   `PulseGlassSurface(…, legibility: .content)`. Toda cor nova de tema precisa de variante clara e escura, e
   estados nunca dependem só de cor (símbolo + texto).
8. **Sem APIs privadas** e sem hacks no Dock do macOS (ADR 0006). Sem polling caro: prefira notificações,
   vnode e display link só durante animações.
9. **Demo**: dados simulados levam o selo DEMO e nunca vão para o banco (`PersistenceTests` garante).
10. **Mudanças com efeito externo** (instalar ferramentas, alterar configurações do sistema ou dos agentes,
    permissões): peça confirmação ao usuário.

## Ao concluir uma tarefa

- `swift test` verde e, para mudanças visuais, capturas revisadas.
- Atualize `docs/status.md` (concluído/pendente/testes) e, se aplicável, `docs/testing.md`, os documentos de
  integração e um ADR para decisões que afetam o produto inteiro.
- Não declare como pronto o que depende de simulação: diga o que foi validado ao vivo e o que foi validado
  por fixtures.

## Mapa rápido

| Preciso mexer em… | Arquivo |
| --- | --- |
| Regras de estado | `Sources/AgentCore/Engine/SessionReducer.swift`, `StalenessPolicy.swift` |
| Prioridade / ilha | `Sources/AgentCore/Presentation/AgentPresenter.swift`, `PulseDockApp/AgentUI/AgentPulseIsland.swift` |
| Mapeamento dos hooks do Claude | `Sources/ClaudeCodeAdapter/ClaudeCodeNormalizer.swift` |
| Codex | `Sources/CodexAdapter/` |
| Sanitização | `Sources/AgentBridge/HookSanitizer.swift`, `SecretRedactor.swift` |
| Layout e magnificação | `Sources/DockRendering/Magnification.swift`, `PulseDockApp/Dock/DockModel.swift` |
| Janela e interação do dock | `PulseDockApp/Dock/DockWindowController.swift`, `DockHostView.swift`, `DockPanel.swift` |
| Smart Return | `PulseDockApp/Agents/SmartReturn.swift` |
| Ajustes | `PulseDockApp/Settings/` (`AppSettings.swift` decodifica de forma tolerante: mantenha os defaults) |
