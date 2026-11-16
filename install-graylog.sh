#!/bin/bash
#==============================================================================
#  GRAYLOG AUTO - Installation automatisee de Graylog sur Debian 13
#
#  Installe sur une seule machine la pile complete decrite par la documentation
#  officielle de Graylog 7.2 (https://go2docs.graylog.org/current/) :
#
#      MongoDB 8.0  ->  Graylog Data Node  ->  Graylog (Open ou Enterprise)
#
#  Interface console maison (aucune dependance a whiptail / dialog), reprise
#  de glpi-auto :
#    - panneau "Machine" en haut a droite (IP, materiel, pare-feu, ports)
#    - grand panneau de configuration avec menus depliants
#    - bouton INSTALLER en bas
#    - ecrans d'installation avec Tux anime et barre de progression reelle
#    - ecran final : identifiants du preflight et de l'administrateur
#
#  Auteur : memton80
#==============================================================================

set -o pipefail

#------------------------------------------------------------------ constantes
SCRIPT_VERSION="1.0"

# Versions suivies par la documentation officielle ("current") de Graylog.
GRAYLOG_SERIES="7.2"
MONGODB_SERIES="8.0"
# La documentation Graylog installe MongoDB depuis la suite "bookworm". C'est
# aussi la seule possible sur Debian 13 : la suite "trixie" du depot MongoDB
# ne contient que les outils (mongosh...), pas le serveur. Les paquets
# bookworm s'installent tels quels sur Debian 13.
MONGODB_SUITE="bookworm"

GRAYLOG_REPO_DEB="graylog-${GRAYLOG_SERIES}-repository_latest.deb"
GRAYLOG_REPO_URL="https://packages.graylog2.org/repo/packages/${GRAYLOG_REPO_DEB}"
MONGODB_KEY_URL="https://www.mongodb.org/static/pgp/server-${MONGODB_SERIES}.asc"
MONGODB_KEYRING="/usr/share/keyrings/mongodb-server-${MONGODB_SERIES}.gpg"
MONGODB_LIST="/etc/apt/sources.list.d/mongodb-org-${MONGODB_SERIES}.list"
MONGODB_REPO="https://repo.mongodb.org/apt/debian"

MONGOD_CONF="/etc/mongod.conf"
DN_CONF="/etc/graylog/datanode/datanode.conf"
GL_CONF="/etc/graylog/server/server.conf"
GL_DEFAULT="/etc/default/graylog-server"
GL_LOG="/var/log/graylog-server/server.log"
SYSCTL_FILE="/etc/sysctl.d/99-graylog-datanode.conf"
MAX_MAP_COUNT=262144

LOGFILE="/var/log/graylog-install.log"
CRED_FILE="/root/graylog-credentials.txt"

# Fichiers de travail : crees dans un repertoire prive par make_workdir()
WORKDIR=""
STEP_LOG="/dev/null"
APT_STATUS="/dev/null"
FW_PORTS_FILE="/dev/null"
PREFLIGHT_FILE="/dev/null"
GL_OFFSET_FILE="/dev/null"

FW_PORTS=""                 # ports ouverts par cette installation
GL_WAIT_MAX=420             # attente maximale du premier demarrage (secondes)
MONGO_WAIT_MAX=90
DN_WATCH=20                 # duree d'observation du Data Node apres son lancement
RESIZED=0

export PATH="$PATH:/usr/sbin:/sbin:/usr/local/sbin"
export DEBIAN_FRONTEND=noninteractive
# Les fichiers poses dans /etc doivent rester lisibles par tous et modifiables
# par root seul, quel que soit le masque herite de la session.
umask 022

#------------------------------------------------------- distribution detectee
# OS_ID       : "debian", "ubuntu"...
# OS_VER      : numero de version majeur (12, 13...), 0 si illisible
# OS_CODENAME : "bookworm", "trixie"...
# OS_LABEL    : libelle court affiche dans l'interface ("DEBIAN 13")
OS_ID="debian"
OS_VER=0
OS_CODENAME=""
OS_LABEL="DEBIAN"
OS_ARCH=""

detect_os_release() {
    local id="" ver="" code=""
    if [[ -r /etc/os-release ]]; then
        id=$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-}")
        ver=$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-}")
        code=$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}")
    fi
    [[ -n $id ]] && OS_ID=$id
    OS_CODENAME=$code
    ver=${ver%%.*}
    if [[ $ver =~ ^[0-9]+$ ]]; then OS_VER=$ver; else OS_VER=0; fi

    OS_LABEL=${OS_ID^^}
    (( OS_VER > 0 )) && OS_LABEL="$OS_LABEL $OS_VER"

    OS_ARCH=$(dpkg --print-architecture 2>/dev/null)
    [[ -z $OS_ARCH ]] && OS_ARCH=$(uname -m 2>/dev/null)
}

# Debian 13 est la cible, Debian 12 est la version couverte par la doc Graylog.
os_supported()   { [[ $OS_ID == debian ]] && (( OS_VER == 12 || OS_VER == 13 )); }
arch_supported() { [[ $OS_ARCH == amd64 || $OS_ARCH == arm64 ]]; }

#==============================================================================
#  1. TERMINAL : locale, couleurs, caracteres de cadre
#==============================================================================

setup_locale() {
    if [[ "$(locale charmap 2>/dev/null)" != "UTF-8" ]]; then
        if locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then
            export LC_ALL="C.UTF-8" LANG="C.UTF-8"
        elif locale -a 2>/dev/null | grep -qiE '^fr_FR\.utf-?8$'; then
            export LC_ALL="fr_FR.UTF-8" LANG="fr_FR.UTF-8"
        fi
    fi
    if [[ "$(locale charmap 2>/dev/null)" == "UTF-8" ]]; then
        UTF8=1
    else
        UTF8=0
    fi
}

setup_charset() {
    if (( UTF8 )); then
        BX_TL='┌'; BX_TR='┐'; BX_BL='└'; BX_BR='┘'; BX_H='─'; BX_V='│'
        BAR_FULL='█'; BAR_EMPTY='░'; GROUND='─'
    else
        BX_TL='+'; BX_TR='+'; BX_BL='+'; BX_BR='+'; BX_H='-'; BX_V='|'
        BAR_FULL='#'; BAR_EMPTY='.'; GROUND='-'
    fi
}

# THEME vaut "dark" (fond sombre) ou "light" (fond clair).
THEME="dark"

# Demande au terminal la couleur de son fond (OSC 11) pour choisir la palette.
# En cas de non-reponse on retombe sur COLORFGBG puis sur le theme sombre.
detect_theme() {
    case "${GRAYLOG_THEME:-}" in
        light|clair)  THEME="light"; return ;;
        dark|sombre)  THEME="dark";  return ;;
    esac

    THEME="dark"
    local resp="" r g b lum saved=""
    if [[ -t 0 && -t 1 ]]; then
        saved=$(stty -g 2>/dev/null)
        stty -echo 2>/dev/null
        printf '\e]11;?\e\\'
        IFS= read -rs -d '\' -t 0.3 resp 2>/dev/null
        [[ -n $saved ]] && stty "$saved" 2>/dev/null
    fi
    if [[ $resp =~ rgb:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4}) ]]; then
        # les composantes font 1 a 4 chiffres hexa : on ne garde que le poids fort
        r=$(( 16#${BASH_REMATCH[1]:0:2} ))
        g=$(( 16#${BASH_REMATCH[2]:0:2} ))
        b=$(( 16#${BASH_REMATCH[3]:0:2} ))
        lum=$(( (r * 299 + g * 587 + b * 114) / 1000 ))
        (( lum > 128 )) && THEME="light"
        return
    fi
    # COLORFGBG = "avant-plan;arriere-plan", fond 7 ou 15 = clair
    if [[ ${COLORFGBG:-} =~ ^[0-9]+\;([0-9]+)$ ]]; then
        case "${BASH_REMATCH[1]}" in
            7|15) THEME="light" ;;
        esac
    fi
}

toggle_theme() {
    if [[ $THEME == dark ]]; then THEME="light"; else THEME="dark"; fi
    setup_colors
}

setup_colors() {
    local ncol=8
    command -v tput >/dev/null 2>&1 && ncol=$(tput colors 2>/dev/null || echo 8)
    [[ "$ncol" =~ ^[0-9]+$ ]] || ncol=8

    C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_REV=$'\e[7m'

    if (( ncol >= 256 )); then
        if [[ $THEME == light ]]; then
            C_FRAME=$'\e[38;5;245m'      # cadre inactif
            C_FRAME_ON=$'\e[38;5;28m'    # cadre du panneau actif
            C_TITLE=$'\e[38;5;25m'       # titres de panneaux
            C_LABEL=$'\e[38;5;238m'
            C_VALUE=$'\e[38;5;16m'
            C_OK=$'\e[38;5;28m'
            C_WARN=$'\e[38;5;130m'
            C_ERR=$'\e[38;5;124m'
            C_MUTED=$'\e[38;5;242m'
            C_SEC=$'\e[38;5;54m'
            C_SEL=$'\e[48;5;253m'
            C_BTN=$'\e[38;5;28m'
            C_BTN_ON=$'\e[48;5;28m\e[38;5;231m'
            C_TUX=$'\e[38;5;16m'
            C_TUX_FEET=$'\e[38;5;130m'
            C_BAR=$'\e[38;5;28m'
            C_BAR_BG=$'\e[38;5;252m'
        else
            C_FRAME=$'\e[38;5;240m'
            C_FRAME_ON=$'\e[38;5;114m'
            C_TITLE=$'\e[38;5;81m'
            C_LABEL=$'\e[38;5;250m'
            C_VALUE=$'\e[38;5;231m'
            C_OK=$'\e[38;5;114m'
            C_WARN=$'\e[38;5;214m'
            C_ERR=$'\e[38;5;203m'
            C_MUTED=$'\e[38;5;244m'
            C_SEC=$'\e[38;5;147m'
            C_SEL=$'\e[48;5;238m'
            C_BTN=$'\e[38;5;114m'
            C_BTN_ON=$'\e[48;5;114m\e[38;5;16m'
            C_TUX=$'\e[38;5;255m'
            C_TUX_FEET=$'\e[38;5;214m'
            C_BAR=$'\e[38;5;114m'
            C_BAR_BG=$'\e[38;5;238m'
        fi
    else
        if [[ $THEME == light ]]; then
            C_FRAME=$'\e[90m'; C_FRAME_ON=$'\e[32m'; C_TITLE=$'\e[34m'
            C_LABEL=$'\e[30m'; C_VALUE=$'\e[30m'; C_OK=$'\e[32m'
            C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_MUTED=$'\e[90m'
            C_SEC=$'\e[35m'; C_SEL=$'\e[7m'; C_BTN=$'\e[32m'
            C_BTN_ON=$'\e[42m\e[97m'; C_TUX=$'\e[30m'; C_TUX_FEET=$'\e[33m'
            C_BAR=$'\e[32m'; C_BAR_BG=$'\e[37m'
        else
            C_FRAME=$'\e[90m'; C_FRAME_ON=$'\e[32m'; C_TITLE=$'\e[36m'
            C_LABEL=$'\e[37m'; C_VALUE=$'\e[97m'; C_OK=$'\e[32m'
            C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_MUTED=$'\e[90m'
            C_SEC=$'\e[36m'; C_SEL=$'\e[100m'; C_BTN=$'\e[32m'
            C_BTN_ON=$'\e[42m\e[30m'; C_TUX=$'\e[97m'; C_TUX_FEET=$'\e[33m'
            C_BAR=$'\e[32m'; C_BAR_BG=$'\e[90m'
        fi
    fi
}

tui_start() {
    printf '\e[?1049h'   # ecran alternatif
    printf '\e[?25l'     # curseur cache
    stty -echo 2>/dev/null
}

tui_stop() {
    stty echo 2>/dev/null
    printf '\e[?25h'
    printf '\e[?1049l'
}

cursor_show() { printf '\e[?25h'; }
cursor_hide() { printf '\e[?25l'; }

on_resize() { RESIZED=1; }

compute_layout() {
    COLS=$(tput cols 2>/dev/null || echo 80)
    ROWS=$(tput lines 2>/dev/null || echo 24)
    [[ "$COLS" =~ ^[0-9]+$ ]] || COLS=80
    [[ "$ROWS" =~ ^[0-9]+$ ]] || ROWS=24

    RIGHT_W=36
    (( COLS < 100 )) && RIGHT_W=32
    (( COLS < 90 ))  && RIGHT_W=30

    HEAD_Y=1;  HEAD_H=3
    BODY_Y=$(( HEAD_Y + HEAD_H ))
    FOOT_H=3
    FOOT_Y=$(( ROWS - FOOT_H ))
    BODY_H=$(( FOOT_Y - BODY_Y ))

    FORM_X=1
    FORM_W=$(( COLS - RIGHT_W - 1 ))
    RIGHT_X=$(( COLS - RIGHT_W + 1 ))
    # 12 lignes : panneau machine detaille (10 informations)
    # 8 lignes  : version compacte, pour garder tous les raccourcis visibles
    MACH_H=12
    HELP_H=$(( BODY_H - MACH_H ))
    if (( HELP_H < 9 )); then
        MACH_H=8
        HELP_H=$(( BODY_H - MACH_H ))
    fi
    (( HELP_H < 3 )) && { MACH_H=$(( BODY_H - 3 )); HELP_H=3; }

    FORM_ROWS=$(( BODY_H - 2 ))
}

term_too_small() { (( COLS < 74 || ROWS < 20 )); }

#==============================================================================
#  2. TRADUCTIONS
#
#  Toutes les chaines affichees sont chargees dans des variables L_* par
#  load_strings(), appelee une fois la langue choisie. Les deux blocs se
#  suivent dans le meme ordre pour rester faciles a comparer.
#==============================================================================

UILANG="fr"
declare -a L_KEYS

load_strings() {
    if [[ $UILANG == en ]]; then
        # ---------------------------------------------------------- ENGLISH
        L_APP_TITLE="GRAYLOG AUTO - $OS_LABEL INSTALLER"
        L_PANEL_CONFIG="Configuration"
        L_PANEL_MACHINE="Machine"
        L_PANEL_KEYS="Shortcuts"
        L_BTN_INSTALL="[ INSTALL ]"
        L_KEYS=(
            "Up/Down|move"
            "Enter|edit / confirm"
            "Space|change value"
            "Left/Right|fold / change"
            "r|refresh machine"
            "t|light/dark theme"
            "q|quit"
        )
        L_NOTE_TARGET="Installed version"
        L_NOTE_LOG="Log file"

        # panneau machine
        L_M_HOST="Hostname"
        L_M_IP="IP address"
        L_M_OS="System"
        L_M_CPU="CPU"
        L_M_RAM="Memory"
        L_M_DISK="Disk /var"
        L_M_FW="Firewall"
        L_M_PWEB="Port %s"
        L_M_CPURAM="CPU / RAM"
        L_M_PORTS="Ports"
        L_V_FREE="free"
        L_V_BUSY="in use"
        L_V_ALLFREE="all free"
        L_V_UNKNOWN="unknown"
        L_V_UNKNOWN_F="unknown"
        L_V_ACTIVE="active"
        L_V_INACTIVE="inactive"
        L_V_NONE="none"
        L_V_CORE="core"
        L_V_CORES="cores"
        L_V_NOAVX="no AVX"
        L_V_SPACE_FREE="free"
        L_V_SPACE_FREE_P="free"
        L_U_GB="GB"; L_U_MB="MB"; L_U_KB="KB"; L_U_B="B"
        L_DECIMAL="."

        # formulaire
        L_SEC_GRAYLOG="Graylog"
        L_SEC_WEB="Web interface"
        L_SEC_MONGO="MongoDB"
        L_SEC_MEM="Memory and journal"
        L_SEC_SYSTEM="System"
        L_F_EDITION="Edition"
        L_H_EDITION="Open: graylog-server package. Enterprise / Security: graylog-enterprise."
        L_O_OPEN="Graylog Open"
        L_O_ENT="Graylog Enterprise"
        L_F_ADMAUTO="Auto password"
        L_H_ADMAUTO="Generates a strong 16 character password for the Graylog admin account."
        L_F_ADMPASS="Admin password"
        L_H_ADMPASS="Password of the admin account (root_password_sha2). 8 characters minimum."
        L_F_BIND="Listen address"
        L_H_BIND="http_bind_address: 0.0.0.0 listens on every interface, as in the docs."
        L_F_PORT="Web port"
        L_H_PORT="Port of the web interface and API (9000 by default, 1024 to 65535)."
        L_F_MBIND="MongoDB listener"
        L_H_MBIND="Everything runs on this machine: local is enough. Others: as in the docs."
        L_O_MLOCAL="local (127.0.0.1)"
        L_O_MALL="all interfaces"
        L_O_MIP="machine IP"
        L_F_OSHEAP="OpenSearch memory"
        L_H_OSHEAP="opensearch_heap (e.g. 4g, 31g max). Half of the RAM is shared with Graylog."
        L_F_GLHEAP="Graylog memory"
        L_H_GLHEAP="Graylog Java heap, -Xms and -Xmx (e.g. 2g, 16g max)."
        L_F_JAGE="Journal max age"
        L_H_JAGE="message_journal_max_age: 72h recommended by the docs (e.g. 12h, 72h, 3d)."
        L_F_JSIZE="Journal max (GB)"
        L_H_JSIZE="message_journal_max_size: docs advise the log volume expected over 72 hours."
        L_F_TZ="Time zone"
        L_H_TZ="timedatectl set-timezone. The Graylog docs use UTC (e.g. UTC, Europe/Paris)."
        L_F_FIREWALL="UFW firewall"
        L_H_FIREWALL="Opens SSH and the web port. Existing rules are kept."
        L_F_FWIN="Log input ports"
        L_H_FWIN="Ports to open for your inputs, e.g. 1514/udp 12201/udp 5044/tcp (empty: none)."
        L_F_TESTS="Verification tests"
        L_H_TESTS="Checks MongoDB, Data Node and Graylog once installed."

        # barre de statut
        L_ST_BUTTON="Press Enter to start the Graylog installation."
        L_ST_SECTION="Enter or Left/Right to fold or unfold the section."
        L_ST_THEME_LIGHT="Light theme enabled (press t for the dark theme)."
        L_ST_THEME_DARK="Dark theme enabled (press t for the light theme)."
        L_ST_REFRESHING="Refreshing machine information..."
        L_ST_REFRESHED="Machine information refreshed."

        # modales
        L_ANY_KEY="Press any key to continue"
        L_ANY_KEY_QUIT="Press any key to quit"
        L_YES="[ Yes ]"
        L_NO="[ No ]"
        L_YESV="yes"
        L_NOV="no"
        L_UNSET="not set"
        L_EMPTY="empty"
        L_EDIT_HELP="Enter: confirm     Esc: cancel"
        L_PASS_CONFIRM="Confirm the password:"
        L_PASS_RETYPE="Type the same value again."
        L_PASS_MISMATCH_T="Passwords do not match"
        L_PASS_MISMATCH=$'The two entries do not match.\nPlease try again.'
        L_INVALID_T="Invalid value"

        # validation
        L_ERR_PASS_SHORT="The password must be at least 8 characters long."
        L_ERR_PASS_CHARS="Spaces are not allowed in the password."
        L_ERR_BIND="Enter an IPv4 address (0.0.0.0 for all) or a host name."
        L_ERR_PORT="Enter a port between 1024 and 65535."
        L_ERR_PORT_BUSY="Port %s is already used by another program: choose another web port."
        L_ERR_HEAP="Enter a size such as 2g or 1536m."
        L_ERR_HEAP_MIN="The minimum is 512m."
        L_ERR_HEAP_OSMAX="OpenSearch memory cannot exceed 31g."
        L_ERR_HEAP_GLMAX="Graylog memory cannot exceed 16g."
        L_ERR_HEAP_SUM="OpenSearch + Graylog memory (%s) exceeds what this machine can give (%s)."
        L_ERR_DURATION="Enter a duration such as 12h, 72h or 3d."
        L_ERR_GB="Enter a whole number of GB (1 or more)."
        L_ERR_JOURNAL_DISK="A %s GB journal does not fit: %s free on /var, and about %s is needed for the software."
        L_ERR_TZ="Unknown time zone (examples: UTC, Europe/Paris)."
        L_ERR_FWPORTS="Expected format: 1514/udp 12201/tcp ... separated by spaces."
        L_FORM_INCOMPLETE_T="Incomplete configuration"

        # confirmation et sortie
        L_CONFIRM_T="Confirmation"
        L_CONFIRM_BODY=$'The Graylog installation is about to start.\n\nMongoDB %s, Graylog Data Node and Graylog %s\nwill be installed (about 3 GB to download).'
        L_CONFIRM_EXISTS=$'WARNING: Graylog is already installed here.\nIts configuration will be updated and the\nservices restarted (existing data is kept).'
        L_CONFIRM_HW="WARNING: issues found on this machine"
        L_CONFIRM_PORTS="WARNING: ports already in use on this machine"
        L_CONFIRM_ASK="Start the installation?"
        L_QUIT_T="Quit"
        L_QUIT_ASK="Quit without installing Graylog?"
        L_CANCELLED="Installation cancelled by the user."
        L_NET_T="No Internet connection"
        L_NET_BODY=$'The Graylog package repository cannot be reached.\n\nA connection is required to download MongoDB\nand the Graylog packages.'
        L_OS_T="Untested system"
        L_OS_BODY=$'This script targets Debian 13 (Debian 12 is the\nversion covered by the Graylog documentation).\n\nDetected system: %s\n\nYou can proceed, without any guarantee.'
        L_ARCH_T="Unsupported architecture"
        L_ARCH_BODY=$'MongoDB and Graylog packages only exist for\namd64 and arm64.\n\nDetected architecture: %s'
        L_TOO_SMALL="Terminal too small: %sx%s. Minimum required 74x20."
        L_TOO_SMALL_CLI="Enlarge the terminal window (minimum 74x20) then run the script again."

        # materiel
        L_HW_T="Machine check"
        L_HW_HEAD="This machine is below the recommendations."
        L_HW_HEAD_CRIT="This machine cannot run Graylog properly."
        L_HW_CONSEQ=$'The installation is still possible, but Graylog\nis likely to be slow under load.'
        L_HW_CONSEQ_CRIT=$'The installation may fail, or leave a Graylog\nthat does not start.'
        L_HW_CONTINUE="You can proceed anyway."
        L_HW_L_CPU="CPU"
        L_HW_L_RAM="Memory"
        L_HW_L_DISK="Disk /var"
        L_HW_L_AVX="Processor"
        L_HW_RECO_CPU="%s cores recommended"
        L_HW_RECO="%s recommended"
        L_HW_INSUF="insufficient"
        L_HW_INSUF_F="insufficient"
        L_HW_AVX="no AVX instructions (MongoDB will not start)"
        L_HW_TMP="mounted noexec (OpenSearch will not start)"
        L_HW_SHORT_CPU="CPU"
        L_HW_SHORT_RAM="memory"
        L_HW_SHORT_DISK="disk"
        L_HW_SHORT_AVX="AVX"

        # ecrans d'installation
        L_ANIM_DL_TITLE="DOWNLOADING COMPONENTS"
        L_ANIM_INST_TITLE="INSTALLATION"
        L_ANIM_DL_PHASE="DOWNLOAD IN PROGRESS"
        L_ANIM_INST_PHASE="CONFIGURATION IN PROGRESS"
        L_ANIM_FAIL_PHASE="INSTALLATION INTERRUPTED"
        L_ANIM_LOG="Full log: %s"
        L_INFO_DL="Downloading: file %s of %s"
        L_INFO_LEFT="%s left"
        L_INFO_PKG="Package: %s"

        # etapes
        L_S_APT_LOCK="Waiting for the package manager"
        L_S_APT_UPDATE="Updating package lists"
        L_S_PREREQ="Installing the prerequisites (gnupg, curl...)"
        L_S_MONGO_REPO="Adding the MongoDB repository"
        L_S_GL_REPO="Adding the Graylog repository"
        L_S_APT_UPDATE2="Reading the new repositories"
        L_S_APT_MONGO="Downloading and installing MongoDB"
        L_S_APT_DN="Downloading and installing Graylog Data Node"
        L_S_APT_GL="Downloading and installing Graylog"
        L_S_TZ="Setting the time zone"
        L_S_HOSTNAME="Checking the host name"
        L_S_MONGO_CONF="Configuring MongoDB"
        L_S_MONGO_START="Starting MongoDB"
        L_S_SYSCTL="Kernel setting vm.max_map_count"
        L_S_DN_CONF="Configuring the Data Node"
        L_S_DN_START="Starting the Data Node"
        L_S_GL_CONF="Configuring Graylog"
        L_S_FIREWALL="Configuring the UFW firewall"
        L_S_FIREWALL_SKIP="Firewall skipped"
        L_S_GL_START="Starting Graylog"
        L_S_GL_WAIT="Waiting for the first start of Graylog"
        L_S_CLEANUP="Cleaning up"
        L_S_DONE="Done"

        # erreurs d'etape
        L_E_APT_UPDATE="Updating the package lists failed."
        L_E_PREREQ="Installing the prerequisites failed."
        L_E_MONGO_REPO="The MongoDB repository could not be added."
        L_E_GL_REPO="The Graylog repository could not be added."
        L_E_APT_MONGO="Installing MongoDB failed."
        L_E_APT_DN="Installing Graylog Data Node failed."
        L_E_APT_GL="Installing Graylog failed."
        L_E_TZ="Setting the time zone failed."
        L_E_HOSTNAME="The host name of this machine cannot be resolved."
        L_E_MONGO_CONF="Configuring MongoDB failed."
        L_E_MONGO_START="MongoDB did not start."
        L_E_SYSCTL="vm.max_map_count could not be raised to %s."
        L_E_DN_CONF="Configuring the Data Node failed."
        L_E_DN_START="The Data Node did not start."
        L_E_GL_CONF="Configuring Graylog failed."
        L_E_FIREWALL="Configuring the firewall failed."
        L_E_GL_START="Graylog did not start."
        L_E_SECRET="The password secret could not be generated."
        L_FATAL_T="Installation failed"
        L_FATAL_LOGTAIL="Last lines of the log:"
        L_FATAL_NONE="(nothing)"
        L_FATAL_LOG="Full log: %s"
        L_FATAL_CLI="Installation failed: %s"
        L_FATAL_CLI2="See the log: %s"

        # ecran final
        L_FINAL_T="Installation complete"
        L_FINAL_DONE="Graylog was installed successfully!"
        L_FINAL_STEP1="1. INITIAL SETUP (preflight) - only once"
        L_FINAL_STEP2="2. GRAYLOG LOGIN - once the preflight is done"
        L_FINAL_LOGIN="GRAYLOG LOGIN"
        L_FINAL_URL="Address"
        L_FINAL_CRED="Credentials"
        L_FINAL_TEMP="(temporary)"
        L_FINAL_PF_HELP1="Follow the 4 steps of the wizard: certificate authority,"
        L_FINAL_PF_HELP2="renewal policy, certificates, then \"Resume startup\"."
        L_FINAL_WARN="WARNING: the admin password does not work in step 1."
        L_FINAL_TYPED="(the password you typed)"
        L_FINAL_TIMEOUT1="WARNING: Graylog has not finished starting yet."
        L_FINAL_TIMEOUT2="Initial password: tail %s"
        L_FINAL_SERVICES="Services"
        L_FINAL_FW="Firewall"
        L_FINAL_FW_OPEN="open ports: %s"
        L_FINAL_FW_HINT="Open your input ports later with: ufw allow 1514/udp"
        L_FINAL_CREDFILE="Saved to"
        L_FINAL_LOG="Log file"
        L_T_UP="running"
        L_T_DOWN="STOPPED"
    else
        # --------------------------------------------------------- FRANCAIS
        L_APP_TITLE="GRAYLOG AUTO - INSTALLATION SUR $OS_LABEL"
        L_PANEL_CONFIG="Configuration"
        L_PANEL_MACHINE="Machine"
        L_PANEL_KEYS="Raccourcis"
        L_BTN_INSTALL="[ INSTALLER ]"
        L_KEYS=(
            "Haut/Bas|naviguer"
            "Entree|modifier / valider"
            "Espace|changer la valeur"
            "Gauche/Droite|replier / changer"
            "r|actualiser machine"
            "t|theme clair/sombre"
            "q|quitter"
        )
        L_NOTE_TARGET="Version installee"
        L_NOTE_LOG="Journal"

        # panneau machine
        L_M_HOST="Nom d'hote"
        L_M_IP="Adresse IP"
        L_M_OS="Systeme"
        L_M_CPU="Processeur"
        L_M_RAM="Memoire"
        L_M_DISK="Disque /var"
        L_M_FW="Pare-feu"
        L_M_PWEB="Port %s"
        L_M_CPURAM="CPU / RAM"
        L_M_PORTS="Ports"
        L_V_FREE="libre"
        L_V_BUSY="utilise"
        L_V_ALLFREE="tous libres"
        L_V_UNKNOWN="inconnu"
        L_V_UNKNOWN_F="inconnue"
        L_V_ACTIVE="actif"
        L_V_INACTIVE="inactif"
        L_V_NONE="aucun"
        L_V_CORE="coeur"
        L_V_CORES="coeurs"
        L_V_NOAVX="sans AVX"
        L_V_SPACE_FREE="libre"
        L_V_SPACE_FREE_P="libres"
        L_U_GB="Go"; L_U_MB="Mo"; L_U_KB="Ko"; L_U_B="o"
        L_DECIMAL=","

        # formulaire
        L_SEC_GRAYLOG="Graylog"
        L_SEC_WEB="Interface web"
        L_SEC_MONGO="MongoDB"
        L_SEC_MEM="Memoire et journal"
        L_SEC_SYSTEM="Systeme"
        L_F_EDITION="Edition"
        L_H_EDITION="Open : paquet graylog-server. Enterprise / Security : graylog-enterprise."
        L_O_OPEN="Graylog Open"
        L_O_ENT="Graylog Enterprise"
        L_F_ADMAUTO="Mot de passe auto"
        L_H_ADMAUTO="Genere un mot de passe fort de 16 caracteres pour le compte admin de Graylog."
        L_F_ADMPASS="Mot de passe admin"
        L_H_ADMPASS="Mot de passe du compte admin (root_password_sha2). 8 caracteres minimum."
        L_F_BIND="Adresse d'ecoute"
        L_H_BIND="http_bind_address : 0.0.0.0 ecoute sur toutes les interfaces, comme la doc."
        L_F_PORT="Port web"
        L_H_PORT="Port de l'interface web et de l'API (9000 par defaut, de 1024 a 65535)."
        L_F_MBIND="Ecoute de MongoDB"
        L_H_MBIND="Tout est sur cette machine : local suffit. Autres choix : ceux de la doc."
        L_O_MLOCAL="locale (127.0.0.1)"
        L_O_MALL="toutes interfaces"
        L_O_MIP="IP de la machine"
        L_F_OSHEAP="Memoire OpenSearch"
        L_H_OSHEAP="opensearch_heap (ex : 4g, 31g max). La moitie de la RAM est partagee avec Graylog."
        L_F_GLHEAP="Memoire Graylog"
        L_H_GLHEAP="Memoire Java de Graylog, -Xms et -Xmx (ex : 2g, 16g max)."
        L_F_JAGE="Age max du journal"
        L_H_JAGE="message_journal_max_age : 72h conseille par la doc (ex : 12h, 72h, 3d)."
        L_F_JSIZE="Journal max (Go)"
        L_H_JSIZE="message_journal_max_size : la doc conseille le volume de logs prevu sur 72 h."
        L_F_TZ="Fuseau horaire"
        L_H_TZ="timedatectl set-timezone. La doc Graylog utilise UTC (ex : UTC, Europe/Paris)."
        L_F_FIREWALL="Pare-feu UFW"
        L_H_FIREWALL="Ouvre SSH et le port web. Les regles existantes sont conservees."
        L_F_FWIN="Ports des entrees"
        L_H_FWIN="Ports a ouvrir pour vos entrees, ex : 1514/udp 12201/udp 5044/tcp (vide : aucun)."
        L_F_TESTS="Verifications"
        L_H_TESTS="Verifie MongoDB, le Data Node et Graylog une fois l'installation finie."

        # barre de statut
        L_ST_BUTTON="Appuyez sur Entree pour lancer l'installation de Graylog."
        L_ST_SECTION="Entree ou Gauche/Droite pour replier ou deplier la section."
        L_ST_THEME_LIGHT="Theme clair active (touche t pour revenir au theme sombre)."
        L_ST_THEME_DARK="Theme sombre active (touche t pour revenir au theme clair)."
        L_ST_REFRESHING="Actualisation des informations machine..."
        L_ST_REFRESHED="Informations machine actualisees."

        # modales
        L_ANY_KEY="Appuyez sur une touche pour continuer"
        L_ANY_KEY_QUIT="Appuyez sur une touche pour quitter"
        L_YES="[ Oui ]"
        L_NO="[ Non ]"
        L_YESV="oui"
        L_NOV="non"
        L_UNSET="non defini"
        L_EMPTY="vide"
        L_EDIT_HELP="Entree : valider     Echap : annuler"
        L_PASS_CONFIRM="Confirmez le mot de passe :"
        L_PASS_RETYPE="Saisissez a nouveau la meme valeur."
        L_PASS_MISMATCH_T="Mots de passe differents"
        L_PASS_MISMATCH=$'Les deux saisies ne correspondent pas.\nVeuillez recommencer.'
        L_INVALID_T="Valeur invalide"

        # validation
        L_ERR_PASS_SHORT="Le mot de passe doit contenir au moins 8 caracteres."
        L_ERR_PASS_CHARS="Les espaces sont interdits dans le mot de passe."
        L_ERR_BIND="Saisissez une adresse IPv4 (0.0.0.0 pour toutes) ou un nom d'hote."
        L_ERR_PORT="Saisissez un port entre 1024 et 65535."
        L_ERR_PORT_BUSY="Le port %s est deja pris par un autre programme : choisissez un autre port web."
        L_ERR_HEAP="Saisissez une taille comme 2g ou 1536m."
        L_ERR_HEAP_MIN="Le minimum est 512m."
        L_ERR_HEAP_OSMAX="La memoire d'OpenSearch ne peut pas depasser 31g."
        L_ERR_HEAP_GLMAX="La memoire de Graylog ne peut pas depasser 16g."
        L_ERR_HEAP_SUM="Memoire OpenSearch + Graylog (%s) superieure a ce que la machine peut donner (%s)."
        L_ERR_DURATION="Saisissez une duree comme 12h, 72h ou 3d."
        L_ERR_GB="Saisissez un nombre entier de Go (1 ou plus)."
        L_ERR_JOURNAL_DISK="Un journal de %s Go ne tient pas : %s sur /var, et il faut environ %s pour les logiciels."
        L_ERR_TZ="Fuseau horaire inconnu (exemples : UTC, Europe/Paris)."
        L_ERR_FWPORTS="Format attendu : 1514/udp 12201/tcp ... separes par des espaces."
        L_FORM_INCOMPLETE_T="Configuration incomplete"

        # confirmation et sortie
        L_CONFIRM_T="Confirmation"
        L_CONFIRM_BODY=$'L\'installation de Graylog va commencer.\n\nMongoDB %s, Graylog Data Node et Graylog %s\nseront installes (environ 3 Go a telecharger).'
        L_CONFIRM_EXISTS=$'ATTENTION : Graylog est deja installe ici.\nSa configuration sera mise a jour et les services\nredemarres (les donnees existantes sont conservees).'
        L_CONFIRM_HW="ATTENTION : points a verifier sur cette machine"
        L_CONFIRM_PORTS="ATTENTION : ports deja utilises sur cette machine"
        L_CONFIRM_ASK="Lancer l'installation ?"
        L_QUIT_T="Quitter"
        L_QUIT_ASK="Quitter sans installer Graylog ?"
        L_CANCELLED="Installation annulee par l'utilisateur."
        L_NET_T="Pas de connexion Internet"
        L_NET_BODY=$'Le depot de paquets Graylog est injoignable.\n\nUne connexion est necessaire pour telecharger\nMongoDB et les paquets Graylog.'
        L_OS_T="Systeme non teste"
        L_OS_BODY=$'Ce script vise Debian 13 (Debian 12 est la version\ncouverte par la documentation Graylog).\n\nSysteme detecte : %s\n\nVous pouvez poursuivre, sans aucune garantie.'
        L_ARCH_T="Architecture non prise en charge"
        L_ARCH_BODY=$'Les paquets MongoDB et Graylog n\'existent que\npour amd64 et arm64.\n\nArchitecture detectee : %s'
        L_TOO_SMALL="Terminal trop petit : %sx%s. Minimum requis 74x20."
        L_TOO_SMALL_CLI="Agrandissez la fenetre du terminal (minimum 74x20) puis relancez le script."

        # materiel
        L_HW_T="Verification de la machine"
        L_HW_HEAD="Cette machine est en dessous des recommandations."
        L_HW_HEAD_CRIT="Cette machine ne peut pas faire tourner Graylog correctement."
        L_HW_CONSEQ=$'L\'installation reste possible, mais Graylog\nrisque d\'etre lent en charge.'
        L_HW_CONSEQ_CRIT=$'L\'installation peut echouer, ou laisser un\nGraylog qui ne demarre pas.'
        L_HW_CONTINUE="Vous pouvez poursuivre malgre tout."
        L_HW_L_CPU="Processeur"
        L_HW_L_RAM="Memoire"
        L_HW_L_DISK="Disque /var"
        L_HW_L_AVX="Processeur"
        L_HW_RECO_CPU="%s coeurs recommandes"
        L_HW_RECO="%s recommandes"
        L_HW_INSUF="insuffisant"
        L_HW_INSUF_F="insuffisante"
        L_HW_AVX="instructions AVX absentes (MongoDB ne demarrera pas)"
        L_HW_TMP="monte en noexec (OpenSearch ne demarrera pas)"
        L_HW_SHORT_CPU="processeur"
        L_HW_SHORT_RAM="memoire"
        L_HW_SHORT_DISK="disque"
        L_HW_SHORT_AVX="AVX"

        # ecrans d'installation
        L_ANIM_DL_TITLE="TELECHARGEMENT DES COMPOSANTS"
        L_ANIM_INST_TITLE="INSTALLATION"
        L_ANIM_DL_PHASE="TELECHARGEMENT EN COURS"
        L_ANIM_INST_PHASE="CONFIGURATION EN COURS"
        L_ANIM_FAIL_PHASE="INSTALLATION INTERROMPUE"
        L_ANIM_LOG="Journal complet : %s"
        L_INFO_DL="Telechargement : fichier %s sur %s"
        L_INFO_LEFT="reste %s"
        L_INFO_PKG="Paquet : %s"

        # etapes
        L_S_APT_LOCK="Attente du gestionnaire de paquets"
        L_S_APT_UPDATE="Mise a jour de la liste des paquets"
        L_S_PREREQ="Installation des prerequis (gnupg, curl...)"
        L_S_MONGO_REPO="Ajout du depot MongoDB"
        L_S_GL_REPO="Ajout du depot Graylog"
        L_S_APT_UPDATE2="Lecture des nouveaux depots"
        L_S_APT_MONGO="Telechargement et installation de MongoDB"
        L_S_APT_DN="Telechargement et installation de Graylog Data Node"
        L_S_APT_GL="Telechargement et installation de Graylog"
        L_S_TZ="Reglage du fuseau horaire"
        L_S_HOSTNAME="Verification du nom d'hote"
        L_S_MONGO_CONF="Configuration de MongoDB"
        L_S_MONGO_START="Demarrage de MongoDB"
        L_S_SYSCTL="Reglage noyau vm.max_map_count"
        L_S_DN_CONF="Configuration du Data Node"
        L_S_DN_START="Demarrage du Data Node"
        L_S_GL_CONF="Configuration de Graylog"
        L_S_FIREWALL="Configuration du pare-feu UFW"
        L_S_FIREWALL_SKIP="Pare-feu ignore"
        L_S_GL_START="Demarrage de Graylog"
        L_S_GL_WAIT="Attente du premier demarrage de Graylog"
        L_S_CLEANUP="Nettoyage"
        L_S_DONE="Termine"

        # erreurs d'etape
        L_E_APT_UPDATE="La mise a jour de la liste des paquets a echoue."
        L_E_PREREQ="L'installation des prerequis a echoue."
        L_E_MONGO_REPO="Le depot MongoDB n'a pas pu etre ajoute."
        L_E_GL_REPO="Le depot Graylog n'a pas pu etre ajoute."
        L_E_APT_MONGO="L'installation de MongoDB a echoue."
        L_E_APT_DN="L'installation de Graylog Data Node a echoue."
        L_E_APT_GL="L'installation de Graylog a echoue."
        L_E_TZ="Le reglage du fuseau horaire a echoue."
        L_E_HOSTNAME="Le nom d'hote de cette machine ne peut pas etre resolu."
        L_E_MONGO_CONF="La configuration de MongoDB a echoue."
        L_E_MONGO_START="MongoDB n'a pas demarre."
        L_E_SYSCTL="vm.max_map_count n'a pas pu etre porte a %s."
        L_E_DN_CONF="La configuration du Data Node a echoue."
        L_E_DN_START="Le Data Node n'a pas demarre."
        L_E_GL_CONF="La configuration de Graylog a echoue."
        L_E_FIREWALL="La configuration du pare-feu a echoue."
        L_E_GL_START="Graylog n'a pas demarre."
        L_E_SECRET="Le secret de chiffrement n'a pas pu etre genere."
        L_FATAL_T="Echec de l'installation"
        L_FATAL_LOGTAIL="Dernieres lignes du journal :"
        L_FATAL_NONE="(aucune)"
        L_FATAL_LOG="Journal complet : %s"
        L_FATAL_CLI="Echec de l'installation : %s"
        L_FATAL_CLI2="Consultez le journal : %s"

        # ecran final
        L_FINAL_T="Installation terminee"
        L_FINAL_DONE="Installation de Graylog terminee avec succes !"
        L_FINAL_STEP1="1. CONFIGURATION INITIALE (preflight) - une seule fois"
        L_FINAL_STEP2="2. CONNEXION A GRAYLOG - une fois le preflight termine"
        L_FINAL_LOGIN="CONNEXION A GRAYLOG"
        L_FINAL_URL="Adresse"
        L_FINAL_CRED="Identifiants"
        L_FINAL_TEMP="(temporaires)"
        L_FINAL_PF_HELP1="Suivez les 4 etapes de l'assistant : autorite de certification,"
        L_FINAL_PF_HELP2="renouvellement, certificats, puis \"Resume startup\"."
        L_FINAL_WARN="ATTENTION : le mot de passe admin ne marche pas a l'etape 1."
        L_FINAL_TYPED="(le mot de passe que vous avez saisi)"
        L_FINAL_TIMEOUT1="ATTENTION : Graylog n'a pas encore fini de demarrer."
        L_FINAL_TIMEOUT2="Mot de passe initial : tail %s"
        L_FINAL_SERVICES="Services"
        L_FINAL_FW="Pare-feu"
        L_FINAL_FW_OPEN="ports ouverts : %s"
        L_FINAL_FW_HINT="Ouvrez ensuite les ports de vos entrees : ufw allow 1514/udp"
        L_FINAL_CREDFILE="Sauvegarde"
        L_FINAL_LOG="Journal"
        L_T_UP="actif"
        L_T_DOWN="ARRETE"
    fi
}

#==============================================================================
#  3. PRIMITIVES DE DESSIN
#==============================================================================

BUF=""

put() { BUF+=$'\e['"$1;$2"'H'"$3"; }

# pad_str <texte> <largeur> -> PAD (coupe ou complete avec des espaces)
pad_str() {
    local s=$1 w=$2 n
    n=${#s}
    if (( n > w )); then
        PAD=${s:0:w}
    else
        printf -v PAD '%s%*s' "$s" $(( w - n )) ''
    fi
}

# rep_char <caractere> <n> -> REPC
rep_char() {
    local n=$2
    (( n <= 0 )) && { REPC=""; return; }
    printf -v REPC '%*s' "$n" ''
    REPC=${REPC// /$1}
}

# draw_box <y> <x> <h> <w> <titre> <couleur>
draw_box() {
    local y=$1 x=$2 h=$3 w=$4 title=$5 col=$6
    local inner=$(( w - 2 )) i top
    rep_char "$BX_H" "$inner"
    local hline=$REPC
    if [[ -n $title ]]; then
        local t=" $title " tl
        tl=${#t}
        if (( tl > inner - 3 )); then
            t=" ${title:0:inner-6}.. "
            tl=${#t}
        fi
        rep_char "$BX_H" $(( inner - 1 - tl ))
        top="${BX_TL}${BX_H}${C_TITLE}${C_BOLD}${t}${C_RESET}${col}${REPC}${BX_TR}"
    else
        top="${BX_TL}${hline}${BX_TR}"
    fi
    put "$y" "$x" "${col}${top}"
    printf -v PAD '%*s' "$inner" ''
    for (( i = 1; i < h - 1; i++ )); do
        put $(( y + i )) "$x" "${col}${BX_V}${C_RESET}${PAD}${col}${BX_V}"
    done
    put $(( y + h - 1 )) "$x" "${col}${BX_BL}${hline}${BX_BR}${C_RESET}"
}

# draw_bar <y> <x> <largeur> <pourcentage>
draw_bar() {
    local y=$1 x=$2 w=$3 pct=$4
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    local barw=$(( w - 6 ))
    local fill=$(( barw * pct / 100 ))
    rep_char "$BAR_FULL" "$fill";            local f=$REPC
    rep_char "$BAR_EMPTY" $(( barw - fill )); local e=$REPC
    printf -v PAD '%4s%%' "$pct"
    put "$y" "$x" "${C_BAR}${f}${C_BAR_BG}${e}${C_RESET}${C_BOLD}${PAD}${C_RESET}"
}

#==============================================================================
#  4. TUX (ASCII, 4 images d'animation + 4 images d'agonie)
#==============================================================================

TUX_H=7
TUX_W=12
declare -a TUX_0 TUX_1 TUX_2 TUX_3
declare -a TUX_D0 TUX_D1 TUX_D2 TUX_D3

load_tux() {
    local l
    while IFS= read -r l; do TUX_0+=("$l"); done <<'ART0'
    .--.
   |o_o |
   |:_/ |
  //   \ \
 (|     | )
/'\_   _/`\
\___)=(___/
ART0
    while IFS= read -r l; do TUX_1+=("$l"); done <<'ART1'
    .--.
   |o_o |
   |:_/ |
  //   \ \
 (|     | )
/'\_   _/`\
(___)=(___)
ART1
    while IFS= read -r l; do TUX_2+=("$l"); done <<'ART2'
    .--.
   |-_- |
   |:_/ |
  //   \ \
 (|     | )
/'\_   _/`\
\___)=(___/
ART2
    while IFS= read -r l; do TUX_3+=("$l"); done <<'ART3'
    .--.
   |o_o |
   |:_/ |
  \\   / /
 (|     | )
/'\_   _/`\
(___)=(___)
ART3

    # Agonie, jouee quand une etape echoue : Tux encaisse le coup (yeux
    # ecarquilles, ailes en l'air), reste sonne (yeux en croix), s'affaisse
    # d'une ligne, puis finit la tete au sol et les pattes en l'air.
    while IFS= read -r l; do TUX_D0+=("$l"); done <<'DEAD0'
    .--.
   |O_O |
   |:_/ |
  \\   / /
 (|     | )
/'\_   _/`\
(___)=(___)
DEAD0
    while IFS= read -r l; do TUX_D1+=("$l"); done <<'DEAD1'
    .--.
   |x_x |
   |:_/ |
  \\   / /
 (|    | )
 /'\_ _/`\
 \__)=(__/
DEAD1
    while IFS= read -r l; do TUX_D2+=("$l"); done <<'DEAD2'

    .--.
   |x_x |
   |:_/ |
  (|    |)
 /'\_  _/`\
 \___)=(__/
DEAD2
    while IFS= read -r l; do TUX_D3+=("$l"); done <<'DEAD3'
 /___)=(___\
 \'/     \'/
  (|     |)
   \\   //
    |:_/|
    |x_x|
     '--'
DEAD3
}

# tux_line <image 0-3> <ligne 0-6> -> TUXL
tux_line() {
    case $1 in
        0) TUXL=${TUX_0[$2]} ;;
        1) TUXL=${TUX_1[$2]} ;;
        2) TUXL=${TUX_2[$2]} ;;
        *) TUXL=${TUX_3[$2]} ;;
    esac
}

# tux_death_line <image 0-3> <ligne 0-6> -> TUXL
tux_death_line() {
    case $1 in
        0) TUXL=${TUX_D0[$2]} ;;
        1) TUXL=${TUX_D1[$2]} ;;
        2) TUXL=${TUX_D2[$2]} ;;
        *) TUXL=${TUX_D3[$2]} ;;
    esac
}

#==============================================================================
#  5. INFORMATIONS MACHINE
#==============================================================================

MI_HOST=""; MI_IP=""; MI_OS=""
MI_FW=""; MI_FW_ST="warn"
MI_PWEB=""; MI_PWEB_ST="warn"
MI_PMONGO=""; MI_PMONGO_ST="warn"
MI_POS=""; MI_POS_ST="warn"
MI_CPU=0; MI_CPU_TXT=""; MI_CPU_ST="ok"; MI_AVX=1; MI_TMP_NOEXEC=0
MI_RAM=0; MI_RAM_TXT=""; MI_RAM_ST="ok"
MI_DISK=0; MI_DISK_TXT=""; MI_DISK_ST="ok"

# Seuils materiels (Mo pour la memoire et le disque).
# En dessous du seuil "MIN" l'installation est fortement deconseillee,
# entre "MIN" et "RECO" elle fonctionne mais sans confort. Les seuils memoire
# sont un peu sous la valeur nominale : une machine "8 Go" annonce ~7900 Mo.
HW_CPU_RECO=4
HW_RAM_MIN=3700
HW_RAM_RECO=7600
HW_RAM_RECO_SHOW=8192
HW_DISK_MIN=10240
HW_DISK_RECO=30720
# Place prise par les paquets (archives apt + fichiers installes), en Mo.
SOFT_DISK_MB=8192

declare -a HW_ISSUES HW_SHORT

get_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    [[ -z $ip ]] && ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
    [[ -z $ip ]] && ip="127.0.0.1"
    printf '%s' "$ip"
}

get_os() {
    local os=""
    [[ -r /etc/os-release ]] && os=$(. /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME")
    [[ -z $os ]] && os=$(uname -sr)
    # "Debian GNU/Linux 13 (trixie)" -> "Debian 13", pour tenir dans le panneau
    os=${os// GNU\/Linux/}
    os=${os%% (*}
    printf '%s' "$os"
}

detect_firewall() {
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qiE '^(Status|Statut)[[:space:]]*:[[:space:]]*(active|actif)'; then
            MI_FW="$L_V_ACTIVE (ufw)"; MI_FW_ST="ok"; return
        fi
        MI_FW="$L_V_INACTIVE (ufw)"; MI_FW_ST="warn"; return
    fi
    if command -v nft >/dev/null 2>&1 && [[ -n $(nft list ruleset 2>/dev/null) ]]; then
        MI_FW="$L_V_ACTIVE (nftables)"; MI_FW_ST="ok"; return
    fi
    if command -v iptables >/dev/null 2>&1 && (( $(iptables -S 2>/dev/null | wc -l) > 3 )); then
        MI_FW="$L_V_ACTIVE (iptables)"; MI_FW_ST="ok"; return
    fi
    MI_FW="$L_V_NONE"; MI_FW_ST="warn"
}

# port_state <port> -> PORT_TXT / PORT_ST
port_state() {
    local port=$1 line proc=""
    if command -v ss >/dev/null 2>&1; then
        line=$(ss -lntpH 2>/dev/null | awk -v p=":$port" '{ if (index($4, p) && substr($4, length($4)-length(p)+1) == p) print }')
    elif command -v netstat >/dev/null 2>&1; then
        line=$(netstat -lntp 2>/dev/null | awk -v p=":$port" '{ if (substr($4, length($4)-length(p)+1) == p) print }')
    else
        PORT_TXT="$L_V_UNKNOWN"; PORT_ST="warn"; return
    fi
    if [[ -z $line ]]; then
        PORT_TXT="$L_V_FREE"; PORT_ST="ok"
    else
        proc=$(printf '%s' "$line" | grep -oE '"[^"]+"' | head -n1 | tr -d '"')
        if [[ -z $proc ]]; then
            # netstat : derniere colonne "1234/mongod", ou "-" si inconnu
            proc=$(printf '%s' "$line" | awk '{print $NF}')
            if [[ $proc == */* ]]; then proc=${proc#*/}; else proc=""; fi
        fi
        if [[ -n $proc ]]; then
            PORT_TXT="$L_V_BUSY ($proc)"
        else
            PORT_TXT="$L_V_BUSY"
        fi
        PORT_ST="err"
    fi
}

# human_mb <taille en Mo> -> "1,9 Go" ou "512 Mo"
human_mb() {
    local m=$1 g d
    if (( m >= 1024 )); then
        g=$(( m / 1024 )); d=$(( (m % 1024) * 10 / 1024 ))
        if (( d == 0 )); then
            printf '%d %s' "$g" "$L_U_GB"
        else
            printf '%d%s%d %s' "$g" "$L_DECIMAL" "$d" "$L_U_GB"
        fi
    else
        printf '%d %s' "$m" "$L_U_MB"
    fi
}

get_cpu_count() {
    local n
    n=$(nproc 2>/dev/null)
    [[ $n =~ ^[0-9]+$ ]] || n=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
    [[ $n =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# MongoDB 5.0 et suivants exigent les instructions AVX sur x86_64. Sans elles
# mongod s'arrete des son lancement sur "Illegal instruction" : cas frequent
# sur une machine virtuelle dont le type de processeur est generique (kvm64).
cpu_has_avx() {
    [[ $(uname -m 2>/dev/null) == x86_64 ]] || return 0
    [[ -r /proc/cpuinfo ]] || return 0
    grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | grep -qw avx
}

# OpenSearch, lance par le Data Node, charge des bibliotheques natives qu'il
# depose dans /tmp. Si /tmp est monte en noexec (serveur durci), le chargement
# echoue ("failed to map segment from shared object") et OpenSearch ne demarre
# jamais. Debian 13 ne pose pas cette option par defaut.
tmp_noexec() {
    command -v findmnt >/dev/null 2>&1 || return 1
    findmnt -no OPTIONS -T /tmp 2>/dev/null | tr ',' '\n' | grep -qx noexec
}

get_ram_mb() {
    local m
    m=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    [[ $m =~ ^[0-9]+$ ]] || m=0
    printf '%s' "$m"
}

# Espace libre sur le systeme de fichiers qui accueillera MongoDB, les index
# du Data Node et le journal de Graylog (/var/lib).
get_disk_mb() {
    local m
    m=$(df -Pm /var 2>/dev/null | awk 'NR==2 {print $4}')
    [[ $m =~ ^[0-9]+$ ]] || m=0
    printf '%s' "$m"
}

# hw_issue <libelle> <valeur> <recommandation> -> ligne alignee du rapport
hw_issue() {
    printf '%-12s: %s (%s)' "$1" "$2" "$3"
}

check_hardware() {
    HW_ISSUES=()
    HW_SHORT=()

    MI_CPU=$(get_cpu_count)
    if cpu_has_avx; then MI_AVX=1; else MI_AVX=0; fi
    if (( MI_CPU <= 0 )); then
        MI_CPU_TXT="$L_V_UNKNOWN"; MI_CPU_ST="warn"
    else
        if (( MI_CPU > 1 )); then MI_CPU_TXT="$MI_CPU $L_V_CORES"; else MI_CPU_TXT="$MI_CPU $L_V_CORE"; fi
        if (( MI_CPU < HW_CPU_RECO )); then
            MI_CPU_ST="warn"
            HW_ISSUES+=("$(hw_issue "$L_HW_L_CPU" "$MI_CPU_TXT" "$(printf "$L_HW_RECO_CPU" "$HW_CPU_RECO")")")
            HW_SHORT+=("$L_HW_SHORT_CPU")
        else
            MI_CPU_ST="ok"
        fi
    fi
    if (( ! MI_AVX )); then
        MI_CPU_TXT="$MI_CPU, $L_V_NOAVX"; MI_CPU_ST="err"
        HW_ISSUES+=("$(printf '%-12s: %s' "$L_HW_L_AVX" "$L_HW_AVX")")
        HW_SHORT+=("$L_HW_SHORT_AVX")
    fi

    MI_TMP_NOEXEC=0
    if tmp_noexec; then
        MI_TMP_NOEXEC=1
        HW_ISSUES+=("$(printf '%-12s: %s' "/tmp" "$L_HW_TMP")")
        HW_SHORT+=("/tmp")
    fi

    MI_RAM=$(get_ram_mb)
    MI_RAM_TXT=$(human_mb "$MI_RAM")
    if (( MI_RAM <= 0 )); then
        MI_RAM_TXT="$L_V_UNKNOWN_F"; MI_RAM_ST="warn"
    elif (( MI_RAM < HW_RAM_MIN )); then
        MI_RAM_ST="err"
        HW_ISSUES+=("$(hw_issue "$L_HW_L_RAM" "$MI_RAM_TXT" "$L_HW_INSUF_F, $(printf "$L_HW_RECO" "$(human_mb $HW_RAM_RECO_SHOW)")")")
        HW_SHORT+=("$L_HW_SHORT_RAM")
    elif (( MI_RAM < HW_RAM_RECO )); then
        MI_RAM_ST="warn"
        HW_ISSUES+=("$(hw_issue "$L_HW_L_RAM" "$MI_RAM_TXT" "$(printf "$L_HW_RECO" "$(human_mb $HW_RAM_RECO_SHOW)")")")
        HW_SHORT+=("$L_HW_SHORT_RAM")
    else
        MI_RAM_ST="ok"
    fi

    MI_DISK=$(get_disk_mb)
    local libre="$L_V_SPACE_FREE_P"
    (( MI_DISK < 2048 )) && libre="$L_V_SPACE_FREE"
    MI_DISK_TXT="$(human_mb "$MI_DISK") $libre"
    if (( MI_DISK <= 0 )); then
        MI_DISK_TXT="$L_V_UNKNOWN"; MI_DISK_ST="warn"
    elif (( MI_DISK < HW_DISK_MIN )); then
        MI_DISK_ST="err"
        HW_ISSUES+=("$(hw_issue "$L_HW_L_DISK" "$MI_DISK_TXT" "$L_HW_INSUF, $(printf "$L_HW_RECO" "$(human_mb $HW_DISK_RECO)")")")
        HW_SHORT+=("$L_HW_SHORT_DISK")
    elif (( MI_DISK < HW_DISK_RECO )); then
        MI_DISK_ST="warn"
        HW_ISSUES+=("$(hw_issue "$L_HW_L_DISK" "$MI_DISK_TXT" "$(printf "$L_HW_RECO" "$(human_mb $HW_DISK_RECO)")")")
        HW_SHORT+=("$L_HW_SHORT_DISK")
    else
        MI_DISK_ST="ok"
    fi
}

hw_is_critical() {
    [[ $MI_RAM_ST == err || $MI_DISK_ST == err ]] || (( ! MI_AVX )) || (( MI_TMP_NOEXEC ))
}

hw_warning_text() {
    local head=$L_HW_HEAD conseq=$L_HW_CONSEQ
    if hw_is_critical; then
        head=$L_HW_HEAD_CRIT
        conseq=$L_HW_CONSEQ_CRIT
    fi
    printf '%s\n\n' "$head"
    printf '  %s\n' "${HW_ISSUES[@]}"
    printf '\n%s\n' "$conseq"
    printf '\n%s\n' "$L_HW_CONTINUE"
}

# Port web a surveiller : celui du formulaire des qu'il existe, 9000 sinon.
web_port() {
    local p=${VAL[http_port]:-9000}
    [[ $p =~ ^[0-9]+$ ]] || p=9000
    printf '%s' "$p"
}

collect_machine_info() {
    MI_HOST=$(hostname 2>/dev/null || printf '%s' "$L_V_UNKNOWN")
    MI_IP=$(get_ip)
    MI_OS=$(get_os)
    check_hardware
    detect_firewall
    port_state "$(web_port)"; MI_PWEB=$PORT_TXT;   MI_PWEB_ST=$PORT_ST
    port_state 27017;         MI_PMONGO=$PORT_TXT; MI_PMONGO_ST=$PORT_ST
    port_state 9200;          MI_POS=$PORT_TXT;    MI_POS_ST=$PORT_ST
}

state_color() {
    case $1 in
        ok)   printf '%s' "$C_OK" ;;
        warn) printf '%s' "$C_WARN" ;;
        *)    printf '%s' "$C_ERR" ;;
    esac
}

# Vrai si un paquet Graylog est deja installe sur la machine.
pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

graylog_found() {
    pkg_installed graylog-server || pkg_installed graylog-enterprise || pkg_installed graylog-datanode
}

#==============================================================================
#  6. MODELE DU FORMULAIRE
#
#  Types de champ : text, num, pass, bool (oui / non) et list (une valeur
#  parmi plusieurs, declaree avec add_options).
#==============================================================================

declare -a SEC_NAME SEC_OPEN
declare -a FLD_SEC FLD_KEY FLD_LABEL FLD_TYPE FLD_HINT FLD_COND
declare -A VAL OPT_VALS OPT_LABEL

add_section() { SEC_NAME+=("$1"); SEC_OPEN+=(1); }

# add_field <cle> <libelle> <type> <valeur> <aide> [condition]
add_field() {
    FLD_SEC+=($(( ${#SEC_NAME[@]} - 1 )))
    FLD_KEY+=("$1"); FLD_LABEL+=("$2"); FLD_TYPE+=("$3")
    VAL["$1"]="$4"
    FLD_HINT+=("$5"); FLD_COND+=("${6:-}")
}

# add_options <cle> <valeur|libelle>...
add_options() {
    local key=$1 o v
    shift
    OPT_VALS[$key]=""
    for o in "$@"; do
        v=${o%%|*}
        OPT_VALS[$key]+="$v "
        OPT_LABEL["$key:$v"]=${o#*|}
    done
}

# Memoire par defaut : la doc demande la moitie de la RAM pour OpenSearch
# (31 Go max) et la moitie pour Graylog (16 Go max), mais sur deux machines
# separees. Ici tout tourne sur la meme : la moitie de la RAM est partagee
# entre les deux, le reste va a MongoDB, au systeme et au cache disque dont
# OpenSearch a besoin.
default_heap_gb() {
    local q=$(( (MI_RAM + 2048) / 4096 ))
    (( q < 1 )) && q=1
    printf '%s' "$q"
}

build_form() {
    local q os gl tz
    q=$(default_heap_gb)
    os=$q; (( os > 31 )) && os=31
    gl=$q; (( gl > 16 )) && gl=16
    tz=$(current_timezone)
    [[ -z $tz ]] && tz="UTC"

    add_section "$L_SEC_GRAYLOG"
    add_field edition    "$L_F_EDITION" list "open" "$L_H_EDITION"
    add_options edition  "open|$L_O_OPEN" "enterprise|$L_O_ENT"
    add_field admin_auto "$L_F_ADMAUTO" bool "oui"  "$L_H_ADMAUTO"
    add_field admin_pass "$L_F_ADMPASS" pass ""     "$L_H_ADMPASS" "admin_auto=non"

    add_section "$L_SEC_WEB"
    add_field bind_addr  "$L_F_BIND" text "0.0.0.0" "$L_H_BIND"
    add_field http_port  "$L_F_PORT" num  "9000"    "$L_H_PORT"

    add_section "$L_SEC_MONGO"
    add_field mongo_bind   "$L_F_MBIND" list "local" "$L_H_MBIND"
    add_options mongo_bind "local|$L_O_MLOCAL" "all|$L_O_MALL" "ip|$L_O_MIP"

    add_section "$L_SEC_MEM"
    add_field os_heap      "$L_F_OSHEAP" text "${os}g" "$L_H_OSHEAP"
    add_field gl_heap      "$L_F_GLHEAP" text "${gl}g" "$L_H_GLHEAP"
    add_field journal_age  "$L_F_JAGE"   text "72h"    "$L_H_JAGE"
    add_field journal_size "$L_F_JSIZE"  num  "5"      "$L_H_JSIZE"

    add_section "$L_SEC_SYSTEM"
    add_field timezone  "$L_F_TZ"       text "$tz" "$L_H_TZ"
    add_field firewall  "$L_F_FIREWALL" bool "oui" "$L_H_FIREWALL"
    add_field fw_inputs "$L_F_FWIN"     text ""    "$L_H_FWIN" "firewall=oui"
    add_field tests     "$L_F_TESTS"    bool "oui" "$L_H_TESTS"
}

field_index() {
    local k=$1 i
    for (( i = 0; i < ${#FLD_KEY[@]}; i++ )); do
        [[ ${FLD_KEY[i]} == "$k" ]] && { printf '%s' "$i"; return 0; }
    done
    printf '%s' "-1"
}

field_visible() {
    local c=${FLD_COND[$1]}
    [[ -z $c ]] && return 0
    local k=${c%%=*} v=${c#*=}
    [[ ${VAL[$k]} == "$v" ]]
}

declare -a VR_TYPE VR_IDX

build_rows() {
    VR_TYPE=(); VR_IDX=()
    local s i
    for (( s = 0; s < ${#SEC_NAME[@]}; s++ )); do
        VR_TYPE+=("sec"); VR_IDX+=("$s")
        if (( SEC_OPEN[s] )); then
            for (( i = 0; i < ${#FLD_KEY[@]}; i++ )); do
                (( FLD_SEC[i] == s )) || continue
                field_visible "$i" || continue
                VR_TYPE+=("fld"); VR_IDX+=("$i")
            done
        fi
        if (( s < ${#SEC_NAME[@]} - 1 )); then VR_TYPE+=("gap"); VR_IDX+=("-1"); fi
    done
}

# valeur affichee d'un champ -> DISPV / DISPC
field_display() {
    local key=${FLD_KEY[$1]} type=${FLD_TYPE[$1]} v=${VAL[${FLD_KEY[$1]}]}
    case $type in
        bool)
            if [[ $v == oui ]]; then DISPV="< $L_YESV >"; DISPC=$C_OK
            else DISPV="< $L_NOV >"; DISPC=$C_MUTED; fi
            ;;
        list)
            DISPV="< ${OPT_LABEL["$key:$v"]:-$v} >"; DISPC=$C_VALUE
            ;;
        pass)
            if [[ -z $v ]]; then DISPV="($L_UNSET)"; DISPC=$C_WARN
            else
                local n=${#v}; (( n > 16 )) && n=16
                rep_char '*' "$n"; DISPV=$REPC; DISPC=$C_VALUE
            fi
            ;;
        *)
            if [[ -z $v ]]; then DISPV="($L_EMPTY)"; DISPC=$C_MUTED
            else DISPV=$v; DISPC=$C_VALUE; fi
            ;;
    esac
}

#==============================================================================
#  7. RENDU DE L'ECRAN PRINCIPAL
#==============================================================================

SEL=0          # index de ligne selectionnee (== nb de lignes -> bouton)
SCROLL=0
STATUS_MSG=""
STATUS_KIND="info"

sel_is_button() { (( SEL >= ${#VR_TYPE[@]} )); }

adjust_scroll() {
    local n=${#VR_TYPE[@]}
    sel_is_button && return
    (( SEL < SCROLL )) && SCROLL=$SEL
    (( SEL >= SCROLL + FORM_ROWS )) && SCROLL=$(( SEL - FORM_ROWS + 1 ))
    (( SCROLL > n - FORM_ROWS )) && SCROLL=$(( n - FORM_ROWS ))
    (( SCROLL < 0 )) && SCROLL=0
}

render_header() {
    local title="$L_APP_TITLE"
    draw_box "$HEAD_Y" 1 "$HEAD_H" "$COLS" "" "$C_FRAME"
    local x=$(( (COLS - ${#title}) / 2 ))
    (( x < 2 )) && x=2
    put $(( HEAD_Y + 1 )) "$x" "${C_BOLD}${C_TITLE}${title}${C_RESET}"
    put $(( HEAD_Y + 1 )) $(( COLS - 10 )) "${C_MUTED}v${SCRIPT_VERSION}${C_RESET}"
}

render_form() {
    local col=$C_FRAME
    sel_is_button || col=$C_FRAME_ON
    draw_box "$BODY_Y" "$FORM_X" "$BODY_H" "$FORM_W" "$L_PANEL_CONFIG" "$col"

    local inner=$(( FORM_W - 4 ))
    local labw=$(( inner - 22 ))
    (( labw > 34 )) && labw=34
    (( labw < 16 )) && labw=16
    local n=${#VR_TYPE[@]} r y i idx

    for (( r = 0; r < FORM_ROWS; r++ )); do
        i=$(( SCROLL + r ))
        (( i >= n )) && break
        y=$(( BODY_Y + 1 + r ))
        idx=${VR_IDX[i]}
        case ${VR_TYPE[i]} in
            sec)
                local mark="v"
                (( SEC_OPEN[idx] )) || mark=">"
                pad_str " ${mark} ${SEC_NAME[idx]}" "$inner"
                if (( SEL == i )); then
                    put "$y" $(( FORM_X + 1 )) "${C_SEL}${C_BOLD}${C_SEC} ${PAD} ${C_RESET}"
                else
                    put "$y" $(( FORM_X + 1 )) "${C_BOLD}${C_SEC} ${PAD} ${C_RESET}"
                fi
                ;;
            fld)
                field_display "$idx"
                # -1 : on garde toujours une colonne vide entre libelle et valeur
                pad_str "    ${FLD_LABEL[idx]}" $(( labw - 1 ))
                local lab="$PAD "
                pad_str "$DISPV" $(( inner - labw ))
                local val=$PAD
                if (( SEL == i )); then
                    put "$y" $(( FORM_X + 1 )) "${C_SEL} ${C_BOLD}${C_LABEL}${lab}${DISPC}${val}${C_RESET}${C_SEL} ${C_RESET}"
                else
                    put "$y" $(( FORM_X + 1 )) " ${C_LABEL}${lab}${DISPC}${val}${C_RESET} "
                fi
                ;;
            *)
                ;;
        esac
    done

    # indicateurs de defilement
    (( SCROLL > 0 )) && put "$BODY_Y" $(( FORM_X + FORM_W - 5 )) "${C_FRAME}[^]${C_RESET}"
    (( SCROLL + FORM_ROWS < n )) && put $(( BODY_Y + BODY_H - 1 )) $(( FORM_X + FORM_W - 5 )) "${C_FRAME}[v]${C_RESET}"
}

render_machine() {
    draw_box "$BODY_Y" "$RIGHT_X" "$MACH_H" "$RIGHT_W" "$L_PANEL_MACHINE" "$C_FRAME"
    local inner=$(( RIGHT_W - 4 ))
    local labw=12
    local y=$(( BODY_Y + 1 ))
    local wp; wp=$(web_port)
    local -a rows
    if (( MACH_H >= 12 )); then
        rows=(
            "$L_M_HOST|$MI_HOST|"
            "$L_M_IP|$MI_IP|"
            "$L_M_OS|$MI_OS|"
            "$L_M_CPU|$MI_CPU_TXT|$MI_CPU_ST"
            "$L_M_RAM|$MI_RAM_TXT|$MI_RAM_ST"
            "$L_M_DISK|$MI_DISK_TXT|$MI_DISK_ST"
            "$L_M_FW|$MI_FW|$MI_FW_ST"
            "$(printf "$L_M_PWEB" "$wp")|$MI_PWEB|$MI_PWEB_ST"
            "$(printf "$L_M_PWEB" 27017)|$MI_PMONGO|$MI_PMONGO_ST"
            "$(printf "$L_M_PWEB" 9200)|$MI_POS|$MI_POS_ST"
        )
    else
        # ecran court : on regroupe pour ne rien perdre d'essentiel
        local hw_st="ok"
        [[ $MI_CPU_ST == warn || $MI_RAM_ST == warn ]] && hw_st="warn"
        [[ $MI_RAM_ST == err || $MI_CPU_ST == err ]] && hw_st="err"
        local ports_st="ok" ports_txt="$L_V_ALLFREE" busy=""
        [[ $MI_PWEB_ST == err ]]   && busy="$busy $wp"
        [[ $MI_PMONGO_ST == err ]] && busy="$busy 27017"
        [[ $MI_POS_ST == err ]]    && busy="$busy 9200"
        if [[ -n $busy ]]; then ports_st="err"; ports_txt="$L_V_BUSY:$busy"; fi
        local cpu_short=$MI_CPU
        (( MI_AVX )) || cpu_short="$MI_CPU ($L_V_NOAVX)"
        rows=(
            "$L_M_HOST|$MI_HOST|"
            "$L_M_IP|$MI_IP|"
            "$L_M_CPURAM|$cpu_short / $MI_RAM_TXT|$hw_st"
            "$L_M_DISK|$MI_DISK_TXT|$MI_DISK_ST"
            "$L_M_FW|$MI_FW|$MI_FW_ST"
            "$L_M_PORTS|$ports_txt|$ports_st"
        )
    fi
    local r lab val st c
    for r in "${rows[@]}"; do
        IFS='|' read -r lab val st <<<"$r"
        c=$C_VALUE
        [[ -n $st ]] && c=$(state_color "$st")
        pad_str "$lab" "$labw"; local L=$PAD
        pad_str "$val" $(( inner - labw - 2 )); local V=$PAD
        put "$y" $(( RIGHT_X + 2 )) "${C_MUTED}${L}${C_RESET}: ${c}${V}${C_RESET}"
        y=$(( y + 1 ))
    done
}

render_help() {
    local y=$(( BODY_Y + MACH_H ))
    draw_box "$y" "$RIGHT_X" "$HELP_H" "$RIGHT_W" "$L_PANEL_KEYS" "$C_FRAME"
    local inner=$(( RIGHT_W - 4 ))
    local keys=("${L_KEYS[@]}")
    local i=0 k lab
    for k in "${keys[@]}"; do
        (( i >= HELP_H - 2 )) && break
        IFS='|' read -r lab k <<<"$k"
        pad_str "$lab" 14; local L=$PAD
        pad_str "$k" $(( inner - 14 )); local V=$PAD
        put $(( y + 1 + i )) $(( RIGHT_X + 2 )) "${C_BOLD}${C_LABEL}${L}${C_RESET}${C_MUTED}${V}${C_RESET}"
        i=$(( i + 1 ))
    done

    # bas du panneau : rappels utiles
    if (( HELP_H >= 14 )); then
        local notes=(
            "$L_NOTE_TARGET"
            "  Graylog $GRAYLOG_SERIES / MongoDB $MONGODB_SERIES"
            "$L_NOTE_LOG"
            "  $LOGFILE"
        )
        rep_char "$BX_H" "$inner"
        put $(( y + HELP_H - 6 )) $(( RIGHT_X + 2 )) "${C_FRAME}${REPC}${C_RESET}"
        local j=0
        for k in "${notes[@]}"; do
            pad_str "$k" "$inner"
            put $(( y + HELP_H - 5 + j )) $(( RIGHT_X + 2 )) "${C_MUTED}${PAD}${C_RESET}"
            j=$(( j + 1 ))
        done
    fi
}

render_button() {
    local col=$C_FRAME lab="$L_BTN_INSTALL"
    sel_is_button && col=$C_FRAME_ON
    draw_box "$FOOT_Y" 1 "$FOOT_H" "$COLS" "" "$col"
    local x=$(( (COLS - ${#lab}) / 2 ))
    if sel_is_button; then
        put $(( FOOT_Y + 1 )) "$x" "${C_BTN_ON}${C_BOLD}${lab}${C_RESET}"
    else
        put $(( FOOT_Y + 1 )) "$x" "${C_BTN}${lab}${C_RESET}"
    fi
}

render_status() {
    local txt=$STATUS_MSG c=$C_MUTED
    case $STATUS_KIND in
        err)  c=$C_ERR ;;
        ok)   c=$C_OK ;;
        warn) c=$C_WARN ;;
    esac
    if [[ -z $txt ]]; then
        if sel_is_button; then
            txt="$L_ST_BUTTON"
        else
            local i=${VR_IDX[$SEL]}
            if [[ ${VR_TYPE[$SEL]} == fld ]]; then
                txt=${FLD_HINT[i]}
            elif [[ ${VR_TYPE[$SEL]} == sec ]]; then
                txt="$L_ST_SECTION"
            fi
        fi
    fi
    pad_str " $txt" "$COLS"
    put "$ROWS" 1 "${c}${PAD}${C_RESET}"
}

render_main() {
    BUF=$'\e[2J'
    if term_too_small; then
        put 1 1 "${C_ERR}$(printf "$L_TOO_SMALL" "$COLS" "$ROWS")${C_RESET}"
        printf '%s' "$BUF"
        return
    fi
    render_header
    render_form
    render_machine
    render_help
    render_button
    render_status
    printf '%s' "$BUF"
}

#==============================================================================
#  8. SAISIE CLAVIER
#==============================================================================

KEY=""

read_key() {
    local k rest
    KEY=""
    IFS= read -rsn1 k 2>/dev/null || { KEY="NONE"; return 0; }
    case "$k" in
        "")     KEY="ENTER" ;;
        $'\e')
            IFS= read -rsn2 -t 0.05 rest 2>/dev/null
            case "$rest" in
                "[A") KEY="UP" ;;
                "[B") KEY="DOWN" ;;
                "[C") KEY="RIGHT" ;;
                "[D") KEY="LEFT" ;;
                "[H"|"OH") KEY="HOME" ;;
                "[F"|"OF") KEY="END" ;;
                # console Linux, tmux, screen, rxvt : Debut et Fin en "ESC [ n ~"
                "[1"|"[7") IFS= read -rsn1 -t 0.05 2>/dev/null; KEY="HOME" ;;
                "[4"|"[8") IFS= read -rsn1 -t 0.05 2>/dev/null; KEY="END" ;;
                "[5") IFS= read -rsn1 -t 0.05 2>/dev/null; KEY="PGUP" ;;
                "[6") IFS= read -rsn1 -t 0.05 2>/dev/null; KEY="PGDN" ;;
                "OA") KEY="UP" ;;
                "OB") KEY="DOWN" ;;
                "OC") KEY="RIGHT" ;;
                "OD") KEY="LEFT" ;;
                "")   KEY="ESC" ;;
                *)    KEY="OTHER" ;;
            esac
            ;;
        " ")     KEY="SPACE" ;;
        $'\t')   KEY="TAB" ;;
        $'\x7f') KEY="BACK" ;;
        *)       KEY="CHAR:$k" ;;
    esac
}

wait_key() { local k; IFS= read -rsn1 k 2>/dev/null; }

#==============================================================================
#  9. FENETRES MODALES
#==============================================================================

# modal_box <h> <w> <titre> -> MX / MY (coin haut gauche)
modal_box() {
    local h=$1 w=$2 title=$3
    MY=$(( (ROWS - h) / 2 )); MX=$(( (COLS - w) / 2 ))
    (( MY < 1 )) && MY=1
    (( MX < 1 )) && MX=1
    BUF=""
    draw_box "$MY" "$MX" "$h" "$w" "$title" "$C_FRAME_ON"
    printf '%s' "$BUF"
}

# edit_line <y> <x> <largeur> <valeur> <masque 0/1> -> EDITED (0 = valide)
edit_line() {
    local y=$1 x=$2 w=$3 buf=$4 mask=$5 k rest disp
    cursor_show
    while :; do
        if (( mask )); then
            rep_char '*' "${#buf}"; disp=$REPC
        else
            disp=$buf
        fi
        (( ${#disp} > w )) && disp=${disp: -w}
        pad_str "$disp" "$w"
        printf '\e[%d;%dH%s%s%s' "$y" "$x" "$C_VALUE" "$PAD" "$C_RESET"
        printf '\e[%d;%dH' "$y" $(( x + ${#disp} ))
        IFS= read -rsn1 k 2>/dev/null || continue
        case "$k" in
            "") EDITED=$buf; cursor_hide; return 0 ;;
            $'\e')
                IFS= read -rsn2 -t 0.05 rest 2>/dev/null
                [[ -z $rest ]] && { cursor_hide; return 1; }
                ;;
            $'\x7f'|$'\b') buf=${buf%?} ;;
            $'\x15') buf="" ;;
            *)
                if [[ $k == [[:print:]] || $(printf '%d' "'$k" 2>/dev/null) -gt 127 ]]; then
                    (( ${#buf} < 200 )) && buf+="$k"
                fi
                ;;
        esac
    done
}

# wrap_text <texte> <largeur> -> WRAPPED (tableau de lignes, coupe aux espaces)
wrap_text() {
    local text=$1 w=$2 l word cur
    local -a words
    WRAPPED=()
    while IFS= read -r l; do
        if (( ${#l} <= w )); then WRAPPED+=("$l"); continue; fi
        cur=""
        read -r -a words <<<"$l"
        for word in "${words[@]}"; do
            if [[ -z $cur ]]; then
                cur=$word
            elif (( ${#cur} + 1 + ${#word} <= w )); then
                cur="$cur $word"
            else
                WRAPPED+=("$cur"); cur=$word
            fi
        done
        [[ -n $cur ]] && WRAPPED+=("$cur")
    done <<<"$text"
}

# modal_message <titre> <texte multi-lignes> [couleur]
modal_message() {
    local title=$1 text=$2 col=${3:-$C_VALUE}
    local -a lines
    local w=0 l maxw=$(( COLS - 10 ))
    (( maxw > 72 )) && maxw=72
    wrap_text "$text" "$maxw"
    lines=("${WRAPPED[@]}")
    for l in "${lines[@]}"; do (( ${#l} > w )) && w=${#l}; done
    w=$(( w + 6 ))
    (( w > COLS - 4 )) && w=$(( COLS - 4 ))
    (( w < 40 )) && w=40
    local h=$(( ${#lines[@]} + 4 ))
    (( h > ROWS - 2 )) && h=$(( ROWS - 2 ))
    modal_box "$h" "$w" "$title"
    BUF=""
    local i
    for (( i = 0; i < ${#lines[@]} && i < h - 4; i++ )); do
        pad_str "${lines[i]}" $(( w - 4 ))
        put $(( MY + 1 + i )) $(( MX + 2 )) "${col}${PAD}${C_RESET}"
    done
    pad_str "$L_ANY_KEY" $(( w - 4 ))
    put $(( MY + h - 2 )) $(( MX + 2 )) "${C_MUTED}${PAD}${C_RESET}"
    printf '%s' "$BUF"
    wait_key
}

# modal_confirm <titre> <question> -> 0 = oui
modal_confirm() {
    local title=$1 text=$2 choice=0
    local -a lines
    local w=0 l
    while IFS= read -r l; do lines+=("$l"); (( ${#l} > w )) && w=${#l}; done <<<"$text"
    w=$(( w + 6 )); (( w < 44 )) && w=44
    (( w > COLS - 4 )) && w=$(( COLS - 4 ))
    local h=$(( ${#lines[@]} + 5 ))
    (( h > ROWS - 2 )) && h=$(( ROWS - 2 ))
    local maxl=$(( h - 5 ))
    modal_box "$h" "$w" "$title"
    while :; do
        BUF=""
        local i
        for (( i = 0; i < ${#lines[@]} && i < maxl; i++ )); do
            pad_str "${lines[i]}" $(( w - 4 ))
            put $(( MY + 1 + i )) $(( MX + 2 )) "${C_VALUE}${PAD}${C_RESET}"
        done
        local yes="$L_YES" no="$L_NO"
        local by=$(( MY + h - 2 )) bx=$(( MX + w - 20 ))
        if (( choice == 0 )); then
            put "$by" "$bx" "${C_BTN_ON}${C_BOLD}${yes}${C_RESET}  ${C_MUTED}${no}${C_RESET}"
        else
            put "$by" "$bx" "${C_MUTED}${yes}${C_RESET}  ${C_BTN_ON}${C_BOLD}${no}${C_RESET}"
        fi
        printf '%s' "$BUF"
        read_key
        case $KEY in
            LEFT|RIGHT|TAB) choice=$(( 1 - choice )) ;;
            ENTER) return $choice ;;
            ESC) return 1 ;;
            "CHAR:o"|"CHAR:O"|"CHAR:y"|"CHAR:Y") return 0 ;;
            "CHAR:n"|"CHAR:N") return 1 ;;
        esac
    done
}

# modal_edit <titre> <invite> <valeur> <masque> <aide> -> EDITED
modal_edit() {
    local title=$1 prompt=$2 cur=$3 mask=$4 hint=$5
    local w=72
    (( w > COLS - 4 )) && w=$(( COLS - 4 ))
    local h=10
    modal_box "$h" "$w" "$title"
    BUF=""
    pad_str "$prompt" $(( w - 4 ))
    put $(( MY + 1 )) $(( MX + 2 )) "${C_LABEL}${PAD}${C_RESET}"
    # l'aide tient sur deux lignes au plus
    wrap_text "$hint" $(( w - 4 ))
    pad_str "${WRAPPED[0]:-}" $(( w - 4 ))
    put $(( MY + 2 )) $(( MX + 2 )) "${C_MUTED}${PAD}${C_RESET}"
    pad_str "${WRAPPED[1]:-}" $(( w - 4 ))
    put $(( MY + 3 )) $(( MX + 2 )) "${C_MUTED}${PAD}${C_RESET}"
    rep_char "$BX_H" $(( w - 6 ))
    put $(( MY + 6 )) $(( MX + 3 )) "${C_FRAME}${REPC}${C_RESET}"
    pad_str "$L_EDIT_HELP" $(( w - 4 ))
    put $(( MY + 7 )) $(( MX + 2 )) "${C_MUTED}${PAD}${C_RESET}"
    printf '%s' "$BUF"
    edit_line $(( MY + 5 )) $(( MX + 3 )) $(( w - 6 )) "$cur" "$mask"
}

# --- Choix de la langue au demarrage ---------------------------------------
# Renvoie 0 si une langue a ete choisie, 1 si l'utilisateur abandonne.
select_language() {
    local sel=0 i
    local -a codes=("fr" "en")
    local -a names=("Francais" "English")

    case "${GRAYLOG_LANG:-}" in
        fr|FR|fr_FR) UILANG="fr"; return 0 ;;
        en|EN|en_US) UILANG="en"; return 0 ;;
    esac

    while :; do
        (( RESIZED )) && { compute_layout; RESIZED=0; }
        local w=46 h=10
        (( w > COLS - 4 )) && w=$(( COLS - 4 ))
        local y=$(( (ROWS - h) / 2 )) x=$(( (COLS - w) / 2 ))
        (( y < 1 )) && y=1
        (( x < 1 )) && x=1

        BUF=$'\e[2J'
        draw_box "$y" "$x" "$h" "$w" "GRAYLOG AUTO" "$C_FRAME_ON"
        pad_str "Choisissez votre langue" $(( w - 4 ))
        put $(( y + 1 )) $(( x + 2 )) "${C_LABEL}${PAD}${C_RESET}"
        pad_str "Choose your language" $(( w - 4 ))
        put $(( y + 2 )) $(( x + 2 )) "${C_MUTED}${PAD}${C_RESET}"
        for (( i = 0; i < ${#names[@]}; i++ )); do
            pad_str "${names[i]}" $(( w - 8 ))
            if (( sel == i )); then
                put $(( y + 4 + i )) $(( x + 2 )) "${C_SEL}${C_BOLD}${C_VALUE}  > ${PAD} ${C_RESET}"
            else
                put $(( y + 4 + i )) $(( x + 2 )) "${C_VALUE}    ${PAD} ${C_RESET}"
            fi
        done
        pad_str "Fleches + Entree / Arrows + Enter" $(( w - 4 ))
        put $(( y + h - 2 )) $(( x + 2 )) "${C_MUTED}${PAD}${C_RESET}"
        printf '%s' "$BUF"

        read_key
        case $KEY in
            UP|"CHAR:k")   (( sel > 0 )) && sel=$(( sel - 1 )) ;;
            DOWN|"CHAR:j"|TAB) (( sel < ${#names[@]} - 1 )) && sel=$(( sel + 1 )) ;;
            "CHAR:f"|"CHAR:F") sel=0 ;;
            "CHAR:e"|"CHAR:E") sel=1 ;;
            ENTER|SPACE) UILANG=${codes[sel]}; return 0 ;;
            ESC|"CHAR:q"|"CHAR:Q") return 1 ;;
        esac
    done
}

#==============================================================================
#  10. INTERACTION AVEC LE FORMULAIRE
#==============================================================================

toggle_bool() {
    local key=$1
    if [[ ${VAL[$key]} == oui ]]; then VAL[$key]="non"; else VAL[$key]="oui"; fi
}

# cycle_list <cle> <sens 1 | -1> : valeur suivante ou precedente de la liste
cycle_list() {
    local key=$1 dir=$2 i n
    local -a opts
    read -r -a opts <<<"${OPT_VALS[$key]}"
    n=${#opts[@]}
    (( n > 0 )) || return
    for (( i = 0; i < n; i++ )); do
        [[ ${opts[i]} == "${VAL[$key]}" ]] && break
    done
    i=$(( (i + dir + n) % n ))
    VAL[$key]=${opts[i]}
}

current_timezone() {
    local tz=""
    command -v timedatectl >/dev/null 2>&1 && tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    [[ -z $tz && -r /etc/timezone ]] && tz=$(head -n1 /etc/timezone 2>/dev/null)
    printf '%s' "$tz"
}

# heap_mb <taille "4g" ou "1536m"> -> taille en Mo (0 si illisible)
heap_mb() {
    local v=$1 n
    n=${v%[mMgG]}
    [[ $n =~ ^[0-9]+$ ]] || { printf '0'; return; }
    case $v in
        *[gG]) printf '%d' $(( n * 1024 )) ;;
        *)     printf '%d' "$n" ;;
    esac
}

validate_value() {
    # validate_value <type de controle> <valeur> -> 0 ok, sinon VERR
    local kind=$1 v=$2 m o
    VERR=""
    case $kind in
        pass)
            if (( ${#v} < 8 )); then VERR="$L_ERR_PASS_SHORT"
            elif [[ $v == *[[:space:]]* ]]; then VERR="$L_ERR_PASS_CHARS"
            fi
            ;;
        bind)
            if [[ $v =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
                for o in "${BASH_REMATCH[@]:1}"; do
                    (( 10#$o > 255 )) && VERR="$L_ERR_BIND"
                done
            elif [[ ! $v =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ || $v =~ ^[0-9.]+$ ]]; then
                VERR="$L_ERR_BIND"
            fi
            ;;
        port)
            if [[ ! $v =~ ^[0-9]{1,5}$ ]] || (( 10#$v < 1024 || 10#$v > 65535 )); then
                VERR="$L_ERR_PORT"
            fi
            ;;
        osheap|glheap)
            if [[ ! $v =~ ^[1-9][0-9]{0,5}[mg]$ ]]; then
                VERR="$L_ERR_HEAP"
            else
                m=$(heap_mb "$v")
                if (( m < 512 )); then VERR="$L_ERR_HEAP_MIN"
                elif [[ $kind == osheap ]] && (( m > 31 * 1024 )); then VERR="$L_ERR_HEAP_OSMAX"
                elif [[ $kind == glheap ]] && (( m > 16 * 1024 )); then VERR="$L_ERR_HEAP_GLMAX"
                fi
            fi
            ;;
        duration)
            [[ $v =~ ^[1-9][0-9]{0,4}[smhd]$ ]] || VERR="$L_ERR_DURATION"
            ;;
        gb)
            [[ $v =~ ^[1-9][0-9]{0,5}$ ]] || VERR="$L_ERR_GB"
            ;;
        tz)
            if [[ ! $v =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ || ! -f /usr/share/zoneinfo/$v ]]; then
                VERR="$L_ERR_TZ"
            fi
            ;;
        fwports)
            for o in $v; do
                if [[ ! $o =~ ^([0-9]{1,5})(:([0-9]{1,5}))?/(tcp|udp)$ ]]; then
                    VERR="$L_ERR_FWPORTS"; break
                fi
                if (( 10#${BASH_REMATCH[1]} < 1 || 10#${BASH_REMATCH[1]} > 65535 )); then
                    VERR="$L_ERR_FWPORTS"; break
                fi
                if [[ -n ${BASH_REMATCH[3]} ]] && (( 10#${BASH_REMATCH[3]} < 1 || 10#${BASH_REMATCH[3]} > 65535 )); then
                    VERR="$L_ERR_FWPORTS"; break
                fi
            done
            ;;
    esac
    [[ -z $VERR ]]
}

field_check_kind() {
    case ${FLD_KEY[$1]} in
        admin_pass)   printf 'pass' ;;
        bind_addr)    printf 'bind' ;;
        http_port)    printf 'port' ;;
        os_heap)      printf 'osheap' ;;
        gl_heap)      printf 'glheap' ;;
        journal_age)  printf 'duration' ;;
        journal_size) printf 'gb' ;;
        timezone)     printf 'tz' ;;
        fw_inputs)    printf 'fwports' ;;
        *) printf 'none' ;;
    esac
}

edit_field() {
    local i=$1 key=${FLD_KEY[$1]} type=${FLD_TYPE[$1]}
    local kind; kind=$(field_check_kind "$i")
    case $type in
        bool) toggle_bool "$key"; return ;;
        list) cycle_list "$key" 1; return ;;
    esac
    local mask=0
    [[ $type == pass ]] && mask=1
    while :; do
        modal_edit "${FLD_LABEL[i]}" "${FLD_LABEL[i]} :" "${VAL[$key]}" "$mask" "${FLD_HINT[i]}" || return
        local v=$EDITED
        # les espaces de debut et de fin ne sont jamais voulus
        if (( ! mask )); then
            v="${v#"${v%%[![:space:]]*}"}"
            v="${v%"${v##*[![:space:]]}"}"
        fi
        if [[ $kind != none ]] && ! validate_value "$kind" "$v"; then
            modal_message "$L_INVALID_T" "$VERR" "$C_ERR"
            continue
        fi
        if (( mask )); then
            modal_edit "${FLD_LABEL[i]}" "$L_PASS_CONFIRM" "" 1 "$L_PASS_RETYPE" || return
            if [[ $EDITED != "$v" ]]; then
                modal_message "$L_PASS_MISMATCH_T" "$L_PASS_MISMATCH" "$C_ERR"
                continue
            fi
        fi
        VAL[$key]=$v
        return
    done
}

validate_form() {
    # -> 0 si tout est bon, sinon FERR / FKEY
    FERR=""; FKEY=""
    local checks=(bind_addr http_port os_heap gl_heap journal_age journal_size timezone)
    local k kind idx
    for k in "${checks[@]}"; do
        idx=$(field_index "$k")
        kind=$(field_check_kind "$idx")
        if ! validate_value "$kind" "${VAL[$k]}"; then
            FERR="${FLD_LABEL[idx]} : $VERR"; FKEY=$k; return 1
        fi
    done
    if [[ ${VAL[admin_auto]} == non ]]; then
        if ! validate_value pass "${VAL[admin_pass]}"; then
            FERR="$L_F_ADMPASS : $VERR"; FKEY="admin_pass"; return 1
        fi
    fi
    if [[ ${VAL[firewall]} == oui ]] && ! validate_value fwports "${VAL[fw_inputs]}"; then
        FERR="$L_F_FWIN : $VERR"; FKEY="fw_inputs"; return 1
    fi

    # Sur une machine sans Graylog, un port web deja pris l'est par un autre
    # programme : Graylog ne pourrait pas s'y installer.
    if ! graylog_found; then
        port_state "${VAL[http_port]}"
        MI_PWEB=$PORT_TXT; MI_PWEB_ST=$PORT_ST
        if [[ $PORT_ST == err ]]; then
            FERR=$(printf "$L_ERR_PORT_BUSY" "${VAL[http_port]}")
            FKEY="http_port"; return 1
        fi
    fi

    # Les deux memoires Java tournent sur la meme machine : il faut laisser de
    # quoi vivre a MongoDB, au service Data Node et au systeme (1 Go au moins).
    local sum=$(( $(heap_mb "${VAL[os_heap]}") + $(heap_mb "${VAL[gl_heap]}") ))
    local avail=$(( MI_RAM - 1024 ))
    if (( MI_RAM > 0 && sum > avail )); then
        (( avail < 0 )) && avail=0
        FERR=$(printf "$L_ERR_HEAP_SUM" "$(human_mb "$sum")" "$(human_mb "$avail")")
        FKEY="os_heap"; return 1
    fi

    # Graylog refuse de demarrer si le journal ne tient pas sur le disque.
    # Sur une machine deja installee les logiciels sont deja la : on ne
    # reserve alors plus rien pour eux.
    local need=$SOFT_DISK_MB
    graylog_found && need=0
    if (( MI_DISK > 0 && VAL[journal_size] * 1024 + need > MI_DISK )); then
        FERR=$(printf "$L_ERR_JOURNAL_DISK" "${VAL[journal_size]}" "$MI_DISK_TXT" "$(human_mb "$need")")
        FKEY="journal_size"; return 1
    fi
    return 0
}

select_field_row() {
    local key=$1 i idx
    # la section du champ fautif est rouverte au besoin
    idx=$(field_index "$key")
    (( idx >= 0 )) && SEC_OPEN[${FLD_SEC[idx]}]=1
    build_rows
    for (( i = 0; i < ${#VR_TYPE[@]}; i++ )); do
        [[ ${VR_TYPE[i]} == fld ]] || continue
        idx=${VR_IDX[i]}
        if [[ ${FLD_KEY[idx]} == "$key" ]]; then SEL=$i; adjust_scroll; return; fi
    done
}

move_sel() {
    local dir=$1 n=${#VR_TYPE[@]} i=$SEL
    while :; do
        i=$(( i + dir ))
        if (( i < 0 )); then return; fi
        if (( i > n )); then return; fi
        if (( i == n )); then SEL=$n; return; fi
        [[ ${VR_TYPE[i]} == gap ]] && continue
        SEL=$i; return
    done
}

#==============================================================================
#  11. ECRANS D'ANIMATION (TUX + BARRE DE PROGRESSION)
#==============================================================================

ANIM_MODE="download"   # download | install
INFO_MODE=""           # apt : la ligne d'information suit le travail d'apt
STEP_LABEL=""
PCT=0
FRAME=0
ANIM_Y=0; ANIM_X=0; ANIM_W=0; ANIM_H=0
TUX_Y=0; GROUND_Y=0; LABEL_Y=0; BAR_Y=0; INFO_Y=0; TITLE_Y=0

anim_layout() {
    ANIM_X=3
    ANIM_W=$(( COLS - 4 ))
    (( ANIM_W > 96 )) && { ANIM_W=96; ANIM_X=$(( (COLS - ANIM_W) / 2 + 1 )); }
    ANIM_Y=2
    local h=$(( ROWS - 3 ))
    ANIM_H=$h
    local inner_y=$(( ANIM_Y + 1 ))
    local content=13
    local free=$(( h - 2 - content ))
    (( free < 0 )) && free=0
    local top=$(( free / 2 ))
    TUX_Y=$(( inner_y + top ))
    GROUND_Y=$(( TUX_Y + TUX_H ))
    TITLE_Y=$(( GROUND_Y + 2 ))
    LABEL_Y=$(( TITLE_Y + 1 ))
    BAR_Y=$(( LABEL_Y + 1 ))
    INFO_Y=$(( BAR_Y + 1 ))
}

anim_begin() {
    ANIM_MODE=$1
    compute_layout
    anim_layout
    local title="$L_ANIM_DL_TITLE"
    [[ $ANIM_MODE == install ]] && title="$L_ANIM_INST_TITLE"
    BUF=$'\e[2J'
    draw_box "$ANIM_Y" "$ANIM_X" "$ANIM_H" "$ANIM_W" "$title" "$C_FRAME_ON"
    pad_str " $(printf "$L_ANIM_LOG" "$LOGFILE")" "$COLS"
    put "$ROWS" 1 "${C_MUTED}${PAD}${C_RESET}"
    printf '%s' "$BUF"
    RESIZED=0
    anim_tick
}

# Ligne d'information sous la barre -> INFO_TXT. Pendant un travail d'apt elle
# reprend ce qu'apt annonce sur son descripteur d'etat : le fichier en cours
# de telechargement et le temps restant, puis le paquet en cours de pose.
anim_info_line() {
    INFO_TXT=""
    [[ $INFO_MODE == apt && -s $APT_STATUS ]] || return 0
    local line="" l pkg
    while IFS= read -r l; do line=$l; done < <(tail -n 2 "$APT_STATUS" 2>/dev/null)
    case $line in
        dlstatus:*)
            if [[ $line =~ file[[:space:]]+([0-9]+)[[:space:]]+of[[:space:]]+([0-9]+) ]]; then
                INFO_TXT=$(printf "$L_INFO_DL" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
                if [[ $line =~ \(([^\)]+)[[:space:]]remaining\) ]]; then
                    INFO_TXT="$INFO_TXT - $(printf "$L_INFO_LEFT" "${BASH_REMATCH[1]}")"
                fi
            fi
            ;;
        pmstatus:*)
            pkg=${line#pmstatus:}
            pkg=${pkg%%:*}
            [[ -n $pkg && $pkg != dpkg-exec ]] && INFO_TXT=$(printf "$L_INFO_PKG" "$pkg")
            ;;
    esac
    return 0
}

anim_tick() {
    (( RESIZED )) && { anim_begin "$ANIM_MODE"; return; }
    FRAME=$(( (FRAME + 1) % 4 ))
    local inner=$(( ANIM_W - 4 ))
    local ix=$(( ANIM_X + 2 ))
    local i x

    # --- position de Tux ---
    if [[ $ANIM_MODE == download ]]; then
        local run=$(( inner - TUX_W - 2 ))
        (( run < 0 )) && run=0
        x=$(( ix + run * PCT / 100 ))
    else
        x=$(( ix + (inner - TUX_W) / 2 ))
    fi
    (( x < ix )) && x=$ix

    BUF=""
    for (( i = 0; i < TUX_H; i++ )); do
        tux_line "$FRAME" "$i"
        local art=$TUXL
        local before=$(( x - ix ))
        printf -v PAD '%*s' "$before" ''
        local pre=$PAD
        pad_str "$art" $(( inner - before ))
        local col=$C_TUX
        (( i >= TUX_H - 1 )) && col=$C_TUX_FEET
        put $(( TUX_Y + i )) "$ix" "${pre}${col}${PAD}${C_RESET}"
    done

    # --- sol ---
    rep_char "$GROUND" "$inner"
    put "$GROUND_Y" "$ix" "${C_FRAME}${REPC}${C_RESET}"

    # --- titre de phase ---
    local ptitle=""
    if [[ $ANIM_MODE == install ]]; then
        local dots=""
        case $FRAME in
            0) dots="" ;;
            1) dots="." ;;
            2) dots=".." ;;
            *) dots="..." ;;
        esac
        ptitle="${L_ANIM_INST_PHASE}${dots}"
    else
        ptitle="$L_ANIM_DL_PHASE"
    fi
    local px=$(( ix + (inner - ${#ptitle}) / 2 ))
    (( px < ix )) && px=$ix
    printf -v PAD '%*s' "$inner" ''
    put "$TITLE_Y" "$ix" "$PAD"
    put "$TITLE_Y" "$px" "${C_BOLD}${C_TITLE}${ptitle}${C_RESET}"

    # --- etape en cours ---
    pad_str "$STEP_LABEL" "$inner"
    put "$LABEL_Y" "$ix" "${C_LABEL}${PAD}${C_RESET}"

    # --- barre ---
    draw_bar "$BAR_Y" "$ix" "$inner" "$PCT"

    # --- information complementaire ---
    anim_info_line
    pad_str "$INFO_TXT" "$inner"
    put "$INFO_Y" "$ix" "${C_MUTED}${PAD}${C_RESET}"

    printf '%s' "$BUF"
}

# Jouee par fatal() : Tux encaisse l'erreur et s'effondre, la barre de
# progression se fige en rouge a l'endroit exact ou l'etape a lache. Le dernier
# dessin reste a l'ecran, la fenetre d'erreur s'ouvre par dessus.
anim_death() {
    # l'ecran d'installation n'a jamais ete affiche : rien a animer
    (( ANIM_W > 2 )) || return 0

    local inner=$(( ANIM_W - 4 ))
    local ix=$(( ANIM_X + 2 ))
    local f i x before pre art

    # Tux meurt la ou il se trouvait, pas ailleurs
    if [[ $ANIM_MODE == download ]]; then
        local run=$(( inner - TUX_W - 2 ))
        (( run < 0 )) && run=0
        x=$(( ix + run * PCT / 100 ))
    else
        x=$(( ix + (inner - TUX_W) / 2 ))
    fi
    (( x < ix )) && x=$ix
    before=$(( x - ix ))

    # barre figee en rouge sur le pourcentage atteint
    local bar_save=$C_BAR
    C_BAR=$C_ERR

    local ptitle="$L_ANIM_FAIL_PHASE"
    local px=$(( ix + (inner - ${#ptitle}) / 2 ))
    (( px < ix )) && px=$ix

    for (( f = 0; f < 4; f++ )); do
        BUF=""
        for (( i = 0; i < TUX_H; i++ )); do
            tux_death_line "$f" "$i"
            art=$TUXL
            printf -v PAD '%*s' "$before" ''
            pre=$PAD
            pad_str "$art" $(( inner - before ))
            put $(( TUX_Y + i )) "$ix" "${pre}${C_ERR}${PAD}${C_RESET}"
        done

        printf -v PAD '%*s' "$inner" ''
        put "$TITLE_Y" "$ix" "$PAD"
        put "$TITLE_Y" "$px" "${C_BOLD}${C_ERR}${ptitle}${C_RESET}"

        pad_str "$STEP_LABEL" "$inner"
        put "$LABEL_Y" "$ix" "${C_ERR}${PAD}${C_RESET}"

        draw_bar "$BAR_Y" "$ix" "$inner" "$PCT"

        pad_str "" "$inner"
        put "$INFO_Y" "$ix" "$PAD"

        printf '%s' "$BUF"
        sleep 0.28
    done

    C_BAR=$bar_save
    sleep 0.5
}

#==============================================================================
#  12. SONDES DE PROGRESSION
#==============================================================================

probe_apt() {
    local dl=-1 pm=-1 line _a _b p
    if [[ -s $APT_STATUS ]]; then
        line=$(grep '^dlstatus:' "$APT_STATUS" 2>/dev/null | tail -n1)
        if [[ -n $line ]]; then
            IFS=: read -r _a _b p _ <<<"$line"; dl=${p%%.*}
        fi
        line=$(grep '^pmstatus:' "$APT_STATUS" 2>/dev/null | tail -n1)
        if [[ -n $line ]]; then
            IFS=: read -r _a _b p _ <<<"$line"; pm=${p%%.*}
        fi
    fi
    [[ $dl =~ ^[0-9]+$ ]] || dl=-1
    [[ $pm =~ ^[0-9]+$ ]] || pm=-1
    # Les paquets Graylog pesent plusieurs centaines de Mo : le telechargement
    # occupe l'essentiel du temps, il prend donc 70 % de la barre de l'etape.
    if (( pm >= 0 )); then
        printf '%d' $(( 70 + pm * 30 / 100 ))
    elif (( dl >= 0 )); then
        printf '%d' $(( dl * 70 / 100 ))
    else
        printf '0'
    fi
}

probe_apt_update() {
    # apt-get update annonce un pourcentage peu fiable : on privilegie le
    # message "Retrieving file N of M" quand il est disponible.
    local line _a _b p=0 q n m f
    [[ -s $APT_STATUS ]] || { printf '0'; return; }
    line=$(grep '^dlstatus:' "$APT_STATUS" 2>/dev/null | tail -n1)
    [[ -z $line ]] && { printf '0'; return; }
    IFS=: read -r _a _b q _ <<<"$line"
    q=${q%%.*}
    [[ $q =~ ^[0-9]+$ ]] && p=$q
    if [[ $line =~ file[[:space:]]+([0-9]+)[[:space:]]+of[[:space:]]+([0-9]+) ]]; then
        n=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}
        if (( m > 0 )); then
            f=$(( n * 100 / m ))
            (( f > p )) && p=$f
        fi
    fi
    printf '%d' "$p"
}

# Sonde des attentes (verrou apt, demarrage d'un service) : le pourcentage
# affiche est le temps ecoule sur le temps d'attente maximum, faute de mieux
# a mesurer.
WAIT_T0=0
WAIT_MAX=1

probe_wait() {
    local e=$(( SECONDS - WAIT_T0 ))
    (( WAIT_MAX > 0 )) || { printf '0'; return; }
    e=$(( e * 100 / WAIT_MAX ))
    (( e < 0 )) && e=0
    (( e > 100 )) && e=100
    printf '%d' "$e"
}

#==============================================================================
#  13. MOTEUR D'EXECUTION DES ETAPES
#==============================================================================

log_line() { printf '%s\n' "$*" >>"$LOGFILE"; }

# step_run <libelle> <pct debut> <pct fin> <sonde|-> <commande...>
#
# La commande tourne en arriere-plan dans un sous-shell : son entree standard
# est /dev/null (aucune question ne peut bloquer l'installation) et ce qu'elle
# affiche part dans le journal. Les variables qu'elle modifie ne remontent pas
# ici : une etape qui doit rendre une valeur l'ecrit dans un fichier.
step_run() {
    local label=$1 ps=$2 pe=$3 probe=$4
    shift 4
    STEP_LABEL=$label
    PCT=$ps
    : >"$STEP_LOG"
    : >"$APT_STATUS"
    printf '\n===== %s : %s =====\n' "$(date '+%F %T')" "$label" >>"$LOGFILE"
    ( "$@" ) >>"$STEP_LOG" 2>&1 &
    local pid=$! sub rc
    while kill -0 "$pid" 2>/dev/null; do
        sub=0
        [[ $probe != "-" ]] && sub=$("$probe")
        [[ $sub =~ ^[0-9]+$ ]] || sub=0
        (( sub > 100 )) && sub=100
        PCT=$(( ps + (pe - ps) * sub / 100 ))
        anim_tick
        sleep 0.12
    done
    wait "$pid"; rc=$?
    cat "$STEP_LOG" >>"$LOGFILE" 2>/dev/null
    PCT=$pe
    INFO_MODE=""
    anim_tick
    return $rc
}

fatal() {
    local msg=$1
    local tail_log
    tail_log=$(tail -n 4 "$STEP_LOG" 2>/dev/null | cut -c1-140)
    log_line "ECHEC : $msg (etape : ${STEP_LABEL:-?}, progression : ${PCT:-0}%)"
    anim_death
    compute_layout
    modal_message "$L_FATAL_T" \
"$msg

$L_FATAL_LOGTAIL
${tail_log:-$L_FATAL_NONE}

$(printf "$L_FATAL_LOG" "$LOGFILE")" "$C_ERR"
    tui_stop
    printf "$L_FATAL_CLI\n" "$msg" >&2
    printf "$L_FATAL_CLI2\n" "$LOGFILE" >&2
    exit 1
}

#==============================================================================
#  14. OUTILS DES TACHES D'INSTALLATION
#==============================================================================

#--------------------------------------------------------- verrou dpkg / apt
# Sur une machine qui vient d'etre installee ou de demarrer, apt est presque
# toujours deja pris : unattended-upgrades applique les mises a jour de
# securite pendant la premiere minute. Sans attente, la toute premiere etape
# echoue sur "Could not get lock /var/lib/dpkg/lock-frontend".
APT_LOCK_MAX=180        # attente maximale, en secondes

# Le verrou de dpkg est pose avec fcntl() : flock(1) ne le voit pas. On se
# rabat donc sur fuser quand il est la, sinon sur les noms de processus
# (unattended-upgr est tronque a 15 caracteres par le noyau).
apt_lock_busy() {
    if command -v fuser >/dev/null 2>&1; then
        fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock \
              /var/lib/apt/lists/lock >/dev/null 2>&1 && return 0
        return 1
    fi
    command -v pgrep >/dev/null 2>&1 || return 1
    local p
    for p in apt apt-get aptitude dpkg unattended-upgr; do
        pgrep -x "$p" >/dev/null 2>&1 && return 0
    done
    return 1
}

# Ne renvoie jamais d'echec : l'attente est un confort, pas une condition.
# Si apt reste occupe, "DPkg::Lock::Timeout" laisse une seconde chance.
do_wait_apt_lock() {
    local waited=0
    if ! apt_lock_busy; then
        printf 'Gestionnaire de paquets disponible.\n'
        return 0
    fi
    printf 'Gestionnaire de paquets occupe (mises a jour automatiques ?).\n'
    while apt_lock_busy && (( waited < APT_LOCK_MAX )); do
        sleep 2
        waited=$(( waited + 2 ))
    done
    if apt_lock_busy; then
        printf 'Toujours occupe apres %ss, on tente quand meme.\n' "$waited"
    else
        printf 'Verrou libere apres %ss.\n' "$waited"
    fi
    return 0
}

# LC_ALL=C : les messages d'apt servent au calcul de progression,
# leur format doit rester stable quelle que soit la langue du systeme.
# DPkg::Lock::Timeout : apt attend le verrou de lui-meme au lieu d'abandonner
# si un autre client se reveille en cours d'installation.
# force-confdef / force-confold : sur une machine deja installee, un fichier
# de configuration modifie est conserve sans poser de question.
APT_OPTS=(-o APT::Status-Fd=3 -o DPkg::Lock::Timeout=120
          -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

do_apt_update() {
    LC_ALL=C apt-get update -y -o APT::Status-Fd=3 -o DPkg::Lock::Timeout=120 3>"$APT_STATUS"
}

do_apt_install() {
    LC_ALL=C apt-get install -y "${APT_OPTS[@]}" "$@" 3>"$APT_STATUS"
}

#------------------------------------------------- fichiers de configuration

# Copie de sauvegarde, prise une seule fois : c'est le fichier livre par le
# paquet que l'on veut pouvoir retrouver, pas celui d'une execution precedente.
backup_once() {
    [[ -f $1 && ! -e $1.graylog-auto.bak ]] && cp -p "$1" "$1.graylog-auto.bak"
    return 0
}

# conf_get <fichier> <cle> : valeur de la premiere ligne active "cle = valeur"
conf_get() {
    [[ -r $1 ]] || return 0
    CS_KEY=$2 awk '
        BEGIN { k = ENVIRON["CS_KEY"] }
        $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") {
            sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]+$/, "")
            print; exit
        }
    ' "$1"
}

# conf_set <fichier> <cle> <valeur>
#
# Ecrit "cle = valeur" dans un fichier de configuration Graylog :
#   - la ligne active existante est remplacee (les doublons sont retires) ;
#   - a defaut, la ligne d'exemple commentee "#cle = ..." est remplacee, pour
#     que le reglage reste a cote de sa documentation ;
#   - sinon la ligne est ajoutee en fin de fichier.
# La valeur passe par l'environnement : aucun caractere n'est interprete.
# Le fichier est reecrit sur place pour garder son proprietaire et ses droits.
conf_set() {
    local f=$1 tmp
    [[ -f $f ]] || { printf 'Fichier introuvable : %s\n' "$f"; return 1; }
    tmp=$(mktemp "$WORKDIR/conf.XXXXXX") || return 1
    CS_KEY=$2 CS_VAL=$3 awk '
        BEGIN { k = ENVIRON["CS_KEY"]; v = ENVIRON["CS_VAL"]; act = 0; com = 0 }
        {
            line[NR] = $0
            if ($0 ~ ("^[[:space:]]*" k "[[:space:]]*=")) { isact[NR] = 1; if (!act) act = NR }
            else if (!com && $0 ~ ("^[[:space:]]*#[[:space:]]*" k "[[:space:]]*=")) com = NR
        }
        END {
            target = act ? act : com
            for (i = 1; i <= NR; i++) {
                if (i == target) print k " = " v
                else if (isact[i]) continue
                else print line[i]
            }
            if (!target) print k " = " v
        }
    ' "$f" >"$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" >"$f" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    printf '  %s : %s\n' "${f##*/}" "$2"
}

# mongo_set_bind <fichier> <ligne>
#
# Place <ligne> ("bindIp: 127.0.0.1", "bindIpAll: true"...) dans le bloc
# "net:" de mongod.conf, a la place des lignes bindIp / bindIpAll existantes.
mongo_set_bind() {
    local f=$1 tmp
    tmp=$(mktemp "$WORKDIR/mongod.XXXXXX") || return 1
    MB_LINE="  $2" awk '
        BEGIN { nl = ENVIRON["MB_LINE"]; innet = 0; done = 0; seen = 0 }
        /^net:[[:space:]]*(#.*)?$/ { innet = 1; seen = 1; print; next }
        innet && /^[^[:space:]#]/ {
            # cle de premier niveau suivante : le bloc net est termine
            if (!done) { print nl; done = 1 }
            innet = 0
        }
        innet && /^[[:space:]]+bindIp(All)?[[:space:]]*:/ {
            if (!done) { print nl; done = 1 }
            next
        }
        { print }
        END {
            if (seen && !done) print nl
            if (!seen) { print "net:"; print "  port: 27017"; print nl }
        }
    ' "$f" >"$tmp" || { rm -f "$tmp"; return 1; }
    cat "$tmp" >"$f" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
}

#----------------------------------------------------------------- services

tcp_open() { ( exec 3<>"/dev/tcp/$1/$2" ) 2>/dev/null; }

# La doc utilise "systemctl start". Sur une machine deja installee le service
# tourne deja, ou tombe en boucle : il est d'abord arrete pour repartir avec sa
# nouvelle configuration. reset-failed remet a zero le compteur de relances de
# systemd, que l'arret d'un service en attente de relance ne vide pas : sans
# cela un service repare resterait considere comme tombe.
svc_start() {
    if [[ $(systemctl show -p ActiveState --value "$1" 2>/dev/null) != inactive ]]; then
        systemctl stop "$1" 2>/dev/null
    fi
    systemctl reset-failed "$1" 2>/dev/null
    systemctl start "$1"
}

# Trace l'etat d'un service qui n'a pas demarre, pour le journal et pour la
# fenetre d'erreur. Celle-ci ne montre que les dernieres lignes : la cause
# (le message de l'exception Java, sans sa pile d'appels) est donc ecrite en
# dernier.
svc_diag() {
    local cause
    systemctl status "$1" --no-pager -l 2>&1 | head -n 8
    journalctl -u "$1" -n 30 --no-pager -o cat 2>&1 | cut -c1-300
    cause=$(journalctl -u "$1" -n 80 --no-pager -o cat 2>/dev/null \
            | grep -aE 'Exception|ERROR|rror:' | tail -n1 \
            | sed -E 's/^.*Exception: //' | cut -c1-260)
    [[ -n $cause ]] && printf '%s\n' "$cause"
    return 0
}

# Nombre de relances automatiques depuis le dernier demarrage manuel. Les
# services Graylog se relancent seuls apres un arret anormal : un service qui
# tombe en boucle n'est jamais "failed", seul ce compteur le trahit.
svc_restarts() {
    local n
    n=$(systemctl show -p NRestarts --value "$1" 2>/dev/null)
    [[ $n =~ ^[0-9]+$ ]] || n=0
    printf '%s' "$n"
}

# Vrai si le service est tombe : en echec, en attente de relance automatique,
# ou deja relance au moins une fois.
svc_crashed() {
    systemctl is-failed --quiet "$1" && return 0
    [[ $(systemctl show -p SubState --value "$1" 2>/dev/null) == auto-restart ]] && return 0
    (( $(svc_restarts "$1") > 0 ))
}

# Vrai si le service tourne et n'est jamais tombe depuis son demarrage.
svc_healthy() {
    systemctl is-active --quiet "$1" || return 1
    ! svc_crashed "$1"
}

#==============================================================================
#  15. TACHES D'INSTALLATION
#
#  Chaque tache reprend les commandes de la documentation officielle :
#    https://go2docs.graylog.org/current/downloading_and_installing_graylog/debian_installation.htm
#  La commande d'origine est rappelee en commentaire ("doc :").
#==============================================================================

#-------------------------------------------------------------- prerequis
# doc : sudo apt-get install gnupg curl
# wget, openssl et sysctl (procps) sont appeles par les etapes suivantes de la
# doc et ne sont pas toujours presents sur une Debian minimale.
do_prereqs() {
    do_apt_install gnupg curl wget ca-certificates openssl procps
}

#------------------------------------------------------------ depot MongoDB
# doc : curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
#          sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor
# doc : echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] http://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main" | sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list
#
# --batch --yes : gpg remplace la cle sans poser de question si le script est
# relance. Le depot est appele en https, comme dans le guide Graylog pour
# OpenSearch et dans la documentation de MongoDB.
do_mongodb_repo() {
    curl -fsSL "$MONGODB_KEY_URL" | \
        gpg --batch --yes -o "$MONGODB_KEYRING" --dearmor || return 1
    [[ -s $MONGODB_KEYRING ]] || return 1
    chmod 644 "$MONGODB_KEYRING"
    echo "deb [ signed-by=$MONGODB_KEYRING ] $MONGODB_REPO $MONGODB_SUITE/mongodb-org/$MONGODB_SERIES main" \
        | tee "$MONGODB_LIST" || return 1
    chmod 644 "$MONGODB_LIST"
}

#------------------------------------------------------------ depot Graylog
# doc : wget https://packages.graylog2.org/repo/packages/graylog-7.2-repository_latest.deb
# doc : sudo dpkg -i graylog-7.2-repository_latest.deb
do_graylog_repo() {
    cd "$WORKDIR" || return 1
    rm -f "$GRAYLOG_REPO_DEB"
    wget -nv "$GRAYLOG_REPO_URL" || return 1
    dpkg -i --force-confdef --force-confold "$GRAYLOG_REPO_DEB"
}

#------------------------------------------------------------------ paquets
# doc : sudo apt-get install -y mongodb-org
do_install_mongodb() { do_apt_install mongodb-org; }

# doc : sudo apt-get install graylog-datanode
do_install_datanode() { do_apt_install graylog-datanode; }

# doc : sudo apt-get install graylog-server      (Graylog Open)
# doc : sudo apt-get install graylog-enterprise  (Graylog Enterprise / Security)
do_install_graylog() { do_apt_install "$GL_PACKAGE"; }

#------------------------------------------------------------ fuseau horaire
# doc : sudo timedatectl set-timezone UTC
do_timezone() {
    local cur
    cur=$(current_timezone)
    if [[ $cur == "$TIMEZONE" ]]; then
        printf 'Fuseau horaire deja regle sur %s.\n' "$TIMEZONE"
        return 0
    fi
    timedatectl set-timezone "$TIMEZONE" || return 1
    printf 'Fuseau horaire : %s -> %s\n' "${cur:-?}" "$TIMEZONE"
}

#---------------------------------------------------------------- nom d'hote
# Le Data Node refuse de demarrer si le nom d'hote de la machine ne se resout
# pas ("Configured hostname ... is not bound to any address! Please configure
# your DNS so the hostname points to this machine"). L'installateur Debian
# inscrit ce nom dans /etc/hosts sur l'adresse 127.0.1.1 ; quand la ligne
# manque (image cloud, conteneur, machine renommee), elle est ajoutee.
do_hostname() {
    local h
    h=$(hostname 2>/dev/null)
    [[ -n $h ]] || { printf "Nom d'hote vide.\n"; return 1; }
    if getent hosts "$h" >/dev/null 2>&1; then
        printf 'Nom resolu : %s\n' "$(getent hosts "$h" | head -n1)"
        return 0
    fi
    printf 'Le nom %s ne se resout pas : ajout dans /etc/hosts.\n' "$h"
    backup_once /etc/hosts
    printf '127.0.1.1\t%s\n' "$h" >>/etc/hosts || return 1
    getent hosts "$h" || { printf 'Toujours pas resolu.\n'; return 1; }
}

#------------------------------------------------------------------ MongoDB
# doc : sudo apt-mark hold mongodb-org
# doc : sudo nano /etc/mongod.conf   (bloc net : bindIp ou bindIpAll)
#
# mongodb-org est un paquet vide qui tire les autres : pour que la version
# reste vraiment figee, ses composants sont retenus aussi, comme le fait la
# documentation de MongoDB.
do_mongodb_config() {
    local p
    apt-mark hold mongodb-org || return 1
    for p in mongodb-org-database mongodb-org-server mongodb-mongosh \
             mongodb-org-mongos mongodb-org-tools; do
        pkg_installed "$p" && apt-mark hold "$p"
    done

    [[ -f $MONGOD_CONF ]] || { printf 'Fichier introuvable : %s\n' "$MONGOD_CONF"; return 1; }
    backup_once "$MONGOD_CONF"
    case $MONGO_BIND in
        all) mongo_set_bind "$MONGOD_CONF" "bindIpAll: true" ;;
        ip)  mongo_set_bind "$MONGOD_CONF" "bindIp: $MI_IP" ;;
        *)   mongo_set_bind "$MONGOD_CONF" "bindIp: 127.0.0.1" ;;
    esac || return 1
    printf 'Bloc net de %s :\n' "$MONGOD_CONF"
    awk '/^net:/ { p = 1; print; next } p && !/^[[:space:]]+[^[:space:]]/ { exit } p' "$MONGOD_CONF"
}

# doc : sudo systemctl daemon-reload
# doc : sudo systemctl enable mongod.service
# doc : sudo systemctl start mongod.service
do_mongodb_start() {
    local i
    systemctl daemon-reload || return 1
    systemctl enable mongod.service || return 1
    svc_start mongod.service || { svc_diag mongod.service; return 1; }
    # doc (depannage) : nc -vz <node_ip> 27017
    for (( i = 0; i < MONGO_WAIT_MAX; i++ )); do
        if systemctl is-failed --quiet mongod.service; then
            svc_diag mongod.service
            (( MI_AVX )) || printf 'Processeur sans AVX : MongoDB %s ne peut pas demarrer.\n' "$MONGODB_SERIES"
            return 1
        fi
        if tcp_open "$MONGO_HOST" 27017; then
            printf 'MongoDB repond sur %s:27017.\n' "$MONGO_HOST"
            return 0
        fi
        sleep 1
    done
    svc_diag mongod.service
    printf 'MongoDB ne repond pas sur %s:27017 apres %ss.\n' "$MONGO_HOST" "$MONGO_WAIT_MAX"
    return 1
}

#-------------------------------------------------------- vm.max_map_count
# doc : cat /proc/sys/vm/max_map_count
# doc : echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.d/99-graylog-datanode.conf
# doc : sudo sysctl --system
#
# Le fichier est ecrit, pas complete : relancer le script n'y empile pas de
# lignes. Si le noyau est deja regle plus haut, rien n'est touche.
do_sysctl() {
    local cur
    cur=$(cat /proc/sys/vm/max_map_count 2>/dev/null)
    [[ $cur =~ ^[0-9]+$ ]] || cur=0
    printf 'vm.max_map_count actuel : %s\n' "$cur"
    if (( cur >= MAX_MAP_COUNT )) && [[ ! -f $SYSCTL_FILE ]]; then
        printf 'Valeur suffisante (minimum %s), rien a changer.\n' "$MAX_MAP_COUNT"
        return 0
    fi
    echo "vm.max_map_count=$MAX_MAP_COUNT" | tee "$SYSCTL_FILE" || return 1
    chmod 644 "$SYSCTL_FILE"
    sysctl --system >/dev/null 2>&1
    cur=$(cat /proc/sys/vm/max_map_count 2>/dev/null)
    [[ $cur =~ ^[0-9]+$ ]] || cur=0
    printf 'vm.max_map_count apres reglage : %s\n' "$cur"
    if (( cur < MAX_MAP_COUNT )); then
        printf 'Le noyau refuse le reglage (conteneur ?) : il doit etre fait\n'
        printf "sur l'hote avec sysctl -w vm.max_map_count=%s\n" "$MAX_MAP_COUNT"
        return 1
    fi
    return 0
}

#---------------------------------------------------------------- Data Node
# doc : sudo nano /etc/graylog/datanode/datanode.conf
#         password_secret = <openssl rand -hex 32>
#         opensearch_heap = 8g
#         mongodb_uri = mongodb://graylog01:27017/graylog
do_datanode_config() {
    backup_once "$DN_CONF"
    conf_set "$DN_CONF" password_secret "$PASSWORD_SECRET" || return 1
    conf_set "$DN_CONF" opensearch_heap "$OS_HEAP" || return 1
    conf_set "$DN_CONF" mongodb_uri "$MONGO_URI" || return 1
}

# doc : sudo systemctl daemon-reload
# doc : sudo systemctl enable graylog-datanode.service
# doc : sudo systemctl start graylog-datanode
do_datanode_start() {
    local i
    systemctl daemon-reload || return 1
    systemctl enable graylog-datanode.service || return 1
    svc_start graylog-datanode || { svc_diag graylog-datanode; return 1; }
    # Un Data Node mal configure s'arrete apres ses controles de demarrage,
    # quelques secondes apres son lancement, puis systemd le relance sans fin.
    for (( i = 0; i < DN_WATCH; i++ )); do
        sleep 1
        if svc_crashed graylog-datanode; then
            svc_diag graylog-datanode
            return 1
        fi
    done
    systemctl is-active --quiet graylog-datanode || { svc_diag graylog-datanode; return 1; }
    printf 'Data Node en service.\n'
}

#------------------------------------------------------------------ Graylog
# doc : sudo nano /etc/graylog/server/server.conf
#         root_password_sha2 = <echo -n "Enter Password: " && head -1 </dev/stdin | tr -d '\n' | sha256sum | cut -d" " -f1>
#         password_secret = <la meme valeur que le Data Node>
#         http_bind_address = 0.0.0.0:9000
#         message_journal_max_age = 72h
#         message_journal_max_size = 90gb
# doc : sudo nano /etc/default/graylog-server
#         GRAYLOG_SERVER_JAVA_OPTS="-Xms2g -Xmx2g -server -XX:+UseG1GC -XX:-OmitStackTraceInFastThrow"
do_graylog_config() {
    backup_once "$GL_CONF"
    conf_set "$GL_CONF" password_secret "$PASSWORD_SECRET" || return 1
    conf_set "$GL_CONF" root_password_sha2 "$ROOT_SHA2" || return 1
    conf_set "$GL_CONF" http_bind_address "$BIND_ADDR:$HTTP_PORT" || return 1
    conf_set "$GL_CONF" mongodb_uri "$MONGO_URI" || return 1
    conf_set "$GL_CONF" message_journal_max_age "$JOURNAL_AGE" || return 1
    conf_set "$GL_CONF" message_journal_max_size "${JOURNAL_SIZE}gb" || return 1

    # Memoire Java : seules les options -Xms et -Xmx de la ligne livree par le
    # paquet sont changees, comme le demande la doc.
    [[ -f $GL_DEFAULT ]] || { printf 'Fichier introuvable : %s\n' "$GL_DEFAULT"; return 1; }
    backup_once "$GL_DEFAULT"
    sed -E -i "/^[[:space:]]*GRAYLOG_SERVER_JAVA_OPTS=/ {
        s/-Xms[0-9]+[kKmMgG]?/-Xms${GL_HEAP}/
        s/-Xmx[0-9]+[kKmMgG]?/-Xmx${GL_HEAP}/
    }" "$GL_DEFAULT" || return 1
    if ! grep -Eq "^[[:space:]]*GRAYLOG_SERVER_JAVA_OPTS=.*-Xms${GL_HEAP}([[:space:]\"]).*-Xmx${GL_HEAP}([[:space:]\"])" "$GL_DEFAULT"; then
        # Ligne absente ou sans reglage de memoire : on complete les options
        # existantes plutot que de les remplacer (la derniere valeur l'emporte).
        printf 'GRAYLOG_SERVER_JAVA_OPTS="$GRAYLOG_SERVER_JAVA_OPTS -Xms%s -Xmx%s"\n' \
            "$GL_HEAP" "$GL_HEAP" >>"$GL_DEFAULT"
    fi
    grep -E '^[[:space:]]*GRAYLOG_SERVER_JAVA_OPTS=.*-Xm' "$GL_DEFAULT"
}

# doc : sudo systemctl daemon-reload
# doc : sudo systemctl enable graylog-server.service
# doc : sudo systemctl start graylog-server.service
#
# La taille du journal de Graylog est relevee avant le demarrage : l'etape
# suivante n'y lit que ce que ce demarrage-ci a ecrit.
do_graylog_start() {
    local off=0
    [[ -f $GL_LOG ]] && off=$(stat -c %s "$GL_LOG" 2>/dev/null)
    [[ $off =~ ^[0-9]+$ ]] || off=0
    printf '%s\n' "$off" >"$GL_OFFSET_FILE"
    systemctl daemon-reload || return 1
    systemctl enable graylog-server.service || return 1
    svc_start graylog-server.service || { svc_diag graylog-server.service; return 1; }
}

# doc : tail /var/log/graylog-server/server.log
#
# Au premier demarrage Graylog ouvre une interface de configuration initiale
# (preflight) et ecrit dans son journal l'identifiant et le mot de passe
# temporaires qui y donnent acces. On attend cette ligne pour la presenter a
# l'ecran final. Resultat dans $PREFLIGHT_FILE :
#   preflight + utilisateur + mot de passe : interface initiale prete
#   running                                : Graylog deja configure, demarre
#   timeout                                : rien vu dans le delai imparti
do_wait_graylog() {
    local off size t=0 line
    local re="with username '([^']+)' and password '([^']+)'"
    off=$(cat "$GL_OFFSET_FILE" 2>/dev/null)
    [[ $off =~ ^[0-9]+$ ]] || off=0
    while (( t < GL_WAIT_MAX )); do
        if svc_crashed graylog-server.service; then
            svc_diag graylog-server.service
            # la cause est aussi dans le journal de Graylog
            tail -c "+$(( off + 1 ))" "$GL_LOG" 2>/dev/null | grep -a 'ERROR' | tail -n 3 | cut -c1-260
            return 1
        fi
        # le Data Node doit toujours etre la : sans lui le preflight n'aboutit pas
        if svc_crashed graylog-datanode; then
            svc_diag graylog-datanode
            return 1
        fi
        if [[ -r $GL_LOG ]]; then
            size=$(stat -c %s "$GL_LOG" 2>/dev/null)
            [[ $size =~ ^[0-9]+$ ]] || size=0
            (( size < off )) && off=0        # journal renouvele entre-temps
            line=$(tail -c "+$(( off + 1 ))" "$GL_LOG" 2>/dev/null \
                   | grep -a 'Initial configuration is accessible at' | tail -n1)
            if [[ $line =~ $re ]]; then
                printf 'preflight\n%s\n%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >"$PREFLIGHT_FILE"
                printf 'Interface de configuration initiale prete apres %ss.\n' "$t"
                return 0
            fi
            if tail -c "+$(( off + 1 ))" "$GL_LOG" 2>/dev/null | grep -aq 'Graylog server up and running'; then
                printf 'running\n' >"$PREFLIGHT_FILE"
                printf 'Graylog deja configure : demarre apres %ss.\n' "$t"
                return 0
            fi
        fi
        sleep 2
        t=$(( t + 2 ))
    done
    printf 'timeout\n' >"$PREFLIGHT_FILE"
    printf 'Rien dans %s apres %ss.\n' "$GL_LOG" "$GL_WAIT_MAX"
    tail -n 15 "$GL_LOG" 2>/dev/null | cut -c1-200
    return 0
}

#----------------------------------------------------------------- pare-feu
# La doc suppose le pare-feu desactive et renvoie a la liste des ports :
# seul le port web (9000 par defaut) doit etre joignable depuis l'exterieur.
# 27017 (MongoDB), 9200 et 8999 (Data Node) ne servent qu'entre les
# composants, tous sur cette machine : ils restent fermes.

# Ports d'ecoute reels de sshd. Ouvrir le 22 sans se poser de question est un
# pari : sur une machine ou SSH ecoute ailleurs, activer le pare-feu avec un
# refus par defaut coupe la session en cours et interdit toute reconnexion.
ssh_ports() {
    local -a p=()
    local l port out="" seen="|"
    if command -v sshd >/dev/null 2>&1; then
        while read -r l; do
            [[ $l =~ ^port[[:space:]]+([0-9]+) ]] && p+=("${BASH_REMATCH[1]}")
        done < <(LC_ALL=C sshd -T 2>/dev/null | grep -i '^port ')
    fi
    if (( ${#p[@]} == 0 )); then
        while read -r l; do
            [[ $l =~ ^[[:space:]]*[Pp]ort[[:space:]]+([0-9]+) ]] && p+=("${BASH_REMATCH[1]}")
        done < <(cat /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null)
    fi
    # le port de la session en cours est le plus sur de tous
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        port=$(awk '{print $4}' <<<"$SSH_CONNECTION")
        [[ $port =~ ^[0-9]+$ ]] && p+=("$port")
    fi
    (( ${#p[@]} == 0 )) && p=(22)
    for port in "${p[@]}"; do
        [[ $seen == *"|$port|"* ]] && continue
        seen="$seen$port|"
        out="$out $port"
    done
    printf '%s' "${out# }"
}

do_firewall() {
    local sshp p act=0 opened=""
    : >"$FW_PORTS_FILE"
    if ! command -v ufw >/dev/null 2>&1; then
        do_apt_install ufw || return 1
    fi
    command -v ufw >/dev/null 2>&1 || return 1

    sshp=$(ssh_ports)
    printf 'Ports SSH detectes : %s\n' "$sshp"

    ufw status 2>/dev/null \
        | grep -qiE '^(Status|Statut)[[:space:]]*:[[:space:]]*(active|actif)' && act=1

    if (( act )); then
        # Pare-feu deja en service : on ajoute seulement ce qui manque. Un
        # "ufw --force reset" effacerait les regles posees par l'administrateur
        # sans le lui avoir demande, et sans moyen de les retrouver ensuite.
        printf 'ufw deja actif : ajout des regles, aucune remise a zero.\n'
    else
        printf 'ufw inactif : mise en place des regles par defaut.\n'
        ufw default deny incoming || return 1
        ufw default allow outgoing || return 1
    fi

    for p in $sshp; do
        ufw allow "$p/tcp" >/dev/null || return 1
        printf 'Autorise : %s/tcp (SSH)\n' "$p"
    done

    ufw allow "$HTTP_PORT/tcp" >/dev/null || return 1
    opened="$HTTP_PORT/tcp"
    printf 'Autorise : %s/tcp (interface web)\n' "$HTTP_PORT"

    for p in $FW_INPUTS; do
        ufw allow "$p" >/dev/null || return 1
        opened="$opened $p"
        printf 'Autorise : %s (entree de logs)\n' "$p"
    done

    # etape executee dans un sous-shell : la liste passe par un fichier pour
    # etre reprise a l'ecran final
    printf '%s\n' "$opened" >"$FW_PORTS_FILE"

    (( act )) || ufw --force enable || return 1
    ufw status verbose 2>/dev/null
    return 0
}

#---------------------------------------------------------------- nettoyage
# Les archives telechargees par apt (pres de 3 Go) ne servent plus.
do_cleanup() {
    apt-get clean
    rm -f "$WORKDIR/$GRAYLOG_REPO_DEB"
    printf 'Archives apt supprimees.\n'
    return 0
}

#==============================================================================
#  16. DEROULEMENT DE L'INSTALLATION
#==============================================================================

random_password() {
    local p
    p=$(openssl rand -base64 24 2>/dev/null | tr -d '=+/[:space:]' | cut -c1-16)
    (( ${#p} >= 12 )) || p=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-16)
    printf '%s' "$p"
}

run_install() {
    EDITION=${VAL[edition]}
    BIND_ADDR=${VAL[bind_addr]}
    HTTP_PORT=${VAL[http_port]}
    MONGO_BIND=${VAL[mongo_bind]}
    OS_HEAP=${VAL[os_heap]}
    GL_HEAP=${VAL[gl_heap]}
    JOURNAL_AGE=${VAL[journal_age]}
    JOURNAL_SIZE=${VAL[journal_size]}
    TIMEZONE=${VAL[timezone]}
    FW_INPUTS=${VAL[fw_inputs]}

    GL_PACKAGE="graylog-server"
    [[ $EDITION == enterprise ]] && GL_PACKAGE="graylog-enterprise"

    # Avec "bindIp: <IP de la machine>" MongoDB n'ecoute plus sur 127.0.0.1 :
    # le Data Node et Graylog doivent alors passer par cette adresse.
    MONGO_HOST="127.0.0.1"
    [[ $MONGO_BIND == ip ]] && MONGO_HOST=$MI_IP
    MONGO_URI="mongodb://$MONGO_HOST:27017/graylog"

    : >"$LOGFILE"
    chmod 600 "$LOGFILE" 2>/dev/null
    log_line "Installation Graylog demarree le $(date '+%F %T')"
    log_line "Script: v$SCRIPT_VERSION  Systeme: $OS_ID $OS_VER ($OS_CODENAME) $OS_ARCH"
    log_line "Hote: $MI_HOST  IP: $MI_IP  CPU: $MI_CPU  RAM: $MI_RAM Mo  Disque /var: $MI_DISK Mo"
    log_line "Graylog $GRAYLOG_SERIES ($GL_PACKAGE)  MongoDB $MONGODB_SERIES ($MONGODB_SUITE)"
    log_line "Ecoute web: $BIND_ADDR:$HTTP_PORT  MongoDB: $MONGO_BIND ($MONGO_URI)"
    log_line "Memoire: OpenSearch $OS_HEAP, Graylog $GL_HEAP  Journal: $JOURNAL_AGE / ${JOURNAL_SIZE}gb"
    log_line "Fuseau: $TIMEZONE  Pare-feu: ${VAL[firewall]} ${FW_INPUTS}"

    #---------------------------------------------------------- phase 1 : DL
    anim_begin download

    WAIT_T0=$SECONDS; WAIT_MAX=$APT_LOCK_MAX
    step_run "$L_S_APT_LOCK" 0 2 probe_wait do_wait_apt_lock

    INFO_MODE="apt"
    step_run "$L_S_APT_UPDATE" 2 5 probe_apt_update \
        do_apt_update \
        || fatal "$L_E_APT_UPDATE"

    INFO_MODE="apt"
    step_run "$L_S_PREREQ" 5 10 probe_apt \
        do_prereqs \
        || fatal "$L_E_PREREQ"

    step_run "$L_S_MONGO_REPO" 10 12 - \
        do_mongodb_repo \
        || fatal "$L_E_MONGO_REPO"

    step_run "$L_S_GL_REPO" 12 14 - \
        do_graylog_repo \
        || fatal "$L_E_GL_REPO"

    INFO_MODE="apt"
    step_run "$L_S_APT_UPDATE2" 14 17 probe_apt_update \
        do_apt_update \
        || fatal "$L_E_APT_UPDATE"

    INFO_MODE="apt"
    step_run "$L_S_APT_MONGO" 17 27 probe_apt \
        do_install_mongodb \
        || fatal "$L_E_APT_MONGO"

    # le Data Node embarque OpenSearch : c'est de loin le plus gros paquet
    INFO_MODE="apt"
    step_run "$L_S_APT_DN" 27 77 probe_apt \
        do_install_datanode \
        || fatal "$L_E_APT_DN"

    INFO_MODE="apt"
    step_run "$L_S_APT_GL" 77 100 probe_apt \
        do_install_graylog \
        || fatal "$L_E_APT_GL"

    sleep 0.4

    #--------------------------------------------- secrets (openssl est la)
    # doc : openssl rand -hex 32
    # Un secret deja en place est conserve : le changer rendrait illisible
    # tout ce que Graylog a chiffre avec.
    STEP_LABEL="$L_S_DN_CONF"
    PASSWORD_SECRET=$(conf_get "$GL_CONF" password_secret)
    [[ -z $PASSWORD_SECRET ]] && PASSWORD_SECRET=$(conf_get "$DN_CONF" password_secret)
    if [[ -n $PASSWORD_SECRET ]]; then
        log_line "password_secret : valeur existante conservee"
    else
        PASSWORD_SECRET=$(openssl rand -hex 32 2>/dev/null)
        log_line "password_secret : nouvelle valeur generee (openssl rand -hex 32)"
    fi
    if (( ${#PASSWORD_SECRET} < 16 )); then
        : >"$STEP_LOG"
        fatal "$L_E_SECRET"
    fi

    if [[ ${VAL[admin_auto]} == oui ]]; then
        ADMIN_PASS=$(random_password)
        VAL[admin_pass]=$ADMIN_PASS
    else
        ADMIN_PASS=${VAL[admin_pass]}
    fi
    # doc : echo -n "Enter Password: " && head -1 </dev/stdin | tr -d '\n' | sha256sum | cut -d" " -f1
    ROOT_SHA2=$(printf '%s' "$ADMIN_PASS" | tr -d '\n' | sha256sum | cut -d" " -f1)

    #------------------------------------------------------ phase 2 : INSTALL
    anim_begin install

    step_run "$L_S_TZ" 0 3 - \
        do_timezone \
        || fatal "$L_E_TZ"

    step_run "$L_S_HOSTNAME" 3 5 - \
        do_hostname \
        || fatal "$L_E_HOSTNAME"

    step_run "$L_S_MONGO_CONF" 5 10 - \
        do_mongodb_config \
        || fatal "$L_E_MONGO_CONF"

    WAIT_T0=$SECONDS; WAIT_MAX=$MONGO_WAIT_MAX
    step_run "$L_S_MONGO_START" 10 22 probe_wait \
        do_mongodb_start \
        || fatal "$L_E_MONGO_START"

    step_run "$L_S_SYSCTL" 22 28 - \
        do_sysctl \
        || fatal "$(printf "$L_E_SYSCTL" "$MAX_MAP_COUNT")"

    step_run "$L_S_DN_CONF" 28 36 - \
        do_datanode_config \
        || fatal "$L_E_DN_CONF"

    WAIT_T0=$SECONDS; WAIT_MAX=$DN_WATCH
    step_run "$L_S_DN_START" 36 48 probe_wait \
        do_datanode_start \
        || fatal "$L_E_DN_START"

    step_run "$L_S_GL_CONF" 48 58 - \
        do_graylog_config \
        || fatal "$L_E_GL_CONF"

    if [[ ${VAL[firewall]} == oui ]]; then
        INFO_MODE="apt"
        step_run "$L_S_FIREWALL" 58 66 - \
            do_firewall \
            || fatal "$L_E_FIREWALL"
        FW_PORTS=$(cat "$FW_PORTS_FILE" 2>/dev/null)
        log_line "Ports ouverts par l'installation : ${FW_PORTS:-aucun}"
    else
        PCT=66; STEP_LABEL="$L_S_FIREWALL_SKIP"; anim_tick
    fi

    step_run "$L_S_GL_START" 66 72 - \
        do_graylog_start \
        || fatal "$L_E_GL_START"

    WAIT_T0=$SECONDS; WAIT_MAX=$GL_WAIT_MAX
    step_run "$L_S_GL_WAIT" 72 96 probe_wait \
        do_wait_graylog \
        || fatal "$L_E_GL_START"

    step_run "$L_S_CLEANUP" 96 100 - do_cleanup

    STEP_LABEL="$L_S_DONE"
    PCT=100
    anim_tick
    sleep 0.6
}

#==============================================================================
#  17. ECRAN FINAL
#==============================================================================

declare -a RC_TXT RC_COL
RECAP=""

# rc_add <couleur: ok | warn | err | title | muted | (vide)> <texte>
rc_add() { RC_COL+=("$1"); RC_TXT+=("$2"); }

svc_word() {
    if svc_healthy "$1"; then
        printf '%s' "$L_T_UP"
    else
        printf '%s' "$L_T_DOWN"; return 1
    fi
}

# Le preflight est servi en http tant qu'aucun certificat n'est pose : on
# verifie plutot que de le supposer.
web_scheme() {
    local host=$BIND_ADDR
    [[ $host == 0.0.0.0 ]] && host="127.0.0.1"
    if curl -s -o /dev/null -m 5 "http://$host:$HTTP_PORT/" 2>/dev/null; then
        printf 'http'
    elif curl -sk -o /dev/null -m 5 "https://$host:$HTTP_PORT/" 2>/dev/null; then
        printf 'https'
    else
        printf 'http'
    fi
}

build_recap() {
    local state="" pf_user="" pf_pass="" host url shown l
    {
        IFS= read -r state
        IFS= read -r pf_user
        IFS= read -r pf_pass
    } <"$PREFLIGHT_FILE" 2>/dev/null

    host=$BIND_ADDR
    [[ $host == 0.0.0.0 ]] && host=$MI_IP
    url="$(web_scheme)://$host:$HTTP_PORT/"

    # un mot de passe saisi a la main n'est ni reaffiche ni ecrit sur le disque
    shown=$ADMIN_PASS
    [[ ${VAL[admin_auto]} == oui ]] || shown=$L_FINAL_TYPED
    RC_TXT=(); RC_COL=()
    # pas d'annonce de succes tant que Graylog n'a pas repondu
    if [[ $state == preflight || $state == running ]]; then
        rc_add ok "$L_FINAL_DONE"
        rc_add "" ""
    fi
    case $state in
        preflight)
            rc_add title "$L_FINAL_STEP1"
            rc_add "" "$(printf '   %-12s : %s' "$L_FINAL_URL" "$url")"
            rc_add "" "$(printf '   %-12s : %s / %s  %s' "$L_FINAL_CRED" "$pf_user" "$pf_pass" "$L_FINAL_TEMP")"
            rc_add muted "   $L_FINAL_PF_HELP1"
            rc_add muted "   $L_FINAL_PF_HELP2"
            rc_add "" ""
            rc_add title "$L_FINAL_STEP2"
            rc_add "" "$(printf '   %-12s : %s' "$L_FINAL_URL" "$url")"
            rc_add "" "$(printf '   %-12s : admin / %s' "$L_FINAL_CRED" "$shown")"
            rc_add "" ""
            rc_add warn "$L_FINAL_WARN"
            ;;
        running)
            rc_add title "$L_FINAL_LOGIN"
            rc_add "" "$(printf '   %-12s : %s' "$L_FINAL_URL" "$url")"
            rc_add "" "$(printf '   %-12s : admin / %s' "$L_FINAL_CRED" "$shown")"
            ;;
        *)
            rc_add warn "$L_FINAL_TIMEOUT1"
            rc_add warn "$(printf "$L_FINAL_TIMEOUT2" "$GL_LOG")"
            rc_add "" ""
            rc_add title "$L_FINAL_LOGIN"
            rc_add "" "$(printf '   %-12s : %s' "$L_FINAL_URL" "$url")"
            rc_add "" "$(printf '   %-12s : admin / %s' "$L_FINAL_CRED" "$shown")"
            ;;
    esac
    rc_add "" ""

    if [[ ${VAL[tests]} == oui ]]; then
        local ok=1 m d g
        m=$(svc_word mongod.service) || ok=0
        d=$(svc_word graylog-datanode.service) || ok=0
        g=$(svc_word graylog-server.service) || ok=0
        l=$(printf '%-12s : MongoDB %s, Data Node %s, Graylog %s' "$L_FINAL_SERVICES" "$m" "$d" "$g")
        if (( ok )); then rc_add ok "$l"; else rc_add err "$l"; fi
    fi
    if [[ ${VAL[firewall]} == oui ]]; then
        rc_add "" "$(printf '%-12s : ' "$L_FINAL_FW")$(printf "$L_FINAL_FW_OPEN" "${FW_PORTS:--}")"
        [[ -z $FW_INPUTS ]] && rc_add muted "$L_FINAL_FW_HINT"
    fi
    rc_add "" "$(printf '%-12s : %s' "$L_FINAL_CREDFILE" "$CRED_FILE")"
    rc_add "" "$(printf '%-12s : %s' "$L_FINAL_LOG" "$LOGFILE")"

    RECAP=$(printf '%s\n' "${RC_TXT[@]}")
}

# Les identifiants sont gardes dans un fichier lisible par root seul : le
# mot de passe temporaire du preflight ne s'affiche qu'une fois dans le
# journal de Graylog, et le mot de passe admin genere nulle part ailleurs.
save_credentials() {
    ( umask 077; printf '%s\n' "$RECAP" >"$CRED_FILE" ) 2>/dev/null
    chmod 600 "$CRED_FILE" 2>/dev/null
}

final_screen() {
    build_recap
    save_credentials

    compute_layout
    BUF=$'\e[2J'
    local w=$(( COLS - 8 ))
    (( w > 78 )) && w=78
    local -a lines=("${RC_TXT[@]}") cols=("${RC_COL[@]}")
    local i
    # ecran trop court : on supprime d'abord les lignes vides plutot que de
    # tronquer la fin du recapitulatif
    if (( ${#lines[@]} + 4 > ROWS - 2 )); then
        local -a cl=() cc=()
        for (( i = 0; i < ${#lines[@]}; i++ )); do
            [[ -n ${lines[i]} ]] && { cl+=("${lines[i]}"); cc+=("${cols[i]}"); }
        done
        lines=("${cl[@]}"); cols=("${cc[@]}")
    fi
    local h=$(( ${#lines[@]} + 4 ))
    (( h > ROWS - 2 )) && h=$(( ROWS - 2 ))
    local y=$(( (ROWS - h) / 2 )) x=$(( (COLS - w) / 2 ))
    (( y < 1 )) && y=1
    (( x < 1 )) && x=1
    draw_box "$y" "$x" "$h" "$w" "$L_FINAL_T" "$C_FRAME_ON"
    local c
    for (( i = 0; i < ${#lines[@]} && i < h - 4; i++ )); do
        case ${cols[i]} in
            ok)    c=$C_OK ;;
            warn)  c=$C_WARN ;;
            err)   c=$C_ERR ;;
            title) c="${C_BOLD}${C_TITLE}" ;;
            muted) c=$C_MUTED ;;
            *)     c=$C_VALUE ;;
        esac
        pad_str "${lines[i]}" $(( w - 4 ))
        put $(( y + 1 + i )) $(( x + 2 )) "${c}${PAD}${C_RESET}"
    done
    pad_str "$L_ANY_KEY_QUIT" $(( w - 4 ))
    put $(( y + h - 2 )) $(( x + 2 )) "${C_MUTED}${PAD}${C_RESET}"
    printf '%s' "$BUF"
    wait_key
}

#==============================================================================
#  18. VERIFICATIONS PREALABLES
#==============================================================================

usage() {
    cat <<EOF
GRAYLOG AUTO v$SCRIPT_VERSION - Graylog $GRAYLOG_SERIES sur Debian 13

Usage : sudo bash $0

  -h, --help       affiche cette aide / show this help
  -V, --version    affiche la version / show the version

Variables d'environnement / Environment variables :
  GRAYLOG_LANG=fr|en           langue de l'interface / interface language
  GRAYLOG_THEME=dark|light     theme de couleurs / color theme
EOF
}

precheck() {
    if [[ $EUID -ne 0 ]]; then
        printf '%s\n' "Ce script doit etre execute en tant que root (su -) ou avec sudo." >&2
        printf '%s\n' "This script must be run as root (su -) or with sudo." >&2
        exit 1
    fi
    if [[ ! -t 0 || ! -t 1 ]]; then
        printf '%s\n' "Ce script necessite un terminal interactif." >&2
        printf '%s\n' "This script requires an interactive terminal." >&2
        exit 1
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        printf '%s\n' "Systeme non supporte : apt-get est introuvable (Debian 13 attendu)." >&2
        printf '%s\n' "Unsupported system: apt-get not found (Debian 13 expected)." >&2
        exit 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        printf '%s\n' "Systeme non supporte : systemd est requis par MongoDB et Graylog." >&2
        printf '%s\n' "Unsupported system: systemd is required by MongoDB and Graylog." >&2
        exit 1
    fi
    touch "$LOGFILE" 2>/dev/null || LOGFILE="/tmp/graylog-install.log"
}

make_workdir() {
    WORKDIR=$(mktemp -d /tmp/graylog-install.XXXXXX) || {
        printf '%s\n' "Impossible de creer un repertoire de travail dans /tmp." >&2
        exit 1
    }
    chmod 700 "$WORKDIR"
    STEP_LOG="$WORKDIR/step.log"
    APT_STATUS="$WORKDIR/apt-status.log"
    FW_PORTS_FILE="$WORKDIR/fw-ports.txt"
    PREFLIGHT_FILE="$WORKDIR/preflight.txt"
    GL_OFFSET_FILE="$WORKDIR/gl-offset.txt"
    : >"$STEP_LOG"; : >"$APT_STATUS"; : >"$FW_PORTS_FILE"; : >"$PREFLIGHT_FILE"
}

check_internet() {
    if command -v wget >/dev/null 2>&1; then
        wget -q --spider --timeout=8 "$GRAYLOG_REPO_URL" && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSI --max-time 8 -o /dev/null "$GRAYLOG_REPO_URL" && return 0
    fi
    ( exec 3<>/dev/tcp/packages.graylog2.org/443 ) 2>/dev/null && return 0
    return 1
}

#==============================================================================
#  19. BOUCLE PRINCIPALE
#==============================================================================

cleanup() {
    tui_stop
    [[ -n $WORKDIR && -d $WORKDIR ]] && rm -rf "$WORKDIR"
}

confirm_install() {
    local extra="" busy=""
    if graylog_found; then
        extra="
$L_CONFIRM_EXISTS
"
    else
        # MongoDB ou un moteur de recherche deja present : leurs ports sont
        # ceux dont MongoDB et le Data Node ont besoin
        port_state 27017; MI_PMONGO=$PORT_TXT; MI_PMONGO_ST=$PORT_ST
        port_state 9200;  MI_POS=$PORT_TXT;    MI_POS_ST=$PORT_ST
        [[ $MI_PMONGO_ST == err ]] && busy="27017"
        [[ $MI_POS_ST == err ]] && busy="${busy:+$busy, }9200"
        [[ -n $busy ]] && extra="
$L_CONFIRM_PORTS
($busy)
"
    fi
    if (( ${#HW_SHORT[@]} > 0 )); then
        local causes="${HW_SHORT[*]}"
        extra+="
$L_CONFIRM_HW
(${causes// /, })
"
    fi
    modal_confirm "$L_CONFIRM_T" \
"$(printf "$L_CONFIRM_BODY" "$MONGODB_SERIES" "$GRAYLOG_SERIES")
$extra
$L_CONFIRM_ASK"
}

main_loop() {
    local n idx dead=0
    while :; do
        build_rows
        n=${#VR_TYPE[@]}
        (( SEL > n )) && SEL=$n
        (( SEL < 0 )) && SEL=0
        [[ ${VR_TYPE[$SEL]:-} == gap ]] && move_sel 1
        adjust_scroll
        render_main
        read_key
        (( RESIZED )) && { compute_layout; RESIZED=0; STATUS_MSG=""; STATUS_KIND="info"; dead=0; continue; }
        if [[ $KEY == "NONE" ]]; then
            # entree standard perdue (terminal ferme) : on evite la boucle folle
            dead=$(( dead + 1 ))
            (( dead > 200 )) && return 1
            continue
        fi
        dead=0
        STATUS_MSG=""
        STATUS_KIND="info"
        idx=${VR_IDX[$SEL]:--1}
        case $KEY in
            UP|"CHAR:k")   move_sel -1 ;;
            DOWN|"CHAR:j"|TAB) move_sel 1 ;;
            PGUP) SEL=$(( SEL - FORM_ROWS )); (( SEL < 0 )) && SEL=0 ;;
            PGDN) SEL=$(( SEL + FORM_ROWS )); (( SEL > n )) && SEL=$n ;;
            HOME) SEL=0 ;;
            END)  SEL=$n ;;
            LEFT|RIGHT|"CHAR:h"|"CHAR:l")
                if sel_is_button; then
                    :
                elif [[ ${VR_TYPE[$SEL]} == sec ]]; then
                    if [[ $KEY == LEFT || $KEY == "CHAR:h" ]]; then SEC_OPEN[idx]=0; else SEC_OPEN[idx]=1; fi
                elif [[ ${FLD_TYPE[$idx]} == bool ]]; then
                    toggle_bool "${FLD_KEY[$idx]}"
                elif [[ ${FLD_TYPE[$idx]} == list ]]; then
                    if [[ $KEY == LEFT || $KEY == "CHAR:h" ]]; then
                        cycle_list "${FLD_KEY[$idx]}" -1
                    else
                        cycle_list "${FLD_KEY[$idx]}" 1
                    fi
                fi
                ;;
            SPACE)
                if ! sel_is_button && [[ ${VR_TYPE[$SEL]} == fld && ${FLD_TYPE[$idx]} == bool ]]; then
                    toggle_bool "${FLD_KEY[$idx]}"
                elif ! sel_is_button && [[ ${VR_TYPE[$SEL]} == fld && ${FLD_TYPE[$idx]} == list ]]; then
                    cycle_list "${FLD_KEY[$idx]}" 1
                elif ! sel_is_button && [[ ${VR_TYPE[$SEL]} == sec ]]; then
                    SEC_OPEN[idx]=$(( 1 - SEC_OPEN[idx] ))
                fi
                ;;
            ENTER)
                if sel_is_button; then
                    if validate_form; then
                        confirm_install && return 0
                    else
                        modal_message "$L_FORM_INCOMPLETE_T" "$FERR" "$C_ERR"
                        select_field_row "$FKEY"
                    fi
                elif [[ ${VR_TYPE[$SEL]} == sec ]]; then
                    SEC_OPEN[idx]=$(( 1 - SEC_OPEN[idx] ))
                else
                    edit_field "$idx"
                    # le port web surveille par le panneau machine suit le champ
                    if [[ ${FLD_KEY[$idx]} == http_port ]]; then
                        port_state "$(web_port)"; MI_PWEB=$PORT_TXT; MI_PWEB_ST=$PORT_ST
                    fi
                fi
                ;;
            "CHAR:t"|"CHAR:T")
                toggle_theme
                if [[ $THEME == light ]]; then
                    STATUS_MSG="$L_ST_THEME_LIGHT"
                else
                    STATUS_MSG="$L_ST_THEME_DARK"
                fi
                STATUS_KIND="ok"
                ;;
            "CHAR:r"|"CHAR:R")
                STATUS_MSG="$L_ST_REFRESHING"
                STATUS_KIND="info"
                render_main
                collect_machine_info
                STATUS_MSG="$L_ST_REFRESHED"
                STATUS_KIND="ok"
                ;;
            "CHAR:q"|"CHAR:Q"|ESC)
                if modal_confirm "$L_QUIT_T" "$L_QUIT_ASK"; then
                    return 1
                fi
                ;;
        esac
    done
}

main() {
    case "${1:-}" in
        -h|--help)    usage; exit 0 ;;
        -V|--version) printf 'GRAYLOG AUTO v%s\n' "$SCRIPT_VERSION"; exit 0 ;;
    esac

    detect_os_release
    setup_locale
    setup_charset
    setup_colors
    precheck
    make_workdir
    load_tux

    trap cleanup EXIT
    trap 'cleanup; exit 130' INT TERM
    trap on_resize WINCH

    compute_layout
    tui_start

    # la couleur de fond est demandee une fois l'ecran alternatif actif :
    # une eventuelle reponse non consommee reste invisible pour l'utilisateur
    detect_theme
    setup_colors

    if ! select_language; then
        cleanup
        printf '%s\n' "Installation annulee. / Installation cancelled."
        exit 0
    fi
    load_strings

    collect_machine_info
    build_form

    if term_too_small; then
        render_main
        wait_key
        cleanup
        printf '%s\n' "$L_TOO_SMALL_CLI" >&2
        exit 1
    fi

    if ! arch_supported; then
        modal_message "$L_ARCH_T" "$(printf "$L_ARCH_BODY" "${OS_ARCH:-?}")" "$C_ERR"
    fi

    if ! os_supported; then
        modal_message "$L_OS_T" "$(printf "$L_OS_BODY" "$MI_OS")" "$C_WARN"
    fi

    if (( ${#HW_ISSUES[@]} > 0 )); then
        local hwcol=$C_WARN
        hw_is_critical && hwcol=$C_ERR
        modal_message "$L_HW_T" "$(hw_warning_text)" "$hwcol"
    fi

    if ! check_internet; then
        modal_message "$L_NET_T" "$L_NET_BODY" "$C_ERR"
    fi

    if ! main_loop; then
        cleanup
        printf '%s\n' "$L_CANCELLED"
        exit 0
    fi

    run_install
    final_screen

    cleanup
    trap - EXIT
    printf '%s\n' "$RECAP"
}

# "exit" sur la meme ligne : bash lit un script au fil de l'eau, il ne doit
# rien aller chercher apres main si le fichier est remplace pendant qu'il tourne.
main "$@"; exit $?
