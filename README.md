# deploy

Runtime repository for langrenn-sprint som starter opp alle tjenester, frontend og backend

## Slik går du fram for å kjøre dette lokalt eller på en skytjeneste (UpCloud er anbefalt)
1. Sette opp virtuell server - ubuntu 24.04 LTS
2. Networking: Open up port 8080 for incoming traffic from any * incoming source.
3. kommandoer for å innstallere containere (kan trolig optimaliseres - trenger ikke alt dette)

```Shell
sudo apt-get update

curl -sSL https://get.docker.com | sh
git clone https://github.com/langrenn-sprint/deploy.git # uten sudo: backup- og status-skriptene må kunne skrive i folderen
cd deploy
# copy .env file og secrets (inkl GOOGLE_APPLICATION_CREDENTIALS)
sudo usermod -aG docker $USER #deretter logge ut og inn igjen
# secrets og konfigurasjon
# opprette en .env fil med miljøvariable, se under
set -a
source .env
set +a
docker compose pull
docker compose up &
docker compose up photo-service race-service event-service competition-format-service user-service mongodb photo-service-gui integration-service video-service-capture
```

4. Backup og systemstatus (på VM-en, i deploy-folderen). Detaljer under [Backup](#backup-uten-nedetid).

```Shell
# i .env: navn og rolle som vises i GUI-et
#   INSTANCE_NAME="UpCloud prod"
#   INSTANCE_ROLE=production
mkdir -p backups
scripts/backup.sh                # test: skal gi en OK-linje
crontab -e                       # legg til (tilpass stien):
# */5 * * * * /home/<user>/deploy/scripts/backup.sh >> /home/<user>/deploy/backups/backup.log 2>&1
scripts/install-status-timer.sh  # oppdaterer systemsiden hvert 30. sekund
```

   Valgfritt, men anbefalt: kopi av backup til GCS (`BACKUP_GCS_BUCKET` i `.env`, se [Backup](#backup-uten-nedetid)) og automatisk backup av serveren hos UpCloud.

5. På lokal PC (reserve): hent backupene fra VM-en med `scripts/pull-backups.sh` fra cron, og sett `INSTANCE_ROLE=standby` i `.env` hvis PC-en skal kjøre løsningen etter en restore. Se [Backup](#backup-uten-nedetid).

## Tilgang til Google storage bucket (lokasjon til secrets file må ligge i .env GOOGLE_APPLICATION_CREDENTIALS)

Set upp application default credentials: https://cloud.google.com/docs/authentication/provide-credentials-adc#how-to

```Bruk vim eller Shell. Kommandoer hvis du skal laste filen opp på en Azure virtuell server
ssh -i sprint_key.pem user@myserver.com
scp -i key.pem -r application_default_credentials.json user@20.251.168.187:/home/user/github/deploy/.
Tips: chmod 700 på nøkkelen
```

## Virtual env if required
python3.13 -m venv .venv
source .venv/bin/activate

## Starte opp containere

Når du har logga inn på serveren, gå til folderen der docker compose filen ligger og kjør følgende kommandoer:

```Filhåndtering - lage bind-mounts som stemmer med referansene i docker compose filen og sikre at alle har tilgang
mkdir files
sudo chmod -R 777 files


Starte opp minimum alle services
```Shell
docker compose pull && docker compose up -d # Henter siste versjon av containere og starter dem
docker compose up race-service competition-format-service photo-service user-service event-service mongodb event-service-gui result-service-gui integration-service # starte tjenester individuelt

```

## Oppdatere én tjeneste til nytt image

Eksempel med `event-service-gui`; det samme gjelder alle tjenester. De andre tjenestene fortsetter å kjøre.
Tjenesten er nede noen sekunder under restart, så unngå dette midt i et løp.

**Nytt image fra CI** (etter merge til main publiseres `ghcr.io/langrenn-sprint/<tjeneste>:latest`):

```Shell
gh run list -R langrenn-sprint/event-service-gui --limit 1   # vent til bygget er ferdig
docker compose pull event-service-gui
docker compose up -d event-service-gui    # lager ny container bare hvis imaget er endret
```

**Lokalt bygd image** (test av egen kode før merge). Bygg med samme navn som i `docker-compose.yml`:

```Shell
cd ~/src/langrenn-sprint/event-service-gui
docker build -t ghcr.io/langrenn-sprint/event-service-gui:latest .
cd ~/src/langrenn-sprint/deploy
docker compose up -d event-service-gui    # ikke kjør pull: det overskriver det lokale imaget
```

Neste `docker compose pull` henter versjonen fra ghcr igjen.

Sjekk resultatet:

```Shell
docker compose ps event-service-gui       # "Up X seconds"
docker compose images event-service-gui   # image-ID og når det ble bygd
docker compose logs -f event-service-gui  # feil ved oppstart
scripts/status.sh                         # oppdaterer systemsiden med nytt image med en gang
```

## Sette opp DNS og SSL (Https) 
Hint: bruk copilot for å få CLI kommandoer
1. DNS entry settes opp hos ISP. Må peke på en public IP på serveren.
2. Installer nginx reverse proxy på serveren
3. Generere sertifikat med certbot
4. Lag Nginx Configuration Filer med følgende config:
   HTTP trafikk på port 80 (default) skal sendes til port 443 (tvinge HTTPS)
   Trafikk på port 443 skal sendes til backend på port 8090 (result-service-gui - tjenesten)
   Trafikk på port 8080 skal sendes til backend på port 8081 (event-service-gui - tjenesten)
5. Valider config og restart Nginx
6. Endre i docker compose filen slik at event-service-gui er kjører på port 8081 (ikke 8080)

## Monitorere logger

Gå til folderen der docker compose filen ligger og kjør følgende kommando:

```Shell
docker compose logs -f
```

## Stoppe containere

Følgende kommando stopper alle services:

```Shell
docker compose stop
```

Følgende kommando stopper og fjerner containere:

```Shell
docker stop $(docker ps -q)
docker rm $(docker ps -aq)
docker compose down
```

## slette images og containere

```Shell
docker system prune -a --volumes
```

## Miljøvariable

Du må sette opp ei .env fil med miljøvariable. Eksempel:

```Shell
JWT_SECRET=secret
ADMIN_USERNAME=admin
ADMIN_PASSWORD=password
GOOGLE_APPLICATION_CREDENTIALS="application_default_credentials.json"
DB_USER=admin
DB_PASSWORD=password
ERROR_FILE=error.log
FERNET_KEY=<generer, se under>
JWT_EXP_DELTA_SECONDS=43200  # levetid for innlogging i sekunder (12 t), se under
LOGGING_LEVEL=INFO
GOOGLE_APPLICATION_CREDENTIALS="application_default_credentials.json"
GOOGLE_CLOUD_PROJECT=sigma-celerity-257719
GOOGLE_STORAGE_BUCKET=langrenn-sprint
GOOGLE_STORAGE_SERVER=https://storage.googleapis.com
RACE_DURATION_ESTIMATE=300
RACE_TIME_DEVIATION_ALLOWED=600
LOCAL_PHOTO_DIRECTORY=/home/heming/github/deploy/files
INSTANCE_NAME="UpCloud prod"  # vises i GUI, se "Systemstatus" under
INSTANCE_ROLE=production      # production | standby | test
```

**`FERNET_KEY`** krypterer sesjons-cookien i GUI-ene. Lag en egen nøkkel for hver instans, og del den aldri
(ikke i git, ikke i README). En nøkkel som har stått i koden eller her er offentlig: da kan hvem som helst
lage en gyldig innlogging-cookie. Ny nøkkel logger ut alle én gang.

```Shell
python3 -c 'import base64, os; print(base64.urlsafe_b64encode(os.urandom(32)).decode())'
docker compose up -d event-service-gui result-service-gui   # etter endring i .env
```

**`JWT_EXP_DELTA_SECONDS`** er hvor lenge en innlogging varer, regnet fra innlogging (ikke fra siste aktivitet).
Med 3600 (1 time) blir brukerne kastet ut midt i arbeidet. Sett den så den dekker en løpsdag, til tokenet
fornyes automatisk (langrenn-sprint/user-service#19). Etter endring: `docker compose up -d user-service`
(gjelder nye innlogginger).

## Backup (uten nedetid)

Databasen tas backup av mens alt kjører, med `mongodump`. Det gir én komprimert fil per backup
som kan restores på en ny VM eller på en lokal PC. Backup-filene inneholder personopplysninger (GDPR):
de skal aldri i git, og bucketen i GCS skal være privat.

Skript i `scripts/`:

| Skript | Kjøres på | Hva |
| --- | --- | --- |
| `backup.sh` | VM (cron) | Dump til `backups/`, siste dump per dag i `backups/daily/`, rydder gamle filer, laster opp til GCS |
| `pull-backups.sh` | Lokal PC (cron) | Henter `backups/` fra VM-en med rsync over ssh |
| `restore.sh` | VM / ny VM / lokal PC | Restorer en dump inn i `mongodb`-tjenesten |
| `status.sh` | systemd-timer, `backup.sh`, `restore.sh` | Skriver `status/system.json` som GUI-et viser |
| `install-status-timer.sh` | VM (én gang) | Installerer timer som kjører `status.sh` hvert 30. sekund |

### 1. Backup på VM-en hvert 5. minutt

```Shell
crontab -e
# legg til (tilpass stien):
*/5 * * * * /home/<user>/deploy/scripts/backup.sh >> /home/<user>/deploy/backups/backup.log 2>&1
```

Sjekk at det virker: `tail backups/backup.log`. Hver linje viser filstørrelse og hvor lang tid dumpen tok.
Tar en dump mer enn ca. 30 sekunder, bør intervallet økes (f.eks. `*/15`).

Standard oppbevaring på VM-en: alle dumper i 48 timer, én per dag i 30 dager
(`BACKUP_KEEP_HOURS` / `BACKUP_KEEP_DAYS` i `.env`).

### 2. Kopi til Google Cloud Storage

Bruk en egen, privat bucket (ikke bucketen med bilder) og en egen service account som bare har tilgang dit.
GCS sin soft delete (standard 7 dager) beskytter mot at filer slettes ved et uhell eller fra en kompromittert VM.

```Shell
gcloud storage buckets create gs://<backup-bucket> --location=europe-north1 \
  --uniform-bucket-level-access --public-access-prevention
gcloud iam service-accounts create langrenn-backup
gcloud storage buckets add-iam-policy-binding gs://<backup-bucket> \
  --member=serviceAccount:langrenn-backup@<project>.iam.gserviceaccount.com \
  --role=roles/storage.objectAdmin   # kun på denne bucketen (rclone må liste og overskrive daglig fil)
gcloud iam service-accounts keys create backup-sa.json \
  --iam-account=langrenn-backup@<project>.iam.gserviceaccount.com
# slett filer i bucketen etter 30 dager
echo '{"rule":[{"action":{"type":"Delete"},"condition":{"age":30}}]}' > lifecycle.json
gcloud storage buckets update gs://<backup-bucket> --lifecycle-file=lifecycle.json
```

Kopier `backup-sa.json` til deploy-folderen på VM-en (`chmod 600 backup-sa.json`) og legg til i `.env`:

```Shell
BACKUP_GCS_BUCKET=<backup-bucket>
# valgfritt: BACKUP_GCS_PREFIX=mongo  BACKUP_GCS_CREDENTIALS=backup-sa.json
```

### 3. Kopi til lokal PC

På PC-en (krever ssh-tilgang til VM-en):

```Shell
crontab -e
*/5 * * * * BACKUP_SSH_KEY=$HOME/.ssh/key.pem /path/to/deploy/scripts/pull-backups.sh <user>@<domain/ip>:/home/<user>/deploy/backups >> $HOME/langrenn-sprint-backups/pull.log 2>&1
```

Filene havner i `~/langrenn-sprint-backups` (dumper i 7 dager, daglige beholdes).

### Restore

På en ny VM eller lokal PC: klon repoet, legg inn `.env`, og kjør:

```Shell
# hent en dump, f.eks. fra GCS: gcloud storage cp gs://<backup-bucket>/mongo/<fil> backups/
scripts/restore.sh backups/mongo_<YYYYmmdd_HHMMSS>.archive.gz
docker compose up -d
```

Collections i dumpen erstatter de som finnes i databasen. Brukere (admin-databasen) restores ikke,
så databasen bruker `DB_USER`/`DB_PASSWORD` fra `.env`.
Test restore på en lokal PC før hvert arrangement.

### Systemstatus for GUI

`scripts/status.sh` skriver `status/system.json` hver gang backup eller restore kjører:
instansnavn og rolle, siste backup (og feil), opplasting til GCS, hvilken backup instansen er
restoret fra, MongoDB-versjon, antall dokumenter per collection, ledig disk og minne, og status, image og
byggetidspunkt, minne- og CPU-bruk for hver tjeneste (fra `docker inspect` og `docker stats`).
Fila inneholder ingen personopplysninger eller hemmeligheter. Format: se issue #13.

- `status/` mountes read-only inn i `event-service-gui` og `result-service-gui` (`SYSTEM_STATUS_FILE`).
- `INSTANCE_NAME` og `INSTANCE_ROLE` i `.env` sendes til GUI-ene. Når rollen ikke er `production`,
  skal GUI-et vise et tydelig banner (langrenn-sprint/event-service-gui#198).
  **Sett `INSTANCE_ROLE=standby` på en reserveinstans** (f.eks. lokal PC etter restore).
- `restore.sh` lagrer hvilken fil som ble restoret i databasen `deploy_system`, collection `restores`.
- Oppdatere manuelt: `scripts/status.sh`

`backup.sh` oppdaterer fila hvert 5. minutt. For at systemsiden skal være ferskere (tjeneste nede,
container restartet), installer en systemd-timer som oppdaterer fila hvert 30. sekund:

```Shell
scripts/install-status-timer.sh          # hvert 30. sekund (spør om sudo én gang for "linger")
scripts/install-status-timer.sh 15       # annet intervall
scripts/install-status-timer.sh --remove # fjerne
systemctl --user list-timers langrenn-status.timer   # sjekk at den går
journalctl --user -u langrenn-status.service         # logg
```

### Anbefalt i tillegg

Slå på automatisk backup av serveren hos UpCloud. Det gir tilbake hele VM-en (`.env`, nginx, sertifikater),
mens dumpene over sikrer dataene.
