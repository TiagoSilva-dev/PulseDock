# ADR 0008 — Localização: o código é a fonte das chaves; traduções em JSON

- Status: aceito
- Data: 2026-10-18

## Contexto

A especificação exige português brasileiro e inglês, sem textos fixos espalhados pelo código, e uma
estrutura pronta para mais idiomas. String Catalogs (`.xcstrings`) dependem do build do Xcode, e o
PulseDock é construído pelo SwiftPM (ADR 0001).

## Decisão

- Toda string visível passa por `tr("chave", "English")` ou, para contagens, por
  `trp("chave", one: "…", other: "…", n)`. O inglês no código é o valor de desenvolvimento e o fallback.
- `scripts/localize.py` extrai as chaves do código e gera, para cada idioma, `Localizable.strings`,
  `Localizable.stringsdict` (plurais, com as regras CLDR do Foundation) e `InfoPlist.strings`
  (textos de pedidos de permissão), em `Resources/Generated/<idioma>.lproj/`.
- Traduções em `Resources/Localization/<idioma>.json`. Chaves de plural mapeiam para
  `{"one": …, "other": …}`, e as do `Info.plist` usam o prefixo `InfoPlist.`.
- O script valida: chaves faltando, chaves sem uso, **placeholders divergentes** (que derrubariam
  `String(format:)`) e formas de plural incompletas. O build de release usa `--strict` e falha nesses casos.
- Frases com mais de um contador foram reescritas como rótulo + valor (por exemplo,
  "Tarefas · 2 de 3"), para não exigir combinações de plural.
- Números e datas usam o `Locale.current` (`0,12 s`, `1,45×`, `18 de out.`).
- Em Ajustes › Geral › Idioma, o usuário escolhe o idioma da interface (vale a partir da próxima
  abertura, como no macOS).

## Consequências

- Adicionar um idioma = um JSON novo + incluir o código em `LANGUAGES` e em `CFBundleLocalizations`.
- 551 chaves simples + 12 de plural, 100 % traduzidas para pt-BR na versão 0.1.0.
