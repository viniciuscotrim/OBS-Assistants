# OBS Assistants

App de menu bar para macOS (SwiftUI) com overlays locais para **OBS Browser
Source** — cada um com seu próprio servidor HTTP embutido, todos rodando
juntos no mesmo app:

- **Impressora (Bambu Lab)** — conecta via MQTT à impressora na rede local e
  expõe o status de impressão (progresso, temperaturas, secagem do AMS,
  etc.) como overlay web.
- **Bambu Studio** — overlay separado com detalhes de fatiamento lidos de um
  `.3mf` local.
- **Now Playing (Music.app)** — lê a faixa em reprodução no Music.app e
  expõe um overlay web (capa do álbum, progresso, marquee) para o OBS,
  incluindo a opção "Music só no streaming" (silencia o Music.app nos seus
  alto-falantes e transmite o áudio real direto pelo overlay via WebSocket).

Cada overlay é servido no seu próprio processo/porta local (impressora e
Bambu Studio compartilham um servidor, Now Playing tem o seu próprio) —
veja `Sources/OBSAssistants/HTTPServer` e `Sources/OBSAssistants/NowPlaying`.
