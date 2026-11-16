# graylog-install

Installation automatisée de **Graylog 7.2** sur **Debian 13** (trixie), avec une
interface console dans le style de [glpi-auto](https://github.com/memton80/glpi-auto).

Le script installe et configure sur une seule machine toute la pile décrite par
la [documentation officielle de Graylog](https://go2docs.graylog.org/current/downloading_and_installing_graylog/debian_installation.htm) :

| Composant | Version | Rôle |
|---|---|---|
| MongoDB | 8.0 | base des métadonnées et de la configuration |
| Graylog Data Node | 7.2 | stockage et recherche des logs (OpenSearch embarqué) |
| Graylog (Open ou Enterprise) | 7.2 | serveur, interface web et API |

## Utilisation

```bash
wget https://raw.githubusercontent.com/memton80/graylog-install/main/install-graylog.sh
su -                       # ou : sudo -i
bash install-graylog.sh
```

Il faut être **root**, dans un **terminal interactif** d'au moins 74 x 20
caractères, avec un accès Internet (environ 3 Go sont téléchargés).

| Variable | Valeurs | Effet |
|---|---|---|
| `GRAYLOG_LANG` | `fr`, `en` | langue de l'interface, sans passer par l'écran de choix |
| `GRAYLOG_THEME` | `dark`, `light` | thème de couleurs, sans détection automatique |

## L'interface

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                           GRAYLOG AUTO - INSTALLATION SUR DEBIAN 13                    v1.0      │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
┌─ Configuration ─────────────────────────────────────────────┐ ┌─ Machine ────────────────────────┐
│  v Graylog                                                  │ │ Nom d'hote  : graylog13          │
│     Edition                       < Graylog Open >          │ │ Adresse IP  : 192.168.1.50       │
│     Mot de passe auto             < oui >                   │ │ Systeme     : Debian 13          │
│                                                             │ │ Processeur  : 4 coeurs           │
│  v Interface web                                            │ │ Memoire     : 15,7 Go            │
│     Adresse d'ecoute              0.0.0.0                   │ │ Disque /var : 48,2 Go libres     │
│     Port web                      9000                      │ │ Pare-feu    : aucun              │
│                                                             │ │ Port 9000   : libre              │
│  v MongoDB                                                  │ │ Port 27017  : libre              │
│     Ecoute de MongoDB             < locale (127.0.0.1) >    │ │ Port 9200   : libre              │
│                                                             │ └──────────────────────────────────┘
│  v Memoire et journal                                       │ ┌─ Raccourcis ─────────────────────┐
│     Memoire OpenSearch            4g                        │ │ Haut/Bas      naviguer           │
│     Memoire Graylog               4g                        │ │ Entree        modifier / valider │
│     Age max du journal            72h                       │ │ Espace        changer la valeur  │
│     Journal max (Go)              5                         │ │ Gauche/Droite replier / changer  │
│                                                             │ │ r             actualiser machine │
│  v Systeme                                                  │ │ t             theme clair/sombre │
│     Fuseau horaire                Europe/Paris              │ │ q             quitter            │
│     Pare-feu UFW                  < oui >                   │ │                                  │
│     Ports des entrees             (vide)                    │ │                                  │
└─────────────────────────────────────────────────────────[v]─┘ └──────────────────────────────────┘
┌──────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                         [ INSTALLER ]                                            │
└──────────────────────────────────────────────────────────────────────────────────────────────────┘
 Entree ou Gauche/Droite pour replier ou deplier la section.
```

- **Machine** (en haut à droite) : nom d'hôte, adresse IP, système, processeur
  (avec la présence des instructions AVX), mémoire, disque, pare-feu et état des
  ports 9000, 27017 et 9200.
- **Configuration** : menus dépliants, modifiables au clavier.
- **INSTALLER** : lance l'installation après confirmation.
- **Écrans d'installation** : Tux animé et barre de progression réelle, d'abord
  pour le téléchargement des paquets, puis pour la configuration.
- **Écran final** : adresse de Graylog, identifiants du preflight et du compte
  admin, état des services.

| Touche | Action |
|---|---|
| Haut / Bas, Tab | naviguer |
| Entrée | modifier le champ, valider |
| Espace | changer la valeur (oui / non, liste) |
| Gauche / Droite | replier une section, changer la valeur |
| `r` | actualiser le panneau Machine |
| `t` | thème clair / sombre |
| `q`, Échap | quitter |

## Les réglages

| Section | Champ | Défaut | Réglage Graylog |
|---|---|---|---|
| Graylog | Édition | Graylog Open | paquet `graylog-server` ou `graylog-enterprise` |
| | Mot de passe auto | oui | mot de passe admin généré (16 caractères) |
| | Mot de passe admin | | `root_password_sha2` |
| Interface web | Adresse d'écoute | `0.0.0.0` | `http_bind_address` |
| | Port web | `9000` | `http_bind_address` |
| MongoDB | Écoute de MongoDB | locale | `bindIp` / `bindIpAll` de `mongod.conf` |
| Mémoire et journal | Mémoire OpenSearch | ¼ de la RAM | `opensearch_heap` |
| | Mémoire Graylog | ¼ de la RAM | `-Xms` / `-Xmx` de `GRAYLOG_SERVER_JAVA_OPTS` |
| | Âge max du journal | `72h` | `message_journal_max_age` |
| | Journal max (Go) | `5` | `message_journal_max_size` |
| Système | Fuseau horaire | celui de la machine | `timedatectl set-timezone` |
| | Pare-feu UFW | oui | ouvre SSH et le port web |
| | Ports des entrées | vide | ports à ouvrir pour les entrées de logs |
| | Vérifications | oui | contrôle des trois services à la fin |

## Ce que fait le script

Chaque étape reprend les commandes de la documentation officielle ; la commande
d'origine est rappelée en commentaire (`# doc :`) dans le script.

**Téléchargement des composants**

1. attente du gestionnaire de paquets, puis `apt-get update` ;
2. prérequis : `gnupg`, `curl`, `wget`, `ca-certificates`, `openssl`, `procps` ;
3. dépôt MongoDB : clé `server-8.0.asc` et fichier `mongodb-org-8.0.list` ;
4. dépôt Graylog : paquet `graylog-7.2-repository_latest.deb` ;
5. installation de `mongodb-org`, `graylog-datanode`, puis `graylog-server`
   (ou `graylog-enterprise`).

**Configuration**

1. fuseau horaire, puis vérification que le nom d'hôte de la machine se résout
   (le Data Node refuse de démarrer sinon ; la ligne manquante est ajoutée à
   `/etc/hosts`) ;
2. MongoDB : version figée (`apt-mark hold`), écoute réseau, activation et
   démarrage, attente de la réponse sur le port 27017 ;
3. noyau : `vm.max_map_count=262144` dans `/etc/sysctl.d/99-graylog-datanode.conf` ;
4. Data Node : `password_secret`, `opensearch_heap` et `mongodb_uri` dans
   `/etc/graylog/datanode/datanode.conf`, activation et démarrage ;
5. Graylog : `password_secret`, `root_password_sha2`, `http_bind_address`,
   `mongodb_uri` et journal dans `/etc/graylog/server/server.conf`, mémoire Java
   dans `/etc/default/graylog-server` ;
6. pare-feu UFW (facultatif) ;
7. démarrage de Graylog et attente de l'interface de configuration initiale ;
8. nettoyage des archives téléchargées.

## Après l'installation : le preflight

Graylog impose une configuration initiale dans le navigateur, à faire une seule
fois. L'écran final donne tout ce qu'il faut :

1. ouvrir l'adresse affichée (`http://<adresse IP>:9000/`) et se connecter avec
   les **identifiants temporaires** que le script a relevés dans
   `/var/log/graylog-server/server.log` ;
2. suivre les quatre étapes de l'assistant : *Create CA* (autorité de
   certification), *Create policy* (renouvellement), *Provision certificate and
   continue*, puis *Resume startup* ;
3. se reconnecter avec le compte **admin** et le mot de passe choisi.

Le mot de passe admin ne fonctionne pas pour l'étape 1 : c'est le comportement
prévu par Graylog.

## Fichiers

| Fichier | Contenu |
|---|---|
| `/var/log/graylog-install.log` | journal complet de l'installation |
| `/root/graylog-credentials.txt` | adresse et identifiants (lisible par root seul) |
| `*.graylog-auto.bak` | copie des fichiers de configuration livrés par les paquets |

## Choix par rapport à la documentation

- **Une seule machine.** La documentation décrit deux serveurs (Graylog et
  MongoDB d'un côté, Data Node de l'autre) et demande de donner à chacun la
  moitié de sa mémoire. Ici les trois services cohabitent : la moitié de la RAM
  est partagée entre OpenSearch et Graylog, le reste va à MongoDB et au système.
- **MongoDB écoute en local par défaut.** Tout étant sur la même machine,
  MongoDB n'a pas besoin d'être joignable depuis le réseau. Les deux autres
  choix du formulaire sont ceux de la documentation.
- **Dépôt MongoDB `bookworm`.** C'est celui de la documentation, et le seul
  possible sur Debian 13 : MongoDB ne publie pas le serveur dans sa suite
  `trixie`. Les paquets s'installent tels quels.
- **Le script peut être relancé.** Les fichiers de configuration sont mis à
  jour sans doublon, le `password_secret` existant est conservé et les services
  sont redémarrés. Un Graylog déjà configuré est reconnu : l'écran final ne
  redemande pas le preflight.
- **Pas de désinstallation.** Le script installe et configure ; il ne retire
  rien.

## Matériel

| | Minimum | Recommandé |
|---|---|---|
| Processeur | instructions AVX obligatoires (MongoDB) | 4 cœurs |
| Mémoire | 4 Go | 8 Go |
| Disque libre sur `/var` | 10 Go | 30 Go |

Le script signale avant l'installation ce qui empêcherait Graylog de tourner :

- **processeur sans AVX** : MongoDB ne démarre pas. Sur une machine virtuelle,
  choisir un type de processeur qui expose AVX (`host` sous Proxmox / KVM) ;
- **`/tmp` monté en `noexec`** (serveur durci) : OpenSearch ne démarre pas.
