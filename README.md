# deploy

Runtime repository for langrenn-sprint som starter opp alle tjenester, frontend og backend

## Slik går du fram for å kjøre dette lokalt eller på en skytjeneste
1. Sette opp virtuell server - ubuntu 24.04 LTS
2. Networking: Open up port 8080 for incoming traffic from any * incoming source.
3. kommandoer for å innstallere containere (kan trolig optimaliseres - trenger ikke alt dette)

```Shell
sudo apt-get update

curl -sSL https://get.docker.com | sh
sudo git clone https://github.com/langrenn-sprint/deploy-video-edge.git
# copy .env file og secrets (inkl GOOGLE_APPLICATION_CREDENTIALS)
sudo usermod -aG docker $USER #deretter logge ut og inn igjen
# secrets og konfigurasjon
# opprette en .env fil med miljøvariable, se under
source .env
docker compose pull
docker compose up &
docker compose up photo-service race-service event-service competition-format-service user-service mongodb photo-service-gui integration-service video-service-capture
```

## Tilgang til Google storage bucket (lokasjon til secrets file må ligge i .env GOOGLE_APPLICATION_CREDENTIALS)

Set upp application default credentials: https://cloud.google.com/docs/authentication/provide-credentials-adc#how-to

```Bruk vim eller Shell. Kommandoer hvis du skal laste filen opp på en Azure virtuell server
ssh -i /home/heming/github/sprint-ubuntu_key.pem azureuser@sprint.northeurope.cloudapp.azure.com
scp -i key.pem -r application_default_credentials.json azureuser@20.251.168.187:/home/azureuser/github/deploy-video-service/.
Tips: chmod 700 på nøkkelen
```

## Virtual env if required
python3.13 -m venv .venv
source .venv/bin/activate

## Starte opp containere

Når du har logga inn på serveren, gå til folderen der docker-compose filen ligger og kjør følgende kommandoer:

```Filhåndtering - lage bind-mounts som stemmer med referansene i docker-compose filen og sikre at alle har tilgang
mkdir files
sudo chmod -R 777 files


Starte opp minimum alle services
```Shell
docker-compose pull && docker-compose up -d # Henter siste versjon av containere og starter dem
docker compose up race-service competition-format-service photo-service user-service event-service mongodb event-service-gui result-service-gui

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
6. Endre i docker-compose filen slik at event-service-gui er kjører på port 8081 (ikke 8080)

## Monitorere logger

Gå til folderen der docker-compose filen ligger og kjør følgende kommando:

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
FERNET_KEY=23EHUWpP_tpleR_RjuX5hxndWqyc0vO-cjNUMSzbjN4=
JWT_EXP_DELTA_SECONDS=10000
LOGGING_LEVEL=INFO
GOOGLE_APPLICATION_CREDENTIALS="application_default_credentials.json"
GOOGLE_CLOUD_PROJECT=sigma-celerity-257719
GOOGLE_STORAGE_BUCKET=langrenn-sprint
GOOGLE_STORAGE_SERVER=https://storage.googleapis.com
RACE_DURATION_ESTIMATE=300
RACE_TIME_DEVIATION_ALLOWED=600
```

## Backup

I Azure VM, stoppe containere i deploy-folder
Rekursivt endre ownership på data-folder

```Shell
docker-compose stop
sudo chown azureuser:azureuser data -R
```

På local pc, opprette backup-folder i deploy-folder
På lokal pc, i home-folder, køyre scp

```Shell
mkdir backup_skagen
scp -i key.pem -r azureuser@<domain/ip>:/home/azureuser/deploy/data backup_skagen
```

I deploy-folder, starte containere på nytt eller lokalt (docker-compose up -d )
