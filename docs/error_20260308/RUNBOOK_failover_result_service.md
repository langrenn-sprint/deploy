# Runbook: Failover ved VM-/sonefeil (result-service)

Formål: Gjenopprette tjenesten raskt ved kapasitetsfeil eller utilgjengelig VM i primærsone.  
Mål: RTO <= 30 min.

## 0) Forutsetninger
- Du har `gcloud`-tilgang med nødvendige rettigheter.
- Du vet navn på kilde-VM, kilde-disk og mål-sone.
- `docker compose`-miljø og `.env` finnes på VM.
- DNS/IP-endring kan utføres av vakt.

Variabler (fyll ut før start):
```bash
export PROJECT_ID="<project-id>"
export SRC_ZONE="europe-north1-a"
export DST_ZONE="europe-north1-c"
export VM_SRC="result-service-20251018-20251018-080230"
export SNAPSHOT="result-service-snapshot-$(date +%Y%m%d-%H%M)"
export DISK_NEW="result-service-disk-new-$(date +%Y%m%d-%H%M)"
export VM_NEW="result-service-$(date +%Y%m%d-%H%M)-new"
export MACHINE_TYPE="e2-standard-2"
export STATIC_IP_NAME="result-service-vm"
export APP_DOMAIN="ragdesprinten-resultat-backup.kjelsaas.no"
```

---

## 1) Verifiser hendelse (maks 2–3 min)
```bash
gcloud config set project "$PROJECT_ID"
gcloud compute instances describe "$VM_SRC" --zone "$SRC_ZONE" \
  --format='get(status,lastStartTimestamp)'
```

Hvis instans ikke starter pga kapasitet / henger i restart: fortsett til steg 2.

---

## 2) Snapshot av kilde-disk
Finn boot-disk:
```bash
gcloud compute instances describe "$VM_SRC" --zone "$SRC_ZONE" \
  --format='get(disks[0].source)' | awk -F/ '{print $NF}'
```

Sett disk-navn (erstatt verdien):
```bash
export SRC_DISK="<disk-navn-fra-kommando-over>"
```

Opprett snapshot:
```bash
gcloud compute snapshots create "$SNAPSHOT" \
  --source-disk "$SRC_DISK" \
  --source-disk-zone "$SRC_ZONE"
```

---

## 3) Opprett ny VM i sekundærsone
```bash
gcloud compute instances create "$VM_NEW" \
  --zone "$DST_ZONE" \
  --machine-type "$MACHINE_TYPE" \
  --create-disk "name=$DISK_NEW,source-snapshot=$SNAPSHOT,mode=rw,boot=yes"
```

Tillat web-trafikk (hvis ikke policy allerede dekker dette):
```bash
gcloud compute instances add-tags "$VM_NEW" --zone "$DST_ZONE" \
  --tags http-server,https-server
```

---

## 4) Flytt statisk IP til ny VM
Frikoble IP fra gammel VM (kan kreve at gammel VM er stoppet):
```bash
gcloud compute instances delete-access-config "$VM_SRC" \
  --zone "$SRC_ZONE" --access-config-name "external-nat"
```

Koble statisk IP til ny VM:
```bash
gcloud compute instances add-access-config "$VM_NEW" \
  --zone "$DST_ZONE" \
  --access-config-name "external-nat" \
  --address "$STATIC_IP_NAME"
```

Verifiser ekstern IP:
```bash
gcloud compute instances describe "$VM_NEW" --zone "$DST_ZONE" \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)'
```

---

## 5) Start applikasjonen på ny VM
SSH inn:
```bash
gcloud compute ssh "$VM_NEW" --zone "$DST_ZONE"
```

På VM:
```bash
cd /home/info_renn_langrenn_kjelsaas/deploy
sudo docker compose pull
sudo docker compose up -d
sudo docker compose ps
```

Sjekk kritiske tjenester:
```bash
sudo docker compose ps | egrep 'race-service|result-service-gui|mongodb'
```

---

## 6) Verifiser intern og ekstern helsetilstand
På VM:
```bash
sudo docker compose logs --tail=200 result-service-gui | tail -n 50
sudo docker compose logs --tail=200 race-service | tail -n 50
```

Utenfra:
```bash
curl -I "http://$APP_DOMAIN"
curl -I "https://$APP_DOMAIN"
```

Nginx/SSL (hvis aktuelt):
```bash
sudo systemctl status nginx --no-pager
sudo certbot certificates
```

---

## 7) Hvis certbot feiler (HTTP challenge timeout)
Sjekk porter og firewall:
```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw status
sudo ss -tulpn | grep -E ':80|:443'
```

Prøv så:
```bash
sudo certbot --nginx -d "$APP_DOMAIN" --redirect
```

---

## 8) Kommunikasjon under hendelse
- Oppdater status hvert 15. minutt.
- Meld disse punktene: påvirkning, nåværende steg, ETA, risiko.
- Etter stabil drift: opprett postmortem innen 24 timer.

---

## 9) Exit-kriterier (incident kan lukkes)
- `https://$APP_DOMAIN` svarer stabilt.
- Kritiske API-kall fungerer uten `ConnectionTimeoutError`.
- Ingen nye `Error. Redirect to main page.` i relevante logger siste 15 min.
- Team har bekreftet normal brukerflyt.

---

## 10) Etterarbeid (obligatorisk)
- Dokumenter faktisk tidslinje og beslutninger.
- Vurder Compute Engine reservation for kritisk maskintype/sone.
- Test runbook kvartalsvis (DR-øvelse).
- Lag enkel script/automation for steg 2–5 for raskere failover.
