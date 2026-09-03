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
  incluindo transmitir o áudio real do Music.app pelo overlay via WebSocket
  (com a opção de também silenciá-lo no Mac, ou deixar tocando normalmente
  enquanto transmite).

Cada um dos três overlays tem seu próprio servidor HTTP local independente
(própria porta, próprio Start/Stop) — todos começam parados; você inicia só
o(s) que for usar no OBS, no menu da barra ("Servidores"). Veja
`Sources/OBSAssistants/HTTPServer` e `Sources/OBSAssistants/NowPlaying`.
