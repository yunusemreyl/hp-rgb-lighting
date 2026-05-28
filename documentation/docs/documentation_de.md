# HP RGB-Beleuchtungstreiber (hp-rgb-lighting) Detaillierte Treiberdokumentation

Dieses Dokument bietet eine umfassende technische Beschreibung der internen Architektur, der Datenstrukturen, der Kernfunktionen sowie der Nutzungsrichtlinien des Linux-Kernel-Begleitmoduls `hp-rgb-lighting.c`. Dieser Treiber steuert die zonenbasierte RGB-Tastaturhintergrundbeleuchtung und zugehörige Attribute von HP Omen- und Victus-Notebooks über die ACPI/WMI-Schnittstelle.

---

## 1. Übersicht und Architektur

Das Modul `hp-rgb-lighting` ist ein leichtgewichtiger Begleittreiber (Companion Driver), der speziell für die Steuerung der RGB-Tastaturbeleuchtung von HP Omen- und Victus-Notebooks entwickelt wurde.

Wichtige architektonische Designentscheidungen:
* **Koexistenz durch Design (Coexistence by Design):** Der Treiber arbeitet nahtlos mit dem standardmäßigen Kernel-Treiber `hp-wmi` zusammen (welcher thermische Profile, Hardwareüberwachung, Lüftersteuerung, Hotkeys und RF-Kill verwaltet). Um Konflikte oder exklusive Belegungen zu vermeiden, registriert dieser Treiber **keinen** WMI-Alias (`MODULE_ALIAS("wmi:...")`). Stattdessen führt er WMI-Methodenaufrufe dynamisch über die gemeinsam genutzte HP-BIOS-GUID aus.
* **Sysfs-Schnittstelle im Userspace:** Das Modul stellt eine Reihe von virtuellen Dateien unter `/sys/devices/platform/hp-rgb-lighting/` zur Verfügung. Dies ermöglicht es Userspace-Anwendungen und benutzerdefinierten Steuerungs-Skripten, die Tastaturfarben und -zustände abzufragen und zu konfigurieren.
* **Threadsicherheit und Nebenläufigkeit:** Alle WMI-Methodenauswertungen sind durch Kernel-Mutex-Sperren (`hp_wmi_query_mutex` und `rgb_mutex`) synchronisiert, um gleichzeitige Schreibkollisionen im zugrunde liegenden ACPI-Interpreter zu verhindern.

---

## 2. Konstanten, Enumerationen und Datenstrukturen

Nachfolgend finden Sie eine detaillierte Erläuterung der wichtigsten Konstanten, Befehlscodes und Datenstrukturen des Treibers:

### A. WMI-GUID
```c
#define HPWMI_BIOS_GUID "5FB7F034-2C63-45E9-BE91-3D44E2C707E4"
```
Die eindeutige WMI-GUID für die Kommunikation mit der proprietären HP-BIOS-Schnittstelle. Dies ist der primäre Routing-Kanal zur ACPI-Firmware.

### B. `enum hp_wmi_command` (WMI-Hauptbefehlscodes)
Bestimmt die übergeordnete Transaktionsart für das HP-BIOS:
* **`HPWMI_READ` (`0x01`):** Initiiert eine Leseabfrage, um Zustandswerte aus dem BIOS abzurufen (z.B. den Status der Windows-Tastensperre).
* **`HPWMI_WRITE` (`0x02`):** Initiiert eine Schreibabfrage, um BIOS-Variablen und -Einstellungen zu ändern.
* **`HPWMI_BACKLIGHT` (`0x20009`):** Spezifische Befehlskategorie zur Steuerung von Farben und Mustern der Hintergrundbeleuchtung.
* **`HPWMI_GAMING_KEY` (`0x2000B`):** Befehl zur Konfiguration spezieller Gaming-Funktionen, wie z. B. der Windows-Tastensperre (Win Lock).

### C. `enum hp_wmi_backlight_commandtype` (Unterbefehle für die Beleuchtung)
Unterabfragen unter dem Hauptbefehl `HPWMI_BACKLIGHT` für präzise Beleuchtungsoperationen:
* **`HPWMI_COLOR_GET_QUERY` (`0x02`):** Ruft die vollständige Tabelle der aktuell aktiven Farbbelegungen aus dem BIOS ab.
* **`HPWMI_COLOR_SET_QUERY` (`0x03`):** Schreibt die modifizierte Farbtabelle zurück in das BIOS, um die neuen Farben auf der Hardware anzuwenden.
* **`HPWMI_BRIGHTNESS_GET_QUERY` (`0x04`):** Fragt den Hauptschalterzustand (Ein/Aus) der Hintergrundbeleuchtung ab.
* **`HPWMI_BRIGHTNESS_SET_QUERY` (`0x05`):** Konfiguriert den Hauptschalterzustand der Hintergrundbeleuchtung.

### D. BIOS-Kommunikationsstrukturen
Das Layout des Pufferspeichers (Buffer), der an die ACPI/WMI-Schnittstelle übergeben und von dieser empfangen wird:

```c
struct bios_args {
  u32 signature;      // Sicherheits-Signatur. Muss 0x55434553 (ASCII für "SECU") entsprechen.
  u32 command;        // Der Hauptbefehlscode (enum hp_wmi_command).
  u32 commandtype;    // Der Unterbefehls-/Abfragetyp (enum hp_wmi_backlight_commandtype).
  u32 datasize;       // Die exakte Größe der in das Feld data[] kopierten Nutzdaten in Bytes.
  u8 data[];          // Flexibles Datenfeld mit variabler Länge für die Eingabedaten.
};
```

```c
struct bios_return {
  u32 sigpass;        // Die vom BIOS zurückgegebene Signatur-Validierungsprüfung.
  u32 return_code;    // Ausführungsergebnis: 0 bei Erfolg, ein Wert ungleich Null signalisiert einen BIOS-Fehlercode.
};
```

---

## 3. Zentrale Hilfsfunktionen

### `encode_outsize_for_pvsz`
```c
static inline int encode_outsize_for_pvsz(int outsize)
```
* **Zweck:** Ordnet die erwartete Ausgabegröße (`outsize`) der passenden ACPI-Methoden-ID zu.
* **Prinzip:** Die HP-WMI-Schnittstelle nutzt unterschiedliche virtuelle ACPI-Methoden (Methoden-IDs 1 bis 5) abhängig von der Speichergröße, die für die Rückgabe der Antwort benötigt wird.
* **Rückgabewerte:**
  - Gibt `-EINVAL` zurück, falls `outsize > 4096` ist.
  - Gibt ansonsten die entsprechende Methoden-ID basierend auf der Größe zurück: `> 1024` $\rightarrow$ 5, `> 128` $\rightarrow$ 4, `> 4` $\rightarrow$ 3, `> 0` $\rightarrow$ 2, `0` $\rightarrow$ 1.

### `hp_wmi_perform_query`
```c
static int hp_wmi_perform_query(int query, enum hp_wmi_command command, void *buffer, int insize, int outsize)
```
Die zentrale Kommunikationsfunktion des Treibers, über die alle ACPI-WMI-Aufrufe serialisiert werden:
1. Ruft `encode_outsize_for_pvsz` auf, um die korrekte ACPI-Methoden-ID (`mid`) zu ermitteln.
2. Reserviert dynamisch Speicher für die Struktur `struct bios_args` mittels `kzalloc` (mindestens 128 Bytes).
3. Setzt die Sicherheits-Signatur `"SECU"` (`0x55434553`), die Befehlsparameter sowie die Eingabegröße und kopiert die Nutzdaten.
4. Sperrt den Mutex `hp_wmi_query_mutex`, um exklusive, serielle Zugriffe auf das BIOS sicherzustellen.
5. Ruft `wmi_evaluate_method` mit der BIOS-GUID, der Methoden-ID, den Eingabedaten und der Ausgabestruktur auf.
6. Überprüft, ob das zurückgegebene ACPI-Objekt vom Typ `ACPI_TYPE_BUFFER` ist, und führt Speichergrenzprüfungen durch.
7. Analysiert `struct bios_return`, um eventuelle Hardware-Fehlercodes des BIOS zu erkennen und zu propagieren.
8. Kopiert bei Erfolg die Antwortdaten in den Ausgabepuffer (`buffer`) und gibt den Kernel-Speicher wieder frei.

---

## 4. Sysfs-Schnittstelle (Die API im Userspace)

Nach dem Laden des Treibers wird die Steuerschnittstelle unter `/sys/devices/platform/hp-rgb-lighting/` erstellt. Alle Lese- und Schreiboperationen in den sysfs-Dateien werden durch den Mutex `rgb_mutex` geschützt, um Race-Conditions zu verhindern.

### A. Tastatur-RGB-Zonen (`zone0` bis `zone7`)
Ermöglicht die unabhängige Steuerung von bis zu **8 Tastaturzonen**.
* **Zugriffsrechte:** Lesen und Schreiben (`0644`).
* **Datenformat:** Ein 6-stelliger, in Großbuchstaben geschriebener hexadezimaler 24-Bit-RGB-Code (z.B. `"FF0000"` für reines Rot, `"0000FF"` für reines Blau).
* **Lesen (`zone_show`):** Ruft die 128 Bytes große Farbtabelle (`COLOR_TABLE_SIZE`) mittels `HPWMI_COLOR_GET_QUERY` aus dem BIOS ab. Die RGB-Farbdaten beginnen ab dem **Byte-Offset 25 (`COLOR_OFFSET`)**. Jede Zone belegt exakt 3 aufeinanderfolgende Bytes (Rot, Grün, Blau in dieser Reihenfolge). Die Funktion gibt diese Werte als hexadezimalen String aus.
* **Schreiben (`zone_store`):** Dekodiert den hexadezimalen Farbwert. Zuerst wird die aktuelle Farbtabelle aus dem BIOS eingelesen, die 3 Bytes der jeweiligen Zone werden angepasst (`tbl[25 + zone * 3 + 0/1/2]`), und schließlich wird die modifizierte Gesamttabelle über `HPWMI_COLOR_SET_QUERY` an das BIOS übertragen.

### B. Hauptschalter für die Helligkeit (`brightness`)
* **Zugriffsrechte:** Lesen und Schreiben (RW).
* **Unterstützte Werte:**
  - `1`: Schaltet die Tastaturhintergrundbeleuchtung vollständig ein (Steuerungscode `0xE4` wird an das BIOS gesendet).
  - `0`: Schaltet die Hintergrundbeleuchtung vollständig aus (Steuerungscode `0x64` wird an das BIOS gesendet).
* **Lesen (`brightness_show`):** Fragt den Beleuchtungszustand aus dem BIOS ab. Gibt `1` zurück, falls das Zustandsbyte `0xE4` entspricht, andernfalls `0`.
* **Schreiben (`brightness_store`):** Übergibt den Wert `0xE4` an das BIOS, um die Beleuchtung einzuschalten, oder `0x64`, um sie auszuschalten.

### C. Windows-Tastensperre / Gaming-Taste (`win_lock`)
* **Zugriffsrechte:** Lesen und Schreiben (RW).
* **Zweck:** Aktiviert oder deaktiviert die physische Sperrfunktion der Windows-Taste auf der Tastatur. Dies verhindert ungewollte Desktop-Wechsel während des Spielens.
* **Unterstützte Werte:**
  - `1`: Windows-Taste gesperrt (Steuerungscode `0x01` wird ans BIOS gesendet).
  - `0`: Windows-Taste entsperrt (Steuerungscode `0x00` wird ans BIOS gesendet).

---

## 5. Lebenszyklus des Plattformgeräts

### A. Initialisierung (`hp_rgb_lighting_init`)
Beim Laden des Kernel-Moduls (mittels `insmod` oder `modprobe`):
1. Prüft mit `wmi_has_guid`, ob die HP-WMI-BIOS-Schnittstelle im System vorhanden ist. Ist dies nicht der Fall, bricht das Laden mit `-ENODEV` ab (verhindert das Laden auf Nicht-HP-Hardware).
2. Registriert ein virtuelles Plattformgerät namens `"hp-rgb-lighting"` (`platform_device_register_simple`).
3. Erstellt die zugehörigen sysfs-Attributdateien (`zone0-7`, `brightness`, `win_lock`) über `sysfs_create_groups`.

### B. Entladen des Treibers (`hp_rgb_lighting_exit`)
Beim Entfernen des Kernel-Moduls (mittels `rmmod`):
1. Entfernt die virtuellen sysfs-Dateien (`sysfs_remove_groups`).
2. Meldet das Plattformgerät ab (`platform_device_unregister`), um die Kernel-Ressourcen sauber freizugeben.

---

## 6. Build-, Installations- und Testanleitung

### Beispiel-`Makefile`
Erstellen Sie eine Datei namens `Makefile` im selben Verzeichnis wie der Quelltext mit folgendem Inhalt:

```makefile
obj-m += hp-rgb-lighting.o

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
```

### Schritte zum Kompilieren und Laden
Führen Sie die folgenden Befehle im Terminal aus, um den Treiber zu übersetzen und zu laden:

```bash
# 1. Kompiliert das Kernel-Modul (.ko)
make

# 2. Lädt das übersetzte Modul in den laufenden Linux-Kernel
sudo insmod hp-rgb-lighting.ko

# 3. Überprüft die Systemprotokolle zur Bestätigung der Registrierung
dmesg | grep hp-rgb-lighting
```

### Praktische Befehlsbeispiele

```bash
# Überprüft die generierten Sysfs-Dateien
ls -lh /sys/devices/platform/hp-rgb-lighting/

# Schaltet die globale Hintergrundbeleuchtung der Tastatur ein
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/brightness

# Setzt die Zone 0 auf die Farbe Rot
echo "FF0000" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone0

# Setzt die Zone 1 auf die Farbe Grün
echo "00FF00" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone1

# Aktiviert die Windows-Tastensperre (Gaming Lock)
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/win_lock

# Liest die hexadezimale RGB-Farbe der Zone 0 aus
cat /sys/devices/platform/hp-rgb-lighting/zone0
```
