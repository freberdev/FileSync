# Filsynk

## Vad det är

Filsynk är en liten menyradsapp för macOS (minst macOS 15) som säkerhetskopierar utvalda mappar på Macen till din egen Linux-server med rsync över SSH, och till en eller flera externa diskar. Den bevakar mapparna, skickar bara det som ändrats och flyttar det som raderas eller skrivs över undan i stället för att ta bort det. Servern och disken är backuper, inte arbetsytor: ändringar går bara från Macen till målet, aldrig tillbaka.

## Bygga och installera

```bash
scripts/build-app.sh --install
open /Applications/Filsynk.app
```

Skriptet bygger `build/Filsynk.app`, signerar den och kopierar den till `/Applications`. Utan `--install` byggs bara `build/Filsynk.app`. Appen är inte notariserad och går inte att dela med andra som den är.

Appikonen ligger i `Resources/AppIcon.icns` och ritas av `swift scripts/make-icon.swift`. Kör skriptet igen om du ändrar ritningen.

"Starta vid inloggning" slås på av sig själv vid första start, men bara om appen körs från `/Applications`. Notisfrågan från macOS kommer första gången en notis ska visas.

### Diskavbild

```bash
scripts/build-dmg.sh
```

Skriptet bygger appen och lägger den i `build/Filsynk-<version>.dmg` tillsammans med en genväg till Program. Öppna filen och dra Filsynk till Program.

### Release på GitHub

Varje push till `main`, alltså också varje merge dit, kör testerna på GitHub, bygger diskavbilden och lägger upp den som en release med namnet `v<version>-<körningens nummer>`. Ändras bara dokumentation (`*.md` och `docs/`) körs ingenting. Flödet ligger i `.github/workflows/release.yml`.

Bra att veta om en nedladdad diskavbild:

- **Den är signerad utan certifikat och inte notariserad.** Första gången vägrar macOS öppna appen. Gå till Systeminställningar → Integritet och säkerhet och välj **Öppna ändå**.
- **Tillstånden frågas om för varje ny version**, eftersom varje bygge utan certifikat räknas som en ny app. Bygger du själv med certifikat, se Signering nedan, ligger de kvar.
- **Den är byggd för Apple Silicon.**
- **Versionen** kommer från `CFBundleShortVersionString` i `Resources/Info.plist`.

## Signering

Byggskriptet signerar alltid appen. Frågan är bara om det sker med eller utan certifikat. Appen fungerar lika bra i båda fallen.

### Varför signera med certifikat

- **Utan certifikat** ser macOS varje nytt bygge som en ny app. Tillstånden för notiser, start vid inloggning, det lokala nätverket och skyddade mappar som Dokument kan då behöva ges om efter varje ombyggnad.
- **Med certifikat** knyts tillstånden till teamet och appens id (`com.freberdev.filsynk`) i stället för till det enskilda bygget, och ligger kvar mellan byggen. Under Inloggningsobjekt står appen med utvecklarens namn.

Skriptet notariserar inte appen. Den går alltså inte att dela med andra som den är, med eller utan certifikat.

### Vilket certifikat

- **Apple Development** räcker för den egna Macen. Xcode skapar det under Settings > Accounts > Manage Certificates > `+` > Apple Development. Det gäller i ett år.
- **Developer ID Application** krävs för att köra appen på en annan dator utan varningar, tillsammans med notarisering. Det förutsätter ett betalt utvecklarkonto, och bara kontoinnehavaren kan skapa det.

### Hitta certifikatets namn och hash

```bash
security find-identity -v -p codesigning
```

Utskriften har en rad per giltigt certifikat:

```
  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Ditt Namn (ABCDE12345)"
     1 valid identities found
```

De 40 tecknen först är hashen, och texten inom citattecken är namnet. Båda går att använda.

Finns det flera certifikat, för olika team, väljer du det team appen ska höra till. Vilket team ett certifikat tillhör syns i fälten `O` (organisation) och `OU` (team-id):

```bash
security find-certificate -c "Apple Development: Ditt Namn (ABCDE12345)" -p | openssl x509 -noout -subject
```

### Ange certifikatet

Det finns två sätt. Miljövariabeln går före filen. Någon `.env`-fil läses inte.

**1. Filen `.signing-identity`** i projektmappen, alltså samma mapp som `Package.swift`. Första raden ska vara certifikatets namn eller hash, och inget annat. Filen ignoreras av git och checkas aldrig in.

```bash
echo "0123456789ABCDEF0123456789ABCDEF01234567" > .signing-identity
```

Därefter signerar `scripts/build-app.sh` med certifikatet varje gång, utan fler åtgärder.

**2. Miljövariabeln `FILSYNK_SIGN_IDENTITY`**, för ett enstaka bygge:

```bash
FILSYNK_SIGN_IDENTITY="Apple Development: Ditt Namn (ABCDE12345)" scripts/build-app.sh --install
```

Ska den gälla alltid lägger du raden `export FILSYNK_SIGN_IDENTITY="…"` i `~/.zshrc`.

För att gå tillbaka till signering utan certifikat tar du bort `.signing-identity`, eller sätter `FILSYNK_SIGN_IDENTITY=-` för ett enstaka bygge.

**Namn eller hash?** Hashen pekar alltid ut exakt ett certifikat, men den byts när certifikatet förnyas. Namnet brukar överleva en förnyelse, men det fungerar inte om två certifikat har samma namn.

### Kontrollera signaturen

Byggskriptet avslutar med `(signed with a certificate)` eller `(signed ad hoc)`. Den installerade appen kontrolleras så här:

```bash
codesign -dv --verbose=2 /Applications/Filsynk.app
```

- Med certifikat: `Authority=Apple Development: …` och `TeamIdentifier=` följt av team-id.
- Utan certifikat: `Signature=adhoc` och `TeamIdentifier=not set`.

```bash
codesign --verify --strict /Applications/Filsynk.app
```

Ingen utskrift betyder att signaturen är giltig.

### Efter första bygget med certifikat

Första gången appen signeras med ett certifikat räknar macOS den som en ny app. Detsamma gäller om du byter certifikat, team eller appens id. Gör då detta en gång:

1. Slå på "Starta vid inloggning" i Filsynks inställningar. Det slås bara på av sig självt vid allra första start.
2. Titta under Systeminställningar > Allmänt > Inloggningsobjekt och ta bort en eventuell äldre Filsynk-post.
3. Godkänn notiser när macOS frågar, vilket sker första gången en notis ska visas.

Därefter ligger tillstånden kvar mellan byggen.

### Felsökning

| Meddelande | Orsak och åtgärd |
|---|---|
| `no identity found` | Namnet eller hashen stämmer inte, eller certifikatet har gått ut. Kör `security find-identity -v -p codesigning` och rätta `.signing-identity`. Har certifikatet gått ut förnyar du det i Xcode. Bygget avbryts, och ingen osignerad app installeras i stället. |
| `ambiguous (matches … and …)` | Flera certifikat matchar namnet. Ange hashen i stället. |
| macOS frågar om `codesign` får använda nyckeln | Välj Tillåt alltid. |
| `errSecInternalComponent` | Nyckelringen är låst, till exempel vid inloggning över SSH. Lås upp den med `security unlock-keychain`. |

## Anslutning

Appen loggar in på servern med en egen SSH-nyckel och hanterar aldrig serverns lösenord. Nyckeln läggs upp en gång, i fem steg. I exemplen står `användare@server` för din egen adress, till exempel `anna@192.168.1.10`.

### Förutsättningar

- Servern kör en SSH-server och har rsync version 3 eller senare. På Ubuntu och Debian installeras båda med `sudo apt install openssh-server rsync`.
- Du kan logga in på servern från Macen, med lösenord eller med en nyckel du redan har.

### 1. Kontrollera att servern går att nå

```bash
ssh användare@server 'echo ansluten; rsync --version | head -1'
```

Första gången frågar `ssh` om serverns värdnyckel ska godkännas. Svara `yes`. Därefter skriver du lösenordet. Utskriften ska sluta så här:

```
ansluten
rsync  version 3.2.7  protocol version 31
```

Står det `openrsync` eller en version under 3 fungerar inte servern som mål.

### 2. Skapa nyckeln

```bash
ssh-keygen -t ed25519 -N "" -C filsynk -f ~/.ssh/filsynk_ed25519
```

- `-t ed25519` väljer nyckeltyp.
- `-N ""` ger en nyckel utan lösenfras, vilket krävs för att synken ska gå obevakad.
- `-C filsynk` sätter en kommentar som gör nyckeln lätt att känna igen på servern.
- `-f` anger var nyckeln sparas.

Kommandot skapar två filer: den privata nyckeln `~/.ssh/filsynk_ed25519`, som aldrig lämnar Macen, och den publika `~/.ssh/filsynk_ed25519.pub`, som läggs på servern. Finns filen redan frågar `ssh-keygen` innan något skrivs över; svara då `n` och använd den befintliga.

Appen skapar nyckeln själv när du trycker Testa anslutning, om den saknas. Steget kan alltså hoppas över.

### 3. Lägg den publika nyckeln på servern

```bash
ssh-copy-id -i ~/.ssh/filsynk_ed25519.pub användare@server
```

Här skriver du serverns lösenord en sista gång, direkt till `ssh`. Appen ser det aldrig. Kommandot lägger till en rad i `~/.ssh/authorized_keys` på servern.

Om `ssh-copy-id` inte går att använda gör det här samma sak:

```bash
cat ~/.ssh/filsynk_ed25519.pub | ssh användare@server 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

### 4. Kontrollera att nyckeln fungerar utan frågor

Det här är samma inloggning som appen gör:

```bash
ssh -i ~/.ssh/filsynk_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 användare@server 'echo ansluten; rsync --version | head -1'
```

Utskriften ska vara densamma som i steg 1, utan att något lösenord efterfrågas. `BatchMode=yes` gör att `ssh` misslyckas i stället för att fråga, precis som i appen.

### 5. Anslut i appen

Skriv serveradressen i Inställningar och tryck **Testa anslutning**. Testet kontrollerar att inloggningen fungerar utan fråga och att serverns rsync är version 3 eller senare, och det skapar och slår upp mapparna på servern. Lyckas det står det `✓ Ansluten, rsync 3.x.y`.

- **Inget synkas mot en server förrän testet lyckats mot exakt den adressen.** Ändrar du adressen måste du testa igen. Testet sparar också serverns hemkatalog, både med och utan uppslagna symlänkar (`verifiedHome` och `verifiedLogicalHome` i `config.json`).
- En mapp på servern som är hemkatalogen, `/` eller något ovanför hemkatalogen nekas, liksom `~/.ssh` och allt under den och sökvägar med `.` eller `..`. Det gäller även om `config.json` ändras för hand.
- Okända värdnycklar godkänns aldrig automatiskt. Steg 1 gör servern känd på vanligt sätt.

### Annan port, annat namn eller åtkomst utifrån

Appen anropar det vanliga `ssh`, som läser `~/.ssh/config`. Lägg in servern där om den lyssnar på en annan port än 22, eller om du vill kunna nå den under samma namn både hemma och borta:

```
Host minserver
    HostName 192.168.1.10
    User anna
    Port 2222
```

Skriv sedan `minserver` som adress i appen. Kontrollera först med `ssh minserver` att uppgifterna stämmer.

Att nå en server på hemmanätet utifrån kräver VPN eller liknande, och det ligger utanför appen. Går servern inte att nå köas ändringarna tills den gör det.

### Se, byta eller dra in nyckeln

Se att nyckeln ligger på servern:

```bash
ssh användare@server 'grep filsynk ~/.ssh/authorized_keys'
```

Se nyckelns fingeravtryck på Macen:

```bash
ssh-keygen -lf ~/.ssh/filsynk_ed25519.pub
```

Dra in nyckeln, så att den inte längre kan logga in. Kommandot tar bort raden på servern och sparar den gamla filen som `authorized_keys.bak`:

```bash
ssh användare@server "sed -i.bak '/ filsynk\$/d' ~/.ssh/authorized_keys"
```

Ta därefter bort nyckeln på Macen:

```bash
rm ~/.ssh/filsynk_ed25519 ~/.ssh/filsynk_ed25519.pub
```

Byta nyckel gör du genom att dra in den gamla och gå igenom steg 2 till 5 igen.

### Felsökning av anslutningen

| Det här händer | Orsak och åtgärd |
|---|---|
| Appen visar "Servern accepterar inte nyckeln ännu" | Den publika nyckeln ligger inte på servern, eller så är adressens användarnamn fel. Gör steg 3 och 4. |
| Steg 4 ger `Permission denied (publickey,password)` | Samma sak. Kontrollera också rättigheterna på servern: `~/.ssh` ska vara `700` och `~/.ssh/authorized_keys` `600`, och hemkatalogen får inte vara skrivbar för andra. |
| `Host key verification failed` | Servern är okänd för Macen, eller har bytt värdnyckel efter en ominstallation. Logga in en gång för hand med `ssh användare@server`. Har servern bytt nyckel tar du först bort den gamla med `ssh-keygen -R server`. |
| Appen visar "Servern nås inte" | Fel adress, servern är avstängd eller så är du på ett annat nät. `nc -z -G 5 server 22` visar om porten går att nå. |
| Appen visar "Servern behöver rsync 3 eller senare" | Installera rsync på servern, se Förutsättningar. |
| Inget hjälper | Lägg till `-v` i kommandot i steg 4. Då skriver `ssh` ut varje steg i inloggningen. |

### Tillåtna tecken

Sökvägen på servern och serveradressen skickas till serverns skal, så bara ofarliga tecken godtas:

- **Sökväg på servern:** bokstäver (även å, ä, ö) och siffror samt `. _ - / + @ , = %`. Ett `~` får bara stå först och följas av `/` eller ingenting (`~/Säkerhetskopia-2026/Mac_1` går bra, `~/R&D` eller `~/Foto*` nekas).
- **Serveradress:** bokstäverna a–z, siffror och `. _ - @ : [ ] %`, och den får inte börja med `-` (`user@192.168.1.10`, `server.example.com`, `user@[fe80::1%en0]`). Ett användarnamn med å, ä eller ö går alltså inte; `användare@server` i exemplen står bara för din egen adress.
- **Nyckelfilen** får inte innehålla mellanslag, citattecken, `$`, `` ` `` eller `\`, och den fullständiga sökvägen (med hemkatalogen i stället för `~`) får inte innehålla mellanslag.
- **Undantag** är vanliga mönster som `node_modules` eller `*.tmp`. Ett undantag får inte vara tomt eller börja med `!`, `+ `, `- `, `: ` eller `. `, eftersom rsync läser sådana rader som regler.
- **Mappar på Macen** får inte innehålla Filsynks egna filer (`~/Library/Logs/Filsynk` och `~/Library/Application Support/Filsynk`); att bevaka hela hemkatalogen nekas därför.

Avvägning: en nyckel utan lösenfras betyder att den som kommer åt ditt användarkonto på Macen också kan logga in på servern. Det är priset för att synken ska fungera obevakad. Nyckeln är egen för Filsynk, så du kan ta bort dess rad ur `~/.ssh/authorized_keys` på servern utan att något annat påverkas.

Konfigurationen ligger i `~/Library/Application Support/Filsynk/config.json`. Varje mapp har en lista `destinations` med ett mål per post: `{"kind":"server","path":…}` eller `{"kind":"disk","volumeUUID":…,"volumeName":…,"path":…}`. En äldre fil med `remotePath` läses och skrivs om i den nya formen nästa gång något sparas. Loggen ligger i `~/Library/Logs/Filsynk/filsynk.log` ("Visa logg" i menyn). Går `config.json` inte att läsa visar appen ett fel, lämnar filen orörd och låser inställningarna tills filen rättats eller tagits bort och appen startats om.

## Lägga till en mapp

En mapp kan ha flera mål: ett på servern och hur många externa diskar som helst. Tabellen i Inställningar har en rad per mål.

Tryck **+** i Inställningar. Under **Mapp på Macen** väljer du en mapp som redan bevakas eller **Välj mapp…**. Under **Mål** väljer du **Server** eller **Extern disk**:

- **Server:** ange var mappen ska ligga på servern (förifyllt med `~/` och mappens namn).
- **Extern disk:** tryck **Välj mapp på disken…** och välj eller skapa en ny, tom mapp på disken. Se Extern disk nedan.

Tryck sedan **Lägg till**. En mapp som inte redan bevakas går appen igenom innan något sparas. Finns det något att varna för, till exempel filer som bara ligger i iCloud (de laddas ner vid första synken), fler än 100 000 filer eller en egen mapp `Raderat` i toppnivån, visas varningen med knapparna **Lägg till ändå** och **Avbryt**. Inget sparas och ingen synk startar förrän du valt. Utan varningar läggs målet till direkt.

**–** tar bort det markerade målet ur appen. Inget tas bort på servern eller disken. Försvinner mappens sista mål bevakas den inte längre.

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

`/home/användare/Sync` står för mappens sökväg på servern, alltså `path` i mappens mål av slaget `server` i `config.json`. Lägg gärna filen på en annan plats än originalet så att du inte skriver över något av misstag.

## Extern disk

Samma mapp kan speglas till en extern disk, vid sidan av servern eller i stället för den. Disken fungerar som servern: innehållet speglas, och det som raderas eller skrivs över flyttas till `Raderat/`.

### Lägga till

Inställningar → Mappar → **+** → **Extern disk** → **Välj mapp på disken…**. Mappen på disken måste vara ny och tom; Finders egna dolda filer (`.DS_Store` och `._*`) räknas inte. Skapa den i väljaren med **Ny mapp**. Disken själv, alltså dess rot, går inte att välja.

Appen lägger en liten fil, `.filsynk`, i mappen. Den anger vilken mapp på Macen som hör till mappen på disken. Appen synkar aldrig in i en mapp som saknar filen eller vars fil hör till en annan mapp, och en mapp med innehåll godtas bara om dess fil hör till just den här mappen. Att en mapp byter namn på Macen räknas som en annan mapp: den kan inte återanvända sin gamla mapp på disken, välj en ny.

Disken ska vara formaterad som APFS, Mac OS Extended eller exFAT.

### Så känns disken igen

Disken känns igen på sitt volym-id, aldrig på namnet. Kopplar du in en annan disk med samma namn händer ingenting. En disk som formaterats om eller bytts ut är en ny disk, och målet måste läggas till igen. Namnet i tabellen och i menyn är bara en visning.

### Inkoppling och utmatning

- När den valda disken kopplas in synkas den direkt.
- Medan disken är inkopplad följer den samma väntetid som servern.
- När disken inte är inkopplad visar raden `Inte inkopplad · senast <datum>` och inget försöks. Menyradens ikon påverkas inte av en frånvarande disk.
- Vid utmatning avbryts en pågående synk, så att disken går att mata ut. Nekar macOS utmatningen återupptar appen synken efter ungefär en minut.
- En bevakad mapp som själv ligger på en extern disk synkas inte medan den disken är frånkopplad.

### Format

- **APFS och Mac OS Extended** behåller rättigheter och ägare.
- **exFAT** behåller inte rättigheter och ägare. Symboliska länkar och alla filnamn fungerar. macOS skapar en fil på 4 kB, `._<namn>`, bredvid varje fil på exFAT. Appen ignorerar dem.

### Raderat på disken

`Raderat/<tidpunkt>/` i mappen på disken fungerar som på servern: raderade och överskrivna filer flyttas dit, ingenting tas bort, och mappen rensas bara för hand. En fil som ersätts av en mapp eller länk med samma namn flyttas också dit först. Begränsning: en symbolisk länk vars mål ändras ersätts utan att den gamla länken sparas.

### Tillstånd

Första gången appen når en extern disk frågar macOS om tillstånd för flyttbara volymer. Svara Tillåt.

## Bra att veta

- **Byta namn på eller flytta en mapp** inuti en bevakad mapp ser ut som radering plus nya filer. Allt under den laddas upp igen och den gamla kopian hamnar i `Raderat/`. Inget går förlorat, men det tar tid och diskutrymme. Samma sak gäller om du byter namn på mappen på servern eller på disken, eller på Macen: det är en borttagning plus en ny mapp. Byts namnet på mappen på Macen hör dessutom markören på disken till den gamla mappen, så ett nytt mål på disken måste läggas till.
- **Filer som ändras ofta** ger en undanflyttad kopia per synktillfälle, som mest ungefär en per minut vid standardinställningen.
- **`Raderat/` växer**, på servern och på disken, tills du rensar den för hand.
- **Avslutas appen stannar synken.** Det som ändras under tiden fångas vid nästa start.
- **macOS integritetsskydd:** `~/Sync` kräver inget tillstånd. Läggs Skrivbord, Dokument eller Hämtade filer till frågar macOS om lov en gång.
- **Osignerad app:** appen byggs lokalt och signeras utan utvecklarcertifikat. Det fungerar på den egna Macen men går inte att dela.
- **Första synken in i en mapp på servern som redan har innehåll** flyttar det innehållet till `Raderat/`. Inget försvinner.
- **Dyra nätverk:** automatisk synk väntar tills nättypen är känd vid start och hålls när macOS markerar nätet som dyrt eller begränsat (delning från telefon, lågdataläge). "Synka nu" körs alltid. Går servern inte att nå köas ändringarna och försöks igen (1, 2, 5, 15 minuter, sedan var 15:e) och direkt när nätet ändras.
- **Nekad inloggning** ger notis direkt. Därefter försöker appen bara var 15:e minut och inte vid nätbyte, så att servern inte ser en ström av misslyckade inloggningar (fail2ban kan annars stänga ute Macen). "Synka nu", "Fortsätt" och en ändring i Inställningar försöker direkt.
- **Notiser:** misslyckas synken minst tre gånger i rad kommer en notis vid det första riktiga felet i serien (till exempel full disk), en gång per serie. Har en mapp inte synkats till servern på över ett dygn kommer en notis, en gång per dygn. En disk som inte är inkopplad ger ingen sådan notis.
- **Ändrade inställningar** (till exempel undantag) nollställer inte en mapps status. En synk som pågår får bli klar om inget som påverkar den har ändrats.
- **Statusen "Inte inställd"** visas så länge någon mapp inte är inställd, även om andra mappar är synkade.
- **Frånkopplad disk** ger raden `Inte inkopplad`. Är disken det enda som är kvar att synka visar menyn "Disken är inte inkopplad"; är något annat mål inkopplat gäller statusen för det.

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

Ytterligare ett prov kör hela kedjan mot riktiga volymer, utan någon fysisk disk (`DiskImageTests`). Det skapar egna diskavbilder (APFS och exFAT, 40 MB) i en temporär katalog, monterar dem där med `hdiutil attach -mountrandom` och kopplar loss dem igen efteråt. Så hamnar inget under `/Volumes` och en riktig extern disk rörs aldrig. Det provar synk till båda formaten, att överskrivna och raderade filer hamnar i `Raderat/`, svenska filnamn och symboliska länkar på exFAT, att en disk som kopplas in igen hämtar ikapp av sig själv, och att en annan avbild med samma namn men annat id lämnas ifred. Det körs bara när du ber om det:

```bash
FILSYNK_DISK_IMAGE_TESTS=1 swift test --filter DiskImageTests
```

Avbilderna monteras utan `-nobrowse`, eftersom Filsynk inte ser dolda volymer. Det tar ungefär en minut och en avbild kan synas en stund i Finder. Om en körning avbryts innan den hunnit städa: leta efter `filsynk-diskprov-` i utskriften från `hdiutil info` och koppla loss just den enheten med `hdiutil detach <enhet>`.

## Checklista

Gör detta en gång. Anteckna det som inte stämmer. `användare@server` och `/home/användare` står för din egen server, `Backupdisk` för din egen externa disk.

1. **Installera.** `scripts/build-app.sh --install`, sedan `open /Applications/Filsynk.app`.

2. **Utseende.**
   - Ikonen syns i menyraden och ingen ikon syns i Dock.
   - Menyn har statusrad överst (till exempel "Allt synkat · 14:32"), en rad per mål (till exempel `~/Sync → Server: ~/Sync   ✓ 14:32`), och sedan Synka nu, Pausa (blir Fortsätt), Inställningar…, Visa logg och Avsluta Filsynk.
   - "Visa logg" öppnar `~/Library/Logs/Filsynk/filsynk.log`.

3. **Inställningar** (ta först bort `~/Library/Application Support/Filsynk/config.json`):
   1. Inställningarna öppnas av sig själva med en rad i tabellen med `~/Sync` under På Macen och `Server: ~/Sync` under Mål, tom adress och en kort vägledning under Server.
   2. Skriv `användare@server` och tryck Testa anslutning: `✓ Ansluten, rsync 3.x.y`. `config.json` har nu `/home/användare/Sync` som `path` i mappens mål av slaget `server`, och `verifiedServer`, `verifiedHome` och `verifiedLogicalHome`. Kolumnen Mål visar `Server: ~/Sync`.
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

5. **Extern disk** (en disk som är formaterad som APFS, Mac OS Extended eller exFAT; gör den här delen med en ny, tom mapp på disken):
   1. Lägg till ett mål: Inställningar → Mappar → **+**, välj en ny mapp på Macen, välj **Extern disk**, **Välj mapp på disken…** och skapa en ny mapp i `/Volumes/Backupdisk`. Texten bredvid knappen blir `Backupdisk: <mappen>`. Raden dyker upp i tabellen med målet `Backupdisk: <mappen>`, och mappen på disken innehåller `.filsynk`. Välj i stället en mapp med innehåll: rött fel, ingenting sparas.
   2. Se första synken: raden går från `Väntar` till `Synkar…` och sedan `✓ <klockslag>`, och filerna finns på disken.
   3. Mata ut disken i Finder: pågår en synk avbryts den, utmatningen lyckas och raden visar `Inte inkopplad · senast <datum>`. Menyradens ikon visar inget fel.
   4. Ändra en fil i mappen på Macen medan disken är utmatad: inget försöks.
   5. Koppla in disken: synken startar direkt och den ändrade filen kommer ikapp.
   6. Radera en fil och skriv över en annan på Macen: efter synken ligger de gamla versionerna i `Raderat/<tid>/` i mappen på disken.
   7. Koppla in en annan disk, med samma namn om det går: ingenting händer, ingen fråga och ingen synk.

6. **Felsökning:**
   - Om appen inte startar vid inloggning: kontrollera under Systeminställningar > Allmänt > Inloggningsobjekt att Filsynk finns och är påslagen, och att appen ligger i `/Applications`. Slå av och på "Starta vid inloggning" i Filsynks inställningar för att registrera den igen.
   - Om notiserna inte visas: kontrollera att Filsynk får visa notiser under Systeminställningar > Notiser. Varje notis skrivs också i loggen, så den går att läsa där via "Visa logg".
