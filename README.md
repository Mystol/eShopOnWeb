# SecureFintech — Mission DevSecOps CI/CD

> **Contexte de formation** : Industrialisation de la chaîne de livraison d'une startup Fintech fictive sur un VPS Ubuntu, en remplacement d'Azure (compte non disponible). Toutes les décisions d'adaptation sont documentées ci-dessous.

---

## Table des matières

1. [Architecture de la solution](#1-architecture-de-la-solution)
2. [Stack technique](#2-stack-technique)
3. [Structure du repository](#3-structure-du-repository)
4. [Compiler et exécuter en local](#4-compiler-et-exécuter-en-local)
5. [Pipeline CI/CD GitLab](#5-pipeline-cicd-gitlab)
6. [Infrastructure Docker (IaC)](#6-infrastructure-docker-iac)
7. [Sécurité : Gitleaks + secrets](#7-sécurité--gitleaks--secrets)
8. [Déploiement sur le VPS](#8-déploiement-sur-le-vps)
9. [Monitoring et backups](#9-monitoring-et-backups)
10. [Secrets — noms uniquement](#10-secrets--noms-uniquement)
11. [Rétrospective personnelle](#11-rétrospective-personnelle)

---

## 1. Architecture de la solution

```
Developer (git push)
  └─► GitLab Repository
        └─► GitLab CI/CD Pipeline
              ├─ Stage 1 : build + test  (.NET 10, artefacts)
              ├─ Stage 2 : security      (Gitleaks scan secrets)
              ├─ Stage 3 : docker        (build image + push GitLab Registry)
              ├─ Stage 4 : deploy-staging   (SSH → VPS, auto)
              └─ Stage 5 : deploy-production (SSH → VPS, manuel ✋)

VPS Ubuntu 24.04 (Hostinger)
  ├─ Traefik v3 (reverse proxy + Let's Encrypt SSL)
  ├─ Coolify v4 (orchestration déploiements)
  ├─ eShopOnWeb Staging    → port 5106  (SQL Server dédié)
  ├─ eShopOnWeb Production → port 5107  (SQL Server dédié)
  ├─ Netdata               → monitoring système temps réel
  └─ Uptime Kuma           → surveillance disponibilité services
```

**Adaptation Azure → VPS** : La formation prévoyait Azure App Service + Azure Pipelines + Azure Key Vault. Faute de possibilité de créer un compte Azure, l'architecture a été adaptée :

| Prévu (Azure) | Réalisé (VPS) | Équivalence |
|--------------|---------------|-------------|
| Azure App Service | Docker Compose + Coolify | Hébergement application |
| Azure Pipelines | GitLab CI/CD | Pipeline CI/CD |
| Azure Key Vault | Variables GitLab CI (masked/protected) | Gestion des secrets |
| Bicep IaC | docker-compose.*.yml | Infrastructure as Code |
| Azure SQL | SQL Server 2022 (Docker) | Base de données |

---

## 2. Stack technique

| Catégorie | Technologie | Version |
|-----------|------------|---------|
| Application | ASP.NET Core (eShopOnWeb) | .NET 10 |
| Pipeline CI/CD | GitLab CI/CD | — |
| Containerisation | Docker + Docker Compose v2 | Docker 29 |
| Orchestration | Coolify | v4 |
| Reverse proxy | Traefik | v3 |
| Base de données | Microsoft SQL Server | 2022 |
| Scan secrets | Gitleaks | latest |
| Monitoring système | Netdata | latest |
| Monitoring services | Uptime Kuma | 1 |
| OS serveur | Ubuntu | 24.04 LTS |
| SSH | Port 4722 (durci) | — |

---

## 3. Structure du repository

```
eShopOnWeb/
├── .gitlab-ci.yml              # Pipeline CI/CD — 5 stages
├── .gitleaksignore             # Faux positifs Gitleaks exclus
├── Dockerfile.ci               # Image runtime (copie artefacts CI)
├── docker-compose.staging.yml  # Infrastructure staging (IaC)
├── docker-compose.production.yml # Infrastructure production (IaC)
├── infra/
│   ├── main.bicep              # Template Bicep (prévu Azure, adapté)
│   └── main.parameters.json
├── src/
│   └── Web/
│       ├── appsettings.json
│       └── appsettings.Docker.json  # Config Docker (sans secrets)
├── docs/
│   └── screenshots/            # Captures d'écran des livrables
└── tests/                      # Tests unitaires et d'intégration
```

---

## 4. Compiler et exécuter en local

### Prérequis
- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0)
- [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- [Git](https://git-scm.com/)

### Cloner et compiler

```bash
git clone https://github.com/Mystol/eShopOnWeb.git
cd eShopOnWeb
dotnet restore eShopOnWeb.sln
dotnet build eShopOnWeb.sln -c Release
```

### Lancer les tests

```bash
dotnet test eShopOnWeb.sln -c Release --logger "trx;LogFileName=results.trx" --results-directory ./test-results
```

### Lancer avec Docker Compose (local)

```bash
# Copier et adapter le fichier d'environnement
cp docker-compose.staging.yml docker-compose.local.yml

# Démarrer (SQL Server + application)
docker compose -f docker-compose.local.yml up -d

# Accéder à l'application
# http://localhost:5106
```

---

## 5. Pipeline CI/CD GitLab

Fichier : [`.gitlab-ci.yml`](.gitlab-ci.yml)

### Stages et déclencheurs

```
push sur main ou develop
    │
    ├─ [build]     dotnet restore → build Release → publish → artefact
    ├─ [test]      dotnet test → rapport .trx (conservé 1 semaine)
    ├─ [security]  Gitleaks detect --no-git --verbose
    ├─ [docker]    docker build (Dockerfile.ci) → push registry GitLab  ← main only
    ├─ [deploy-staging]    SSH → VPS → docker compose pull & up          ← main only
    └─ [deploy-production] SSH → VPS → approbation MANUELLE requise      ← main only
```

### Variables GitLab CI requises

| Variable | Type | Description |
|----------|------|-------------|
| `CI_REGISTRY_USER` | Auto GitLab | Login registry |
| `CI_REGISTRY_PASSWORD` | Auto GitLab | Token registry |
| `CI_REGISTRY` | Auto GitLab | URL registry |
| `VPS_HOST` | Custom masked | IP du VPS |
| `SSH_PRIVATE_KEY` | Custom masked | Clé privée ED25519 (base64) |
| `SA_PASSWORD_STG` | Custom masked | Mot de passe SA SQL staging |
| `SA_PASSWORD_PRD` | Custom masked | Mot de passe SA SQL production |

> La clé SSH est encodée en base64 pour respecter la contrainte de masquage GitLab (pas de saut de ligne dans les variables masquées).

### Dockerfile CI optimisé

Le `Dockerfile.ci` ne fait pas `dotnet restore` — les binaires sont déjà compilés par le stage `build` et passés via artefact. Cela évite les timeouts NuGet dans Docker-in-Docker (problème rencontré avec DinD et les registries NuGet lents).

```dockerfile
FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY ci-publish/ ./
ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "Web.dll"]
```

---

## 6. Infrastructure Docker (IaC)

Les fichiers `docker-compose.staging.yml` et `docker-compose.production.yml` jouent le rôle de l'IaC (équivalent Bicep/Terraform pour le VPS).

### Environnements

| Environnement | Port app | Réseau Docker | Base SQL |
|--------------|----------|---------------|----------|
| Staging | 5106 | securefintech-stg | sqlserver-stg |
| Production | 5107 | securefintech-prd | sqlserver-prd |

### Déploiement manuel (hors pipeline)

```bash
# Sur le VPS, depuis /opt/securefintech/staging/
export IMAGE_NAME=registry.gitlab.com/mystol/eshoponweb/eshopweb
export IMAGE_TAG=<sha-commit>
export SA_PASSWORD=<depuis gestionnaire de secrets>

docker compose -f docker-compose.staging.yml pull
docker compose -f docker-compose.staging.yml up -d
```

---

## 7. Sécurité : Gitleaks + secrets

### Gitleaks (scan de secrets)

- Image : `zricethezav/gitleaks:latest`
- Mode : `--no-git` (scan des fichiers courants uniquement, pas l'historique du fork upstream)
- Configuration : [`.gitleaksignore`](.gitleaksignore)
- `allow_failure: false` — le pipeline échoue si un secret est détecté

**Faux positif exclu** : Une clé ASP.NET Core Data Protection expirée (2021), présente dans le repo upstream NimblePros, est exclue via `.gitleaksignore`. Cette clé ne présente aucun risque (expirée, publique sur GitHub).

### Durcissement VPS

- SSH sur port non standard (4722), authentification par clé uniquement
- UFW activé + règles DOCKER-USER pour bloquer l'exposition directe des ports Docker
- fail2ban configuré (3 tentatives → ban 24h)
- Docker : `no-new-privileges`, `icc=false`, rotation des logs

---

## 8. Déploiement sur le VPS

### Accès

```bash
ssh -p 4722 root@<VPS_IP>
```

### URLs de l'application

| Environnement | URL |
|--------------|-----|
| Staging | `http://<VPS_IP>:5106` |
| Production | `http://<VPS_IP>:5107` |

### Commandes utiles sur le VPS

```bash
# Voir tous les conteneurs
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Logs de l'application staging
docker logs staging-eshopwebmvc-1 -f

# Logs de l'application production
docker logs production-eshopwebmvc-1 -f

# Lancer un backup manuel
/opt/securefintech/scripts/backup.sh
```

---

## 9. Monitoring et backups

### Monitoring

| Outil | Accès | Rôle |
|-------|-------|------|
| **Netdata** | `http://localhost:19999` (VPS) | CPU, RAM, disque, réseau, Docker |
| **Uptime Kuma** | `http://<VPS_IP>:3001` | Disponibilité des services (UP/DOWN) |
| **Coolify** | Interface web | Logs conteneurs, déploiements |

### Backups automatiques

- **Script** : `/opt/securefintech/scripts/backup.sh`
- **Cron** : tous les jours à **02h00**
- **Rétention** : 7 jours glissants
- **Contenu** : dumps SQL Server (CatalogDb + IdentityDb) + archives volumes Docker
- **Rapport** : email automatique après chaque run (succès ou échec)

---

## 10. Secrets — noms uniquement

> Les valeurs ne sont jamais stockées dans le code source. Elles sont injectées via les variables CI/CD GitLab (masked + protected).

| Nom de la variable | Usage |
|-------------------|-------|
| `VPS_HOST` | Adresse IP du VPS de déploiement |
| `SSH_PRIVATE_KEY` | Clé privée SSH (base64) pour l'accès au VPS depuis le pipeline |
| `SA_PASSWORD_STG` | Mot de passe administrateur SQL Server — environnement staging |
| `SA_PASSWORD_PRD` | Mot de passe administrateur SQL Server — environnement production |

Les chaînes de connexion SQL sont construites dans les `docker-compose.*.yml` à partir de ces variables, sans jamais être écrites en clair dans le code.

---

## 11. Rétrospective personnelle

### Ce qui a bien fonctionné

- **La démarche IaC** : avoir tout le déploiement dans des fichiers YAML versionnés (`.gitlab-ci.yml`, `docker-compose.*.yml`) rend chaque changement traçable et reproductible. Recréer l'environnement depuis zéro ne prend que quelques minutes.
- **La séparation staging / production** : deux environnements isolés (réseau Docker distinct, SQL Server distinct, port distinct) avec gate d'approbation manuelle en production. C'est exactement ce qu'on ferait en entreprise.
- **Gitleaks en gate bloquant** : avoir `allow_failure: false` force à traiter les problèmes de sécurité avant tout merge. La configuration `--no-git` a été une décision intelligente pour éviter les faux positifs de l'historique du fork upstream.

### Ce qui a bloqué (et comment ça a été résolu)

| Problème | Cause | Solution |
|----------|-------|----------|
| **NuGet timeout dans Docker-in-Docker** | Le réseau DinD est lent, `dotnet restore` dépassait 20 min | Dockerfile.ci qui copie les binaires déjà compilés — zéro `dotnet restore` dans Docker |
| **Variables GitLab masquées refusées** | Les chaînes de connexion SQL contiennent des espaces (`User Id`, `Initial Catalog`) | Utilisation des alias sans espaces (`uid=`, `Database=`) |
| **SSH_PRIVATE_KEY avec sauts de ligne** | GitLab ne masque pas les variables multi-lignes | Encodage base64 de la clé + décodage dans le pipeline |
| **`docker-compose` non trouvé sur le VPS** | Docker 29 intègre Compose v2 (`docker compose`, sans tiret) | Suppression du tiret dans toutes les commandes |
| **Port SSH 4722 non pris en compte** | Ubuntu 24.04 utilise `ssh.socket` (systemd socket activation) qui override `sshd_config` | Création de `/etc/systemd/system/ssh.socket.d/override.conf` |
| **Coolify "Not reachable"** | Coolify stockait le port SSH 22 en base — non mis à jour après le durcissement | Mise à jour directe en base PostgreSQL Coolify |
| **Gitleaks détecte 5 secrets** | Clés Data Protection ASP.NET Core dans l'historique du repo upstream | Utilisation de `--no-git` + `.gitleaksignore` pour les faux positifs |

### Ce que j'ai appris

- Un pipeline CI/CD n'est pas qu'une suite de commandes — c'est un contrat entre les développeurs et l'infrastructure. Chaque stage a une responsabilité unique et doit être idempotent.
- La sécurité se construit par couches : secrets masqués dans CI, pas de mot de passe dans le code, SSH durci, pare-feu, fail2ban. Aucune couche seule ne suffit.
- Docker Compose comme IaC est sous-estimé : la reproductibilité d'un environnement complet en un seul fichier YAML est extrêmement puissante pour des projets sans budget cloud.
- Les problèmes les plus chronophages ne sont pas techniques mais de configuration : permissions, ports, encodage des variables. La résolution méthodique (lire les logs, tester par étapes) est plus efficace que de chercher une solution miracle.

---

## Liens

- **Repository GitLab** : https://gitlab.com/Mystol/eshoponweb
- **Repository GitHub** (mirror) : https://github.com/Mystol/eShopOnWeb
- **Application Staging** : `http://<VPS_IP>:5106`
- **Application Production** : `http://<VPS_IP>:5107`
- **Coolify Dashboard** : https://backstage-coolify-ops.lacroixdubenin.bj

---

*Mission réalisée dans le cadre de la formation AZ-400 DevOps — SecureFintech (projet fictif)*
