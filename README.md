# Riepilogo Iliad (macOS)

App nativa per macOS che mostra quanto traffico resta alle SIM Iliad Italia, con notifiche e storico.

## Requisiti

- macOS 15 o successivo.
- Xcode con Swift 6 (sviluppata e testata con Xcode 27).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), per generare il progetto: `brew install xcodegen`.

Il `.xcodeproj` non è committato: `make generate` lo ricrea da `project.yml`.

## Build e avvio

1. `make generate && make build`
2. `make run` (oppure apri `build/Build/Products/Debug/RiepilogoIliad.app`)

I test si lanciano con `make test`. I test non toccano dati reali: la suite è ospitata
nell'app (app-hosted) e `RiepilogoIliadApp` salta del tutto l'avvio quando gira sotto XCTest,
quindi `make test` non apre il database in `Application Support`, non accede al Portachiavi,
non tocca Safari e non mostra icone né richieste di notifiche.

## Prima configurazione

1. Apri il popover dall'icona nella barra dei menu → ingranaggio (Impostazioni).
2. Aggiungi le SIM (nome, ID utente, password). Le password finiscono nel Portachiavi.
   Il nome è la chiave con cui l'app riconosce la SIM (è la colonna `account` nel database),
   quindi **deve essere unico**: vuoto o doppio, anche solo di lettere ("SIM 1" e "sim 1"),
   viene rifiutato. Aggiungere, rinominare o togliere una SIM aggiorna il popover subito.
3. (Opzionale) "Importa account da config.yaml" e "Importa storico da iliad.db" per migrare dalla app Go.
4. Attiva "Apri al login" e "Notifiche" se vuoi.

Le password non passano mai da `UserDefaults` né dal database: vanno nel Portachiavi di login, con
servizio `riepilogo-iliad` e una voce per SIM (chiave = id della SIM). "Importa account da config.yaml"
accetta il `config.yaml` della app Go (stesse chiavi `accounts`, `renewal_day`, `refresh_interval`),
unisce le SIM per nome e scrive le password importate nel Portachiavi. "Importa storico da iliad.db"
sostituisce il database con quello della app Go (schema identico) e salva il precedente in
`iliad.db.bak`. Il file viene scambiato mentre l'app è aperta, quindi dopo l'import **esci e riapri**:
la connessione già aperta sul database comincia a fallire dopo lo scambio.

Se il database non si apre (file corrotto o import sbagliato), tutte le finestre — popover,
Impostazioni, Storico — mostrano l'errore e il percorso del file, con il pulsante **"Sposta il
database"**: il database e i suoi file di supporto (`-wal`, `-shm`) vengono **rinominati** con un
suffisso `.bak` con data e ora (niente viene cancellato) e al prossimo avvio l'app ne crea uno
vuoto. Dopo averlo spostato, **esci e riapri**.

## Modalità di aggiornamento

La modalità si sceglie in Impostazioni → Aggiornamento → "Modalità":

- **Automatico (diretto → Safari)** (predefinita): prima prova la connessione diretta via HTTP; se la
  rete la blocca passa da Safari. Il fallback scatta **solo** sugli errori di rete: un errore di
  autenticazione o di parsing non lo attiva, perché fallirebbe uguale.
- **Solo diretto (HTTP)**: niente Safari, mai.
- **Solo Safari**: niente HTTP diretto.

L'intervallo si sceglie con lo stesso picker: 1, 2, 4, 6, 8, 12 o 24 ore (4 ore di default, minimo 1 ora).
Cambiarlo prende effetto subito: l'attesa in corso viene annullata e riparte con il nuovo intervallo,
senza aspettare la fine del sonno precedente.

L'app controlla anche quando il Mac si risveglia: se l'ultimo aggiornamento risale a più di due intervalli
lo rilancia subito, altrimenti non fa nulla e lascia lavorare il timer. Serve al portatile che dorme
più di un intervallo — l'attesa in corso riprende al risveglio, ma senza questo controllo i dati
mostrati sarebbero vecchi.

"Verifica account" è disattivato mentre un aggiornamento è in corso: i due percorsi userebbero la
stessa scheda di Safari, e il logout della verifica invaliderebbe la sessione dell'aggiornamento
facendo segnalare un falso "credenziali non valide". Se capita comunque, la verifica risponde
"Aggiornamento in corso. Riprova tra poco." — non un errore di autenticazione.

## Rete bloccata (hotspot Iliad)

La modalità automatica prova prima la connessione diretta e, se bloccata, passa da Safari.
Per il fallback serve una volta sola: Safari → Impostazioni → Avanzate → "Mostra funzioni per sviluppatori web",
poi menu Sviluppo → "Consenti JavaScript dagli eventi Apple". Al primo uso macOS chiederà il permesso di controllare Safari.

Il fallback usa Safari perché è il browser a poter passare dal Wi-Fi dell'hotspot alla rete mobile:
lo script riusa una scheda già aperta su iliad.it, altrimenti ne apre una nuova su
`www.iliad.it/account/login`, e da lì esegue la stessa richiesta della app in pagina. Servono quindi
Safari utilizzabile dall'app e l'opzione JavaScript attiva; senza l'opzione l'app lo segnala e la
lettura fallisce.

## Dove stanno i dati

- Database: `~/Library/Application Support/RiepilogoIliad/iliad.db` (SQLite, schema identico a quello
  della app Go, così lo storico si migra senza conversioni).
- Le letture più vecchie di **180 giorni** vengono cancellate all'avvio dell'app.
- Impostazioni (SIM, intervallo, modalità, soglia notifiche) in `UserDefaults`; password nel Portachiavi.

Ogni scheda del popover mostra anche lo **sparkline a 7 giorni** del dato residuo e due badge:
rosso quando l'ultimo aggiornamento è fallito (i valori mostrati restano quelli dell'ultima
lettura riuscita), arancione quando l'ultima lettura riuscita ha più di due intervalli. In fondo al
popover c'è la data dell'ultimo aggiornamento.

La finestra "Storico" mostra il grafico degli ultimi 30 giorni della SIM scelta, con gli ultimi 14 giorni
in tabella.

## Note

- Nessun server locale: l'app parla solo con iliad.it (direttamente o tramite Safari).
- Progetto non affiliato a Iliad Italia S.p.A.

## Checklist di accettazione manuale

Da fare a mano sulla Mac, con `make run`:

1. `make run` → icona nella barra dei menu; il popover mostra le SIM (dopo il primo aggiornamento).
2. Sull'hotspot: il primo aggiornamento ricade su Safari (compare/attiva una scheda su iliad.it) e i dati arrivano.
3. Su rete normale (o con Modalità = "Solo diretto (HTTP)"): l'aggiornamento usa HTTP diretto, Safari intatto.
4. "Verifica account" mostra una riga per SIM con l'esito e il trasporto usato (`direct`/`safari`).
5. Forza una lettura bassa (o alza la soglia) → arriva una notifica.
6. Attiva "Apri al login" → l'app compare in Impostazioni di Sistema → Generali → Elementi di login.
7. "Importa storico" da iliad.db → il grafico dello storico mostra i dati della app Go.
8. Esci e riapri → gli ultimi dati compaiono subito, l'aggiornamento parte in background.
