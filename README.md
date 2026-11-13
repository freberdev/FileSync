# Filsynk

## Vad det är

Filsynk är en liten menyradsapp för macOS (minst macOS 15) som säkerhetskopierar utvalda mappar på Macen till din egen Linux-server med rsync över SSH. Den bevakar mapparna, skickar bara det som ändrats och flyttar det som raderas eller skrivs över undan på servern i stället för att ta bort det. Servern är en backup, inte en arbetsyta: ändringar går bara från Macen till servern, aldrig tillbaka.

## Bygga och installera

```bash
scripts/build-app.sh --install
open /Applications/Filsynk.app
```

Skriptet bygger `build/Filsynk.app`, signerar den lokalt (utan utvecklarcertifikat) och kopierar den till `/Applications`. Utan `--install` byggs bara `build/Filsynk.app`. Appen är inte notariserad och går inte att dela med andra som den är.

"Starta vid inloggning" slås på av sig själv vid första start, men bara om appen körs från `/Applications`. Notisfrågan från macOS kommer första gången en notis ska visas.

## Anslutning

Appen hanterar aldrig serverns lösenord. Den använder en egen SSH-nyckel. Kör detta en gång i Terminal (byt ut adressen mot din):

```bash
ssh-keygen -t ed25519 -N "" -C filsynk -f ~/.ssh/filsynk_ed25519
ssh-copy-id -i ~/.ssh/filsynk_ed25519.pub user@192.168.1.10
```

Lösenordet skriver du bara till `ssh-copy-id`, direkt till `ssh`. Appen ser det aldrig. Nyckeln skapas också av "Testa anslutning" om den saknas.

Skriv sedan serveradressen i Inställningar och tryck **Testa anslutning**. Testet kontrollerar att inloggning fungerar utan fråga, att serverns rsync är version 3 eller senare, och skapar och slår upp mapparna på servern.

- **Inget synkas mot en server förrän testet lyckats mot exakt den adressen.** Ändrar du adressen måste du testa igen.
- En mapp på servern som är hemkatalogen, `/` eller något ovanför hemkatalogen nekas.
- Okända värdnycklar godkänns aldrig automatiskt; `ssh-copy-id` gör värden känd på vanligt sätt.

Avvägning: en nyckel utan lösenfras betyder att den som kommer åt ditt användarkonto på Macen också kan logga in på servern. Det är priset för att synken ska fungera obevakad. Nyckeln är egen för Filsynk, så du kan ta bort dess rad ur `~/.ssh/authorized_keys` på servern utan att något annat påverkas.

Konfigurationen ligger i `~/Library/Application Support/Filsynk/config.json`, loggen i `~/Library/Logs/Filsynk/filsynk.log` ("Visa logg" i menyn). Går `config.json` inte att läsa visar appen ett fel, lämnar filen orörd och låser inställningarna tills filen rättats eller tagits bort och appen startats om.

## Så ser det ut på servern

Mappens innehåll speglas rakt av. `Raderat/` ligger i målmappens toppnivå:

```
/home/user/Sync/               <- spegel av ~/Sync på Macen
  rapport.docx
  Projekt/
    anteckningar.md
  Raderat/                        <- finns bara på servern
    2026-11-17_143205/            <- ett synktillfälle (lokal tid, start)
      rapport.docx                <- föregående version, överskriven
      Projekt/
        gammal.txt                <- raderad på Macen
```

- `Raderat/` rensas bara för hand. Appen tar aldrig bort något på servern.
- Namnet `Raderat` är reserverat i toppnivån av varje bevakad mapp. Finns en sådan mapp på Macen säkerhetskopieras den inte, och appen varnar.

## Återställa

Hämta en fil som den ser ut nu:

```bash
rsync -a user@192.168.1.10:/home/user/Sync/rapport.docx ~/Återställt/
```

Hämta en äldre version eller en raderad fil under `Raderat/`:

```bash
rsync -a user@192.168.1.10:/home/user/Sync/Raderat/2026-11-17_143205/rapport.docx ~/Återställt/
```

`<remotePath>` är den absoluta sökvägen som står i `config.json`. Lägg gärna filen på en annan plats än originalet så att du inte skriver över något av misstag.

## Bra att veta

- **Byta namn på eller flytta en mapp** inuti en bevakad mapp ser ut som radering plus nya filer. Allt under den laddas upp igen och den gamla kopian hamnar i `Raderat/`. Inget går förlorat, men det tar tid och diskutrymme. Samma sak gäller om du byter namn på mappen på servern eller på Macen: det är en borttagning plus en ny mapp.
- **Filer som ändras ofta** ger en undanflyttad kopia per synktillfälle, som mest ungefär en per minut vid standardinställningen.
- **`Raderat/` växer** tills du rensar den för hand.
- **Avslutas appen stannar synken.** Det som ändras under tiden fångas vid nästa start.
- **macOS integritetsskydd:** `~/Sync` kräver inget tillstånd. Läggs Skrivbord, Dokument eller Hämtade filer till frågar macOS om lov en gång.
- **Osignerad app:** appen byggs lokalt och signeras utan utvecklarcertifikat. Det fungerar på den egna Macen men går inte att dela.
- **Första synken in i en mapp på servern som redan har innehåll** flyttar det innehållet till `Raderat/`. Inget försvinner.
- **Dyra nätverk:** automatisk synk väntar tills nättypen är känd vid start och hålls när macOS markerar nätet som dyrt eller begränsat (delning från telefon, lågdataläge). "Synka nu" körs alltid. Går servern inte att nå köas ändringarna och försöks igen (1, 2, 5, 15 minuter, sedan var 15:e) och direkt när nätet ändras.
- Är en mapp osynkad i över ett dygn kommer en notis, en gång per dygn. Nekad inloggning ger notis direkt.

## Tester

```bash
swift test
```

Integrationstesterna för själva synken (`SyncIntegrationTests`) kräver rsync 3.x på Macen (`brew install rsync`) och hoppas annars över. Systemets `/usr/bin/rsync` är `openrsync` och duger inte som mottagare.

Det finns också ett prov hela vägen mot den riktiga servern (`EndToEndTests`), som bara körs när du pekar ut servern och nyckeln:

```bash
FILSYNK_E2E_SERVER=user@192.168.1.10 FILSYNK_E2E_IDENTITY=~/.ssh/filsynk_ed25519 swift test --filter EndToEndTests
```

Det använder en temporär lokal mapp och en egen katalog `~/filsynk-interop-e2e-<slumptal>` på servern, som tas bort efteråt. `~/Sync` rörs aldrig. Skriptet `scripts/verify-rsync-interop.sh <server> <nyckel>` provar bara rsync-flaggorna mot servern.

## Checklista

Gör detta en gång. Anteckna det som inte stämmer.

1. **Installera.** `scripts/build-app.sh --install`, sedan `open /Applications/Filsynk.app`.

2. **Utseende.**
   - Ikonen syns i menyraden och ingen ikon syns i Dock.
   - Menyn har statusrad överst (till exempel "Allt synkat · 14:32"), en rad per mapp, och sedan Synka nu, Pausa (blir Fortsätt), Inställningar…, Visa logg och Avsluta Filsynk.
   - "Visa logg" öppnar `~/Library/Logs/Filsynk/filsynk.log`.

3. **Inställningar** (ta först bort `~/Library/Application Support/Filsynk/config.json`):
   1. Inställningarna öppnas av sig själva med raden `~/Sync → ~/Sync` och tom adress.
   2. Skriv `user@192.168.1.10` och tryck Testa anslutning: `✓ Ansluten, rsync 3.2.7`. `config.json` har nu `remotePath` `/home/user/Sync` och `verifiedServer`.
   3. Ange en adress som inte finns (`x@192.0.2.1`): `Servern nås inte.` inom cirka 10 sekunder.
   4. Lägg till en mapp som ligger inuti `~/Sync`: rött fel, ingenting sparas. Ange `~` som mapp på servern: nekas.
   5. Skriv `node_modules, *.tmp` i Undantag: `config.json` har `"exclude": ["node_modules", "*.tmp"]`.
   (Sätt tillbaka rätt serveradress och testa anslutningen igen efter punkt 3.)

4. **Prov hela vägen** (första gången något skrivs i `~/Sync` på servern). Kontrollera med `ssh user@192.168.1.10 'ls -R ~/Sync'`:

   | # | Gör på Macen | Förväntat |
   |---|---|---|
   | 1 | `echo v1 > ~/Sync/prov.txt` | Ikonen visar väntande och sedan synkat inom cirka 70 s. `prov.txt` finns på servern |
   | 2 | `echo v2 > ~/Sync/prov.txt` | Servern har `v2`. `~/Sync/Raderat/<tid>/prov.txt` innehåller `v1` |
   | 3 | `rm ~/Sync/prov.txt` | Borta ur `~/Sync` på servern. Finns i en ny `Raderat/<tid>/` med `v2` |
   | 4 | Stäng av wifi, `echo x > ~/Sync/offline.txt`, vänta 90 s | Ikonen visar "väntar på servern". Ingen notis |
   | 5 | Slå på wifi | `offline.txt` kommer fram utan att man gör något |
   | 6 | `Pausa`, `echo y > ~/Sync/paus.txt`, vänta 90 s, `Fortsätt` | Inget skickas under pausen. Kommer fram direkt efter `Fortsätt` |
   | 7 | Dela nät från telefon, `echo z > ~/Sync/dyrt.txt`, vänta 90 s | Inget skickas. `Synka nu` skickar den |
   | 8 | På servern: flytta bort raden ur `~/.ssh/authorized_keys`, ändra en fil | Notis `Filsynk: inloggningen nekades`. Lägg tillbaka raden; nästa försök lyckas |
   | 9 | Logga ut och in | Filsynk startar av sig själv |
   | 10 | Låt appen stå orörd i 10 min, läs av i Aktivitetskontroll | CPU 0,0 % i vila, minne under 60 MB |

   Punkt 8 ändrar en fil på servern och görs av dig själv på servern. Ta efteråt bort provfilerna ur `~/Sync` på Macen; de hamnar i `Raderat/` på servern, vilket är avsett.

5. **Om något inte fungerar:**
   - Om punkt 9 inte startar appen (lokalt signerad app): säg till, så byts inloggningsobjektet mot en launchd-agent i `~/Library/LaunchAgents/dev.freber.filsynk.plist`.
   - Om notisen i punkt 8 inte visas: säg till, så byts notiserna mot `osascript -e 'display notification …'`.
   Vilken väg som används antecknas här: _systemets inloggningsobjekt och notiser (ej verifierat än)_.
