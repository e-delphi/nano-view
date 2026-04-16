# NanoView

Wrapper Windows minimalista para transformar sites em aplicativos nativos de desktop. Escrito em Delphi puro sobre a Win32 API + WebView2 (Edge/Chromium), sem VCL nem FMX — um único arquivo `.dpr`, binário compacto e baixo consumo de memória.

## Funcionalidades

- **WebView2 (Chromium)** — renderização moderna via runtime do Edge instalado no Windows.
- **Abre maximizado** e respeita DPI por monitor (Per-Monitor v2).
- **Tema sincronizado com o site** — a barra de título do Windows acompanha em tempo real o tema do site (lê `localStorage.theme` e cai em `prefers-color-scheme` como fallback). Mudanças são detectadas via *monkey-patch* em `Storage.prototype` + `window.chrome.webview.postMessage`.
- **Ícone na bandeja do sistema** permanente.
- **Fechar vai para a bandeja** (X esconde, não encerra).
- **Menu de contexto (clique direito na bandeja):**
  - *Abrir* — restaura a janela no mesmo estado anterior (maximizada ou normal).
  - *Iniciar com o Windows* — checkbox que adiciona/remove entrada em `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`. Ao iniciar pelo autorun, o app sobe silenciosamente direto para a bandeja (`/tray`).
  - *Fechar* — encerra o processo de fato.
- **Menu escuro seguindo o Windows** — usa os ordinais não documentados de `uxtheme.dll` (`SetPreferredAppMode`, `AllowDarkModeForWindow`, `FlushMenuThemes`).
- **Instância única** — mutex nomeado + `RegisterWindowMessage` + `FindWindow`: tentar abrir uma segunda vez traz a janela existente de volta.
- **Multi-app por configuração** — `MUTEX_NAME` e `SHOW_MSG_NAME` incorporam o `CLASS_NAME`, então builds com `CLASS_NAME` diferentes coexistem (um binário por site).
- **Permissões auto-concedidas** — notificações, câmera, microfone, clipboard, geolocalização etc. são liberadas via `add_PermissionRequested` (escopo: origem carregada).
- **WebSocket / SSE amigável** — app fica vivo em bandeja, então conexões persistentes da página continuam recebendo eventos mesmo com a janela fechada (alternativa prática ao FCM Web Push, que não é suportado pelo WebView2).

## Configuração

Todas as constantes ficam no topo de [NV.dpr](NV.dpr):

```pascal
const
  URL            = 'https://conversa.igerp.com/';
  CLASS_NAME     = 'TConversa';
  WINDOWN_TITLE  = 'Conversa';
  WINDOWN_SIZE   : TPoint = (X: 1920; Y: 1080);
```

- `URL` — endereço carregado no WebView.
- `CLASS_NAME` — classe Win32 da janela, também usada como chave única para mutex, mensagem registrada e valor no autorun. Troque para rodar várias "instalações" do mesmo binário apontando para sites diferentes.
- `WINDOWN_TITLE` — título exibido na barra.
- `WINDOWN_SIZE` — tamanho "restaurado" (quando sair de maximizado).

Ícone do executável: edite `NV.res` (recurso `MAINICON`).

## Requisitos

- Delphi 11 ou superior (usa `Winapi.WebView2`, incluído na RTL moderna).
- **WebView2 Runtime** instalado no Windows — já vem com Windows 11 e com Edge Chromium atualizado no Windows 10. Caso precise distribuir, instale o [Evergreen Bootstrapper](https://developer.microsoft.com/microsoft-edge/webview2/) junto.
- `WebView2Loader.dll` ao lado do executável (distribuído com o SDK do WebView2).
- Windows 10 1903+ para os ajustes de menu escuro. Em versões anteriores, os APIs do `uxtheme.dll` retornam `nil` e o menu renderiza no estilo padrão sem crash.

## Como compilar

1. Abra `NV.dproj` no Delphi.
2. Escolha a plataforma (Win32 ou Win64).
3. Build. O executável fica em `Win64\Release\NV.exe` (ou similar).
4. Coloque `WebView2Loader.dll` na mesma pasta do `.exe`.

## Arquitetura

Tudo em um único `.dpr` (~400 linhas), organizado em blocos:

- **Single instance** — mutex + mensagem Win32 registrada antes de `CoInitialize`.
- **Handlers COM do WebView2** — `TEnvironmentHandler`, `TControllerHandler`, `TWebMessageReceivedHandler`, `TPermissionRequestedHandler` (classes `TInterfacedObject` implementando as interfaces do runtime).
- **Bandeja** — `Shell_NotifyIcon` + `CreatePopupMenu` / `TrackPopupMenu`.
- **Tema do sistema** — `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)` + `uxtheme.dll` (ordinais 133/135/136).
- **Sincronização de tema com o site** — script injetado via `AddScriptToExecuteOnDocumentCreated` + `add_WebMessageReceived`.
- **Autorun** — `RegSetValueEx`/`RegDeleteValue` em `HKCU\...\Run` com arg `/tray`.

## Por que não Electron / Tauri / WebView padrão?

- **Binário de ~1MB** em vez de dezenas/centenas.
- **Sem bundler, sem Node, sem Rust toolchain** — só o Delphi.
- Reaproveita o runtime do Edge que a maioria das máquinas Windows já tem instalado, mesmo approach do Tauri no Windows.
- Controle direto sobre a janela nativa (DWM, temas, bandeja, mensagens Win32).

## Licença

MIT
