# deploy

Runtime repository for langrenn-sprint som starter opp alle tjenester, frontend og backend

## Slik går du fram for å kjøre dette lokalt eller på en skytjeneste

1. Sette opp virtuell server - ubuntu
2. Networking: Open up port 8080 and 8090 for incoming traffic from any * incoming source.
3. Tildele dns navn - eks: ragdesprinten.norwayeast.cloudapp.azure.com

4. kommandoer for å innstallere containere (kan trolig optimaliseres - trenger ikke alt dette)

```Shell
sudo apt-get update
sudo apt-get install python-is-python3
curl -sSL <https://install.python-poetry.org> | python3 -
log out and back in
sudo apt install docker-compose
sudo git clone <https://github.com/langrenn-sprint/deploy.git>
copy .env file og secrets (inkl GOOGLE_APPLICATION_CREDENTIALS)
sudo usermod -aG docker $USER #deretter logge ut og inn igjen
docker-compose up --build
```

## AZURE remote access

```Shell
ssh -i /home/heming/github/sprint-ubuntu_key.pem azureuser@sprint.northeurope.cloudapp.azure.com
ssh -i /home/heming/github/sprint2-ubuntu_key_0223.pem azureuser@ragdesprinten.norwayeast.cloudapp.azure.com
```

## slette images og containere

```Shell
sudo docker image prune -a
sudo docker rm -f $(sudo docker ps -a -q)
sudo docker-compose rm result-service-gui
```

## Miljøvariable

Du må sette opp ei .env fil med miljøvariable. Eksempel:

```Shell
JWT_SECRET=secret
ADMIN_USERNAME=admin
ADMIN_PASSWORD=password
DB_USER=admin
DB_PASSWORD=password
EVENTS_HOST_SERVER=localhost
EVENTS_HOST_PORT=8082
PHOTOS_HOST_SERVER=localhost
PHOTOS_HOST_PORT=8092
FERNET_KEY=23EHUWpP_tpleR_RjuX5hxndWqyc0vO-cjNUMSzbjN4=
GOOGLE_OAUTH_CLIENT_ID=826356442895-g21vdoamuakjgrdparu4nem2hr930bnn.apps.googleusercontent.com
JWT_EXP_DELTA_SECONDS=3600
LOGGING_LEVEL=DEBUG
RACE_HOST_SERVER=localhost
RACE_SERVICE_PORT=8088
USERS_HOST_SERVER=localhost
USERS_HOST_PORT=8086
USER_SERVICE_HOST=localhost
USER_SERVICE_PORT=8086
```
