# Guide de déploiement Ansible - Keycloak SSO Server

Ce guide explique comment déployer Keycloak sur plusieurs serveurs en utilisant Ansible, et comment l'intégrer avec Active Directory (Samba AD).

## Prérequis

- Ansible 2.9+ installé sur la machine de contrôle
- Accès SSH avec clés publiques sur les serveurs cibles
- Privilèges sudo sur les serveurs cibles
- Debian 13 (Trixie) sur les serveurs cibles
- Minimum 2GB RAM par serveur

## Structure des fichiers

```
keycloak-installer/
├── install-keycloak.sh          # Script d'installation
├── inventory.ini                # Inventaire Ansible
├── deploy-keycloak.yml          # Playbook principal
├── configure-ad.yml             # Playbook intégration AD
└── group_vars/
    └── keycloak_servers.yml     # Variables de groupe
```

## Configuration de l'inventaire

Créez un fichier `inventory.ini` :

```ini
[keycloak_servers]
keycloak-prod ansible_host=192.168.1.100 ansible_user=debian
keycloak-test ansible_host=192.168.1.150 ansible_user=debian

[keycloak_servers:vars]
ansible_become=yes
ansible_become_method=sudo
ansible_python_interpreter=/usr/bin/python3
```

## Variables de configuration

Créez le fichier `group_vars/keycloak_servers.yml` :

```yaml
---
# Configuration Keycloak
keycloak_domain: "auth.example.com"
keycloak_behind_proxy: true
keycloak_listen_address: "127.0.0.1"
keycloak_http_port: 8080
keycloak_admin_user: "admin"

# Admin password (use Ansible Vault for production)
keycloak_admin_password: "ChangeMe123!"

# Installation Docker
skip_docker_install: false

# Reverse proxy
configure_reverse_proxy: false
reverse_proxy_type: "nginx"  # nginx, caddy, traefik

# Certificats SSL (si configure_reverse_proxy=true)
use_letsencrypt: true
letsencrypt_email: "admin@example.com"
```

## Playbook Ansible

Créez le fichier `deploy-keycloak.yml` :

```yaml
---
- name: Deploy Keycloak SSO Server
  hosts: keycloak_servers
  become: yes
  vars:
    script_url: "https://raw.githubusercontent.com/tiagomatiastm-prog/keycloak-installer/master/install-keycloak.sh"
    install_script: "/tmp/install-keycloak.sh"

  tasks:
    - name: Update apt cache
      apt:
        update_cache: yes
        cache_valid_time: 3600

    - name: Install required packages
      apt:
        name:
          - curl
          - ca-certificates
          - gnupg
          - openssl
        state: present

    - name: Download Keycloak installation script
      get_url:
        url: "{{ script_url }}"
        dest: "{{ install_script }}"
        mode: '0755'

    - name: Check if Keycloak is already installed
      stat:
        path: /opt/keycloak/docker-compose.yml
      register: keycloak_installed

    - name: Build installation command
      set_fact:
        install_command: >-
          {{ install_script }}
          --domain {{ keycloak_domain }}
          --listen {{ keycloak_listen_address }}
          --http-port {{ keycloak_http_port }}
          --admin-user {{ keycloak_admin_user }}
          --admin-password {{ keycloak_admin_password }}
          --behind-proxy {{ keycloak_behind_proxy }}
          {% if skip_docker_install %}--skip-docker{% endif %}

    - name: Install Keycloak
      shell: "{{ install_command }}"
      args:
        executable: /bin/bash
      register: install_result
      when: not keycloak_installed.stat.exists

    - name: Display installation output
      debug:
        var: install_result.stdout_lines
      when: not keycloak_installed.stat.exists

    - name: Wait for Keycloak to be ready
      wait_for:
        host: "{{ keycloak_listen_address }}"
        port: "{{ keycloak_http_port }}"
        delay: 30
        timeout: 300
      when: not keycloak_installed.stat.exists

    - name: Check Keycloak service status
      systemd:
        name: keycloak
        state: started
        enabled: yes
      register: service_status

    - name: Retrieve installation info
      slurp:
        src: /root/keycloak-info.txt
      register: keycloak_info
      changed_when: false

    - name: Display installation info
      debug:
        msg: "{{ keycloak_info.content | b64decode }}"

    - name: Configure Nginx reverse proxy
      block:
        - name: Install Nginx
          apt:
            name: nginx
            state: present

        - name: Install Certbot for Let's Encrypt
          apt:
            name:
              - certbot
              - python3-certbot-nginx
            state: present
          when: use_letsencrypt

        - name: Create Nginx configuration for Keycloak
          template:
            src: templates/nginx-keycloak.conf.j2
            dest: /etc/nginx/sites-available/keycloak
            mode: '0644'

        - name: Enable Nginx site
          file:
            src: /etc/nginx/sites-available/keycloak
            dest: /etc/nginx/sites-enabled/keycloak
            state: link

        - name: Test Nginx configuration
          command: nginx -t
          register: nginx_test
          changed_when: false

        - name: Reload Nginx
          systemd:
            name: nginx
            state: reloaded

        - name: Obtain Let's Encrypt certificate
          command: >
            certbot --nginx -d {{ keycloak_domain }}
            --non-interactive --agree-tos
            --email {{ letsencrypt_email }}
            --redirect
          when: use_letsencrypt
          register: certbot_result

      when: configure_reverse_proxy and reverse_proxy_type == "nginx"

- name: Display deployment summary
  hosts: keycloak_servers
  become: yes
  gather_facts: no
  tasks:
    - name: Show access information
      debug:
        msg:
          - "=========================================="
          - "Keycloak deployed successfully!"
          - "=========================================="
          - "Host: {{ inventory_hostname }}"
          - "Admin Console: https://{{ keycloak_domain }}/admin"
          - "Username: {{ keycloak_admin_user }}"
          - ""
          - "Check /root/keycloak-info.txt for full details"
          - "=========================================="
```

## Template Nginx

Créez le fichier `templates/nginx-keycloak.conf.j2` :

```nginx
# Keycloak - Nginx Configuration
# Generated by Ansible

upstream keycloak {
    server {{ keycloak_listen_address }}:{{ keycloak_http_port }};
}

server {
    listen 80;
    listen [::]:80;
    server_name {{ keycloak_domain }};

    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # Redirect to HTTPS
    location / {
        return 301 https://$server_name$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name {{ keycloak_domain }};

    # SSL Configuration (will be managed by Certbot)
    ssl_certificate /etc/letsencrypt/live/{{ keycloak_domain }}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{ keycloak_domain }}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/{{ keycloak_domain }}/chain.pem;

    # SSL Security
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    # Headers required for Keycloak
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;

    # Buffer settings for large headers
    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;

    location / {
        proxy_pass http://keycloak;
    }
}
```

## Déploiement

### 1. Vérifier la configuration

```bash
# Test de connectivité
ansible keycloak_servers -i inventory.ini -m ping

# Vérifier les variables
ansible-inventory -i inventory.ini --list --yaml
```

### 2. Déployer sur tous les serveurs

```bash
ansible-playbook -i inventory.ini deploy-keycloak.yml
```

### 3. Déployer sur un serveur spécifique

```bash
ansible-playbook -i inventory.ini deploy-keycloak.yml --limit keycloak-test
```

### 4. Mode dry-run (vérification)

```bash
ansible-playbook -i inventory.ini deploy-keycloak.yml --check
```

---

# Intégration avec Active Directory (Samba AD)

## Prérequis

- Serveur Samba AD déjà déployé et fonctionnel
- Compte de service dans AD pour Keycloak
- Connectivité réseau entre Keycloak et AD

## Variables pour l'intégration AD

Ajoutez à `group_vars/keycloak_servers.yml` :

```yaml
---
# Active Directory Configuration
ad_enabled: true
ad_server: "192.168.1.50"  # IP de votre serveur Samba AD
ad_domain: "example.local"
ad_base_dn: "DC=example,DC=local"
ad_users_dn: "CN=Users,DC=example,DC=local"
ad_bind_dn: "CN=keycloak-service,CN=Users,DC=example,DC=local"
ad_bind_password: "ServiceAccountPassword123!"
ad_realm_name: "company"  # Nom du realm dans Keycloak

# LDAP Settings
ad_connection_url: "ldap://{{ ad_server }}:389"
ad_use_ssl: false  # true si LDAPS (port 636)
ad_vendor: "ad"  # ad, rhds, tivoli, edirectory, other

# User Synchronization
ad_sync_users: true
ad_sync_interval: 86400  # 24 heures en secondes

# Group Mapping
ad_sync_groups: true
ad_group_dn: "CN=Users,DC=example,DC=local"
```

## Playbook d'intégration AD

Créez le fichier `configure-ad.yml` :

```yaml
---
- name: Configure Keycloak Active Directory Integration
  hosts: keycloak_servers
  become: yes
  vars:
    keycloak_admin_cli: "/usr/bin/docker exec keycloak /opt/keycloak/bin/kcadm.sh"
    keycloak_admin_url: "http://localhost:{{ keycloak_http_port }}"

  tasks:
    - name: Wait for Keycloak to be fully started
      uri:
        url: "{{ keycloak_admin_url }}/health/ready"
        status_code: 200
      register: result
      until: result.status == 200
      retries: 30
      delay: 10

    - name: Authenticate with Keycloak admin
      shell: |
        {{ keycloak_admin_cli }} config credentials \
          --server {{ keycloak_admin_url }} \
          --realm master \
          --user {{ keycloak_admin_user }} \
          --password {{ keycloak_admin_password }}
      no_log: true
      changed_when: false

    - name: Create new realm for company
      shell: |
        {{ keycloak_admin_cli }} create realms \
          -s realm={{ ad_realm_name }} \
          -s enabled=true
      register: create_realm
      failed_when: create_realm.rc != 0 and 'already exists' not in create_realm.stderr
      changed_when: create_realm.rc == 0

    - name: Configure LDAP User Federation
      shell: |
        {{ keycloak_admin_cli }} create components \
          -r {{ ad_realm_name }} \
          -s name="Active Directory" \
          -s providerId=ldap \
          -s providerType=org.keycloak.storage.UserStorageProvider \
          -s 'config.priority=["1"]' \
          -s 'config.enabled=["true"]' \
          -s 'config.cachePolicy=["DEFAULT"]' \
          -s 'config.vendor=["{{ ad_vendor }}"]' \
          -s 'config.connectionUrl=["{{ ad_connection_url }}"]' \
          -s 'config.bindDn=["{{ ad_bind_dn }}"]' \
          -s 'config.bindCredential=["{{ ad_bind_password }}"]' \
          -s 'config.usersDn=["{{ ad_users_dn }}"]' \
          -s 'config.authType=["simple"]' \
          -s 'config.searchScope=["2"]' \
          -s 'config.useTruststoreSpi=["ldapsOnly"]' \
          -s 'config.usernameLDAPAttribute=["sAMAccountName"]' \
          -s 'config.rdnLDAPAttribute=["cn"]' \
          -s 'config.uuidLDAPAttribute=["objectGUID"]' \
          -s 'config.userObjectClasses=["person, organizationalPerson, user"]' \
          -s 'config.editMode=["READ_ONLY"]' \
          -s 'config.syncRegistrations=["false"]' \
          -s 'config.pagination=["true"]'
      no_log: true
      register: ldap_config
      failed_when: ldap_config.rc != 0 and 'already exists' not in ldap_config.stderr
      changed_when: ldap_config.rc == 0

    - name: Get LDAP component ID
      shell: |
        {{ keycloak_admin_cli }} get components \
          -r {{ ad_realm_name }} \
          --fields id,name \
          | grep -B1 '"name" : "Active Directory"' \
          | grep '"id"' \
          | cut -d'"' -f4
      register: ldap_component_id
      changed_when: false

    - name: Trigger user synchronization
      shell: |
        {{ keycloak_admin_cli }} create \
          user-storage/{{ ldap_component_id.stdout }}/sync?action=triggerFullSync \
          -r {{ ad_realm_name }}
      when: ad_sync_users and ldap_component_id.stdout != ""
      register: sync_users
      changed_when: sync_users.rc == 0

    - name: Configure group mapper
      shell: |
        {{ keycloak_admin_cli }} create components \
          -r {{ ad_realm_name }} \
          -s name="group-mapper" \
          -s providerId=group-ldap-mapper \
          -s providerType=org.keycloak.storage.ldap.mappers.LDAPStorageMapper \
          -s parentId={{ ldap_component_id.stdout }} \
          -s 'config."groups.dn"=["{{ ad_group_dn }}"]' \
          -s 'config."group.name.ldap.attribute"=["cn"]' \
          -s 'config."group.object.classes"=["group"]' \
          -s 'config."preserve.group.inheritance"=["true"]' \
          -s 'config."membership.ldap.attribute"=["member"]' \
          -s 'config."membership.attribute.type"=["DN"]' \
          -s 'config."groups.ldap.filter"=[""]' \
          -s 'config.mode=["READ_ONLY"]' \
          -s 'config."user.roles.retrieve.strategy"=["LOAD_GROUPS_BY_MEMBER_ATTRIBUTE"]' \
          -s 'config."mapped.group.attributes"=[""]' \
          -s 'config."drop.non.existing.groups.during.sync"=["false"]'
      when: ad_sync_groups and ldap_component_id.stdout != ""
      register: group_mapper
      failed_when: group_mapper.rc != 0 and 'already exists' not in group_mapper.stderr
      changed_when: group_mapper.rc == 0

    - name: Test LDAP connection
      shell: |
        {{ keycloak_admin_cli }} create \
          testLDAPConnection \
          -r {{ ad_realm_name }} \
          -s action=testConnection \
          -s connectionUrl={{ ad_connection_url }} \
          -s bindDn={{ ad_bind_dn }} \
          -s bindCredential={{ ad_bind_password }}
      no_log: true
      register: test_connection
      changed_when: false

    - name: Display connection test result
      debug:
        msg: "LDAP connection test: {{ 'SUCCESS' if test_connection.rc == 0 else 'FAILED' }}"

    - name: Test LDAP authentication
      shell: |
        {{ keycloak_admin_cli }} create \
          testLDAPConnection \
          -r {{ ad_realm_name }} \
          -s action=testAuthentication \
          -s connectionUrl={{ ad_connection_url }} \
          -s bindDn={{ ad_bind_dn }} \
          -s bindCredential={{ ad_bind_password }}
      no_log: true
      register: test_auth
      changed_when: false

    - name: Display authentication test result
      debug:
        msg: "LDAP authentication test: {{ 'SUCCESS' if test_auth.rc == 0 else 'FAILED' }}"

- name: Display AD Integration Summary
  hosts: keycloak_servers
  gather_facts: no
  tasks:
    - name: Show integration summary
      debug:
        msg:
          - "=========================================="
          - "Active Directory Integration Complete!"
          - "=========================================="
          - "Realm: {{ ad_realm_name }}"
          - "AD Server: {{ ad_server }}"
          - "AD Domain: {{ ad_domain }}"
          - "Users DN: {{ ad_users_dn }}"
          - ""
          - "Users have been synchronized from AD"
          - "Users can now login with their AD credentials"
          - ""
          - "Admin Console: https://{{ keycloak_domain }}/admin"
          - "Realm: {{ ad_realm_name }}"
          - "=========================================="
```

## Déploiement avec intégration AD

```bash
# 1. Déployer Keycloak
ansible-playbook -i inventory.ini deploy-keycloak.yml

# 2. Configurer l'intégration AD
ansible-playbook -i inventory.ini configure-ad.yml
```

## Création du compte de service dans Samba AD

Sur votre serveur Samba AD :

```bash
# Se connecter au serveur Samba AD
ssh root@samba-ad-server

# Créer l'utilisateur de service
samba-tool user create keycloak-service 'ServiceAccountPassword123!' \
  --description="Service account for Keycloak LDAP"

# Désactiver l'expiration du mot de passe
samba-tool user setexpiry keycloak-service --noexpiry

# Vérifier l'utilisateur
samba-tool user show keycloak-service
```

## Test de l'intégration

### 1. Vérifier la synchronisation

```bash
# Dans Keycloak Admin Console
# Realm {{ ad_realm_name }} → Users
# Vous devriez voir les utilisateurs AD
```

### 2. Tester l'authentification

```bash
# Essayer de se connecter avec un utilisateur AD
# Account Console: https://auth.example.com/realms/company/account
# Utiliser: username@example.local + mot de passe AD
```

### 3. Vérifier les groupes

```bash
# Dans Keycloak Admin Console
# Realm {{ ad_realm_name }} → Groups
# Vous devriez voir les groupes AD synchronisés
```

## Gestion des secrets avec Ansible Vault

```bash
# Créer un fichier de variables chiffrées
ansible-vault create group_vars/keycloak_secrets.yml

# Éditer le fichier
ansible-vault edit group_vars/keycloak_secrets.yml

# Contenu du fichier
---
vault_keycloak_admin_password: "SuperSecretPassword123!"
vault_ad_bind_password: "ServiceAccountPassword123!"

# Dans group_vars/keycloak_servers.yml, référencer ces variables
keycloak_admin_password: "{{ vault_keycloak_admin_password }}"
ad_bind_password: "{{ vault_ad_bind_password }}"

# Déployer avec le vault
ansible-playbook -i inventory.ini deploy-keycloak.yml --ask-vault-pass
```

## Troubleshooting AD Integration

### Test de connexion LDAP

```bash
# Depuis le serveur Keycloak
sudo docker exec -it keycloak bash

# Installer ldapsearch
apt update && apt install -y ldap-utils

# Tester la connexion
ldapsearch -x -H ldap://192.168.1.50:389 \
  -D "CN=keycloak-service,CN=Users,DC=example,DC=local" \
  -w "ServiceAccountPassword123!" \
  -b "CN=Users,DC=example,DC=local" \
  "(objectClass=person)"
```

### Logs Keycloak

```bash
# Voir les logs de Keycloak
sudo docker logs keycloak -f | grep -i ldap

# Augmenter le niveau de log
# Éditez /opt/keycloak/config/.env
KC_LOG_LEVEL=debug
# Redémarrer
sudo systemctl restart keycloak
```

## Ressources

- Documentation Ansible : https://docs.ansible.com/
- Keycloak LDAP Guide : https://www.keycloak.org/docs/latest/server_admin/#_ldap
- Samba AD Documentation : https://wiki.samba.org/index.php/Setting_up_Samba_as_an_Active_Directory_Domain_Controller
