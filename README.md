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

Appen hanterar aldrig serverns lösenord. Den använder en egen SSH-nyckel. Kör detta en gång i Terminal (`användare@server` är din egen adress):

```bash
ssh-keygen -t ed25519 -N "" -C filsynk -f ~/.ssh/filsynk_ed25519
ssh-copy-id -i ~/.ssh/filsynk_ed25519.pub användare@server
```

Lösenordet skriver du bara till `ssh-copy-id`, direkt till `ssh`. Appen ser det aldrig. Nyckeln skapas också av "Testa anslutning" om den saknas.

Skriv sedan serveradressen i Inställningar och tryck **Testa anslutning**. Testet kontrollerar att inloggning fungerar utan fråga, att serverns rsync är version 3 eller senare, och skapar och slår upp mapparna på servern.

- **Inget synkas mot en server förrän testet lyckats mot exakt den adressen.** Ändrar du adressen måste du testa igen. Testet sparar också serverns hemkatalog, både med och utan uppslagna symlänkar (`verifiedHome` och `verifiedLogicalHome` i `config.json`).
- En mapp på servern som är hemkatalogen, `/` eller något ovanför hemkatalogen nekas, liksom `~/.ssh` och allt under den och sökvägar med `.` eller `..`. Det gäller även om `config.json` ändras för hand.
- Okända värdnycklar godkänns aldrig automatiskt; `ssh-copy-id` gör värden känd på vanligt sätt.

### Tillåtna tecken

Sökvägen på servern och serveradressen skickas till serverns skal, så bara ofarliga tecken godtas:

- **Sökväg på servern:** bokstäver (även å, ä, ö) och siffror samt `. _ - / + @ , = %`. Ett `~` får bara stå först och följas av `/` eller ingenting (`~/Säkerhetskopia-2026/Mac_1` går bra, `~/R&D` eller `~/Foto*` nekas).
- **Serveradress:** bokstäverna a–z, siffror och `. _ - @ : [ ] %`, och den får inte börja med `-` (`user@192.168.1.10`, `server.example.com`, `user@[fe80::1%en0]`). Ett användarnamn med å, ä eller ö går alltså inte; `användare@server` i exemplen står bara för din egen adress.
- **Nyckelfilen** får inte innehålla mellanslag, citattecken, `$`, `` ` `` eller `\`, och den fullständiga sökvägen (med hemkatalogen i stället för `~`) får inte innehålla mellanslag.
- **Undantag** är vanliga mönster som `node_modules` eller `*.tmp`. Ett undantag får inte vara tomt eller börja med `!`, `+ `, `- `, `: ` eller `. `, eftersom rsync läser sådana rader som regler.
- **Mappar på Macen** får inte innehålla Filsynks egna filer (`~/Library/Logs/Filsynk` och `~/Library/Application Support/Filsynk`); att bevaka hela hemkatalogen nekas därför.

Avvägning: en nyckel utan lösenfras betyder att den som kommer åt ditt användarkonto på Macen också kan logga in på servern. Det är priset för att synken ska fungera obevakad. Nyckeln är egen för Filsynk, så du kan ta bort dess rad ur `~/.ssh/authorized_keys` på servern utan att något annat påverkas.

Konfigurationen ligger i `~/Library/Application Support/Filsynk/config.json`, loggen i `~/Library/Logs/Filsynk/filsynk.log` ("Visa logg" i menyn). Går `config.json` inte att läsa visar appen ett fel, lämnar filen orörd och låser inställningarna tills filen rättats eller tagits bort och appen startats om.

## Lägga till en mapp

Välj mappen med **+** i Inställningar och ange var den ska ligga på servern. Innan något sparas går appen igenom mappen. Finns det något att varna för, till exempel filer som bara ligger i iCloud (de laddas ner vid första synken), fler än 100 000 filer eller en egen mapp `Raderat` i toppnivån, visas varningen med knapparna **Lägg till ändå** och **Avbryt**. Inget sparas och ingen synk startar förrän du valt. Utan varningar läggs mappen till direkt.

## Så ser det ut på servern

Mappens innehåll speglas rakt av. `Raderat/` ligger i målmappens toppnivå:

```
/home/användare/Sync/             <- spegel av ~/Sync på Macen
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
rsync -a användare@server:/home/användare/Sync/rapport.docx ~/Återställt/
```

Hämta en äldre version eller en raderad fil under `Raderat/`:

```bash
rsync -a användare@server:/home/användare/Sync/Raderat/2026-11-17_143205/rapport.docx ~/Återställt/
```

`/home/användare/Sync` står för mappens sökväg på servern, alltså värdet `remotePath` för mappen i `config.json`. Lägg gärna filen på en annan plats än originalet så att du inte skriver över något av misstag.

## Bra att veta

- **Byta namn på eller flytta en mapp** inuti en bevakad mapp ser ut som radering plus nya filer. Allt under den laddas upp igen och den gamla kopian hamnar i `Raderat/`. Inget går förlorat, men det tar tid och diskutrymme. Samma sak gäller om du byter namn på mappen på servern eller på Macen: det är en borttagning plus en ny mapp.
- **Filer som ändras ofta** ger en undanflyttad kopia per synktillfälle, som mest ungefär en per minut vid standardinställningen.
- **`Raderat/` växer** tills du rensar den för hand.
- **Avslutas appen stannar synken.** Det som ändras under tiden fångas vid nästa start.
- **macOS integritetsskydd:** `~/Sync` kräver inget tillstånd. Läggs Skrivbord, Dokument eller Hämtade filer till frågar macOS om lov en gång.
- **Osignerad app:** appen byggs lokalt och signeras utan utvecklarcertifikat. Det fungerar på den egna Macen men går inte att dela.
- **Första synken in i en mapp på servern som redan har innehåll** flyttar det innehållet till `Raderat/`. Inget försvinner.
- **Dyra nätverk:** automatisk synk väntar tills nättypen är känd vid start och hålls när macOS markerar nätet som dyrt eller begränsat (delning från telefon, lågdataläge). "Synka nu" körs alltid. Går servern inte att nå köas ändringarna och försöks igen (1, 2, 5, 15 minuter, sedan var 15:e) och direkt när nätet ändras.
- **Nekad inloggning** ger notis direkt. Därefter försöker appen bara var 15:e minut och inte vid nätbyte, så att servern inte ser en ström av misslyckade inloggningar (fail2ban kan annars stänga ute Macen). "Synka nu", "Fortsätt" och en ändring i Inställningar försöker direkt.
- **Notiser:** misslyckas synken minst tre gånger i rad kommer en notis vid det första riktiga felet i serien (till exempel full disk), en gång per serie. Är en mapp osynkad i över ett dygn kommer en notis, en gång per dygn.
- **Ändrade inställningar** (till exempel undantag) nollställer inte en mapps status. En synk som pågår får bli klar om inget som påverkar den har ändrats.
- **Statusen "Inte inställd"** visas så länge någon mapp inte är inställd, även om andra mappar är synkade.

## Tester

```bash
swift test
```

Integrationstesterna för själva synken (`SyncIntegrationTests`) kräver rsync 3.x på Macen (`brew install rsync`) och hoppas annars över. Systemets `/usr/bin/rsync` är `openrsync` och duger inte som mottagare.

Det finns också ett prov hela vägen mot den riktiga servern (`EndToEndTests`), som bara körs när du pekar ut servern och nyckeln:

```bash
FILSYNK_E2E_SERVER=användare@server FILSYNK_E2E_IDENTITY=~/.ssh/filsynk_ed25519 swift test --filter EndToEndTests
```

Det använder en temporär lokal mapp och en egen katalog `~/filsynk-interop-e2e-<slumptal>` på servern, som tas bort efteråt. `~/Sync` rörs aldrig. Skriptet `scripts/verify-rsync-interop.sh <server> <nyckel>` provar bara rsync-flaggorna mot servern.

## Checklista

Gör detta en gång. Anteckna det som inte stämmer. `användare@server` och `/home/användare` står för din egen server.

1. **Installera.** `scripts/build-app.sh --install`, sedan `open /Applications/Filsynk.app`.

2. **Utseende.**
   - Ikonen syns i menyraden och ingen ikon syns i Dock.
   - Menyn har statusrad överst (till exempel "Allt synkat · 14:32"), en rad per mapp, och sedan Synka nu, Pausa (blir Fortsätt), Inställningar…, Visa logg och Avsluta Filsynk.
   - "Visa logg" öppnar `~/Library/Logs/Filsynk/filsynk.log`.

3. **Inställningar** (ta först bort `~/Library/Application Support/Filsynk/config.json`):
   1. Inställningarna öppnas av sig själva med raden `~/Sync → ~/Sync`, tom adress och en kort vägledning under Server.
   2. Skriv `användare@server` och tryck Testa anslutning: `✓ Ansluten, rsync 3.x.y`. `config.json` har nu `remotePath` `/home/användare/Sync`, `verifiedServer`, `verifiedHome` och `verifiedLogicalHome`. Kolumnen "På servern" visar `~/Sync`.
   3. Ange en adress som inte finns (`x@192.0.2.1`): `Servern nås inte.` inom cirka 10 sekunder. Ange `x@h;ls`: rött fel, ingenting sparas.
   4. Lägg till en mapp som ligger inuti `~/Sync`: rött fel, ingenting sparas. Ange `~` eller `~/R&D` som mapp på servern: nekas.
   5. Lägg till en mapp med filer som bara finns i iCloud (eller en egen mapp `Raderat` i toppnivån): varningen visas med Lägg till ändå och Avbryt. Avbryt sparar ingenting; Lägg till ändå lägger till mappen och synken startar först då.
   6. Skriv `node_modules, *.tmp` i Undantag: `config.json` har `"exclude": ["node_modules", "*.tmp"]`. Skriv `!` i Undantag: rött fel, ingenting sparas.
   (Sätt tillbaka rätt serveradress och testa anslutningen igen efter punkt 3.)

4. **Prov hela vägen** (första gången något skrivs i `~/Sync` på servern). Det som kontrolleras på servern görs med `ssh användare@server 'ls -R ~/Sync'` eller `cat`:

   | # | Gör på Macen | Förväntat |
   |---|---|---|
   | 1 | `echo v1 > ~/Sync/prov.txt` | Ikonen visar väntande och sedan synkat inom cirka 70 s. På servern finns `prov.txt` |
   | 2 | `echo v2 > ~/Sync/prov.txt` | På servern innehåller `prov.txt` `v2` och `~/Sync/Raderat/<tid>/prov.txt` innehåller `v1` |
   | 3 | `rm ~/Sync/prov.txt` | På servern är `prov.txt` borta ur `~/Sync` och finns i en ny `Raderat/<tid>/` med `v2` |
   | 4 | Stäng av wifi, `echo x > ~/Sync/offline.txt`, vänta 90 s | Ikonen visar "väntar på servern". Ingen notis |
   | 5 | Slå på wifi | På servern kommer `offline.txt` fram utan att man gör något |
   | 6 | `Pausa`, `echo y > ~/Sync/paus.txt`, vänta 90 s, `Fortsätt` | På servern finns ingen `paus.txt` under pausen. Den kommer fram direkt efter `Fortsätt` |
   | 7 | Dela nät från telefon, `echo z > ~/Sync/dyrt.txt`, vänta 90 s | På servern finns ingen `dyrt.txt`. `Synka nu` skickar den |
   | 8 | `echo l > ~/Sync/lock.txt`, stäng locket inom 30 s, vänta några minuter, öppna | På servern kommer `lock.txt` fram inom ungefär en minut efter att locket öppnats |
   | 9 | På servern: flytta bort raden ur `~/.ssh/authorized_keys`, ändra en fil på Macen | Notis `Filsynk: inloggningen nekades`. Lägg tillbaka raden på servern och tryck `Synka nu`; synken lyckas |
   | 10 | Logga ut och in | Filsynk startar av sig själv |
   | 11 | Låt appen stå orörd i 10 min, läs av i Aktivitetskontroll | CPU 0,0 % i vila, minne under 60 MB |

   Punkt 9 ändrar `authorized_keys` på servern och görs för hand där. Ta efteråt bort provfilerna ur `~/Sync` på Macen; de hamnar i `Raderat/` på servern, vilket är avsett.

5. **Felsökning:**
   - Om appen inte startar vid inloggning: kontrollera under Systeminställningar > Allmänt > Inloggningsobjekt att Filsynk finns och är påslagen, och att appen ligger i `/Applications`. Slå av och på "Starta vid inloggning" i Filsynks inställningar för att registrera den igen.
   - Om notiserna inte visas: kontrollera att Filsynk får visa notiser under Systeminställningar > Notiser. Varje notis skrivs också i loggen, så den går att läsa där via "Visa logg".
