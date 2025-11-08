# Keycloak SSO Server Installer

Installation automatisée de Keycloak (serveur SSO/Identity Provider) avec PostgreSQL sur Debian 13.

## Description

Ce projet fournit un script d'installation automatique pour déployer Keycloak, une solution open-source de gestion d'identité et d'accès (IAM) qui supporte :

- **Single Sign-On (SSO)** : Une seule authentification pour toutes vos applications
- **OAuth 2.0 / OpenID Connect** : Standard moderne pour l'authentification
- **SAML 2.0** : Support des applications enterprise legacy
- **User Federation** : Intégration avec Active Directory, LDAP
- **Social Login** : Google, Facebook, GitHub, etc.
- **Multi-Factor Authentication (MFA)** : 2FA, TOTP, WebAuthn
- **Fine-grained Authorization** : Gestion avancée des permissions

## Caractéristiques

- Installation 100% automatisée via Docker Compose
- Support des variables d'environnement et arguments CLI
- Configuration par défaut pour tests en local
- Support reverse proxy (Nginx, Caddy, Traefik, HAProxy)
- Génération automatique des mots de passe sécurisés
- Service systemd pour gestion automatique
- PostgreSQL comme base de données (production-ready)
- Health checks et metrics intégrés

## Prérequis

- Debian 13 (Trixie) - testé sur cette version
- Accès root (sudo)
- Connexion internet
- Ports disponibles :
  - 8080/tcp (Keycloak HTTP) - configurable
- Minimum 2GB RAM recommandés pour Keycloak
- Docker et Docker Compose (installés automatiquement si absents)

## Installation rapide

### Installation de test (localhost)

```bash
curl -fsSL https://raw.githubusercontent.com/tiagomatiastm-prog/keycloak-installer/main/install-keycloak.sh | sudo bash
```

### Installation personnalisée

```bash
# Télécharger le script
curl -fsSL -O https://raw.githubusercontent.com/tiagomatiastm-prog/keycloak-installer/main/install-keycloak.sh
chmod +x install-keycloak.sh

# Installation avec domaine personnalisé
sudo ./install-keycloak.sh --domain auth.example.com --admin-password MySecurePassword123

# Installation avec ports personnalisés
sudo ./install-keycloak.sh --domain auth.local --http-port 9000 --listen 0.0.0.0 --behind-proxy false
```

## Options du script

```
Usage: ./install-keycloak.sh [OPTIONS]

OPTIONS:
    -d, --domain DOMAIN              Domain name for Keycloak (default: auth.ysalinde.fr)
    -l, --listen ADDRESS             Listen address (default: 127.0.0.1 for reverse proxy)
    -p, --http-port PORT             HTTP port for Keycloak (default: 8080)
    -u, --admin-user USERNAME        Admin username (default: admin)
    -P, --admin-password PASSWORD    Admin password (auto-generated if not provided)
    --behind-proxy [true|false]      Running behind reverse proxy (default: true)
    --skip-docker                    Skip Docker installation (use if already installed)
    -h, --help                       Show this help message
```

## Exemples d'utilisation

### Test en local
```bash
sudo ./install-keycloak.sh
```
Accès : http://127.0.0.1:8080/admin

### Production avec reverse proxy (RECOMMANDÉ)
```bash
sudo ./install-keycloak.sh \
  --domain auth.mycompany.com \
  --admin-password MyVerySecurePassword123!
```

### Sans reverse proxy (accès direct)
```bash
sudo ./install-keycloak.sh \
  --domain auth.example.com \
  --behind-proxy false \
  --listen 0.0.0.0
```

### Ports personnalisés
```bash
sudo ./install-keycloak.sh \
  --domain auth.local \
  --http-port 9000 \
  --listen 0.0.0.0
```

## Configuration reverse proxy

Si vous utilisez un reverse proxy (recommandé pour la production), vous devez configurer HTTPS car OAuth/OIDC requiert une connexion sécurisée.

### Exemple avec Nginx

```nginx
upstream keycloak {
    server 127.0.0.1:8080;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name auth.example.com;

    # Certificats SSL
    ssl_certificate /path/to/cert.pem;
    ssl_certificate_key /path/to/key.pem;

    # Headers requis pour Keycloak
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;

    location / {
        proxy_pass http://keycloak;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }
}

# Redirection HTTP → HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name auth.example.com;
    return 301 https://$server_name$request_uri;
}
```

### Exemple avec Caddy

```caddy
auth.example.com {
    reverse_proxy 127.0.0.1:8080 {
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-Proto {scheme}
    }
}
```

### Exemple avec Traefik

```yaml
http:
  routers:
    keycloak:
      rule: "Host(`auth.example.com`)"
      entryPoints:
        - websecure
      service: keycloak
      tls:
        certResolver: letsencrypt

  services:
    keycloak:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:8080"
```

### Configuration Zoraxy (OAuth SSO Proxy)

Zoraxy peut utiliser Keycloak pour protéger vos applications :

1. **Dans Keycloak** : Créez un client OAuth pour Zoraxy
   - Client ID : `zoraxy`
   - Client Protocol : `openid-connect`
   - Access Type : `confidential`
   - Valid Redirect URIs : `https://your-app.example.com/*`

2. **Dans Zoraxy** : Configurez OAuth 2.0
   - Provider : Custom OpenID Connect
   - Authorization URL : `https://auth.example.com/realms/master/protocol/openid-connect/auth`
   - Token URL : `https://auth.example.com/realms/master/protocol/openid-connect/token`
   - User Info URL : `https://auth.example.com/realms/master/protocol/openid-connect/userinfo`
   - Client ID : `zoraxy`
   - Client Secret : (depuis Keycloak)

## Configuration du pare-feu

### UFW (Ubuntu/Debian)
```bash
# Keycloak HTTP
sudo ufw allow 8080/tcp

# Si reverse proxy sur la même machine
sudo ufw allow 443/tcp
sudo ufw allow 80/tcp
```

### iptables
```bash
# Keycloak HTTP
iptables -A INPUT -p tcp --dport 8080 -j ACCEPT

# Si reverse proxy
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
```

## Utilisation

### Première connexion

1. Accédez à l'Admin Console
   ```
   https://auth.example.com/admin
   ```

2. Connectez-vous avec les credentials générés (voir `/root/keycloak-info.txt`)

3. **Changez immédiatement le mot de passe admin**

### Créer un nouveau Realm

Les realms permettent d'isoler les utilisateurs et applications (multi-tenancy).

1. Admin Console → Realms → Create Realm
2. Nom : `mycompany` (ou votre choix)
3. Enabled : ON
4. Create

### Créer un client OAuth/OIDC (pour une application)

1. Sélectionnez votre realm
2. Clients → Create Client
3. Configuration :
   - Client type : `OpenID Connect`
   - Client ID : `my-app` (nom de votre application)
   - Valid redirect URIs : `https://my-app.example.com/*`
   - Web origins : `https://my-app.example.com`
4. Credentials → Copier le Client Secret

### Créer des utilisateurs

1. Sélectionnez votre realm
2. Users → Add user
3. Remplir : Username, Email, First name, Last name
4. Create
5. Credentials → Set password
   - Password : (votre choix)
   - Temporary : OFF (pour mot de passe permanent)

### Configuration LDAP/Active Directory

1. User Federation → Add provider → LDAP
2. Configuration :
   - Vendor : `Active Directory` ou `Other`
   - Connection URL : `ldap://your-ad-server.com:389`
   - Bind DN : `CN=keycloak,CN=Users,DC=example,DC=com`
   - Bind Credential : (mot de passe du compte de liaison)
   - Users DN : `CN=Users,DC=example,DC=com`
3. Test connection → Test authentication
4. Save
5. Synchronize all users

## Gestion du service

```bash
# Démarrer
sudo systemctl start keycloak

# Arrêter
sudo systemctl stop keycloak

# Redémarrer
sudo systemctl restart keycloak

# Statut
sudo systemctl status keycloak

# Logs de Keycloak
sudo docker logs keycloak -f

# Logs de tous les conteneurs
sudo docker compose -f /opt/keycloak/docker-compose.yml logs -f
```

## Architecture

```
┌─────────────────────────────────────────┐
│      Reverse Proxy (Optional)           │
│      (Nginx/Caddy/Traefik/Zoraxy)       │
│            HTTPS (443)                   │
└────────────┬────────────────────────────┘
             │
        ┌────▼─────┐
        │ Keycloak │
        │  :8080   │
        └────┬─────┘
             │
        ┌────▼──────┐
        │ PostgreSQL│
        │   :5432   │
        └───────────┘
```

## Fichiers importants

- `/opt/keycloak/` - Répertoire d'installation
- `/opt/keycloak/docker-compose.yml` - Configuration Docker Compose
- `/opt/keycloak/config/.env` - Variables d'environnement (secrets)
- `/opt/keycloak/data/` - Données persistantes
  - `postgres/` - Base de données PostgreSQL
  - `keycloak/` - Données Keycloak
- `/root/keycloak-info.txt` - Informations de connexion et secrets
- `/etc/systemd/system/keycloak.service` - Service systemd

## Sauvegarde

### Sauvegarde complète
```bash
# Arrêter les services
sudo systemctl stop keycloak

# Créer l'archive
sudo tar czf keycloak-backup-$(date +%Y%m%d).tar.gz /opt/keycloak

# Redémarrer les services
sudo systemctl start keycloak
```

### Sauvegarde de la base de données uniquement
```bash
# Export de la base de données
sudo docker exec keycloak-postgres pg_dump -U keycloak keycloak > keycloak-db-backup-$(date +%Y%m%d).sql
```

### Restauration
```bash
# Arrêter les services
sudo systemctl stop keycloak

# Restaurer l'archive complète
sudo tar xzf keycloak-backup-20250108.tar.gz -C /

# OU restaurer juste la base de données
cat keycloak-db-backup-20250108.sql | sudo docker exec -i keycloak-postgres psql -U keycloak keycloak

# Redémarrer les services
sudo systemctl start keycloak
```

## Endpoints importants

```
# Admin Console
https://auth.example.com/admin

# Account Console (pour les utilisateurs)
https://auth.example.com/realms/{realm}/account

# OpenID Configuration
https://auth.example.com/realms/{realm}/.well-known/openid-configuration

# Token endpoint
https://auth.example.com/realms/{realm}/protocol/openid-connect/token

# Authorization endpoint
https://auth.example.com/realms/{realm}/protocol/openid-connect/auth

# User info endpoint
https://auth.example.com/realms/{realm}/protocol/openid-connect/userinfo

# Health check
https://auth.example.com/health

# Metrics (Prometheus format)
https://auth.example.com/metrics
```

## Désinstallation

```bash
# Arrêter et désactiver le service
sudo systemctl stop keycloak
sudo systemctl disable keycloak

# Supprimer les conteneurs
cd /opt/keycloak
sudo docker compose down -v

# Supprimer les fichiers
sudo rm -rf /opt/keycloak
sudo rm /etc/systemd/system/keycloak.service
sudo rm /root/keycloak-info.txt

# Recharger systemd
sudo systemctl daemon-reload
```

## Dépannage

### Keycloak ne démarre pas

```bash
# Vérifier les logs
sudo docker logs keycloak

# Vérifier l'état des conteneurs
sudo docker ps -a | grep keycloak

# Redémarrer tous les services
sudo systemctl restart keycloak
```

### Problème de connexion à la base de données

```bash
# Vérifier que PostgreSQL fonctionne
sudo docker exec keycloak-postgres pg_isready

# Se connecter à la base
sudo docker exec -it keycloak-postgres psql -U keycloak -d keycloak

# Vérifier les tables
\dt
```

### Erreur "Invalid redirect URI"

Dans Keycloak Admin Console :
1. Clients → Votre client
2. Settings → Valid Redirect URIs
3. Ajouter l'URI correcte (avec wildcard si nécessaire) : `https://app.example.com/*`
4. Save

### Erreur CORS

Dans Keycloak Admin Console :
1. Clients → Votre client
2. Settings → Web Origins
3. Ajouter : `https://app.example.com` ou `*` (pour test uniquement)
4. Save

### Réinitialiser le mot de passe admin

```bash
# Se connecter au conteneur Keycloak
sudo docker exec -it keycloak bash

# Créer un nouvel utilisateur admin temporaire
/opt/keycloak/bin/kc.sh bootstrap-admin create --username newadmin --password newpassword

# Se connecter avec ce compte et changer le mot de passe de l'admin original
```

## Performance et optimisation

### Ressources recommandées

- **Minimum** : 1 CPU, 2GB RAM
- **Recommandé** : 2 CPU, 4GB RAM
- **Production** : 4 CPU, 8GB RAM

### Tuning PostgreSQL

Éditez `/opt/keycloak/docker-compose.yml` et ajoutez dans la section postgres :

```yaml
command:
  - postgres
  - -c
  - max_connections=200
  - -c
  - shared_buffers=256MB
  - -c
  - effective_cache_size=1GB
```

### Tuning Keycloak

Éditez `/opt/keycloak/config/.env` :

```bash
# Augmenter le cache
KC_CACHE=ispn
KC_CACHE_STACK=kubernetes

# Désactiver les features non utilisées
KC_FEATURES_DISABLED=impersonation,scripts,upload_scripts
```

## Sécurité

### Meilleures pratiques

1. **Toujours utiliser HTTPS en production** (via reverse proxy)
2. **Changer le mot de passe admin** après installation
3. **Activer MFA** pour les utilisateurs admin
4. **Limiter les redirect URIs** aux domaines nécessaires uniquement
5. **Configurer les sessions** avec des timeouts appropriés
6. **Activer les logs d'audit** pour traçabilité
7. **Mettre à jour régulièrement** Keycloak et PostgreSQL
8. **Sauvegarder régulièrement** la base de données
9. **Utiliser des realms séparés** pour différents environnements (dev, prod)
10. **Configurer le pare-feu** pour limiter l'accès

### Activer l'authentification à deux facteurs (2FA)

1. Realm Settings → Authentication → Required Actions
2. Enable : `Configure OTP`
3. Users peuvent activer 2FA dans Account Console

## Mise à jour

```bash
# Arrêter les services
sudo systemctl stop keycloak

# Mettre à jour les images Docker
cd /opt/keycloak
sudo docker compose pull

# Redémarrer les services
sudo systemctl start keycloak
```

## Support et documentation

- Documentation officielle Keycloak : https://www.keycloak.org/documentation
- Server Administration Guide : https://www.keycloak.org/docs/latest/server_admin/
- Securing Applications Guide : https://www.keycloak.org/docs/latest/securing_apps/
- GitHub Keycloak : https://github.com/keycloak/keycloak
- Issues de ce projet : https://github.com/tiagomatiastm-prog/keycloak-installer/issues

## Licence

MIT License - voir LICENSE pour plus de détails.

## Auteur

Tiago - 2025

## Contributeurs

Contributions bienvenues ! N'hésitez pas à ouvrir une issue ou un pull request.
