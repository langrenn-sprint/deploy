# Incident-rapport: Nedetid Ragdesprinten 2026-03-08

| | |
|---|---|
| **Dato** | 2026-03-08 |
| **Nedetid** | ~8 timer |
| **System** | langrenn-sprint/deploy (result-service m.fl.) |
| **Miljø** | Google Cloud, `europe-north1` |
| **Domene** | `ragdesprinten-resultat.kjelsaas.no` |

---

## 1) Oppsummering

VM-instansen i `europe-north1-a` lot seg ikke restarte (kapasitetsmangel for `e2-standard-2` i sonen). Uten avtalt driftsberedskap tok det ~8 timer før tjenesten var tilbake.

Løsning: Ny VM ble opprettet i `europe-north1-c` fra disk-snapshot, og den faste (reserverte) eksterne IP-adressen ble flyttet dit — slik at trafikken til `ragdesprinten-resultat.kjelsaas.no` fungerte på ny server.

---

## 2) Påvirkning

- Brukere mistet tilgang til resultatløsningen i ~8 timer.
- Gjenoppretting var helt manuell (snapshot → ny VM → IP-flytt → Docker-oppstart).
- Høy risiko for gjentakelse uten tiltak.

---

## 3) Hva skjedde (teknisk)

### Infrastruktur (primærhendelse)
VM i `europe-north1-a` kom ikke opp etter restart — maskintypen var ikke tilgjengelig i sonen.

Gjenopprettingssteg:
1. Snapshot av disk i opprinnelig sone
2. Ny VM i `europe-north1-c` fra snapshot
3. Oppstart av tjenester (`docker compose up`)
4. Flytting av fast ekstern IP til ny VM
5. Verifisering av at domenet pekte korrekt

Kommandoer som ble brukt er dokumentert i [RUNBOOK_failover_result_service.md](../RUNBOOK_failover_result_service.md).

### Applikasjonsfeil (sekundærsymptom)
Etter at infrastrukturen feilet, viste loggene `ConnectionTimeoutError` på interne kall fra `result-service-gui` til `race-service:8080`. Alle GUI-forespørsler ga `Error. Redirect to main page.`

---

## 4) Loggstatistikk

Kilde: `error_ragde_202603081220.log`

### Club logo not found (datakvalitetsfeil)
| Metrikk | Verdi |
|---|---|
| Antall | 113 (~6/min) |
| Tidsrom | 11:57:38 – 12:14:21 |
| Siste 10 min før timeout | 1 |
| Siste 5 min før timeout | 0 |

Observasjon: Disse feilene avtar markant rett før timeout-feilene starter. Det kan tyde på at infrastrukturen gradvis ble utilgjengelig — tjenesten klarte etter hvert ikke å gjøre noen kall i det hele tatt.

### ConnectionTimeoutError (infrastrukturfeil)
| Metrikk | Verdi |
|---|---|
| Antall | 7 |
| Tidsrom | 12:20:10 – 12:22:08 |
| Varighet | ~2 min |

Merk: Loggutdraget dekker kun ~2 min, ikke hele nedetidsvinduet på ~8 timer.

---

## 5) Rotårsak

**Primær:** Kapasitetsmangel i `europe-north1-a` for maskintype `e2-standard-2` ved restart. Single-zone avhengighet uten failover.

**Sekundær:** Timeout-feilene i applikasjonen er symptomer — de oppsto fordi backend-tjenestene ikke lenger var tilgjengelige.

**Medvirkende:**
- Ingen driftsberedskap avtalt for arrangementet
- Ingen ferdig runbook for rask sonemigrering
- Applikasjonen håndterer timeout dårlig (redirect uten feilmelding)

---

## 6) Hva fungerte / hva fungerte ikke

| Fungerte | Fungerte ikke |
|---|---|
| Snapshot-gjenoppretting til ny sone | Restart i opprinnelig sone |
| Tjenesten kom opp på ny instans | Manuell prosess uten runbook |
| IP-flytt sikret domenetrafikk | Appen degraderte dårlig ved timeout |

---

## 7) Tiltak

### A. Umiddelbart (før neste arrangement)
1. **Driftsberedskap** — avtal vaktordning med incident lead + backup og eskaleringsplan (maks 10 min responstid)
2. **Failover-runbook** — lag og test (mål: tjeneste oppe innen 15 min). Se [RUNBOOK_failover_result_service.md](../RUNBOOK_failover_result_service.md)
3. **Forhåndsgodkjente soner** — dokumenter minst to (f.eks. `europe-north1-a` og `europe-north1-c`)
4. **Enkel helsesjekk** — ett script som verifiserer alle kritiske tjenester

### B. Kort sikt
1. **Kapasitetsreservasjon** i GCP for kritisk maskintype
2. **Standby-VM** (kald) i sekundær sone
3. **Overvåking/varsling** — VM nede, container healthcheck, timeout-rate
4. **Automatisk snapshot-policy** — daglig + før arrangement

### C. Mellomlang sikt
1. **Multi-zone design** for å fjerne single point of failure
2. **Applikasjonsrobusthet** — retry med backoff, tydelig feilmelding i GUI, health-endpoint
3. **DR-øvelser** kvartalsvis

---

## 8) Beredskapsmål

| Mål | Verdi |
|---|---|
| Gjenoppretting (RTO) | ≤ 30 min |
| Datatap (RPO) | ≤ 15 min |
| Krav | Testet failover-prosedyre før neste sesong |

---

## 9) Åpne beslutninger

- Skal vi betale for kapasitetsreservasjon i kritisk periode?
- Skal vi ha standby-instans i sekundær sone under arrangement?
- Hvem eier failover-runbook og er incident lead?
- Hva er akseptert maks nedetid?
