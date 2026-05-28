# Pilote de Rétroéclairage HP RGB (hp-rgb-lighting) Documentation Technique Détaillée

Ce document fournit une description technique approfondie de l'architecture interne, des structures de données, des fonctions clés et des instructions d'utilisation du module complémentaire du noyau Linux `hp-rgb-lighting.c`. Ce pilote gère le rétroéclairage RGB par zone des claviers de PC portables HP Omen et Victus via l'interface ACPI/WMI.

---

## 1. Présentation et Architecture

Le module `hp-rgb-lighting` est un pilote complémentaire (companion driver) léger conçu spécifiquement pour piloter les fonctions de rétroéclairage RGB du clavier des ordinateurs portables HP Omen et Victus.

Choix de conception architecturale clés :
* **Coexistence par Conception (Coexistence by Design) :** Le pilote fonctionne en parfaite synergie avec le pilote standard du noyau `hp-wmi` (qui s'occupe de la gestion des profils thermiques, du hwmon, des touches de raccourci et du bouton de mode avion). Pour éviter tout conflit d'accès exclusif sur l'interface WMI, ce pilote **n'enregistre aucun** alias de périphérique WMI (`MODULE_ALIAS("wmi:...")`). Au lieu de cela, il exécute ses requêtes de manière dynamique à travers le GUID partagé de la BIOS HP.
* **Interface Sysfs dans l'Espace Utilisateur :** Le module crée un ensemble de fichiers virtuels dans le répertoire `/sys/devices/platform/hp-rgb-lighting/` permettant aux scripts système et aux utilitaires de l'espace utilisateur de lire et d'écrire l'état du rétroéclairage.
* **Gestion des Threads et de la Concurrence :** Tous les appels aux méthodes WMI sont synchronisés via des mutex de noyau (`hp_wmi_query_mutex` et `rgb_mutex`) afin de prévenir les collisions d'écritures simultanées dans l'interpréteur ACPI sous-jacent.

---

## 2. Constantes, Énumérations et Structures de Données

Voici l'explication détaillée des constantes, codes de commande et structures utilisés dans le module :

### A. WMI GUID
```c
#define HPWMI_BIOS_GUID "5FB7F034-2C63-45E9-BE91-3D44E2C707E4"
```
Le GUID unique requis pour communiquer avec l'interface BIOS propriétaire de HP. Il s'agit du canal de routage principal vers le micrologiciel ACPI.

### B. `enum hp_wmi_command` (Codes de Commandes Principaux de WMI)
Spécifie le type général de transaction demandée au BIOS HP :
* **`HPWMI_READ` (`0x01`) :** Déclenche une requête de lecture pour extraire des variables d'état du BIOS (ex : lecture de l'état du verrou Windows).
* **`HPWMI_WRITE` (`0x02`) :** Déclenche une requête d'écriture pour modifier des variables dans le BIOS.
* **`HPWMI_BACKLIGHT` (`0x20009`) :** Catégorie de commande spécifique dédiée à la lecture ou à l'écriture des couleurs de rétroéclairage.
* **`HPWMI_GAMING_KEY` (`0x2000B`) :** Commande dédiée à la configuration des fonctions de jeu, comme le verrouillage de la touche Windows (Win Lock).

### C. `enum hp_wmi_backlight_commandtype` (Sous-commandes de Rétroéclairage)
Sous-requêtes utilisées sous la commande principale `HPWMI_BACKLIGHT` pour spécifier les opérations de rétroéclairage :
* **`HPWMI_COLOR_GET_QUERY` (`0x02`) :** Récupère la table de mappage des couleurs active depuis le BIOS.
* **`HPWMI_COLOR_SET_QUERY` (`0x03`) :** Écrit la table de mappage de couleurs modifiée dans le BIOS pour appliquer de nouvelles teintes.
* **`HPWMI_BRIGHTNESS_GET_QUERY` (`0x04`) :** Lit l'état du commutateur principal (activé/désactivé) du rétroéclairage.
* **`HPWMI_BRIGHTNESS_SET_QUERY` (`0x05`) :** Modifie l'état du commutateur principal du rétroéclairage.

### D. Structures de Communication BIOS
L'organisation en mémoire des tampons (buffers) de données transmis et reçus via l'interface ACPI/WMI :

```c
struct bios_args {
  u32 signature;      // Signature de validation de sécurité. Doit être 0x55434553 (ASCII pour "SECU").
  u32 command;        // Code de commande principal (enum hp_wmi_command).
  u32 commandtype;    // Type de sous-commande/requête (enum hp_wmi_backlight_commandtype).
  u32 datasize;       // Taille exacte en octets des données copiées dans le tableau data[].
  u8 data[];          // Tableau de données d'entrée flexible et de longueur variable.
};
```

```c
struct bios_return {
  u32 sigpass;        // Code de validation de la signature retourné par le BIOS.
  u32 return_code;    // Code de retour : 0 pour un succès, valeur non nulle indiquant un code d'erreur du BIOS.
};
```

---

## 3. Fonctions Auxiliaires Clés

### `encode_outsize_for_pvsz`
```c
static inline int encode_outsize_for_pvsz(int outsize)
```
* **Objectif :** Associe la taille attendue du tampon de sortie (`outsize`) à l'ID de méthode ACPI approprié.
* **Fonctionnement :** L'interface WMI de HP utilise des méthodes ACPI virtuelles (numérotées de 1 à 5) en fonction de la taille du tampon nécessaire pour retourner la réponse.
* **Règles de retour :**
  - Retourne `-EINVAL` si `outsize > 4096`.
  - Retourne l'ID de méthode correspondant selon la taille : `> 1024` $\rightarrow$ 5, `> 128` $\rightarrow$ 4, `> 4` $\rightarrow$ 3, `> 0` $\rightarrow$ 2, `0` $\rightarrow$ 1.

### `hp_wmi_perform_query`
```c
static int hp_wmi_perform_query(int query, enum hp_wmi_command command, void *buffer, int insize, int outsize)
```
La fonction centrale du pilote qui sérialise et traite toutes les communications WMI/ACPI :
1. Fait appel à `encode_outsize_for_pvsz` pour trouver l'ID de méthode ACPI requis (`mid`).
2. Alloue dynamiquement de la mémoire pour la structure `struct bios_args` à l'aide de `kzalloc` avec la taille d'entrée nécessaire (en s'assurant d'un espace de remplissage minimum de 128 octets).
3. Renseigne la signature de sécurité `"SECU"` (`0x55434553`), les paramètres de commande, la taille des données d'entrée, puis copie la charge utile.
4. Verrouille le mutex `hp_wmi_query_mutex` pour forcer un traitement séquentiel exclusif au niveau du BIOS.
5. Invoque `wmi_evaluate_method` en fournissant le GUID du BIOS, l'ID de la méthode, les données d'entrée et la structure de sortie.
6. Valide que l'objet ACPI retourné est bien de type `ACPI_TYPE_BUFFER` et vérifie l'intégrité des limites mémoire.
7. Analyse `struct bios_return` afin de propager d'éventuelles erreurs matérielles renvoyées par le BIOS.
8. En cas de succès, copie les données de réponse vers le tampon de sortie (`buffer`) et libère les ressources noyau précédemment allouées.

---

## 4. Interface Sysfs (API Espace Utilisateur)

Une fois le pilote chargé, les interfaces de contrôle sont créées sous `/sys/devices/platform/hp-rgb-lighting/`. Afin de prévenir les accès concurrents et éviter les blocages, le mutex `rgb_mutex` protège l'ensemble des opérations d'écriture et de lecture.

### A. Zones RGB du Clavier (`zone0` à `zone7`)
Permet de contrôler indépendamment jusqu'à **8 zones de rétroéclairage** distinctes.
* **Droits d'accès :** Lecture et Écriture (`0644`).
* **Format des données :** Chaîne hexadécimale de 6 caractères en majuscules (format RGB 24 bits), ex : `"FF0000"` pour un rouge pur, `"0000FF"` pour du bleu.
* **Lecture (`zone_show`) :** Récupère la table de couleurs de 128 octets (`COLOR_TABLE_SIZE`) depuis le BIOS à l'aide de `HPWMI_COLOR_GET_QUERY`. Les données RGB débutent au **25ème octet de décalage (`COLOR_OFFSET`)**. Chaque zone occupe exactement 3 octets consécutifs (Rouge, Vert, Bleu). La fonction formate ces valeurs en une chaîne hexadécimale majuscule.
* **Écriture (`zone_store`) :** Analyse la chaîne hexadécimale fournie. Elle lit d'abord la table de couleurs active depuis le BIOS, met à jour les 3 octets de la zone correspondante (`tbl[25 + zone * 3 + 0/1/2]`), puis écrit à nouveau la table entière via `HPWMI_COLOR_SET_QUERY`.

### B. Commutateur Principal de Luminosité (`brightness`)
* **Droits d'accès :** Lecture et Écriture (RW).
* **Valeurs prises en charge :**
  - `1` : Allume complètement le rétroéclairage (code de contrôle `0xE4` transmis au BIOS).
  - `0` : Éteint complètement le rétroéclairage (code de contrôle `0x64` transmis au BIOS).
* **Lecture (`brightness_show`) :** Interroge le BIOS. Retourne `1` si le code d'état correspond à `0xE4`, sinon retourne `0`.
* **Écriture (`brightness_store`) :** Envoie la valeur `0xE4` au BIOS pour activer la lumière ou `0x64` pour l'éteindre.

### C. Verrouillage de la Touche Windows / Gaming Key (`win_lock`)
* **Droits d'accès :** Lecture et Écriture (RW).
* **Objectif :** Active ou désactive la fonction matérielle de verrouillage de la touche Windows pour éviter d'interrompre le jeu par un retour intempestif au bureau.
* **Valeurs prises en charge :**
  - `1` : Verrouille la touche Windows (envoie `0x01` au BIOS).
  - `0` : Déverrouille la touche Windows (envoie `0x00` au BIOS).

---

## 5. Cycle de Vie du Périphérique Plateforme

### A. Initialisation (`hp_rgb_lighting_init`)
Lors du chargement du module (via `insmod` ou `modprobe`) :
1. Vérifie si l'interface HP WMI BIOS est disponible sur le système à l'aide de `wmi_has_guid`. Si celle-ci n'est pas détectée, le chargement s'interrompt avec l'erreur `-ENODEV` (évite l'activation sur du matériel non HP).
2. Enregistre un périphérique plateforme virtuel nommé `"hp-rgb-lighting"` (`platform_device_register_simple`).
3. Crée et rattache les fichiers d'attributs sysfs (`zone0-7`, `brightness`, `win_lock`) au périphérique virtuel à l'aide de `sysfs_create_groups`.

### B. Nettoyage (`hp_rgb_lighting_exit`)
Lors du déchargement du module (via `rmmod`) :
1. Supprime de manière sécurisée les fichiers sysfs virtuels (`sysfs_remove_groups`).
2. Annule l'enregistrement du périphérique plateforme (`platform_device_unregister`), nettoyant ainsi la structure système du noyau.

---

## 6. Guide de Compilation, d'Installation et d'Utilisation

### Exemple de fichier `Makefile`
Créez un fichier nommé `Makefile` dans le répertoire contenant le code source avec le contenu suivant :

```makefile
obj-m += hp-rgb-lighting.o

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
```

### Instructions de Compilation et Chargement
Exécutez les commandes suivantes dans votre terminal pour compiler et charger le pilote :

```bash
# 1. Compile le module noyau (.ko)
make

# 2. Charge le pilote dans le noyau actif de Linux
sudo insmod hp-rgb-lighting.ko

# 3. Vérifie que le pilote s'est correctement enregistré dans les logs noyau
dmesg | grep hp-rgb-lighting
```

### Exemples d'Utilisation Pratiques en Ligne de Commande

```bash
# Inspecte les fichiers d'attributs sysfs créés
ls -lh /sys/devices/platform/hp-rgb-lighting/

# Active le rétroéclairage global du clavier
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/brightness

# Change la Zone 0 en Rouge
echo "FF0000" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone0

# Change la Zone 1 en Vert
echo "00FF00" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone1

# Active le verrouillage de la touche Windows (Gaming Lock)
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/win_lock

# Lit la couleur hexadécimale RGB configurée pour la Zone 0
cat /sys/devices/platform/hp-rgb-lighting/zone0
```
